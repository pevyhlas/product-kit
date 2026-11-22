#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$PK_ROOT/scripts/maintainer/fails-on-base.sh"
if [ ! -f "$CHECK" ]; then
    echo 'Cannot run: scripts/maintainer/fails-on-base.sh is missing.' >&2
    exit 1
fi

FIXTURE="$(mktemp -d)" || exit 1
track_tmp "$FIXTURE"
mkdir -p "$FIXTURE"/{scripts,templates,commands,workflows,tests/helpers} || exit 1

g() { git -C "$FIXTURE" "$@"; }
commit() { g add -A && g commit -qm "$1" && g rev-parse HEAD; }
replay() ( cd "$FIXTURE" && bash "$CHECK" "$@" )
compare() { GITHUB_STEP_SUMMARY='' run replay "$@"; }

g init -q && g config user.name test && g config user.email test@example.invalid || exit 1
for dir in scripts templates commands workflows; do
    printf 'old\n' > "$FIXTURE/$dir/value"
done
printf 'exit 99\n' > "$FIXTURE/tests/test_unchanged.sh"
printf 'exit 99\n' > "$FIXTURE/tests/test_deleted.sh"
printf 'obsolete\n' > "$FIXTURE/tests/obsolete-fixture"
printf 'exit 0\n' > "$FIXTURE/tests/test_renamed.sh"
printf 'exit 99\n' > "$FIXTURE/tests/test_changed.sh"
BASE="$(commit 'common ancestor')" || exit 1
printf 'base-only\n' > "$FIXTURE/scripts/value"
printf 'exit 99\n' > "$FIXTURE/tests/test_base_only.sh"
BASE_TIP="$(commit 'base advanced independently')" || exit 1

g checkout -q --detach "$BASE" || exit 1
printf 'head fixture\n' > "$FIXTURE/tests/fixture"
printf 'exit 99\n' > "$FIXTURE/tests/helpers/test_not_an_entry_point.sh"
rm "$FIXTURE/tests/test_deleted.sh" "$FIXTURE/tests/obsolete-fixture" || exit 1
mv "$FIXTURE/tests/test_renamed.sh" "$FIXTURE/tests/test_new_name.sh" || exit 1
cat > "$FIXTURE/tests/test_changed.sh" <<'TEST'
set -e
test -z "${GITHUB_STEP_SUMMARY:-}"
test ! -e tests/obsolete-fixture
test "$(cat tests/fixture)" = 'head fixture'
# Prove the snapshot is the common ancestor, not the moving base tip or a merged checkout.
case "$(cat scripts/value)" in old|fixed) ;; *) exit 42 ;; esac
TEST
NO_REPRO="$(commit 'test changes that pass on both')" || exit 1

for dir in scripts templates commands workflows; do
    printf 'fixed\n' > "$FIXTURE/$dir/value"
done
cat > "$FIXTURE/tests/test_regression space.sh" <<'TEST'
set -e
for dir in scripts templates commands workflows; do
    test "$(cat "$dir/value")" = "$(cat scripts/value)"
done
if [ "$(cat scripts/value)" != fixed ]; then
    printf 'old behavior reproduced\n'
    exit 1
fi
TEST
printf 'present\n' > "$FIXTURE/templates/new-input"
cat > "$FIXTURE/tests/test_missing.sh" <<'TEST'
if [ ! -f templates/new-input ]; then
    echo 'Cannot run: missing <templates/new-input> & required by test'
    exit 127
fi
TEST
printf 'exit 2\n' > "$FIXTURE/tests/test_broken.sh"
# shellcheck disable=SC2016 # The fixture reads the snapshot when it runs.
printf 'test "$(cat scripts/value)" = old\n' > "$FIXTURE/tests/test_head_only_failure.sh"
HEAD_TIP="$(commit 'regression cases')" || exit 1

