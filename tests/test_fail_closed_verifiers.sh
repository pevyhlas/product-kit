#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TESTS_DIR/install-fixture.sh"

# Faults are scoped to a single producer; all other invocations use the real tools.
mkdir "$_SCRATCH_CWD/bin"
REAL_GIT="$(command -v git)" || exit 1
REAL_FIND="$(command -v find)" || exit 1
REAL_CAT="$(command -v cat)" || exit 1
REAL_WC="$(command -v wc)" || exit 1
REAL_AWK="$(command -v awk)" || exit 1
export REAL_GIT REAL_FIND REAL_CAT REAL_WC REAL_AWK
cat > "$_SCRATCH_CWD/bin/git" <<'SH'
#!/usr/bin/env bash
case "$VERIFY_FAULT:$*" in
    install-index:*'ls-files '*'.prdkit/.install-state'*) exit 5 ;;
    worktrees-fail:*'worktree list --porcelain')
        "$REAL_GIT" "$@"; exit 5 ;;
    worktrees-empty:*'worktree list --porcelain') exit 0 ;;
    worktrees-eof:*'worktree list --porcelain')
        printf 'worktree %s\nHEAD %s\ndetached\n' "$VERIFY_PROJECT" "$VERIFY_HEAD"; exit 0 ;;
    worktrees-crlf:*'worktree list --porcelain')
        printf 'worktree %s\r\nHEAD %s\r\ndetached\r\n\r\n' "$VERIFY_PROJECT" "$VERIFY_HEAD"; exit 0 ;;
    source-tree-fail:*'ls-tree -r '*)
        "$REAL_GIT" "$@"; exit 5 ;;
    source-tree-eof:*'ls-tree -r '*)
        "$REAL_GIT" "$@" | awk 'NR>1 {print row} {row=$0} END {printf "%s",row}'; exit 0 ;;
    config-fail-commit:*"cat-file blob $VERIFY_CONFIG_OID")
        "$REAL_GIT" "$@" | sed -n '1p'; exit 5 ;;
    installed-empty:*'ls-tree -r -z --name-only '*) exit 0 ;;
    installed-eof:*'ls-tree -r -z --name-only '*)
        printf '.prdkit/scripts/bash/common.sh'; exit 0 ;;
    remote-*:*'ls-remote '*)
        case "$VERIFY_FAULT" in
            remote-fail) "$REAL_GIT" "$@"; exit 5 ;;
            remote-empty) exit 0 ;;
            remote-eof) printf '%s\trefs/heads/feature' "$VERIFY_HEAD" ;;
            remote-crlf) printf '%s\trefs/heads/feature\r\n' "$VERIFY_HEAD" ;;
            remote-duplicate) printf '%s\trefs/heads/feature\n%s\trefs/heads/feature\n' "$VERIFY_HEAD" "$VERIFY_HEAD" ;;
            remote-nul) printf '%s\trefs/heads/fea\000ture\n' "$VERIFY_HEAD" ;;
            remote-partial) printf '%s\trefs/heads/feature\nrecord without a terminator' "$VERIFY_HEAD" ;;
        esac
        exit 0 ;;
    local-status-fail:*'status --porcelain=v1 '*) exit 5 ;;
    doc-history-fail:*'log -M --diff-filter=D '*) exit 5 ;;
    doc-index-eof:*'ls-files -z -- specs') printf 'specs/results/pending.log'; exit 0 ;;
    squash-empty:*'diff --no-renames --name-only -z '*) exit 0 ;;
    squash-eof:*'diff --no-renames --name-only -z '*) printf 'one.txt'; exit 0 ;;
    close-default-fail:*'ls-tree --name-only main -- :(literal)specs/changes/'*|close-default-fail:*'cat-file -e main:specs/changes/'*)
        exit 5 ;;
    close-log-fail:*'ls-tree HEAD -- :(literal).prdkit/history/log.md') exit 5 ;;
