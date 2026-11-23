#!/usr/bin/env bash
# cleanup-change.sh removes finished change worktrees the safe way and clears
# the stale "prunable" registrations that otherwise strand a harness session
# trying to re-enter a worktree whose directory was deleted out of band. doctor
# detects those stale registrations read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TESTS_DIR/lib/states.sh"

generated_states cleanup "$PK_ROOT/scripts"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
CLEAN="$PROJ/.prdkit/scripts/bash/cleanup-change.sh"
cd "$PROJ" || exit 1

slot_for() (
    shopt -s nullglob
    local slots=("$1/.git/prdkit-retired/$2".*)
    [ "${#slots[@]}" -eq 1 ] && printf '%s\n' "${slots[0]}"
)
module_retained() { # id, expected commit, revision inside archived module
    local slot
    slot="$(slot_for "$PROJ2" "$1")"
    run git --git-dir="$slot/admin/modules/vendor/sub" --work-tree="$PROJ2" rev-parse "$3"
    assert_eq 0 "$STATUS" 'archived module resolves the commit'
    assert_eq "$2" "$OUTPUT" 'exact expected object recovered'
    run test ! -e "$PROJ2/.worktrees/$1"; assert_eq 0 "$STATUS" 'original checkout gone'
}
it "removes a clean change worktree and clears its registration"
git -C "$PROJ" worktree add -qb 010-clean "$PROJ/.worktrees/010-clean" >/dev/null 2>&1
run bash "$CLEAN" --json 010-clean
assert_eq 0 "$STATUS" "clean worktree removed"
assert_contains "$OUTPUT" '"result":"ok"' "reports success"
run test ! -d "$PROJ/.worktrees/010-clean"
assert_eq 0 "$STATUS" "worktree directory gone"
assert_not_contains "$(git -C "$PROJ" worktree list --porcelain)" "010-clean" "registration cleared"

it "refuses a worktree with uncommitted work unless --force"
git -C "$PROJ" worktree add -qb 011-dirty "$PROJ/.worktrees/011-dirty" >/dev/null 2>&1
echo "uncommitted" > "$PROJ/.worktrees/011-dirty/scratch.txt"
run bash "$CLEAN" 011-dirty
assert_eq 1 "$STATUS" "dirty worktree not removed"
assert_contains "$OUTPUT" "uncommitted or untracked changes" "explains the refusal"
run test -d "$PROJ/.worktrees/011-dirty"
assert_eq 0 "$STATUS" "dirty worktree left intact"

it "--force removes a worktree with uncommitted work"
run bash "$CLEAN" --force 011-dirty
assert_eq 0 "$STATUS" "force removes dirty worktree"
slot="$(slot_for "$PROJ" 011-dirty)"
assert_contains "$OUTPUT" "$slot" "force reports the quarantine slot"
assert_eq uncommitted "$(cat "$slot/checkout/scratch.txt")" "forced retirement keeps the exact untracked bytes"
run test ! -d "$PROJ/.worktrees/011-dirty"
assert_eq 0 "$STATUS" "dirty worktree gone after --force"

it "committed work is not checked for integration: it stays on the change's branch"
git -C "$PROJ" worktree add -qb 022-committed "$PROJ/.worktrees/022-committed" >/dev/null 2>&1
echo work > "$PROJ/.worktrees/022-committed/work.txt"
git -C "$PROJ/.worktrees/022-committed" add work.txt
git -C "$PROJ/.worktrees/022-committed" commit -qm 'unmerged work'
tip="$(git -C "$PROJ/.worktrees/022-committed" rev-parse HEAD)"
run bash "$CLEAN" 022-committed
assert_eq 0 "$STATUS" "a clean worktree with unmerged commits is removed"
assert_eq "$tip" "$(git -C "$PROJ" rev-parse --verify -q refs/heads/022-committed)" "branch and its commits kept"
slot="$(slot_for "$PROJ" 022-committed)"
git pack-refs --all
run git log "refs/prdkit-retired/${slot##*/}/HEAD"
assert_eq 0 "$STATUS" "documented named-branch inspection succeeds"
assert_contains "$OUTPUT" "$tip"

it "prunes the stale registration a manual rm -rf leaves behind"
git -C "$PROJ" worktree add -qb 012-stale "$PROJ/.worktrees/012-stale" >/dev/null 2>&1
rm -rf "$PROJ/.worktrees/012-stale"
assert_contains "$(git -C "$PROJ" worktree list --porcelain)" "012-stale" "stale entry present before prune"
run bash "$CLEAN" --json --prune
assert_eq 0 "$STATUS" "prune succeeds"
assert_contains "$OUTPUT" "012-stale" "prune names the cleared registration"
assert_not_contains "$(git -C "$PROJ" worktree list --porcelain)" "012-stale" "stale registration cleared"

it "batch prune preflights every candidate and reports earlier slots on a later runtime failure"
for suffix in a b; do
    path="$PROJ/.worktrees/114-batch-$suffix"
    git worktree add -q --detach "$path"
    rm -rf "$path"
done
last="$PROJ/.git/worktrees/114-batch-b"
: > "$last/index.lock"
run bash "$CLEAN" --json --prune
assert_eq 1 "$STATUS" "busy second candidate refused"
assert_file "$PROJ/.git/worktrees/114-batch-a/HEAD" "first registration was not modified"
rm "$last/index.lock"
batchshim="$(mktemp -d)"; track_tmp "$batchshim"
cat > "$batchshim/mv" <<'SH'
#!/bin/sh
test "$1" != "$LAST" || exit 1
exec "$REAL_MV" "$@"
SH
chmod +x "$batchshim/mv"
run env LAST="$last" REAL_MV="$(command -v mv)" PATH="$batchshim:$PATH" bash "$CLEAN" --json --prune
assert_eq 1 "$STATUS" "second move failed"
json="$(printf '%s\n' "$OUTPUT" | tail -1)"
assert_eq "$PROJ/.worktrees/114-batch-a" "$(jq -r '.paths[]' <<< "$json")" "names exactly the retired path"
assert_contains "$(jq -r .message <<< "$json")" "$(slot_for "$PROJ" 114-batch-a)" "JSON identifies its recovery slot"

it "force refuses unmerged index entries before either directory moves"
path="$PROJ/.worktrees/115-unmerged"
git worktree add -q --detach "$path"
oid="$(git -C "$path" rev-parse HEAD:.gitkeep)"
printf '100644 %s 2\tconflict\n' "$oid" | git -C "$path" update-index --index-info
run bash "$CLEAN" --force 115-unmerged
assert_eq 1 "$STATUS"
assert_file "$path/.git"; assert_file "$PROJ/.git/worktrees/115-unmerged/index"

it "an unborn worktree is refused before moving its staged file or registration"
path="$PROJ/.worktrees/120-unborn"
git worktree add -q --detach "$path"
git -C "$path" checkout -q --orphan unborn-120
echo staged > "$path/new"; git -C "$path" add new
run bash "$CLEAN" --force 120-unborn
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'no committed HEAD'
assert_file "$path/new"; assert_file "$PROJ/.git/worktrees/120-unborn/index"

it "retains the prior staged version recorded only in stash conflict undo"
path="$PROJ/.worktrees/121-undo"
git worktree add -q --detach "$path"
echo base > "$path/file"; git -C "$path" add file; git -C "$path" commit -qm base
echo stashed > "$path/file"; git -C "$path" stash push -q
echo 'only staged before conflict' > "$path/file"; git -C "$path" add file
prior="$(git -C "$path" rev-parse :file)"
run git -C "$path" stash apply
assert_eq 1 "$STATUS" "stash conflicts with the prior staged content"
echo resolved > "$path/file"; git -C "$path" add file
assert_contains "$(git -C "$path" ls-files --resolve-undo)" "$prior"
# Exercise the verifier alone: omit this class from *both* publications in a
# disposable copy. Presence in the object database must not count as retention.
mutant="${CLEAN%/*}/omit-undo.sh"
# shellcheck disable=SC2016 # Match literal source in the disposable copy.
sed '/cat "\$slot\/undo" >> "\$slot\/oids"/d; /--indexed-objects "\^\$tree" >> "\$slot\/oids"/d' "$CLEAN" > "$mutant"
run bash "$mutant" --force 121-undo
assert_eq 1 "$STATUS" "missing undo reachability refuses retirement"
failed_slot="$(slot_for "$PROJ" 121-undo)"
assert_contains "$OUTPUT" "$failed_slot"
assert_contains "$(cat "$failed_slot/missing")" "$prior"
holding="$PROJ/.git/worktrees/${failed_slot##*/}.retiring"
assert_file "$holding/locked" "failed verification stays registered and protected"
# Operator recovery, as documented. Both original names must be free.
original="$PROJ/.git/worktrees/121-undo"
if [ -d "$holding" ] && [ ! -e "$original" ] && [ ! -e "$path" ]; then
    mv "$holding" "$original" && mv "$failed_slot/checkout" "$path" && git worktree unlock "$path"
fi
run bash "$CLEAN" --force 121-undo
assert_eq 0 "$STATUS" "conflict undo retained: $OUTPUT"
git reflog expire --expire=now --all && git gc --prune=now -q
run git cat-file blob "$prior"
assert_eq 0 "$STATUS"; assert_eq 'only staged before conflict' "$OUTPUT"

it "ordinary GC after interruption at each cutover keeps aged HEAD and index contents"
cut="$(mktemp -d)"; track_tmp "$cut"
git -C "$cut" init -q
git -C "$cut" config user.name test; git -C "$cut" config user.email test@example.invalid
git -C "$cut" commit --allow-empty -qm initial
mkdir -p "$cut/.prdkit/scripts" "$cut/shim"
cp -R "${CLEAN%/*}" "$cut/.prdkit/scripts/bash"
cat > "$cut/shim/mv" <<'SH'
#!/bin/sh
case "$1:$2" in
    *"/checkout") boundary=checkout ;;
    *".retiring") boundary=holding ;;
    *"/admin") boundary=archive ;;
    *) exec "$REAL_MV" "$@" ;;
esac
interrupt() { echo "$1" > "$MARK"; kill -TERM "$PPID"; exit 1; }
[ "$POINT" != "before-$boundary" ] || interrupt "$POINT"
if [ "$POINT:$boundary" = after-holding:holding ] && [ -n "${CUT:-}" ]; then
    # The initial transaction is already durable. Neither new OID existed
    # when those refs were written; only the holding registration can root it.
    live() { git --git-dir="$admin" --work-tree="$CUT" "$@"; }
    admin="$1"
    late_tip=$(live commit-tree 'HEAD^{tree}' -p HEAD -m 'late detached commit') &&
        live update-ref HEAD "$late_tip" &&
        late_blob=$(echo 'late staged bytes' | live hash-object -w --stdin) &&
        live update-index --cacheinfo "100644,$late_blob,file" || exit 1
    for oid in "$late_tip" "$late_blob"; do
        pre=$(printf '%.2s' "$oid"); touch -t 200001010000 "$CUT/.git/objects/$pre/${oid#"$pre"}" || exit 1
    done
    printf '%s\n%s\n' "$late_tip" "$late_blob" > "$CUT/late-oids"