it "head tests and fixtures run against the exact snapshots and only changed suites are selected"
compare "$BASE_TIP" "$HEAD_TIP" 'fix(close)!: keep failed writes retryable'
assert_eq 0 "$STATUS" "one or more reproductions pass the fix policy"
assert_contains "$OUTPUT" "Base (merge base): \`$BASE\` · Head: \`$HEAD_TIP\`"
assert_contains "$OUTPUT" '2 of 6 changed test suite(s) fail on base and pass on head.'
assert_contains "$OUTPUT" '<code>tests/test_changed.sh</code> — Base: PASS; Head: PASS.'
assert_contains "$OUTPUT" '<code>tests/test_new_name.sh</code> — Base: PASS; Head: PASS.'
assert_contains "$OUTPUT" '<code>tests/test_regression\ space.sh</code> — Base: FAIL (exit 1); Head: PASS.'
assert_contains "$OUTPUT" 'old behavior reproduced'
assert_contains "$OUTPUT" '<code>tests/test_missing.sh</code> — Base: FAIL (exit 127); Head: PASS.'
assert_contains "$OUTPUT" 'missing &lt;templates/new-input&gt; &amp; required by test'
assert_contains "$OUTPUT" '<code>tests/test_broken.sh</code> — Base: FAIL (exit 2); Head: FAIL (exit 2).'
assert_contains "$OUTPUT" '<code>tests/test_head_only_failure.sh</code> — Base: PASS; Head: FAIL (exit 1).'
for excluded in test_not_an_entry_point.sh test_base_only.sh test_unchanged.sh test_deleted.sh test_renamed.sh; do
    assert_not_contains "$OUTPUT" "$excluded"
done
assert_eq "$HEAD_TIP" "$(g rev-parse HEAD)" "source checkout stays at its original commit"
assert_eq "" "$(g status --porcelain)" "source checkout stays clean"

it "a conventional fix needs a base failure and a head pass; lookalike titles are advisory"
for title in 'fix: patch' 'fix(close): patch' 'fix!: patch' 'fix(close)!: patch'; do
    compare "$BASE_TIP" "$NO_REPRO" "$title"
    assert_eq 1 "$STATUS" "$title requires a reproduction"
    assert_contains "$OUTPUT" 'A fix PR must have at least one changed test suite'
done
for title in 'fixture: patch' 'fixing the docs' 'feat: a fix'; do
    compare "$BASE_TIP" "$NO_REPRO" "$title"
    assert_eq 0 "$STATUS" "$title is advisory"
    assert_contains "$OUTPUT" '0 of 2 changed test suite(s)'
done

it "failures in both snapshots or on head only do not count, and are advisory for a feature"
compare "$NO_REPRO" "$HEAD_TIP" 'feat: add behavior'
assert_eq 0 "$STATUS" "head test failures are reported without enforcing fix policy"
assert_contains "$OUTPUT" 'Head failure output'
BROKEN_ONLY="$(g checkout -q --detach "$BASE" &&
    printf 'exit 1\n' > "$FIXTURE/tests/test_broken.sh" &&
    commit 'fails in both snapshots')" || exit 1
compare "$BASE_TIP" "$BROKEN_ONLY" 'fix: no evidence'
assert_eq 1 "$STATUS" "a base failure also failing on head is not evidence"
assert_contains "$OUTPUT" '0 of 1 changed test suite(s)'

it "zero changed suites fail a fix, and the workflow summary is appended even on failure"
SUMMARY="$_SCRATCH_CWD/summary"
printf 'earlier summary\n' > "$SUMMARY"
GITHUB_STEP_SUMMARY="$SUMMARY" run replay "$BASE_TIP" "$BASE" 'fix: no tests'
assert_eq 1 "$STATUS"
assert_eq '' "$OUTPUT" "not duplicated on stdout when writing a job summary"
assert_eq 'earlier summary' "$(head -n 1 "$SUMMARY")"
assert_contains "$(cat "$SUMMARY")" 'No added or changed test suites.'
compare "$BASE_TIP" "$BASE" 'docs: no tests'
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '0 of 0 changed test suite(s)'

it "a stalled base times out, its children stop, and head and later suites still run"
g checkout -q --detach "$BASE" || exit 1
printf 'fixed\n' > "$FIXTURE/scripts/value"
cat > "$FIXTURE/tests/test_10_stalled.sh" <<'TEST'
if [ "$(cat scripts/value)" = old ]; then
    trap '' TERM
    sleep 12 &
    printf '%s\n' "$!" > "$REPLAY_TEST_CHILD"
    echo 'old behavior stalled'
    wait