esac
exec "$REAL_GIT" "$@"
SH
cat > "$_SCRATCH_CWD/bin/find" <<'SH'
#!/usr/bin/env bash
case "$VERIFY_FAULT:$*" in
    find-fail:*'.prdkit/workflows '*'-print0') exit 5 ;;
    find-empty:*'.prdkit/workflows '*'-print0') exit 0 ;;
    find-eof:*'.prdkit/workflows '*'-print0') printf '%s' "$1/work.md"; exit 0 ;;
esac
exec "$REAL_FIND" "$@"
SH
cat > "$_SCRATCH_CWD/bin/cat" <<'SH'
#!/usr/bin/env bash
case "$VERIFY_FAULT:${1:-}" in
    spec-short:*/specs/SPEC.md) sed -n '1p' "$1"; exit 0 ;;
    spec-fail:*/specs/SPEC.md) sed -n '1p' "$1"; exit 5 ;;
    config-short-worktree:*/.prdkit/memory/config.md) sed -n '1p' "$1"; exit 0 ;;
esac
exec "$REAL_CAT" "$@"
SH
cat > "$_SCRATCH_CWD/bin/wc" <<'SH'
#!/usr/bin/env bash
if [ "$VERIFY_FAULT" = line-count ] && [ "$*" = -l ]; then
    # Match only the two-line fixture; other counts must use the real input.
    spool="$(mktemp)" || exit 1
    trap 'rm -f "$spool"' EXIT
    cat > "$spool" || exit 1
    if cmp -s "$spool" "$COUNT_TARGET"; then
        : > "$COUNT_HIT"
        printf '1\n'; exit 5
    fi
    "$REAL_WC" -l < "$spool"; exit $?
fi
exec "$REAL_WC" "$@"
SH
cat > "$_SCRATCH_CWD/bin/awk" <<'SH'
#!/usr/bin/env bash
if [ "$VERIFY_FAULT" = version-reader ] && [ "${2:-}" = 'prefix=version: ' ]; then
    "$REAL_AWK" "$@"; exit 5
fi
if [ "$VERIFY_FAULT" = metadata-short ]; then
    case "$*" in *'function metadata_header'*'specs/changes/001-example.md')
        printf 'task\037P1\0370\0371\037\n'; exit 0 ;;
    esac
fi
case "$VERIFY_FAULT:$*" in
    part-short:*'function metadata_header'*'specs/parts/p1.1-truncated.md')
        printf 'specs/parts/p1.1-truncated.md\037P1.1\n'; exit 0 ;;
    part-extra:*'function metadata_header'*'specs/parts/p1.1-truncated.md')
        printf 'specs/parts/p1.1-truncated.md\037P1.1\037\037\037\037extra\n'; exit 0 ;;