fi
"$REAL_MV" "$@" || exit 1
[ "$POINT" != "after-$boundary" ] || interrupt "$POINT"
SH
chmod +x "$cut/shim/mv"
for point in after-checkout before-holding after-holding before-archive after-archive; do
    id="124-$point"; path="$cut/.worktrees/$id"
    git -C "$cut" worktree add -q --detach "$path"
    git -C "$path" commit -q --allow-empty -m "$point"
    tip="$(git -C "$path" rev-parse HEAD)"
    echo "$point staged" > "$path/file"; git -C "$path" add file
    staged="$(git -C "$path" rev-parse :file)"; echo different > "$path/file"
    control="$(echo "unreferenced $point" | git -C "$cut" hash-object -w --stdin)"
    for oid in "$tip" "$staged" "$control"; do
        touch -t 200001010000 "$cut/.git/objects/${oid:0:2}/${oid:2}"
    done
    run env REAL_MV="$(command -v mv)" CUT="$cut" POINT="$point" MARK="$cut/mark" PATH="$cut/shim:$PATH" \
        bash "$cut/.prdkit/scripts/bash/cleanup-change.sh" --force "$id"
    assert_eq 1 "$STATUS"; assert_eq "$point" "$(cat "$cut/mark")" "retirement interrupted at $point"
    slot="$(slot_for "$cut" "$id")"; ns="refs/prdkit-retired/${slot##*/}"
    if [ "$point" = after-holding ]; then
        late_tip="$(sed -n '1p' "$cut/late-oids")"; late_blob="$(sed -n '2p' "$cut/late-oids")"
        run git -C "$cut" rev-list --objects --no-object-names --glob="$ns/before/*"
        assert_eq 0 "$STATUS"; assert_contains "$OUTPUT" "$tip"; assert_contains "$OUTPUT" "$staged"
        assert_not_contains "$OUTPUT" "$late_tip"; assert_not_contains "$OUTPUT" "$late_blob"
    fi
    run git -C "$cut" gc -q; assert_eq 0 "$STATUS" "default GC ran"
    run git -C "$cut" cat-file -e "$control"; assert_eq 1 "$STATUS" "unrooted old control collected"
    assert_eq "$tip" "$(git -C "$cut" rev-parse --verify "$tip^{commit}")"
    assert_eq "$point staged" "$(git -C "$cut" cat-file blob "$staged")"
    case "$point" in
        after-holding)
            assert_eq 'late detached commit' "$(git -C "$cut" log -1 --format=%s "$late_tip")"
            assert_eq 'late staged bytes' "$(git -C "$cut" cat-file blob "$late_blob")"
            holding="$cut/.git/worktrees/${slot##*/}.retiring"; original="$cut/.git/worktrees/$id"
            assert_file "$holding/locked"
            if [ ! -e "$original" ] && [ ! -L "$original" ] && [ ! -e "$path" ] && [ ! -L "$path" ]; then
                mv "$holding" "$original" && mv "$slot/checkout" "$path"
            fi
            run git -C "$path" status --short
            assert_eq 0 "$STATUS"; assert_contains "$OUTPUT" 'AM file'
            assert_eq 'late staged bytes' "$(git -C "$path" show :file)"
            assert_eq different "$(cat "$path/file")"
            if [ -d "$original/prdkit-cleanup.lock" ]; then rmdir "$original/prdkit-cleanup.lock"; fi
            run git -C "$cut" worktree unlock "$path"; assert_eq 0 "$STATUS" ;;
        after-archive)
            assert_file "$slot/admin/index"
            assert_not_contains "$(git -C "$cut" worktree list --porcelain)" "$path"
            run git -C "$cut" rev-parse --verify "$ns/HEAD^{commit}"
            assert_eq 0 "$STATUS"; assert_eq "$tip" "$OUTPUT"
            run git -C "$cut" rev-parse --verify "$ns/index^{tree}"
            assert_eq 0 "$STATUS"; assert_eq "$point staged" "$(git -C "$cut" show "$ns/index:file")"
            run test ! -e "$path"; assert_eq 0 "$STATUS" "completed slot left retired" ;;
    esac
done

it "recovers an interrupted stale prune through the locked admin alone"
id=126-stale-recovery; path="$cut/.worktrees/$id"
git -C "$cut" worktree add -q --detach "$path"
tip="$(git -C "$path" rev-parse HEAD)"
echo 'staged before checkout disappeared' > "$path/file"; git -C "$path" add file
staged="$(git -C "$path" rev-parse :file)"
original="$(git -C "$path" rev-parse --absolute-git-dir)"
rm -rf "$path"
run env REAL_MV="$(command -v mv)" CUT= POINT=after-holding MARK="$cut/stale-mark" PATH="$cut/shim:$PATH" \
    bash "$cut/.prdkit/scripts/bash/cleanup-change.sh" --prune
assert_eq 1 "$STATUS"; assert_eq after-holding "$(cat "$cut/stale-mark")"
slot="$(slot_for "$cut" "$id")"; holding="$cut/.git/worktrees/${slot##*/}.retiring"
assert_file "$holding/locked"
for absent in "$path" "$slot/checkout"; do
    run test ! -e "$absent"; assert_eq 0 "$STATUS"; run test ! -L "$absent"; assert_eq 0 "$STATUS"
done
test ! -e "$original" && test ! -L "$original" && mv "$holding" "$original"
assert_eq 0 "$?" 'only the admin restored'
run git --git-dir="$original" rev-parse --verify 'HEAD^{commit}'
assert_eq 0 "$STATUS"; assert_eq "$tip" "$OUTPUT"
run git --git-dir="$original" ls-files --stage
assert_eq 0 "$STATUS"; assert_contains "$OUTPUT" "$staged"
run git --git-dir="$original" show :file
assert_eq 0 "$STATUS"; assert_eq 'staged before checkout disappeared' "$OUTPUT"
assert_file "$original/locked"
run rmdir "$original/prdkit-cleanup.lock"; assert_eq 0 "$STATUS" 'only the empty cleanup lock removed'
run git -C "$cut" worktree unlock "$path"; assert_eq 0 "$STATUS"
run bash "$cut/.prdkit/scripts/bash/cleanup-change.sh" --prune
assert_eq 0 "$STATUS"; assert_not_contains "$(git -C "$cut" worktree list --porcelain)" "$path"

it "forced retirement preserves an intent-to-add placeholder and its different working bytes"
for format in sha1 sha256; do
    repo="$(mktemp -d)"; track_tmp "$repo"
    if [ "$format" = sha256 ]; then git init -q --object-format=sha256 "$repo" 2>/dev/null || continue
    else git init -q "$repo"; fi
    git -C "$repo" -c user.email=t@example.invalid -c user.name=test commit -qm init --allow-empty
    mkdir -p "$repo/.prdkit/scripts"; cp -R "${CLEAN%/*}" "$repo/.prdkit/scripts/bash"
    empty="$(git -C "$repo" hash-object --stdin </dev/null)"
    assert_not_contains "$(git -C "$repo" rev-list --objects --no-object-names --all)" "$empty" "history does not protect an empty blob"
    path="$repo/.worktrees/125-intent"; git -C "$repo" worktree add -q --detach "$path"
    printf 'not staged yet\n' > "$repo/expected"; cp "$repo/expected" "$path/pending"
    git -C "$path" add -N pending
    admin="$(git -C "$path" rev-parse --absolute-git-dir)"
    cp "$admin/index" "$repo/index-before"
    run bash "$repo/.prdkit/scripts/bash/cleanup-change.sh" --force 125-intent
    assert_eq 0 "$STATUS" "$format intent-to-add retirement succeeds: $OUTPUT"
    slot="$(slot_for "$repo" 125-intent)"; ns="refs/prdkit-retired/${slot##*/}"
    run git -C "$repo" gc --prune=now -q
    assert_eq 0 "$STATUS" "$format immediate GC succeeded"
    for namespace in "$ns/before" "$ns"; do
        assert_eq "$empty" "$(git -C "$repo" rev-parse --verify "$namespace/objects/$empty^{blob}")" "each phase roots the exact empty blob"
    done
    run cmp "$repo/index-before" "$slot/admin/index"; assert_eq 0 "$STATUS" "archived index is byte-identical"
    run cmp "$repo/expected" "$slot/checkout/pending"; assert_eq 0 "$STATUS" "working bytes intact"
done

it "removing an already-deleted worktree by id just prunes it"
git -C "$PROJ" worktree add -qb 013-gone "$PROJ/.worktrees/013-gone" >/dev/null 2>&1
rm -rf "$PROJ/.worktrees/013-gone"
run env CDPATH=.: bash "$CLEAN" 013-gone
assert_eq 0 "$STATUS" "already-gone worktree handled"
assert_contains "$OUTPUT" "already gone" "explains it only needed pruning"
assert_not_contains "$(git -C "$PROJ" worktree list --porcelain)" "013-gone" "registration cleared"

it "quarantines the index and HEAD even when a shared symbolic tag points back to the registration"
stale="$PROJ/.worktrees/105-stale-history"
git worktree add -q --detach "$stale"
git -C "$stale" commit -q --allow-empty -m detached
detached="$(git -C "$stale" rev-parse HEAD)"
oldest="$(git commit-tree 'HEAD^{tree}' -m old-only)"
oldlog="$(mktemp)"; track_tmp "$oldlog"
printf '%s %s Test <test@example.invalid> 1234567890 +0000\told-only endpoint\n' "$oldest" "$detached" > "$oldlog"
cp "$oldlog" "$(git -C "$stale" rev-parse --absolute-git-dir)/logs/HEAD"
git symbolic-ref refs/tags/indirect worktrees/105-stale-history/HEAD
assert_eq "$detached" "$(git rev-parse 'refs/tags/indirect^{commit}')" "tag resolves through the live registration"
printf 'index only\n' > "$stale/staged"; git -C "$stale" add staged
rm -rf "$stale"
run bash "$CLEAN" 105-stale-history
assert_eq 0 "$STATUS" "stale checkout retired"
assert_not_contains "$(git worktree list --porcelain)" "$stale"
slot="$(slot_for "$PROJ" 105-stale-history)"
assert_contains "$OUTPUT" "$slot" "reports the recovery location"
git symbolic-ref --delete refs/tags/indirect
git reflog expire --expire=now --all
git gc --prune=now -q
ns="refs/prdkit-retired/${slot##*/}"
run git log "$ns/HEAD"
assert_eq 0 "$STATUS" "detached commit resolves after GC of the original repository"
assert_contains "$OUTPUT" "$detached"
assert_eq "$oldest" "$(git rev-parse "$ns/objects/$oldest^{commit}")" "oldest old endpoint is a surviving ref"
run git show "$ns/index:staged"
assert_eq 0 "$STATUS" "index-only object survives"
assert_eq 'index only' "$OUTPUT"
run cmp "$oldlog" "$slot/admin/logs/HEAD"; assert_eq 0 "$STATUS" "reflog bytes intact"

