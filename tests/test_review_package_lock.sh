#!/usr/bin/env bash
# Force overlap after comparison/before allocation. All instrumentation/mutation is confined
# to private fixture copies; there is NO production lock-bypass or scheduling switch.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
P="$(mktemp -d)"; track_tmp "$P"; cd "$P"
git init -q; git config user.name test; git config user.email test@example.invalid
printf '.prdkit/cache/\n' > .gitignore
printf 'base\n' > source.txt; git add -A; git commit -qm base
BASE="$(git rev-parse HEAD)"; MAIN="$(git symbolic-ref --short HEAD)"
git update-ref "refs/remotes/origin/$MAIN" "$BASE"; git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$MAIN"
printf 'change\n' >> source.txt; git commit -qam change

for mutation in 0 1; do
    it "Forced overlap with private lock mutation=$mutation"
    copy="$P/.git/lock-copy-$mutation"; sync="$P/.git/barrier-$mutation"
    mkdir -p "$copy" "$sync"
    cp "$PK_ROOT"/scripts/*.sh "$copy/"
    awk -v mutate="$mutation" '
        $0=="if ! acquire_review_lock; then" && mutate { print "if false; then"; acquire++; next }
        /^# Claim the round directory atomically:/ {
            print "printf \"%s\\n\" \"$CALLER-compared\" >&8"
            print "IFS= read -r _release < \"$SYNC_DIR/$CALLER.release\""
            hook++
        }
        { print }
        END { if (hook!=1 || (mutate && acquire!=1)) exit 1 }
    ' "$PK_ROOT/scripts/build-review-package.sh" > "$copy/build-review-package.sh"
    mkfifo "$sync/events" "$sync/one.release" "$sync/two.release"
    exec 8<> "$sync/events"
    id="00$((mutation+1))-overlap"
    launch() {
        local caller="$1" status=0
        CALLER="$caller" SYNC_DIR="$sync" bash "$copy/build-review-package.sh" "$id" "$BASE" > "$sync/$caller.out" 2> "$sync/$caller.err" || status=$?
        printf '%s\n' "$status" > "$sync/$caller.status"
        printf '%s-exit:%s\n' "$caller" "$status" >&8
    }
    launch one & first=$!
    event=""
    IFS= read -r -t 60 event <&8 || { kill "$first" 2>/dev/null || true; _no 'first comparison barrier timed out'; exit 1; }
    assert_eq one-compared "$event" 'first request is held inside comparison/allocation critical section'
    launch two & second=$!
    IFS= read -r -t 60 event <&8 || { kill "$first" "$second" 2>/dev/null || true; _no 'overlap event timed out'; exit 1; }
    printf 'release\n' > "$sync/one.release"
    wait "$first"
    # In the mutant BOTH requests have already compared the same prior state. Stage the
    # filesystem claims after that forced overlap: even a perfectly atomic mkdir cannot
    # repair the stale second comparison. This is not a scheduler-dependent race test.
    if [ "$event" = two-compared ]; then printf 'release\n' > "$sync/two.release"; fi
    wait "$second"
    exec 8>&-
    root="$P/.prdkit/cache/evidence/$id/reviews"
    if [ "$(cat "$sync/one.status")" != 0 ]; then
        printf 'Private copy mutation=%s failure evidence:\n' "$mutation"
        cat "$sync/one.err" "$sync/two.err" "$sync/one.out" "$sync/two.out"
        find "$root" -name manifest.tsv -type f -exec cat {} \;
    fi
    assert_eq 0 "$(cat "$sync/one.status")" 'first request completed'
    if [ "$mutation" = 0 ]; then
        assert_eq two-exit:1 "$event" 'forced concurrent second request is refused, not serialized by chance'
        assert_eq 1 "$(cat "$sync/two.status")" 'lock refusal is nonzero'
        assert_file "$root/round-1/completed.tsv" 'one completed package'
        assert_eq absent "$([ -e "$root/round-2" ] && echo present || echo absent)" 'no duplicate allocation'
    else
        assert_eq two-compared "$event" 'negative control reaches comparison concurrently without lock'
        assert_eq 0 "$(cat "$sync/two.status")" 'negative control also completes'
        assert_file "$root/round-1/completed.tsv" 'negative control first completion'
        assert_file "$root/round-2/completed.tsv" 'negative control demonstrates duplicate allocation'
    fi
done

it "Final artifact integrity rejects post-inventory mutation in a private copy"
copy="$P/.git/integrity-copy"; mkdir "$copy"
cp "$PK_ROOT"/scripts/*.sh "$copy/"
awk '
    /^# Validate final artifacts/ { print "printf tampered >> \"$PACKAGE_DIR/diff.patch\""; n++ }
    { print }
    END { if (n!=1) exit 1 }
' "$PK_ROOT/scripts/build-review-package.sh" > "$copy/build-review-package.sh"
STATUS=0; OUTPUT=""
run bash "$copy/build-review-package.sh" 003-integrity "$BASE"
assert_eq 1 "$STATUS" 'post-inventory mutation cannot complete a package'
assert_contains "$OUTPUT" 'final artifact integrity failed for diff.patch' 'integrity mismatch is explicit'
assert_eq absent "$([ -e "$P/.prdkit/cache/evidence/003-integrity/reviews/round-1/completed.tsv" ] && echo present || echo absent)" 'failed assembly never gets a completion binding'

it "Existing lock files, legacy directories and symlinks are never reclaimed"
for kind in file directory symlink; do
    id="004-$kind"; root="$P/.prdkit/cache/evidence/$id/reviews"; mkdir -p "$root"
    case "$kind" in
        file) printf 'another request\n' > "$root/.allocation-lock" ;;
        directory) mkdir "$root/.allocation-lock" ;;
        symlink) printf 'protected\n' > "$P/protected"; ln -s "$P/protected" "$root/.allocation-lock" ;;
    esac
    run bash "$PK_ROOT/scripts/build-review-package.sh" "$id" "$BASE"
    assert_eq 1 "$STATUS" "existing $kind lock refuses"
    assert_contains "$OUTPUT" 'allocation busy' 'busy is explicit, not a new round'
    assert_eq absent "$([ -e "$root/round-1" ] && echo present || echo absent)" 'no artifact allocation'
    case "$kind" in
        file) assert_eq 'another request' "$(cat "$root/.allocation-lock")" 'other lock bytes untouched' ;;
        directory) assert_eq directory "$([ -d "$root/.allocation-lock" ] && echo directory)" 'legacy directory retained' ;;
        symlink) assert_eq protected "$(cat "$P/protected")" 'symlink target untouched' ;;
    esac
done
finish