fi
TEST
printf 'exit 0\n' > "$FIXTURE/tests/test_20_finished.sh"
STALLED="$(commit 'stalled base regression')" || exit 1
export REPLAY_TEST_CHILD="$_SCRATCH_CWD/stalled-child"
child_stopped() {
    local pid proc_state until
    [ -s "$REPLAY_TEST_CHILD" ] || return 1
    read -r pid < "$REPLAY_TEST_CHILD" || return 1
    until=$((SECONDS + 3))
    while :; do
        proc_state="$(ps -o stat= -p "$pid" 2>/dev/null)" || return 0
        if [[ $proc_state =~ ^[[:space:]]*Z ]]; then return 0; fi # already stopped; not yet reaped
        if [ "$SECONDS" -ge "$until" ]; then return 1; fi
        sleep 1
    done
}
for title in 'feat: advisory stall' 'fix: handle stall'; do
    PRDKIT_REPLAY_SUITE_SECONDS=2 compare "$BASE" "$STALLED" "$title"
    assert_eq 0 "$STATUS" "base timeout is valid evidence when head passes: $title"
    assert_contains "$OUTPUT" '<code>tests/test_10_stalled.sh</code> — Base: FAIL (timed out after 2s); Head: PASS.'
    assert_contains "$OUTPUT" 'old behavior stalled'
    assert_contains "$OUTPUT" '<code>tests/test_20_finished.sh</code> — Base: PASS; Head: PASS.'
    assert_contains "$OUTPUT" '1 of 2 changed test suite(s)'
    if child_stopped; then _ok 'TERM-ignoring descendant stopped'; else _no 'descendant is still running'; fi
done

it "the head has its own timeout and a normal exit 124 is not labeled a timeout"
cat > "$FIXTURE/tests/test_40_head_timeout.sh" <<'TEST'
if [ "$(cat scripts/value)" = fixed ]; then sleep 12; else exit 124; fi
TEST
HEAD_STALL="$(commit 'head also stalls')" || exit 1
PRDKIT_REPLAY_SUITE_SECONDS=2 compare "$BASE" "$HEAD_STALL" 'ci: report head timeout'
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '<code>tests/test_40_head_timeout.sh</code> — Base: FAIL (exit 124); Head: FAIL (timed out after 2s).'
assert_contains "$OUTPUT" '1 of 3 changed test suite(s)'

it "the comparison budget marks unrun suites without treating them as evidence"
PRDKIT_REPLAY_BUDGET_SECONDS=5 compare "$BASE" "$STALLED" 'fix: no time for evidence'
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" '<code>tests/test_10_stalled.sh</code> — Not run on base or head (comparison budget exhausted).'
assert_contains "$OUTPUT" '2 suite(s) not run; skipped suites are not evidence.'
assert_contains "$OUTPUT" '0 of 2 changed test suite(s)'

it "a completed row is already in the summary when a later suite is still running"
g checkout -q --detach "$STALLED" || exit 1
printf 'exit 0 # updated in the cancellation fixture\n' > "$FIXTURE/tests/test_20_finished.sh"
cat > "$FIXTURE/tests/test_30_later.sh" <<'TEST'
trap '' TERM
sleep 12 &
printf '%s\n' "$!" > "$REPLAY_TEST_CHILD"
: > "$REPLAY_TEST_STARTED"
wait
TEST
CANCEL_HEAD="$(commit 'later suite stalls on cancellation')" || exit 1
export REPLAY_TEST_STARTED="$_SCRATCH_CWD/started"
: > "$SUMMARY"
(
    cd "$FIXTURE" || exit 1
    export GITHUB_STEP_SUMMARY="$SUMMARY" PRDKIT_REPLAY_SUITE_SECONDS=10
    exec bash "$CHECK" "$STALLED" "$CANCEL_HEAD" 'ci: cancellation fixture'
) >"$_SCRATCH_CWD/cancel-log" 2>&1 &
replay_pid=$!
stop_wait_at=$((SECONDS + 8))
while [ ! -f "$REPLAY_TEST_STARTED" ] && [ "$SECONDS" -lt "$stop_wait_at" ]; do sleep 1; done
assert_file "$REPLAY_TEST_STARTED" "later base suite reached its stall"
assert_contains "$(cat "$SUMMARY")" '<code>tests/test_20_finished.sh</code> — Base: PASS; Head: PASS.' \
    "completed row is visible before cancellation"
kill -TERM "$replay_pid" 2>/dev/null
cancel_status=0
wait "$replay_pid" || cancel_status=$?
assert_eq 143 "$cancel_status" "comparator stopped on TERM"
assert_contains "$(cat "$SUMMARY")" '<code>tests/test_20_finished.sh</code> — Base: PASS; Head: PASS.' \
    "completed row survives the comparator's cleanup"
assert_not_contains "$(cat "$SUMMARY")" 'tests/test_30_later.sh' "interrupted suite never reports a result"
if child_stopped; then _ok 'cancellation stopped the later descendant'; else _no 'cancelled descendant is still running'; fi

finish