it "the same recovery command uses the source ref backend and ignores transport filters"
table="$(make_inited_project)"; track_tmp "$table"
if git -C "$table" refs migrate --ref-format=reftable >/dev/null 2>&1; then
    git -C "$table" config uploadpack.hideRefs refs/heads
    unrelated="$(echo unrelated | git -C "$table" hash-object -w --stdin)"
    git -C "$table" update-ref --create-reflog refs/testing/common "$unrelated"
    for mode in named detached; do
        path="$table/.worktrees/106-table-$mode"
        flags=(-b "106-table-$mode"); [ "$mode" = named ] || flags=(--detach)
        git -C "$table" worktree add -q "${flags[@]}" "$path"
        git -C "$path" commit -q --allow-empty -m local
        expected="$(git -C "$path" rev-parse HEAD)"
        for value in first second; do
            endpoint="$(echo "$mode $value" | git -C "$path" hash-object -w --stdin)"
            git -C "$path" update-ref --create-reflog refs/worktree/logged "$endpoint"
            if [ "$value" = first ]; then oldest_blob="$endpoint"; fi
        done
        run bash "$table/.prdkit/scripts/bash/cleanup-change.sh" "106-table-$mode"
        assert_eq 0 "$STATUS" "retired $mode reftable: $OUTPUT"
        slot="$(slot_for "$table" "106-table-$mode")"
        git -C "$table" gc --prune=now -q
        run git -C "$table" log "refs/prdkit-retired/${slot##*/}/HEAD"
        assert_eq 0 "$STATUS" "documented inspection on reftable"
        assert_contains "$OUTPUT" "$expected"
        run git -C "$table" rev-list --objects --no-object-names --glob="refs/prdkit-retired/${slot##*/}/*"
        assert_eq 0 "$STATUS"; assert_not_contains "$OUTPUT" "$unrelated"
        assert_contains "$OUTPUT" "$oldest_blob"; assert_contains "$OUTPUT" "$endpoint"
        assert_eq "$mode first" "$(git -C "$table" cat-file blob "$oldest_blob")"
        assert_eq "$mode second" "$(git -C "$table" cat-file blob "$endpoint")"
    done
fi

