#!/usr/bin/env bash
# PRIVATE-fixture synthetic controls: no host, credentials or production test switches.
# Bound all FIFO cases; synchronized copies exercise the actual EXIT cleanup path.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TESTS_DIR/review-package-fixtures.sh"
BUILD="${PACKAGE_TEST_BUILDER:-$PK_ROOT/scripts/build-review-package.sh}"
STATUS=0; OUTPUT=""
P="$(mktemp -d)"; track_tmp "$P"; cd "$P" || exit 1
git init -q; git config user.name test; git config user.email test@example.invalid
printf '.prdkit/cache/\n' > .gitignore; printf 'base\n' > source.txt
git add -A; git commit -qm base || exit 1
BASE="$(git rev-parse HEAD)"; MAIN="$(git symbolic-ref --short HEAD)"
git update-ref "refs/remotes/origin/$MAIN" "$BASE"; git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$MAIN"
printf 'change\n' >> source.txt; git commit -qam change || exit 1
set -m # Each fixture job gets its own process group, including any blocked acquisition child.
stop_job() {
    case "$1" in ''|0|1|*[!0-9]*) return 1 ;; esac
    kill -TERM -- "-$1" 2>/dev/null || true
}
bounded() {
    local id="$1" dir="$P/.git/bounded-$1" job event=""
    mkdir "$dir"; mkfifo "$dir/events"; exec 8<> "$dir/events"
    (
        status=0
        bash "$BUILD" "$id" "$BASE" > "$dir/output" 2>&1 || status=$?
        printf '%s\n' "$status" > "$dir/status"
        printf 'done\n' >&8
    ) & job=$!
    if IFS= read -r -t 10 event <&8; then
        wait "$job" || true; STATUS="$(cat "$dir/status")"
    else
        stop_job "$job"; wait "$job" 2>/dev/null || true; STATUS=124
    fi
    OUTPUT="$(cat "$dir/output")"; exec 8>&-
}
incumbent_snapshot() {
    package_snapshot "$root/.allocation-lock"
    local d
    for d in "$root"/round-*; do [ ! -d "$d" ] || package_snapshot "$d"; done
}
prepare_copy() {
    copy="$P/.git/copy-$window"; sync="$P/.git/sync-$window"
    mkdir -p "$copy" "$sync"; cp "$(dirname "$BUILD")"/*.sh "$copy/"
    awk '
        function pause(label) {
            print "if [ \"${SAFETY_ROLE:-}\" = contender ] && [ \"$SAFETY_WINDOW\" = \"" label "\" ]; then"
            print "  trap '\''exit 143'\'' TERM"
            print "  printf \"%s\\n\" \"contender-" label "\" >&8"
            print "  IFS= read -r _release <&9"
            if (label=="ready") print "  SAFETY_WINDOW=failed"
            print "fi"
        }
        index($0, "ERROR: package allocation busy") { pause("failed"); refused++ }
        /^if ! \(set -C; : > "\$LOCK_PATH"\)/ || /^[[:space:]]*if ! mkdir "\$LOCK_CANDIDATE"/ {
            pause("ready"); claim++
        }
        /^[[:space:]]*LOCK_OWNED=true/ { pause("uncertain"); owned++ }
        /^# Claim the round directory atomically:/ {
            print "if [ \"${SAFETY_ROLE:-}\" = incumbent ]; then"
            print "  printf \"%s\\n\" incumbent-held >&8"
            print "  IFS= read -r _release <&7"
            print "fi"; held++
        }
        { print }
        index($0, "=\"$REVIEW_DIR/.allocation-lock\"") { pause("pre"); pre++ }
        END { if (pre!=1 || refused!=1 || claim!=1 || held!=1) exit 1 }
    ' "$BUILD" > "$copy/build-review-package.sh" || exit 1
    mkfifo "$sync/events" "$sync/incumbent-release" "$sync/contender-release"
    exec 7<> "$sync/incumbent-release"; exec 8<> "$sync/events"; exec 9<> "$sync/contender-release"
}
event_is() {
    local expected="$1" event=""
    if ! IFS= read -r -t 30 event <&8; then _no "timed out waiting for $expected"; return 1; fi
    assert_eq "$expected" "$event" 'controlled interruption window reached'
}
[ "$#" -gt 0 ] || set -- entries interruptions uncertain
for group in "$@"; do
    case "$group" in
        entries)
            n=0
            for kind in regular directory dangling null-link fifo fifo-link directory-link; do
                it "Pre-existing $kind is refused without opening or replacing it"
                n=$((n+1)); id="00$n-$kind"; root="$P/.prdkit/cache/evidence/$id/reviews"; mkdir -p "$root"
                leaf="$root/.allocation-lock"
                case "$kind" in
                    regular) printf 'incumbent\n' > "$leaf" ;;
                    directory) mkdir "$leaf"; printf 'incumbent\n' > "$leaf/claim" ;;
                    dangling) ln -s "$P/absent-target" "$leaf" ;;
                    null-link) ln -s /dev/null "$leaf" ;;
                    fifo) mkfifo "$leaf" ;;
                    fifo-link) mkfifo "$P/protected-fifo"; ln -s "$P/protected-fifo" "$leaf" ;;
                    directory-link) mkdir "$P/protected-directory"; ln -s "$P/protected-directory" "$leaf" ;;
                esac
                before="$(package_snapshot "$root")"
                bounded "$id"
                assert_eq 1 "$STATUS" "nonblocking busy refusal for $kind: $OUTPUT"
                assert_eq "$before" "$(package_snapshot "$root")" 'exact entry identity/type/target/bytes and prior artifacts retained'
                assert_eq absent "$([ -e "$root/round-1" ] && echo present || echo absent)" 'no comparison/allocation without ownership'
            done ;;
        interruptions)
            for window in pre failed; do
                it "Interrupted $window contender cannot remove an active incumbent"
                prepare_copy
                id="010-$window"; root="$P/.prdkit/cache/evidence/$id/reviews"
                mkdir -p "$root/round-7"; printf 'prior failure\n' > "$root/round-7/report.txt"
                if [ "$window" = failed ]; then
                    SAFETY_ROLE=contender SAFETY_WINDOW=ready bash "$copy/build-review-package.sh" "$id" "$BASE" > "$sync/contender.out" 2> "$sync/contender.err" & contender=$!
                    event_is contender-ready || { stop_job "$contender"; exit 1; }
                fi
                SAFETY_ROLE=incumbent SAFETY_WINDOW="$window" bash "$copy/build-review-package.sh" "$id" "$BASE" > "$sync/incumbent.out" 2> "$sync/incumbent.err" & incumbent=$!
                event_is incumbent-held || { stop_job "$incumbent"; exit 1; }
                if [ "$window" = pre ]; then
                    SAFETY_ROLE=contender SAFETY_WINDOW=pre bash "$copy/build-review-package.sh" "$id" "$BASE" > "$sync/contender.out" 2> "$sync/contender.err" & contender=$!
                    event_is contender-pre || { stop_job "$contender"; stop_job "$incumbent"; exit 1; }
                else
                    # Switch the private copy window after the pre-acquisition pause, within
                    # the same contender process, so its actual refused branch is interrupted.
                    printf 'continue\n' >&9
                    event_is contender-failed || { stop_job "$contender"; stop_job "$incumbent"; exit 1; }
                fi
                before="$(incumbent_snapshot)"
                stop_job "$contender"; status=0; wait "$contender" 2>/dev/null || status=$?
                assert_eq 143 "$status" 'contender terminates through EXIT cleanup'
                assert_eq "$before" "$(incumbent_snapshot)" 'incumbent claim/inode and artifacts remain while active'
                kill -0 "$incumbent" 2>/dev/null
                assert_eq 0 "$?" 'incumbent remains active'
                printf 'continue\n' >&7
                status=0; wait "$incumbent" || status=$?
                assert_eq 0 "$status" "incumbent still completes: $(cat "$sync/incumbent.err")"
                exec 7>&-; exec 8>&-; exec 9>&-
            done ;;
        uncertain)
            it "Interrupted unconfirmed own claim remains stale rather than being reclaimed"
            window=uncertain; prepare_copy
            id=011-uncertain; root="$P/.prdkit/cache/evidence/$id/reviews"
            SAFETY_ROLE=contender SAFETY_WINDOW=uncertain bash "$copy/build-review-package.sh" "$id" "$BASE" > "$sync/contender.out" 2> "$sync/contender.err" & contender=$!
            event_is contender-uncertain || { stop_job "$contender"; exit 1; }
            before="$(package_snapshot "$root/.allocation-lock")"
            stop_job "$contender"; status=0; wait "$contender" 2>/dev/null || status=$?
            assert_eq 143 "$status" 'uncertain acquisition interrupted'
            assert_eq "$before" "$(package_snapshot "$root/.allocation-lock")" 'unconfirmed shared claim left for reconciliation'
            bounded "$id"
            assert_eq 1 "$STATUS" 'stale claim is not automatically retried/reclaimed'
            assert_eq "$before" "$(package_snapshot "$root/.allocation-lock")" 'stale exact entry retained'
            exec 7>&-; exec 8>&-; exec 9>&- ;;
        *) echo "unknown group: $group" >&2; exit 2 ;;
    esac
done
set +m
finish