esac
exec "$REAL_AWK" "$@"
SH
chmod +x "$_SCRATCH_CWD"/bin/*
fault() { run env VERIFY_FAULT="$1" PATH="$_SCRATCH_CWD/bin:$PATH" "${@:2}"; }
failed() {
    if [ "$STATUS" -ne 0 ]; then _ok "$1"; else _no "$1" "unexpected success: $OUTPUT"; fi
}

source_fixture
manifest="$FIXTURE/.prdkit/.manifest"
cp "$manifest" "$_SCRATCH_CWD/clean-manifest"

it 'manifest-based adoption rejects a missing final LF, even after valid required rows'
size="$(wc -c < "$manifest")"
head -c "$((size - 1))" "$_SCRATCH_CWD/clean-manifest" > "$manifest"
run bash "$CHECKER" --json
failed "$_CURRENT"
assert_contains "$OUTPUT" 'LF-terminated'

it 'all adoption lanes reject empty, CRLF and unterminated manifests'
for format in empty crlf eof truncated; do
    case "$format" in
        empty) : > "$manifest" ;;
        crlf) awk '{printf "%s\r\n",$0}' "$_SCRATCH_CWD/clean-manifest" > "$manifest" ;;
        eof) head -c "$((size - 1))" "$_SCRATCH_CWD/clean-manifest" > "$manifest" ;;
        truncated) cp "$_SCRATCH_CWD/clean-manifest" "$manifest"; printf 'unparsed final entry' >> "$manifest" ;;
    esac
    fixture_commit
    run bash "$CHECKER" --json; failed "manifest lane: $format"
    fixture_reject; fixture_reject --head HEAD
done
cp "$_SCRATCH_CWD/clean-manifest" "$manifest"; fixture_commit

it 'manifest verification does not invent the managed AGENTS.md section terminator'
cp "$FIXTURE/AGENTS.md" "$_SCRATCH_CWD/clean-agents"
size="$(wc -c < "$FIXTURE/AGENTS.md")"
head -c "$((size - 1))" "$_SCRATCH_CWD/clean-agents" > "$FIXTURE/AGENTS.md"
run bash "$CHECKER" --json
failed "$_CURRENT"
assert_contains "$OUTPUT" 'managed section drift'
cp "$_SCRATCH_CWD/clean-agents" "$FIXTURE/AGENTS.md"

it 'adoption cannot approve a failed or short installation inventory'
fault install-index bash "$CHECKER" --json
failed "$_CURRENT"
assert_contains "$OUTPUT" 'Installation inventory did not complete'
for mode in find-fail find-empty find-eof; do
    fault "$mode" bash "$CHECKER" --json --require-source
    failed "worktree proof: $mode"
    assert_contains "$OUTPUT" '"source_verification":"failed"'
done
for mode in installed-empty installed-eof; do
    fault "$mode" bash "$CHECKER" --json --head HEAD
    failed "committed proof: $mode"
    assert_contains "$OUTPUT" '"source_verification":"failed"'
done
for mode in source-tree-fail source-tree-eof; do
    for lane in worktree committed; do
        args=(--require-source)
        [ "$lane" != committed ] || args=(--head HEAD)
        fault "$mode" bash "$CHECKER" --json "${args[@]}"
        failed "$lane: $mode"
    done
done
fixture_check; assert_eq 0 "$STATUS" 'healthy worktree proof'
fixture_check --head HEAD; assert_eq 0 "$STATUS" 'healthy committed proof'

it 'pinned-source proof refuses a short worktree snapshot or failed committed config read'
VERIFY_CONFIG_OID="$(git -C "$FIXTURE" rev-parse HEAD:.prdkit/memory/config.md)" || exit 1
export VERIFY_CONFIG_OID
fault config-short-worktree bash "$CHECKER" --json --require-source
failed 'short worktree config'
assert_contains "$OUTPUT" '"source_verification":"failed"'
fault config-fail-commit bash "$CHECKER" --json --head HEAD
failed 'failed committed config read'
assert_contains "$OUTPUT" '"source_verification":"failed"'

it 'truncated VERSION is not adoption evidence'
printf '1.5.0' > "$KIT/VERSION"
run bash "$CHECKER" --json; failed 'manifest lane VERSION without LF'
printf '1.5.0\n' > "$KIT/VERSION"

it 'adoption refuses a plausible count from a failed VERSION line counter'
COUNT_TARGET="$KIT/VERSION"; COUNT_HIT="$_SCRATCH_CWD/count-hit"
export COUNT_TARGET COUNT_HIT
printf 'stale second line\n' >> "$COUNT_TARGET"
fault line-count bash "$CHECKER" --json
failed 'failed VERSION line count'
assert_file "$COUNT_HIT"
assert_contains "$OUTPUT" 'Invalid kit source VERSION'
rm -f "$COUNT_HIT"
printf '1.5.0\n' > "$KIT/VERSION"

it 'pinned-source proof refuses a manifest version emitted by a failed reader'
for lane in worktree committed; do
    args=(--require-source)
    [ "$lane" != committed ] || args=(--head HEAD)
    fault version-reader bash "$CHECKER" --json "${args[@]}"
    failed "$lane: failed manifest version reader"
    assert_contains "$OUTPUT" 'Manifest must record exactly one readable version'
done

it 'both pinned-source lanes reject a required workflow missing after a pin change'
printf '# New Workflow\n' > "$KIT/workflows/zzz.md"
git -C "$KIT" add workflows/zzz.md && git -C "$KIT" commit -qm 'new required workflow' || exit 1
new_pin="$(git -C "$KIT" rev-parse HEAD)" || exit 1
git -C "$FIXTURE" update-index --cacheinfo "160000,$new_pin,.product-kit" || exit 1
fixture_commit
fixture_reject; fixture_reject --head HEAD

project="$(make_inited_project)" || exit 1
track_tmp "$project"
cd "$project" || exit 1
VERIFY_PROJECT="$(pwd -P)" || exit 1
export VERIFY_PROJECT
B="$VERIFY_PROJECT/.prdkit/scripts/bash"
mkdir -p specs/changes
git branch -M main
git add -A && git commit -qm installed || exit 1
git checkout -qb feature || exit 1
printf 'one\n' > one.txt
git add one.txt && git commit -qm example || exit 1
VERIFY_HEAD="$(git rev-parse HEAD)" || exit 1
export VERIFY_HEAD

it 'status and doctor refuse incomplete worktree inventories'
for mode in worktrees-fail worktrees-empty worktrees-eof worktrees-crlf; do
    for verifier in status doctor; do
        fault "$mode" bash "$B/$verifier.sh" --json
        failed "$verifier: $mode"
    done
done

it 'status and doctor refuse malformed canonical specs instead of reporting no findings'
for format in empty crlf eof truncated; do
    case "$format" in
        empty) : > specs/SPEC.md ;;
        crlf) printf '# Example\r\n- **R-01 First**: example.\r\n' > specs/SPEC.md ;;
        eof) printf '# Example\n- **R-01 First**: example.' > specs/SPEC.md ;;
        truncated) printf '# Example\n- **R-' > specs/SPEC.md ;;
    esac
    for verifier in status doctor; do
        run bash "$B/$verifier.sh" --json; failed "$verifier: $format"
    done
    for view in --stats compact; do
        args=()
        case "$view" in --stats) args=(--stats) ;; esac
        run bash "$B/read-spec.sh" ${args[@]+"${args[@]}"} specs/SPEC.md
        failed "reader $view: $format"
        assert_contains "$OUTPUT" 'Invalid spec text'
    done
    bash "$B/read-spec.sh" --raw specs/SPEC.md > "$_SCRATCH_CWD/raw"
    run cmp -s specs/SPEC.md "$_SCRATCH_CWD/raw"
    assert_eq 0 "$STATUS" "raw preserves $format bytes"
done
printf '# Example\n- **R-01 First**: example.\n' > specs/SPEC.md

it 'status and doctor reject incomplete or overlong part metadata rows'
mkdir -p specs/parts
printf '# P1.1 Truncated\n\n**Parent**: P9\n' > specs/parts/p1.1-truncated.md
for mode in part-short part-extra; do
    for verifier in status doctor; do
        fault "$mode" bash "$B/$verifier.sh" --json
        failed "$verifier: $mode"
        assert_contains "$OUTPUT" 'Invalid part metadata row'
    done
done
rm specs/parts/p1.1-truncated.md

it 'target lookup refuses damaged text even when the navigation target itself is intact'
target_file=specs/navigation.md
printf '%s\n' '# Example' 'Tracking: [X][nav-x]' '<!-- prdkit:navigation:v1 begin -->' \
    '[nav-x]: https://example.test/items/X' '<!-- prdkit:navigation:v1 end -->' > "$target_file"
run bash "$B/read-spec.sh" --target nav-x "$target_file"
assert_eq 0 "$STATUS" 'intact target resolves'
assert_contains "$OUTPUT" '[nav-x]: https://example.test/items/X'
size="$(wc -c < "$target_file")"
head -c "$((size - 1))" "$target_file" > "$_SCRATCH_CWD/target-eof"
mv "$_SCRATCH_CWD/target-eof" "$target_file"
run bash "$B/read-spec.sh" --target nav-x "$target_file"
failed 'reader target: eof'
assert_contains "$OUTPUT" 'Invalid spec text'
rm "$target_file"

it 'doctor rejects CRLF budget config and status refuses a description-less log entry'
config=.prdkit/memory/config.md
cp "$config" "$_SCRATCH_CWD/clean-config"
awk '{printf "%s\r\n",$0}' "$_SCRATCH_CWD/clean-config" > "$config"
run bash "$B/doctor.sh" --json; failed 'doctor CRLF config'
cp "$_SCRATCH_CWD/clean-config" "$config"
mkdir -p .prdkit/history/log
printf -- '- 2026-11-22 001-example:\n' > .prdkit/history/log/001-example.md
run bash "$B/status.sh" --json; failed 'status malformed log entry'
it 'status refuses a plausible count from a failed log-entry line counter'
COUNT_TARGET="$VERIFY_PROJECT/.prdkit/history/log/001-example.md"
printf '%s\n' '- 2026-11-22 001-example: done' 'stale second line' > "$COUNT_TARGET"
fault line-count bash "$B/status.sh" --json
failed 'failed log-entry line count'
assert_file "$COUNT_HIT"
assert_contains "$OUTPUT" 'Malformed log entry'
rm .prdkit/history/log/001-example.md

it 'read-spec detects a failed or short snapshot producer'
for mode in spec-fail spec-short; do
    fault "$mode" bash "$B/read-spec.sh" --stats specs/SPEC.md
    failed "$mode"
done
run bash "$B/read-spec.sh" --stats specs/SPEC.md
assert_eq 0 "$STATUS" 'complete snapshot parses'

it 'doctor fails if the deleted-record history producer fails or the tracked path list is short'
for mode in doc-history-fail doc-index-eof; do
    fault "$mode" bash "$B/doctor.sh" --json; failed "$mode"
done
run bash "$B/doctor.sh" --json
assert_eq 0 "$STATUS" "healthy doctor inventory: $OUTPUT"

it 'status cannot infer a squash from an incomplete changed-path list'
for mode in squash-empty squash-eof; do
    fault "$mode" bash "$B/status.sh" --json; failed "$mode"
done
run bash "$B/status.sh" --json
assert_eq 0 "$STATUS" "healthy status inventory: $OUTPUT"

it 'delivery requires exactly one complete remote-head record and no partial local observation'
git add specs && git commit -qm spec || exit 1
VERIFY_HEAD="$(git rev-parse HEAD)" || exit 1
for mode in remote-fail remote-empty remote-eof remote-crlf remote-duplicate remote-nul remote-partial; do
    fault "$mode" bash "$B/check-delivery.sh" --json "$project"
    failed "$mode"
    assert_contains "$OUTPUT" '"transport":"BLOCKED"'
done
fault local-status-fail bash "$B/check-delivery.sh" --local-only --json "$project"
failed 'local producer failure'

it 'close preflight refuses an incomplete duplicate scan without changing HEAD, index or record'
# A gate stub isolates preflight; the real host-review integration is covered in test_close_change.
printf '#!/usr/bin/env bash\nprintf "review passed\\n"\n' > "$B/check-review.sh"
git add "$B/check-review.sh" && git commit -qm 'stub delegated review' || exit 1
record=specs/changes/001-example.md
printf '# Change: Example\n\n**Tags**: sample\n' > "$record"
git add "$record" && git commit -qm 'open record' || exit 1
before_head="$(git rev-parse HEAD)"; before_index="$(git hash-object .git/index)"
close_args=(--pr https://example.test/pull/1 001-example 'Update behavior — R-01 — complete — #1')
it 'status, doctor and close reject a short optional metadata inventory'
for verifier in status doctor; do
    fault metadata-short bash "$B/$verifier.sh" --json
    failed "$verifier: missing metadata footer"
done
fault metadata-short bash "$B/close-change.sh" "${close_args[@]}"
failed 'close: missing metadata footer'
assert_contains "$OUTPUT" 'cannot read tags'
assert_eq "$before_head" "$(git rev-parse HEAD)" 'HEAD unchanged'
assert_eq "$before_index" "$(git hash-object .git/index)" 'index bytes unchanged'
assert_file "$record"
[ ! -e .prdkit/history/log/001-example.md ] || _no 'no entry written'
if [ "$(git rev-parse HEAD)" != "$before_head" ]; then git checkout -qb retry-metadata "$before_head" || exit 1; fi

it 'close preflight rejects invalid folded logs before writing an entry'
for format in empty crlf eof; do
    case "$format" in
        empty) : > .prdkit/history/log.md ;;
        crlf) printf '# Closed changes\r\n' > .prdkit/history/log.md ;;
        eof) printf '# Closed changes' > .prdkit/history/log.md ;;
    esac
    fault none bash "$B/close-change.sh" "${close_args[@]}"
    failed "close $format"
    assert_contains "$OUTPUT" 'invalid .prdkit/history/log.md'
    assert_eq "$before_head" "$(git rev-parse HEAD)" 'HEAD unchanged'
    assert_eq "$before_index" "$(git hash-object .git/index)" 'index bytes unchanged'
    assert_file "$record"
    [ ! -e .prdkit/history/log/001-example.md ] || _no 'no entry written'
    # Restore only this disposable fixture if the base accepted the malformed input.
    if [ "$(git rev-parse HEAD)" != "$before_head" ]; then git checkout -q -b "retry-$format" "$before_head" || exit 1; fi
done
printf '# Closed changes\n' > .prdkit/history/log.md
fault close-default-fail bash "$B/close-change.sh" "${close_args[@]}"
failed 'close default tree producer failed'
assert_contains "$OUTPUT" 'could not check for specs/changes/001-example.md on main'
assert_eq "$before_head" "$(git rev-parse HEAD)" 'HEAD unchanged after producer failure'
assert_file "$record"
if [ "$(git rev-parse HEAD)" != "$before_head" ]; then git checkout -qb retry-default "$before_head" || exit 1; fi

it 'a failed folded-log lookup is not a successful absence'
before_index="$(git hash-object .git/index)"
fault close-log-fail bash "$B/close-change.sh" "${close_args[@]}"
failed 'close folded log lookup failed'
assert_contains "$OUTPUT" 'could not check for .prdkit/history/log.md at HEAD'
assert_eq "$before_head" "$(git rev-parse HEAD)" 'HEAD unchanged after failed lookup'
assert_eq "$before_index" "$(git hash-object .git/index)" 'index unchanged after failed lookup'
assert_file "$record"
[ ! -e .prdkit/history/log/001-example.md ] || _no 'no duplicate entry written'
if [ "$(git rev-parse HEAD)" != "$before_head" ]; then git checkout -qb retry-log-fail "$before_head" || exit 1; fi

it 'close checks the committed folded log when sparse checkout omits it'
printf '# Closed changes\n\n- 2026-11-22 001-example: Already closed\n' > .prdkit/history/log.md
git add .prdkit/history/log.md && git commit -qm 'fold the existing entry' || exit 1
git sparse-checkout set --no-cone '/*' '!/.prdkit/history/log.md' || exit 1
[ ! -e .prdkit/history/log.md ] && git cat-file -e HEAD:.prdkit/history/log.md || exit 1
before_head="$(git rev-parse HEAD)"; before_index="$(git hash-object .git/index)"
run bash "$B/close-change.sh" "${close_args[@]}"
failed 'close sparse folded log'
assert_contains "$OUTPUT" 'the log already has an entry for 001-example'
assert_eq "$before_head" "$(git rev-parse HEAD)" 'HEAD unchanged with sparse folded log'
assert_eq "$before_index" "$(git hash-object .git/index)" 'index unchanged with sparse folded log'
assert_file "$record"
[ ! -e .prdkit/history/log/001-example.md ] || _no 'no entry written with sparse folded log'
finish