it "a pre-commit writer finishing at cutover is retained or fails visibly"
hooks="$(mktemp -d)"; track_tmp "$hooks"
cat > "$hooks/pre-commit" <<'SH'
#!/bin/sh
: > "$SYNC/paused"
n=0; while [ ! -f "$SYNC/resume" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
test -f "$SYNC/resume"
SH
cat > "$hooks/mv" <<'SH'
#!/bin/sh
if [ "$1" = "$WRITER_ADMIN" ]; then
    # At the old snapshot-to-rename boundary, let this commit finish.
    : > "$SYNC/resume"
    n=0; while [ ! -f "$SYNC/finished" ] && [ "$n" -lt 100 ]; do sleep 0.1; n=$((n+1)); done
fi
exec "$REAL_MV" "$@"
SH
chmod +x "$hooks/pre-commit" "$hooks/mv"
writer="$PROJ/.worktrees/112-writer"
git worktree add -q --detach "$writer"
writer_admin="$(git -C "$writer" rev-parse --absolute-git-dir)"
(
    rc=0; SYNC="$hooks" git -C "$writer" -c core.hooksPath="$hooks" commit --allow-empty -qm 'in flight' || rc=$?
    echo "$rc" > "$hooks/finished"
) &
writer_pid=$!
for n in {1..100}; do [ ! -f "$hooks/paused" ] || break; sleep 0.1; done
assert_file "$hooks/paused" "real commit is paused"
run env SYNC="$hooks" WRITER_ADMIN="$writer_admin" REAL_MV="$(command -v mv)" PATH="$hooks:$PATH" bash "$CLEAN" 112-writer
if [ "$STATUS" -ne 0 ]; then
    # Some versions hold index.lock during the hook; refusing preflight is correct.
    assert_eq 1 "$STATUS"; assert_file "$writer_admin/HEAD" "busy registration unchanged"
    : > "$hooks/resume"; wait "$writer_pid"
    run bash "$CLEAN" 112-writer
else
    wait "$writer_pid"
fi
assert_eq 0 "$STATUS" "quiescent retirement completes"
if [ "$(cat "$hooks/finished")" = 0 ]; then
    slot="$(slot_for "$PROJ" 112-writer)"
    git reflog expire --expire=now --all; git gc --prune=now -q
    assert_eq 'in flight' "$(git log -1 --format=%s "refs/prdkit-retired/${slot##*/}/HEAD")" "successful concurrent commit is rooted"
fi
it "stale relative administration pointers can be matched without the missing checkout"
relative="$PROJ/.worktrees/106-relative"
git worktree add -qb 106-relative "$relative"
reladmin="$(git -C "$relative" rev-parse --absolute-git-dir)"
printf '../../../.worktrees/106-relative/.git\n' > "$reladmin/gitdir"
rm -rf "$relative"
# Older Git does not interpret relative registrations; exercise its ordinary path
# there, and the actual relative-pointer behavior on versions supporting it.
if git worktree list --porcelain | grep -Fqx "worktree $relative"; then
    run bash "$CLEAN" 106-relative
    assert_eq 0 "$STATUS" "Git's relative pointer resolves against its own admin directory"
    run test ! -e "$reladmin"; assert_eq 0 "$STATUS" "exact registration retired"
else
    printf '%s/.git\n' "$relative" > "$reladmin/gitdir"
    run bash "$CLEAN" 106-relative
    assert_eq 0 "$STATUS" "absolute fallback for older fixture Git"
fi

it "old Git supports plain worktrees and refuses ambiguous listings before removal"
legacy="$(mktemp -d)"; track_tmp "$legacy"
cat > "$legacy/git" <<'SH'
#!/bin/sh
case " $* " in *" worktree list --porcelain -z "*) exit 129 ;; esac
exec "$FIXTURE_GIT" "$@"
SH
chmod +x "$legacy/git"
git worktree add -qb 107-old-git "$PROJ/.worktrees/107-old-git"
run env FIXTURE_GIT="$(command -v git)" PATH="$legacy:$PATH" bash "$CLEAN" 107-old-git
assert_eq 0 "$STATUS" "ordinary cleanup works without porcelain -z"
git worktree add -qb 108-safe "$PROJ/.worktrees/108-safe"
odd="$PROJ/.worktrees/"$'two\nlines'
git worktree add -qb 109-odd "$odd"
run env FIXTURE_GIT="$(command -v git)" PATH="$legacy:$PATH" bash "$CLEAN" 108-safe
assert_eq 1 "$STATUS" "ambiguous legacy listing refuses even an unrelated target"
run test -d "$PROJ/.worktrees/108-safe"; assert_eq 0 "$STATUS" "nothing removed"
git worktree remove "$odd"

it "refuses to remove the worktree it is run from"
git -C "$PROJ" worktree add -qb 014-current "$PROJ/.worktrees/014-current" >/dev/null 2>&1
run bash -c 'cd "$2" && bash "$1" 014-current' _ "$CLEAN" "$PROJ/.worktrees/014-current"
assert_eq 1 "$STATUS" "refused from inside the worktree"
assert_contains "$OUTPUT" "currently inside" "tells the user to run from the main checkout"
run test -d "$PROJ/.worktrees/014-current"
assert_eq 0 "$STATUS" "current worktree left intact"
git -C "$PROJ" worktree remove --force "$PROJ/.worktrees/014-current" >/dev/null 2>&1 || true

it "review and check evidence in the worktree's ignored cache survives removal"
# The documented close -> merge -> cleanup sequence: the review package and retrospective live
# only in the worktree's gitignored cache, which `git worktree remove` would delete silently.
git -C "$PROJ" add -A >/dev/null 2>&1; git -C "$PROJ" commit -qm installed >/dev/null 2>&1  # .gitignore covers .prdkit/cache/
git -C "$PROJ" worktree add -qb 016-evidence "$PROJ/.worktrees/016-evidence" >/dev/null 2>&1
EV="$PROJ/.worktrees/016-evidence/.prdkit/cache"
mkdir -p "$EV/evidence/016-evidence/reviews/round-1" "$EV/retrospectives"
printf 'Verdict: PASS\n' > "$EV/evidence/016-evidence/reviews/round-1/report.md"
printf 'diff\n' > "$EV/evidence/016-evidence/reviews/round-1/package.diff"
printf 'lessons\n' > "$EV/retrospectives/016-evidence.md"
# Usage-enrichment input is gitignored too, so it is not dirt; it must not vanish with the worktree.
run bash "$CLEAN" --json 016-evidence
assert_eq 0 "$STATUS" "worktree removed"
assert_contains "$OUTPUT" "preserved 3 evidence file(s)" "preservation reported"
assert_eq "Verdict: PASS" "$(cat "$PROJ/.prdkit/cache/evidence/016-evidence/reviews/round-1/report.md" 2>/dev/null)" "review report kept"
assert_eq "lessons" "$(cat "$PROJ/.prdkit/cache/retrospectives/016-evidence.md" 2>/dev/null)" "retrospective kept"

it "linked evidence roots are refused for committed and forced checkouts"
outside_cache="$(mktemp -d)"; track_tmp "$outside_cache"
mkdir -p "$outside_cache/evidence"; echo fixture > "$outside_cache/evidence/fixture"
for mode in committed forced; do
    path="$PROJ/.worktrees/116-$mode"
    git worktree add -q --detach "$path"
    mkdir -p "$path/.prdkit"
    ln -s "$outside_cache" "$path/.prdkit/cache"
    args=(--force)
    if [ "$mode" = committed ]; then
        git -C "$path" add -f .prdkit/cache && git -C "$path" commit -qm fixture
        args=()
    fi
    run bash "$CLEAN" ${args[@]+"${args[@]}"} "116-$mode"
    assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" "could not preserve its evidence"
    assert_file "$path/.git"; run test ! -e "$PROJ/.prdkit/cache/evidence/fixture"; assert_eq 0 "$STATUS"
done
path="$PROJ/.worktrees/117-destination"
git worktree add -q --detach "$path"
mkdir -p "$path/.prdkit/cache/evidence/nested"
echo fixture > "$path/.prdkit/cache/evidence/nested/report"
ln -s "$outside_cache" "$PROJ/.prdkit/cache/evidence/nested"
run bash "$CLEAN" --force 117-destination
assert_eq 1 "$STATUS"; assert_file "$path/.git"
run test ! -e "$outside_cache/report"; assert_eq 0 "$STATUS"
rm "$PROJ/.prdkit/cache/evidence/nested"

it "every change's evidence survives removal; unsupported recovery paths block cleanup"
# new-change.sh run inside a worktree opens the next change there, so one worktree can hold
# several changes' evidence, and cleanup must not discard unsupported recovery data.
git -C "$PROJ" worktree add -qb 018-first "$PROJ/.worktrees/018-first" >/dev/null 2>&1
EV="$PROJ/.worktrees/018-first/.prdkit"
mkdir -p "$EV/cache/evidence/018-first" "$EV/cache/evidence/019-second" "$EV/ledger" "$PROJ/.prdkit/ledger"
printf 'first\n' > "$EV/cache/evidence/018-first/report.md"
printf 'second\n' > "$EV/cache/evidence/019-second/report.md"
printf '{"event":"a"}\n' > "$PROJ/.prdkit/ledger/events.jsonl"
printf '{"event":"a"}\n{"event":"b"}\n{"event":"c"}\n' > "$EV/ledger/events.jsonl"
run bash "$CLEAN" 019-second
assert_eq 1 "$STATUS" "no worktree named for the second change"
run bash "$CLEAN" 018-first --force
assert_eq 1 "$STATUS" "unsupported recovery data is not removed"
assert_contains "$OUTPUT" 'cleanup expects recovery copies in .prdkit/cache/evidence/'
assert_eq '{"event":"a"}' "$(cat "$PROJ/.prdkit/ledger/events.jsonl")" "main spool unchanged"
mv "$EV/ledger/events.jsonl" "$PROJ/.prdkit/ledger/archived.jsonl"
rmdir "$EV/ledger"
run bash "$CLEAN" 018-first
assert_eq 0 "$STATUS" "worktree removed"
assert_eq "first" "$(cat "$PROJ/.prdkit/cache/evidence/018-first/report.md" 2>/dev/null)" "its own evidence kept"
assert_eq "second" "$(cat "$PROJ/.prdkit/cache/evidence/019-second/report.md" 2>/dev/null)" "the other change's evidence kept"
it "an unsupported linked recovery path leaves the target unchanged"
git -C "$PROJ" worktree add -qb 021-spool "$PROJ/.worktrees/021-spool" >/dev/null 2>&1
mkdir -p "$PROJ/.worktrees/021-spool/.prdkit/ledger"
ln -s "$PROJ/.prdkit/ledger/archived.jsonl" "$PROJ/.worktrees/021-spool/.prdkit/ledger/events.jsonl"
run bash "$CLEAN" 021-spool --force
assert_eq 1 "$STATUS" "cleanup refuses a linked spool"
assert_eq '{"event":"a"}' "$(cat "$PROJ/.prdkit/ledger/events.jsonl")" "main spool unchanged"

it "a refused removal copies nothing; the worktree's own copy of the script refuses"
git -C "$PROJ" worktree add -qb 020-refused "$PROJ/.worktrees/020-refused" >/dev/null 2>&1
mkdir -p "$PROJ/.worktrees/020-refused/.prdkit/cache/evidence/020-refused"
printf 'kept\n' > "$PROJ/.worktrees/020-refused/.prdkit/cache/evidence/020-refused/out.txt"
echo "uncommitted" > "$PROJ/.worktrees/020-refused/scratch.txt"
run bash "$CLEAN" 020-refused
assert_eq 1 "$STATUS" "dirty worktree refused"
run test ! -e "$PROJ/.prdkit/cache/evidence/020-refused"
assert_eq 0 "$STATUS" "nothing copied before the refusal"
rm -f "$PROJ/.worktrees/020-refused/scratch.txt"
mkdir -p "$PROJ/.worktrees/020-refused/.prdkit/scripts/bash"
cp "$PROJ"/.prdkit/scripts/bash/*.sh "$PROJ/.worktrees/020-refused/.prdkit/scripts/bash/"
run bash -c 'cd "$1" && bash .worktrees/020-refused/.prdkit/scripts/bash/cleanup-change.sh 020-refused' _ "$PROJ"
assert_eq 1 "$STATUS" "the worktree's copy refuses"
assert_contains "$OUTPUT" "run the main checkout's" "names the right script"
run test -f "$PROJ/.worktrees/020-refused/.prdkit/cache/evidence/020-refused/out.txt"
assert_eq 0 "$STATUS" "evidence left intact"
git -C "$PROJ" worktree remove --force "$PROJ/.worktrees/020-refused" >/dev/null 2>&1 || true

it "a different file already in the main cache refuses the removal"
git -C "$PROJ" worktree add -qb 017-clash "$PROJ/.worktrees/017-clash" >/dev/null 2>&1
mkdir -p "$PROJ/.worktrees/017-clash/.prdkit/cache/evidence/017-clash" "$PROJ/.prdkit/cache/evidence/017-clash"
printf 'new\n' > "$PROJ/.worktrees/017-clash/.prdkit/cache/evidence/017-clash/out.txt"
printf 'old\n' > "$PROJ/.prdkit/cache/evidence/017-clash/out.txt"
run bash "$CLEAN" 017-clash
assert_eq 1 "$STATUS" "removal refused"
assert_contains "$OUTPUT" "could not preserve its evidence" "conflict explained"
run test -f "$PROJ/.worktrees/017-clash/.prdkit/cache/evidence/017-clash/out.txt"
assert_eq 0 "$STATUS" "worktree evidence left intact"
git -C "$PROJ" worktree remove --force "$PROJ/.worktrees/017-clash" >/dev/null 2>&1 || true

it "reports a clear error for an unknown change id"
run bash "$CLEAN" 999-nope
assert_eq 1 "$STATUS" "unknown id fails"
assert_contains "$OUTPUT" "No worktree found" "names the missing change"

it "doctor flags a stale worktree registration without pruning it"
git -C "$PROJ" worktree add -qb 015-doctor "$PROJ/.worktrees/015-doctor" >/dev/null 2>&1
rm -rf "$PROJ/.worktrees/015-doctor"
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh" --json
assert_contains "$OUTPUT" "Stale worktree registration" "stale worktree surfaced"
assert_contains "$OUTPUT" "cleanup-change.sh --prune" "names the repair"
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh" --strict
assert_eq 1 "$STATUS" "--strict fails while a stale worktree lingers"
assert_contains "$OUTPUT" "015-doctor" "names the stale path"
assert_contains "$(git -C "$PROJ" worktree list --porcelain)" "015-doctor" "doctor did not prune (read-only)"

# --- Submodules: git refuses to remove any worktree whose submodules are initialized -------------
# A local file-path submodule needs protocol.file.allow, which modern git denies by default.
PROJ2="$(make_inited_project)"; track_tmp "$PROJ2"
PROJ2="$(cd "$PROJ2" && pwd -P)"
CLEAN2="$PROJ2/.prdkit/scripts/bash/cleanup-change.sh"
SUBSRC="$(mktemp -d)"; track_tmp "$SUBSRC"
git -C "$SUBSRC" init -q
git -C "$SUBSRC" -c user.email=t@example.com -c user.name=test commit -q --allow-empty -m sub
git -C "$PROJ2" -c protocol.file.allow=always submodule add -q "$SUBSRC" vendor/sub >/dev/null 2>&1
git -C "$PROJ2" add -A >/dev/null 2>&1; git -C "$PROJ2" commit -qm 'add submodule' >/dev/null 2>&1
sub_worktree() { # change id: a worktree of PROJ2 with its submodule initialized
    git -C "$PROJ2" worktree add -qb "$1" "$PROJ2/.worktrees/$1" >/dev/null 2>&1
    git -C "$PROJ2/.worktrees/$1" -c protocol.file.allow=always submodule update --init -q >/dev/null 2>&1
}
sub_worktree 050-sub-control
run git -C "$PROJ2" worktree remove "$PROJ2/.worktrees/050-sub-control"
assert_contains "$OUTPUT" "submodules" "fixture: git itself refuses a clean worktree with initialized submodules"
git -C "$PROJ2" worktree remove --force "$PROJ2/.worktrees/050-sub-control" >/dev/null 2>&1

it "refuses a redirected module gitfile before asking Git for checkout status"
sub_worktree 118-layout
path="$PROJ2/.worktrees/118-layout"
observer="$(mktemp -d)"; track_tmp "$observer"
git -C "$SUBSRC" config core.fsmonitor "$observer/unused"
printf 'gitdir: %s/.git\n' "$SUBSRC" > "$path/vendor/sub/.git"
cat > "$observer/git" <<'SH'
#!/bin/sh
case " $* " in *" status "*) : > "$SEEN" ;; esac
exec "$FIXTURE_GIT" "$@"
SH
chmod +x "$observer/git"
run env PATH="$observer:$PATH" SEEN="$observer/status" FIXTURE_GIT="$(command -v git)" bash "$CLEAN2" 118-layout
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'unsupported submodule layout'
run test ! -e "$observer/status"; assert_eq 0 "$STATUS" 'no status before layout validation'
git -C "$SUBSRC" config --unset core.fsmonitor

it "a clean worktree in a repository with submodules is removed without --force, evidence preserved"
sub_worktree 051-sub-clean
mkdir -p "$PROJ2/.worktrees/051-sub-clean/.prdkit/cache/evidence/051-sub-clean" "$PROJ2/.worktrees/051-sub-clean/.prdkit/cache/retrospectives"
printf 'kept\n' > "$PROJ2/.worktrees/051-sub-clean/.prdkit/cache/evidence/051-sub-clean/out.txt"
printf 'lessons\n' > "$PROJ2/.worktrees/051-sub-clean/.prdkit/cache/retrospectives/051-sub-clean.md"
run bash "$CLEAN2" --json 051-sub-clean
assert_eq 0 "$STATUS" "removed"
assert_contains "$OUTPUT" '"result":"ok"' "reports success"
assert_contains "$OUTPUT" "quarantine" "reports recovery location"
run test ! -d "$PROJ2/.worktrees/051-sub-clean"
assert_eq 0 "$STATUS" "worktree directory gone"
assert_not_contains "$(git -C "$PROJ2" worktree list --porcelain)" "051-sub-clean" "registration cleared"
assert_eq "kept" "$(cat "$PROJ2/.prdkit/cache/evidence/051-sub-clean/out.txt" 2>/dev/null)" "evidence kept"
assert_eq "lessons" "$(cat "$PROJ2/.prdkit/cache/retrospectives/051-sub-clean.md" 2>/dev/null)" "retrospective kept"
assert_eq "$(git -C "$PROJ2" rev-parse HEAD)" "$(git -C "$PROJ2" rev-parse refs/heads/051-sub-clean)" "branch kept"

it "the same repository: an untracked file refuses the worktree as dirty, and it stays"
sub_worktree 052-sub-dirty
echo scratch > "$PROJ2/.worktrees/052-sub-dirty/scratch.txt"
run bash "$CLEAN2" 052-sub-dirty
assert_eq 1 "$STATUS" "dirty worktree refused"
assert_contains "$OUTPUT" "uncommitted or untracked changes" "reported as dirty"
assert_not_contains "$OUTPUT" "git refused" "not blamed on git"
run test -f "$PROJ2/.worktrees/052-sub-dirty/scratch.txt"
assert_eq 0 "$STATUS" "worktree and its file kept"

it "a modified submodule is dirty too; nothing is discarded"
sub_worktree 053-sub-modified
echo scratch > "$PROJ2/.worktrees/053-sub-modified/vendor/sub/scratch.txt"
run bash "$CLEAN2" 053-sub-modified
assert_eq 1 "$STATUS" "untracked file inside the submodule refused"
assert_contains "$OUTPUT" "uncommitted or untracked changes" "reported as dirty"
run test -f "$PROJ2/.worktrees/053-sub-modified/vendor/sub/scratch.txt"
assert_eq 0 "$STATUS" "submodule content kept"

it "a locked worktree is refused with git's reason, not as uncommitted changes, and stays"
sub_worktree 054-sub-locked
git -C "$PROJ2" worktree lock --reason "on a removable disk" "$PROJ2/.worktrees/054-sub-locked"
run bash "$CLEAN2" 054-sub-locked
assert_eq 1 "$STATUS" "locked worktree refused"
assert_contains "$OUTPUT" "locked working tree" "git's reason reported"
assert_contains "$OUTPUT" "worktree itself is clean" "says the tree is clean"
assert_not_contains "$OUTPUT" "uncommitted or untracked changes" "not reported as dirty"
run test -d "$PROJ2/.worktrees/054-sub-locked"
assert_eq 0 "$STATUS" "locked worktree kept"
run bash "$CLEAN2" --json 054-sub-locked
assert_contains "$OUTPUT" '"result":"refused"' "JSON refuses"
assert_contains "$OUTPUT" "locked working tree" "JSON carries git's reason"
git -C "$PROJ2" worktree unlock "$PROJ2/.worktrees/054-sub-locked"

it "a locked worktree without submodules is reported the same way"
git -C "$PROJ" worktree add -qb 055-locked "$PROJ/.worktrees/055-locked" >/dev/null 2>&1
git -C "$PROJ" worktree lock "$PROJ/.worktrees/055-locked"
run bash "$CLEAN" 055-locked
assert_eq 1 "$STATUS" "locked worktree refused"
assert_contains "$OUTPUT" "locked working tree" "git's reason reported"
git -C "$PROJ" worktree unlock "$PROJ/.worktrees/055-locked"
git -C "$PROJ" worktree remove --force "$PROJ/.worktrees/055-locked" >/dev/null 2>&1 || true

it "a deinitialized submodule's unused store is also retired before removal"
sub_worktree 056-sub-control
tip56="$(git -C "$PROJ2/.worktrees/056-sub-control/vendor/sub" rev-parse HEAD)"
git -C "$PROJ2/.worktrees/056-sub-control" submodule deinit -q -- vendor/sub
run bash "$CLEAN2" 056-sub-control
assert_eq 0 "$STATUS" "clean worktree removed"
module_retained 056-sub-control "$tip56" 'HEAD^{commit}'

it "an uninitialized index gitlink needs no native removal or translated-error parsing"
SHIM="$(mktemp -d)"; track_tmp "$SHIM"
REAL_GIT="$(command -v git)"
cat > "$SHIM/git" <<EOF
#!/usr/bin/env bash
case " \$* " in
    *" worktree remove "*) touch "$SHIM/called"; echo "fatal: odstranit nelze pracovni strom s podmoduly" >&2; exit 128 ;;
esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SHIM/git"
worded="$PROJ2/.worktrees/057-sub-worded"
git -C "$PROJ2" worktree add -qb 057-sub-worded "$worded"
assert_contains "$(git -C "$worded" ls-files -s vendor/sub)" 160000
run test ! -e "$(git -C "$worded" rev-parse --absolute-git-dir)/modules"; assert_eq 0 "$STATUS" "no populated store"
run env PATH="$SHIM:$PATH" bash "$CLEAN2" 057-sub-worded
assert_eq 0 "$STATUS" "removed although git's message is not recognisable"
run test ! -d "$PROJ2/.worktrees/057-sub-worded"
assert_eq 0 "$STATUS" "worktree gone"
run test ! -e "$SHIM/called"; assert_eq 0 "$STATUS" "no destructive Git removal invoked"

# --- Submodule commits kept only in the worktree's copy of the submodule --------------------------
# Each linked worktree keeps its own submodule repository (<git-dir>/modules/<name>), which the
# removal deletes. A commit made there and recorded in the superproject branch, but never pushed,
# leaves the worktree clean; removing it would leave the branch pointing at a commit that exists
# nowhere.
GITID=(-c user.email=t@example.com -c user.name=test)
sub_commit() { # change id: commit in the worktree's submodule, record it in the superproject; echoes the commit
    git -C "$PROJ2/.worktrees/$1/vendor/sub" "${GITID[@]}" commit -q --allow-empty -m "local $1" >/dev/null 2>&1
    git -C "$PROJ2/.worktrees/$1" add vendor/sub >/dev/null 2>&1
    git -C "$PROJ2/.worktrees/$1" "${GITID[@]}" commit -qm "record $1" >/dev/null 2>&1
    git -C "$PROJ2/.worktrees/$1/vendor/sub" rev-parse HEAD
}
nowhere_else() { # commit: true when neither the submodule's origin nor the main checkout's copy has it
    ! git -C "$SUBSRC" cat-file -e "$1^{commit}" 2>/dev/null && ! git -C "$PROJ2/vendor/sub" cat-file -e "$1^{commit}" 2>/dev/null
}
mutex_of() { # change id: the path of the removal mutex in the worktree's git directory
    printf '%s/prdkit-cleanup.lock' "$(git -C "$PROJ2/.worktrees/$1" rev-parse --absolute-git-dir)"
}

it "an embedded submodule store is retained, even under --force"
embedded="$PROJ2/.worktrees/101-embedded"
git -C "$PROJ2" worktree add -qb 101-embedded "$embedded"
git clone -q "$SUBSRC" "$embedded/vendor/sub"
embedded_tip="$(sub_commit 101-embedded)"
run bash "$CLEAN2" --force 101-embedded
assert_eq 1 "$STATUS" "embedded store refused"
assert_contains "$OUTPUT" 'unsupported submodule layout'
assert_eq "$embedded_tip" "$(git -C "$embedded/vendor/sub" rev-parse HEAD)" "local commit preserved"
git -C "$embedded" submodule absorbgitdirs >/dev/null 2>&1
run bash "$CLEAN2" 101-embedded
assert_eq 0 "$STATUS" "absorbed store can move with the admin directory"
module_retained 101-embedded "$embedded_tip" 'HEAD^{commit}'

it "a retiring submodule cannot strand its own linked worktree"
sub_worktree 102-linked
module="$PROJ2/.worktrees/102-linked/vendor/sub"
linked="$(mktemp -d)"; track_tmp "$linked"
git -C "$module" worktree add -q --detach "$linked"
git -C "$linked" "${GITID[@]}" commit -q --allow-empty -m 'linked checkout work'
linked_tip="$(git -C "$linked" rev-parse HEAD)"
run bash "$CLEAN2" --force 102-linked
assert_eq 1 "$STATUS" "dependent checkout refused"
# find may encounter the dependent HEAD's commondir before the module's own
# HEAD; both preflight paths refuse the layout, but only one prints a detail.
assert_contains "$OUTPUT" 'unsupported submodule layout'
assert_contains "$(git -C "$PROJ2" worktree list --porcelain)" "worktree $PROJ2/.worktrees/102-linked"
assert_eq "$linked_tip" "$(git -C "$linked" rev-parse 'HEAD^{commit}')" "linked checkout and commit survive"

it "a local-only gitlink commit survives in the retired module"
sub_worktree 083-sub-control
c83="$(sub_commit 083-sub-control)"
if nowhere_else "$c83"; then _ok 'fixture: only one commit copy'; else _no 'unexpected surviving copy'; fi
run bash "$CLEAN2" 083-sub-control
assert_eq 0 "$STATUS" "local-only commit retained"
module_retained 083-sub-control "$c83" 'HEAD^{commit}'

it "a ref named commondir is not relocation metadata"
sub_worktree 082-sub-ref
work="$PROJ2/.worktrees/082-sub-ref/vendor/sub"
tip82="$(git -C "$work" rev-parse HEAD)"
git -C "$work" branch commondir "$tip82"
run bash "$CLEAN2" 082-sub-ref
assert_eq 0 "$STATUS" "clean module with fully reachable ref retires: $OUTPUT"
module_retained 082-sub-ref "$tip82" 'refs/heads/commondir^{commit}'

it "a retiring module that actually depends on alternates stays registered"
sub_worktree 081-alternate
mod="$(git -C "$PROJ2/.worktrees/081-alternate/vendor/sub" rev-parse --absolute-git-dir)"
printf '%s\n' "$SUBSRC/.git/objects" > "$mod/objects/info/alternates"
run bash "$CLEAN2" --force 081-alternate
assert_eq 1 "$STATUS" "relative repository dependencies refused"
assert_file "$mod/HEAD" "registration kept"

it "ordinary cleanup captures a previously absent store born at retirement"
late="$(mktemp -d)"; track_tmp "$late"
realmv="$(command -v mv)"
cat > "$late/mv" <<'SH'
#!/bin/sh
if [ "$1" = "$ADMIN" ]; then "$INJECT" || exit 1; fi
exec "$MV" "$@"
SH
cat > "$late/git" <<'SH'
#!/bin/sh
case " $* " in *" worktree remove "*) "$INJECT" || exit 1 ;; esac
exec "$GIT" "$@"
SH
cat > "$late/inject" <<'SH'
#!/bin/sh
test ! -e "$ADMIN/modules" || exit 1
"$GIT" init -q --bare "$ADMIN/modules/late" || exit 1
tree=$("$GIT" --git-dir="$ADMIN/modules/late" mktree </dev/null) || exit 1
oid=$("$GIT" --git-dir="$ADMIN/modules/late" -c user.email=t@example.invalid -c user.name=test commit-tree "$tree" -m late) || exit 1
"$GIT" --git-dir="$ADMIN/modules/late" update-ref HEAD "$oid" && echo "$oid" > "$OID"
SH
chmod +x "$late/mv" "$late/git" "$late/inject"
for mode in ordinary forced; do
    id="110-late-$mode"; work="$PROJ/.worktrees/$id"
    git -C "$PROJ" worktree add -qb "$id" "$work"
    admin="$(git -C "$work" rev-parse --absolute-git-dir)"
    args=(); [ "$mode" = ordinary ] || args=(--force)
    run env GIT="$REAL_GIT" MV="$realmv" ADMIN="$admin" INJECT="$late/inject" OID="$late/$mode" \
        PATH="$late:$PATH" bash "$CLEAN" ${args[@]+"${args[@]}"} "$id"
    assert_eq 0 "$STATUS" "$mode cleanup completed: $OUTPUT"
    assert_file "$late/$mode" "writer actually created its first commit"
    slot="$(slot_for "$PROJ" "$id")"
    run git --git-dir="$slot/admin/modules/late" rev-parse 'HEAD^{commit}'
    assert_eq 0 "$STATUS" 'commit object readable from quarantine'
    assert_eq "$(cat "$late/$mode")" "$OUTPUT" 'exact late commit retained'
    run test ! -e "$work"; assert_eq 0 "$STATUS" 'checkout removed'
done
it "a writer updating an already populated store at retirement is captured in both modes"
cat > "$late/inject" <<'SH'
#!/bin/sh
repo="$ADMIN/modules/vendor/sub"
old=$("$GIT" --git-dir="$repo" --work-tree=. rev-parse HEAD) || exit 1
new=$("$GIT" --git-dir="$repo" --work-tree=. -c user.name=test -c user.email=t@example.invalid commit-tree "$old^{tree}" -p "$old" -m 'existing writer') || exit 1
"$GIT" --git-dir="$repo" --work-tree=. update-ref refs/heads/late "$new" && echo "$new" > "$OID"
SH
for mode in ordinary forced; do
    id="113-existing-$mode"; sub_worktree "$id"; work="$PROJ2/.worktrees/$id"
    admin="$(git -C "$work" rev-parse --absolute-git-dir)"
    args=(); [ "$mode" = ordinary ] || args=(--force)
    run env GIT="$REAL_GIT" MV="$realmv" ADMIN="$admin" INJECT="$late/inject" OID="$late/existing-$mode" \
        PATH="$late:$PATH" bash "$CLEAN2" ${args[@]+"${args[@]}"} "$id"
    assert_eq 0 "$STATUS" "$mode captures the existing store: $OUTPUT"
    module_retained "$id" "$(cat "$late/existing-$mode")" 'refs/heads/late^{commit}'
done
it "a worktree someone has locked with git is refused by --force with git's reason"
sub_worktree 085-sub-held
git -C "$PROJ2" worktree lock --reason "another sweep" "$PROJ2/.worktrees/085-sub-held"
run bash "$CLEAN2" --force 085-sub-held
assert_eq 1 "$STATUS" "refused"
assert_contains "$OUTPUT" "another sweep" "git's reason reported"
run test -d "$PROJ2/.worktrees/085-sub-held"
assert_eq 0 "$STATUS" "worktree kept"
git -C "$PROJ2" worktree unlock "$PROJ2/.worktrees/085-sub-held"
git -C "$PROJ2" worktree remove --force --force "$PROJ2/.worktrees/085-sub-held" >/dev/null 2>&1 || true

it "a second run cannot take the mutex: refused, kept, and the other run's mutex is left alone"
sub_worktree 086-sub-busy
M86="$(mutex_of 086-sub-busy)"
mkdir "$M86"
run bash "$CLEAN2" 086-sub-busy
assert_eq 1 "$STATUS" "refused"
assert_contains "$OUTPUT" "another cleanup-change.sh run holds $M86" "names the mutex"
run test -d "$PROJ2/.worktrees/086-sub-busy"
assert_eq 0 "$STATUS" "worktree kept"
run test -d "$M86"
assert_eq 0 "$STATUS" "the other run's mutex kept"
rmdir "$M86"
run bash "$CLEAN2" 086-sub-busy
assert_eq 0 "$STATUS" "removed once the mutex is free"

it "an older stash in the submodule lives only in the reflog, and is kept"
sub_worktree 087-sub-stash
S87="$PROJ2/.worktrees/087-sub-stash/vendor/sub"
echo one > "$S87/one.txt"; git -C "$S87" "${GITID[@]}" stash push -qu -m one >/dev/null 2>&1
echo two > "$S87/two.txt"; git -C "$S87" "${GITID[@]}" stash push -qu -m two >/dev/null 2>&1
old87="$(git -C "$S87" rev-parse 'stash@{1}')"
git -C "$PROJ2/vendor/sub" -c protocol.file.allow=always fetch -q "$S87" refs/stash:refs/heads/newest-stash-087 >/dev/null 2>&1
run git -C "$PROJ2/vendor/sub" cat-file -e "$(git -C "$S87" rev-parse 'stash@{0}')^{commit}"
assert_eq 0 "$STATUS" "fixture: the newest stash is held by the main checkout's copy"
run bash "$CLEAN2" 087-sub-stash
assert_eq 0 "$STATUS" "stash history moved intact"
module_retained 087-sub-stash "$old87" 'stash@{1}^{commit}'

it "a rejecting reference transaction leaves only its own registration locked"
failbin="$(mktemp -d)"; track_tmp "$failbin"
cat > "$failbin/reference-transaction" <<'SH'
#!/bin/sh
test "$1" != prepared || ! grep -F ' refs/prdkit-retired/' >/dev/null
SH
chmod +x "$failbin/reference-transaction"
work="$PROJ/.worktrees/111-interrupted"
git -C "$PROJ" worktree add -qb 111-interrupted "$work"
admin="$(git -C "$work" rev-parse --absolute-git-dir)"
echo 'only copy' > "$work/untracked"
git -C "$PROJ" config core.hooksPath "$failbin"
run bash "$CLEAN" --force 111-interrupted
git -C "$PROJ" config --unset core.hooksPath
assert_eq 1 "$STATUS" "partial retirement reported"
slot="$(slot_for "$PROJ" 111-interrupted)"
assert_contains "$OUTPUT" "$slot" "names actual recovery location"
assert_file "$admin/locked" "Git prune cannot collect the missing checkout's registration"
assert_file "$admin/index" "original index preserved"
assert_eq 'only copy' "$(cat "$slot/checkout/untracked")" "untracked content is recoverable"
assert_file "$admin/HEAD" "failure leaves a real locked registration"
git -C "$PROJ" worktree add -q --detach "$PROJ/.worktrees/123-after-refusal"
run bash "$CLEAN" 123-after-refusal
assert_eq 0 "$STATUS" "another worktree retires after the hook is removed"

it "a missing archived module HEAD cannot yield a successful retirement"
sub_worktree 119-unreadable
module_admin="$(git -C "$PROJ2/.worktrees/119-unreadable/vendor/sub" rev-parse --absolute-git-dir)"
printf '%040d\n' 1 > "$module_admin/HEAD"
run bash "$CLEAN2" --force 119-unreadable
assert_eq 1 "$STATUS" "missing module object reported as a failure"
slot="$(slot_for "$PROJ2" 119-unreadable)"
assert_contains "$OUTPUT" "$slot"
holding="$PROJ2/.git/worktrees/${slot##*/}.retiring"
assert_file "$holding/modules/vendor/sub/HEAD"; assert_file "$holding/locked"
git -C "$PROJ2" worktree add -q --detach "$PROJ2/.worktrees/122-unrelated"
run bash "$CLEAN2" 122-unrelated
assert_eq 0 "$STATUS" "locked recovery registration does not block unrelated cleanup"

it "two overlapping runs: the second is refused while the first holds the mutex, and the first removes"
SHIM6="$(mktemp -d)"; track_tmp "$SHIM6"
cat > "$SHIM6/mv" <<EOF
#!/usr/bin/env bash
case "\$1" in
    */worktrees/079-sub-overlap)
        : > "$SHIM6/in"
        n=0; while [ ! -e "$SHIM6/go" ] && [ "\$n" -lt 600 ]; do sleep 0.1; n=\$((n + 1)); done ;;
esac
exec "$(command -v mv)" "\$@"
EOF
chmod +x "$SHIM6/mv"
sub_worktree 079-sub-overlap
env PATH="$SHIM6:$PATH" bash "$CLEAN2" 079-sub-overlap > "$SHIM6/first.out" 2>&1 &
first=$!
n=0; while [ ! -e "$SHIM6/in" ] && [ "$n" -lt 600 ]; do sleep 0.1; n=$((n + 1)); done
run test -e "$SHIM6/in"
assert_eq 0 "$STATUS" "fixture: the first run is inside its forced removal"
run bash "$CLEAN2" 079-sub-overlap
assert_eq 1 "$STATUS" "the second run is refused"
assert_contains "$OUTPUT" "another cleanup-change.sh run holds" "because the first holds the mutex"
: > "$SHIM6/go"
if wait "$first"; then STATUS=0; else STATUS=$?; fi
assert_eq 0 "$STATUS" "the first run removes the worktree"
run test ! -d "$PROJ2/.worktrees/079-sub-overlap"
assert_eq 0 "$STATUS" "worktree gone"

it "concurrent cleanup of different worktrees publishes shared evidence without replacement"
race="$(mktemp -d)"; track_tmp "$race"
cat > "$race/cp" <<'SH'
#!/usr/bin/env bash
if [ "${2##*/}" = shared-race.txt ]; then
    : > "$SYNC/$WRITER.ready"
    case "$WRITER" in
        first) other="$SYNC/second.ready" ;;
        second) other="$SYNC/first.done" ;;
    esac
    # Hold both past the absence check, then let the first complete before the second copies.
    for ((n=0; n<300; n++)); do
        [ ! -e "$other" ] || break
        sleep 0.1
    done
    [ -e "$other" ] || exit 1
fi
exec "$REAL_CP" "$@"
SH
chmod +x "$race/cp"
for variant in different identical; do
    sync="$race/$variant"; mkdir "$sync"
    first_id="130-first-$variant"; second_id="131-second-$variant"
    rel=".prdkit/cache/evidence/$variant/shared-race.txt"
    for id in "$first_id" "$second_id"; do
        work="$PROJ/.worktrees/$id"
        git -C "$PROJ" worktree add -qb "$id" "$work" || exit 1
        mkdir -p "$work/${rel%/*}"
        bytes=first
        if [ "$id" = "$second_id" ] && [ "$variant" = different ]; then bytes=second; fi
        printf '%s\n' "$bytes" > "$work/$rel"
    done
    (
        rc=0
        env PATH="$race:$PATH" SYNC="$sync" WRITER=first REAL_CP="$(command -v cp)" bash "$CLEAN" "$first_id" || rc=$?
        : > "$sync/first.done"
        exit "$rc"
    ) > "$sync/first.out" 2>&1 &
    first=$!
    env PATH="$race:$PATH" SYNC="$sync" WRITER=second REAL_CP="$(command -v cp)" bash "$CLEAN" "$second_id" > "$sync/second.out" 2>&1 &
    second=$!
    rc=0; wait "$first" || rc=$?
    assert_eq 0 "$rc" "first cleanup succeeds: $(cat "$sync/first.out")"
    assert_file "$sync/first.ready"; assert_file "$sync/second.ready"
    rc=0; wait "$second" || rc=$?
    if [ "$variant" = different ]; then
        assert_eq 1 "$rc" "the conflicting cleanup refuses"
        assert_contains "$(cat "$sync/second.out")" 'could not preserve its evidence'
        assert_eq second "$(cat "$PROJ/.worktrees/$second_id/$rel")" 'refused worktree keeps its copy'
    else
        assert_eq 0 "$rc" "identical copies both succeed: $(cat "$sync/second.out")"
        run test ! -e "$PROJ/.worktrees/$second_id"; assert_eq 0 "$STATUS" 'second worktree retired'
    fi
    assert_eq first "$(cat "$PROJ/$rel")" 'winner was not replaced'
    assert_eq '' "$(find "$PROJ/${rel%/*}" -name '.prdkit-evidence.*')" 'no staging directories left behind'
done

it "evidence copy runs inside its private stage"
id=132-stage; rel=".prdkit/cache/evidence/$id/report.txt"
git -C "$PROJ" worktree add -qb "$id" "$PROJ/.worktrees/$id" || exit 1
mkdir -p "$PROJ/.worktrees/$id/${rel%/*}"
printf 'retained\n' > "$PROJ/.worktrees/$id/$rel"
cat > "$race/cp" <<'SH'
#!/usr/bin/env bash
if [ "${2##*/}" = report.txt ]; then
    case "$PWD" in */.prdkit-evidence.*) ;; *) exit 1 ;; esac
    case "$3" in report.txt|./report.txt) ;; *) exit 1 ;; esac
fi
exec "$REAL_CP" "$@"
SH
chmod +x "$race/cp"
cat > "$race/rm" <<'SH'
#!/usr/bin/env bash
case "${2:-}" in
    *report.txt)
        case "$PWD:$2" in */.prdkit-evidence.*:./report.txt) : > "$CLEANED" ;; esac ;;
esac
exec "$REAL_RM" "$@"
SH
chmod +x "$race/rm"
run env PATH="$race:$PATH" REAL_CP="$(command -v cp)" REAL_RM="$(command -v rm)" \
    CLEANED="$race/stage-cleaned" bash "$CLEAN" "$id"
assert_eq 0 "$STATUS" 'M4: copy destination is relative to a pinned stage'
assert_file "$PROJ/$rel"
assert_file "$race/stage-cleaned" 'M4: exit trap cleans relative to the pinned stage'

it "retirement rechecks the identity of previously published evidence"
rm "$race/cp" "$race/rm"
id=133-rotate; rel=".prdkit/cache/evidence/$id/report.txt"
git -C "$PROJ" worktree add -qb "$id" "$PROJ/.worktrees/$id" || exit 1
mkdir -p "$PROJ/.worktrees/$id/${rel%/*}"
printf 'retained\n' > "$PROJ/.worktrees/$id/$rel"
cat > "$race/mktemp" <<'SH'
#!/usr/bin/env bash
# Rotate a disposable evidence directory after preservation, at quarantine allocation.
case "$*" in *"/prdkit-retired/"*)
    mv "$DEST" "$DEST.previous" && mkdir "$DEST" || exit 1 ;;
esac
exec "$REAL_MKTEMP" "$@"
SH
chmod +x "$race/mktemp"
run env PATH="$race:$PATH" REAL_CP="$(command -v cp)" REAL_MKTEMP="$(command -v mktemp)" \
    DEST="$PROJ/${rel%/*}" bash "$CLEAN" "$id"
assert_eq 1 "$STATUS" 'M4: changed canonical destination refuses retirement'
assert_file "$PROJ/.worktrees/$id/$rel" 'M4: source still available'
assert_file "$PROJ/${rel%/*}.previous/report.txt" 'fixture rotated the published copy'

# --- --closed: sweep every closed change's worktree ----------------------------------------------
# Closed means the record was replaced with a per-change entry on the trusted integration
# branch (origin/HEAD), never the worktree's own branch. A later fold preserves that evidence.
BRANCH="$(git -C "$PROJ" symbolic-ref --short HEAD)"
for id in 060-closed-clean 061-open 062-closed-dirty 063-closed-locked 064-self-claimed 065-logged-record 066-never-logged; do
    git -C "$PROJ" worktree add -qb "$id" "$PROJ/.worktrees/$id" >/dev/null 2>&1
done
git -C "$PROJ" worktree add -qb 069-stale "$PROJ/.worktrees/069-stale" >/dev/null 2>&1
rm -rf "$PROJ/.worktrees/069-stale"
mkdir -p "$PROJ/.worktrees/060-closed-clean/.prdkit/cache/evidence/060-closed-clean"
printf 'kept\n' > "$PROJ/.worktrees/060-closed-clean/.prdkit/cache/evidence/060-closed-clean/out.txt"
echo scratch > "$PROJ/.worktrees/062-closed-dirty/scratch.txt"
git -C "$PROJ" worktree lock --reason "held" "$PROJ/.worktrees/063-closed-locked"
# 064 closes itself on its own branch only; the trusted branch never hears of it.
(
    cd "$PROJ/.worktrees/064-self-claimed" || exit 1
    mkdir -p specs/log
    printf -- '- 2026-11-10 064-self-claimed: done\n' > specs/log.md
    printf -- '- 2026-11-10 064-self-claimed: done\n' > specs/log/064-self-claimed.md
    git add specs && git commit -qm 'claim closed'
)

it "--closed refuses outright when no trusted integration branch resolves"
run bash "$CLEAN" --closed
assert_eq 1 "$STATUS" "no origin/HEAD: refused"
assert_contains "$OUTPUT" "no trusted integration branch" "says why"
run bash "$CLEAN" --json --closed
assert_eq 1 "$STATUS" "JSON refuses too"
assert_contains "$OUTPUT" '"result":"refused"' "JSON result"
run test -d "$PROJ/.worktrees/060-closed-clean"
assert_eq 0 "$STATUS" "nothing was removed"

# Close four records on trusted history and compact three of their entries.
mkdir -p "$PROJ/specs/changes" "$PROJ/specs/log"
printf '# 061-open\n' > "$PROJ/specs/changes/061-open.md"
printf '# 065-logged-record\n' > "$PROJ/specs/changes/065-logged-record.md"
closed_ids=(067-closed-here 063-closed-locked 062-closed-dirty 060-closed-clean)
for id in "${closed_ids[@]}"; do printf '# %s\n' "$id" > "$PROJ/specs/changes/$id.md"; done
git -C "$PROJ" add specs && git -C "$PROJ" commit -qm 'open changes' || exit 1
for id in "${closed_ids[@]}"; do
    git -C "$PROJ" rm -q "specs/changes/$id.md" || exit 1
    printf -- '- 2026-11-10 %s: x\n' "$id" > "$PROJ/specs/log/$id.md"
done
git -C "$PROJ" add specs && git -C "$PROJ" commit -qm 'close changes' || exit 1
printf -- '- 2026-11-10 065-logged-record: x\n' > "$PROJ/specs/log.md"
for id in "${closed_ids[@]:0:3}"; do
    cat "$PROJ/specs/log/$id.md" >> "$PROJ/specs/log.md"
    git -C "$PROJ" rm -q "specs/log/$id.md" || exit 1
done
git -C "$PROJ" add specs && git -C "$PROJ" commit -qm 'fold close entries' || exit 1
git -C "$PROJ" update-ref "refs/remotes/origin/$BRANCH" HEAD
git -C "$PROJ" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$BRANCH"

it "--closed removes closed changes' clean worktrees, skips the rest and exits non-zero on a refusal"
run bash "$CLEAN" --closed --help
assert_contains "$OUTPUT" "--closed" "usage documents the mode"
run bash "$CLEAN" --closed --force
assert_eq 2 "$STATUS" "--closed never forces"
run bash "$CLEAN" --closed 060-closed-clean
assert_eq 2 "$STATUS" "a change id and --closed are exclusive"
run bash "$CLEAN" --json --closed
assert_eq 1 "$STATUS" "the dirty and the locked worktree were refused"
assert_contains "$OUTPUT" '"action":"closed"' "closed action"
assert_contains "$OUTPUT" '"result":"refused"' "result is refused"
assert_contains "$OUTPUT" "060-closed-clean" "the clean worktree closed by its entry file is listed as removed"
assert_contains "$OUTPUT" '"skipped":[' "skipped list"
assert_contains "$OUTPUT" "062-closed-dirty\",\"reason\":\"uncommitted or untracked changes" "dirty one skipped as dirty"
assert_contains "$OUTPUT" "063-closed-locked\",\"reason\":\"git refused the removal: cannot remove a locked working tree" "locked one skipped with git's reason"
assert_contains "$OUTPUT" '"pruned":[]' "closed cleanup reports no incidental prune"
run test ! -d "$PROJ/.worktrees/060-closed-clean"
assert_eq 0 "$STATUS" "060-closed-clean removed"
for id in 061-open 062-closed-dirty 063-closed-locked 064-self-claimed 065-logged-record 066-never-logged; do
    run test -d "$PROJ/.worktrees/$id"
    assert_eq 0 "$STATUS" "$id kept"
done
assert_contains "$(git -C "$PROJ" worktree list --porcelain)" "069-stale" "stale registration left alone"
assert_eq "kept" "$(cat "$PROJ/.prdkit/cache/evidence/060-closed-clean/out.txt" 2>/dev/null)" "evidence preserved"
run test -f "$PROJ/.worktrees/062-closed-dirty/scratch.txt"
assert_eq 0 "$STATUS" "the dirty worktree's file kept"
assert_eq "060-closed-clean" "$(git -C "$PROJ" for-each-ref --format='%(refname:short)' refs/heads/060-closed-clean)" "branch kept"

it "--closed skips the worktree holding the current directory, then succeeds once the rest are clean"
rm -f "$PROJ/.worktrees/062-closed-dirty/scratch.txt"
git -C "$PROJ" worktree add -qb 067-closed-here "$PROJ/.worktrees/067-closed-here" >/dev/null 2>&1
git -C "$PROJ" worktree unlock "$PROJ/.worktrees/063-closed-locked"
run bash -c 'cd "$2/.worktrees/067-closed-here" && bash "$1" --closed' _ "$CLEAN" "$PROJ"
assert_eq 0 "$STATUS" "nothing was refused"
assert_contains "$OUTPUT" "067-closed-here: it holds the current directory" "reported as skipped"
for id in 062-closed-dirty 063-closed-locked; do
    run test ! -d "$PROJ/.worktrees/$id"
    assert_eq 0 "$STATUS" "$id removed"
done
run test -d "$PROJ/.worktrees/067-closed-here"
assert_eq 0 "$STATUS" "the current worktree kept"
run bash "$CLEAN" --closed
assert_eq 0 "$STATUS" "from the main checkout it is removed"
assert_contains "$OUTPUT" "Removed 1 closed change worktree" "text summary"
run test ! -d "$PROJ/.worktrees/067-closed-here"
assert_eq 0 "$STATUS" "067-closed-here removed"
run bash "$CLEAN" --closed
assert_eq 0 "$STATUS" "nothing left to do"
assert_contains "$OUTPUT" "Removed 0 closed change worktree" "idempotent"
for id in 061-open 064-self-claimed 065-logged-record 066-never-logged; do
    run test -d "$PROJ/.worktrees/$id"
    assert_eq 0 "$STATUS" "$id still kept"
done

it "--closed matches only .worktrees/<id> on branch <id>: a detached HEAD, another branch or directory stays"
OUTSIDE="$(mktemp -d)"; track_tmp "$OUTSIDE"; OUTSIDE="$(cd "$OUTSIDE" && pwd -P)"
git -C "$PROJ" worktree add -q --detach "$PROJ/.worktrees/090-closed-detached" >/dev/null 2>&1
git -C "$PROJ/.worktrees/090-closed-detached" commit -q --allow-empty -m 'reachable from no ref'
c90="$(git -C "$PROJ/.worktrees/090-closed-detached" rev-parse HEAD)"
git -C "$PROJ" worktree add -qb feature-x "$PROJ/.worktrees/091-closed-other-branch" >/dev/null 2>&1
git -C "$PROJ" worktree add -qb 092-closed-elsewhere "$OUTSIDE/092-closed-elsewhere" >/dev/null 2>&1
git -C "$PROJ" worktree add -qb 093-closed-renamed "$PROJ/.worktrees/scratch" >/dev/null 2>&1
git -C "$PROJ" worktree add -qb 094-closed-exact "$PROJ/.worktrees/094-closed-exact" >/dev/null 2>&1
exact_ids=(090-closed-detached 091-closed-other-branch 092-closed-elsewhere 093-closed-renamed 094-closed-exact)
for id in "${exact_ids[@]}"; do printf '# %s\n' "$id" > "$PROJ/specs/changes/$id.md"; done
git -C "$PROJ" add specs && git -C "$PROJ" commit -qm 'open more changes' || exit 1
for id in "${exact_ids[@]}"; do
    git -C "$PROJ" rm -q "specs/changes/$id.md" || exit 1
    printf -- '- 2026-11-11 %s: x\n' "$id" > "$PROJ/specs/log/$id.md"
done
git -C "$PROJ" add specs && git -C "$PROJ" commit -qm 'close more' || exit 1
git -C "$PROJ" update-ref "refs/remotes/origin/$BRANCH" HEAD
run bash "$CLEAN" --json --closed
assert_eq 0 "$STATUS" "nothing refused"
assert_contains "$OUTPUT" '"paths":["'"$PROJ"'/.worktrees/094-closed-exact"]' "only the exact layout removed"
assert_contains "$OUTPUT" "Removed 1 closed change worktree(s), skipped 0," "the others are not candidates, so not skipped either"
run test ! -d "$PROJ/.worktrees/094-closed-exact"
assert_eq 0 "$STATUS" "the exact layout removed"
for wt in "$PROJ/.worktrees/090-closed-detached" "$PROJ/.worktrees/091-closed-other-branch" "$OUTSIDE/092-closed-elsewhere" "$PROJ/.worktrees/scratch"; do
    run test -d "$wt"
    assert_eq 0 "$STATUS" "${wt##*/} kept"
done
assert_eq "$c90" "$(git -C "$PROJ/.worktrees/090-closed-detached" rev-parse HEAD)" "the detached HEAD's commit is kept"
for wt in "$PROJ/.worktrees/090-closed-detached" "$PROJ/.worktrees/091-closed-other-branch" "$OUTSIDE/092-closed-elsewhere" "$PROJ/.worktrees/scratch"; do
    git -C "$PROJ" worktree remove --force "$wt" >/dev/null 2>&1 || true
done

it "--closed removes a closed change's clean worktree that has submodules"
for id in 070-sub-closed 071-sub-open; do sub_worktree "$id"; done
sub_worktree 103-stale-sub
stale_tip="$(sub_commit 103-stale-sub)"
store="$(git -C "$PROJ2/.worktrees/103-stale-sub/vendor/sub" rev-parse --absolute-git-dir)"
rm -rf "$PROJ2/.worktrees/103-stale-sub"
run bash -c 'cd "$1" && bash .prdkit/scripts/bash/new-change.sh --short-name separate "Separate change"' _ "$PROJ2"
assert_eq 0 "$STATUS" "creating an unrelated change succeeds"
assert_eq "$stale_tip" "$(git --git-dir="$store" --work-tree="$PROJ2" rev-parse 'HEAD^{commit}')" "new change leaves local-only module commit intact"
mkdir -p "$PROJ2/specs/changes" "$PROJ2/specs/log"
printf '# 070-sub-closed\n' > "$PROJ2/specs/changes/070-sub-closed.md"
printf '# 071-sub-open\n' > "$PROJ2/specs/changes/071-sub-open.md"
git -C "$PROJ2" add specs && git -C "$PROJ2" commit -qm 'open changes' || exit 1
git -C "$PROJ2" rm -q specs/changes/070-sub-closed.md || exit 1
printf -- '- 2026-11-10 070-sub-closed: x\n' > "$PROJ2/specs/log/070-sub-closed.md"
git -C "$PROJ2" add specs >/dev/null 2>&1; git -C "$PROJ2" commit -qm 'close' >/dev/null 2>&1
B2="$(git -C "$PROJ2" symbolic-ref --short HEAD)"
git -C "$PROJ2" update-ref "refs/remotes/origin/$B2" HEAD
git -C "$PROJ2" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$B2"
run bash "$CLEAN2" --closed
assert_eq 0 "$STATUS" "swept"
run test ! -d "$PROJ2/.worktrees/070-sub-closed"
assert_eq 0 "$STATUS" "the closed change's worktree removed"
run test -d "$PROJ2/.worktrees/071-sub-open"
assert_eq 0 "$STATUS" "the open change's worktree kept"
git -C "$PROJ2" worktree add -qb 104-stale-plain "$PROJ2/.worktrees/104-stale-plain"
rm -rf "$PROJ2/.worktrees/104-stale-plain"
run bash "$CLEAN2" 104-stale-plain
assert_eq 0 "$STATUS" "pruning a plain registration by ID does not prune others"
run git --git-dir="$store" --work-tree="$PROJ2" cat-file -e "$stale_tip^{commit}"
assert_eq 0 "$STATUS" "unrelated removal leaves the stale store alone"
run bash "$CLEAN2" --prune
assert_eq 0 "$STATUS" "explicit prune quarantines the stale module"
module_retained 103-stale-sub "$stale_tip" 'HEAD^{commit}'
run test ! -e "$store"; assert_eq 0 "$STATUS" "old module store gone"
run test ! -e "${store%/modules/*}"; assert_eq 0 "$STATUS" "old stale admin gone"
assert_not_contains "$(git -C "$PROJ2" worktree list --porcelain)" 103-stale-sub

it "--closed refuses a direct shared-log close and a replacement line that was not folded"
unsupported_ids=(095-direct-shared 096-rewritten-shared)
for id in "${unsupported_ids[@]}"; do printf '# %s\n' "$id" > "$PROJ/specs/changes/$id.md"; done
git -C "$PROJ" add specs && git -C "$PROJ" commit -qm 'open more changes' || exit 1
for id in "${unsupported_ids[@]}"; do
    git -C "$PROJ" worktree add -qb "$id" "$PROJ/.worktrees/$id" || exit 1
    git -C "$PROJ" rm -q "specs/changes/$id.md" || exit 1
done
printf -- '- 2026-11-11 095-direct-shared: direct shared-log close\n' >> "$PROJ/specs/log.md"
printf -- '- 2026-11-11 096-rewritten-shared: the original line\n' > "$PROJ/specs/log/096-rewritten-shared.md"
git -C "$PROJ" add specs && git -C "$PROJ" commit -qm 'close two ways' || exit 1
git -C "$PROJ" rm -q specs/log/096-rewritten-shared.md || exit 1
printf -- '- 2026-11-12 096-rewritten-shared: different from the original line\n' >> "$PROJ/specs/log.md"
git -C "$PROJ" add specs && git -C "$PROJ" commit -qm 'substitute a shared-log entry' || exit 1
git -C "$PROJ" update-ref "refs/remotes/origin/$BRANCH" HEAD || exit 1
before="$(git -C "$PROJ" worktree list --porcelain)"
run bash "$CLEAN" --json --closed
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" '"paths":[]' 'nothing removed'
for id in "${unsupported_ids[@]}"; do
    assert_contains "$OUTPUT" "expected specs/log/$id.md from close-change.sh"
    assert_file "$PROJ/.worktrees/$id/specs/changes/$id.md"
done
assert_eq "$before" "$(git -C "$PROJ" worktree list --porcelain)" 'registrations untouched'

finish
