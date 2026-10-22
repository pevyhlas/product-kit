#!/usr/bin/env bash
# Tests for the behavioral eval runner (tests/evals/run-evals.sh) using the
# deterministic mock driver — no agent CLI, no subscription, no network.
# Verifies the pass/fail plumbing both ways: a well-behaved (comply) mock makes
# every scenario PASS, a misbehaving (violate) mock makes every scenario FAIL.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RUNNER="$PK_ROOT/tests/evals/run-evals.sh"
SCENARIO_COUNT=$(find "$PK_ROOT/tests/evals/scenarios" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' ')

# --- syntax: every eval shell script parses ---
it "eval scripts pass 'bash -n'"
for s in "$RUNNER" "$PK_ROOT"/tests/evals/drivers/mock.sh \
         "$PK_ROOT"/tests/evals/scenarios/*/setup.sh \
         "$PK_ROOT"/tests/evals/scenarios/*/assert.sh; do
    if bash -n "$s" 2>/dev/null; then _ok "syntax ok: ${s#"$PK_ROOT"/}"; else _no "syntax error: ${s#"$PK_ROOT"/}"; fi
done

# --- --list ---
it "--list shows every scenario and needs no driver"
run bash "$RUNNER" --list
assert_eq 0 "$STATUS" "--list exits 0"
assert_contains "$OUTPUT" "01-open-change" "lists 01-open-change"
assert_contains "$OUTPUT" "13-explicit-recovery-hold" "lists 13-explicit-recovery-hold"
assert_contains "$OUTPUT" "16-stall-budget" "lists 16-stall-budget"
assert_not_contains "$OUTPUT" "02-implement-gate" "retired 0.x gate scenarios stay retired"

# --- unknown / missing drivers degrade gracefully ---
it "unknown driver produces a clear error"
run bash "$RUNNER" --driver not-a-driver
assert_eq 1 "$STATUS" "unknown driver exits 1"
assert_contains "$OUTPUT" "Unknown driver" "names the problem"
assert_contains "$OUTPUT" "mock" "points at supported drivers"

# --- comply mode: all scenarios pass ---
RES1="$(mktemp -d)"; track_tmp "$RES1"
it "mock driver (comply): every scenario passes and runner exits 0"
run env EVAL_RESULTS_DIR="$RES1" EVAL_MOCK_MODE=comply bash "$RUNNER" --driver mock
assert_eq 0 "$STATUS" "runner exits 0 when all scenarios pass"
assert_contains "$OUTPUT" "$SCENARIO_COUNT passed, 0 failed, 0 errored" "reports all passed"
assert_not_contains "$OUTPUT" "ASSERT FAIL" "no assertion failures leak"

it "comply run writes one JSON line per scenario"
jsonl="$(find "$RES1" -mindepth 2 -maxdepth 2 -name 'results.jsonl' 2>/dev/null | head -n 1)"
assert_file "$jsonl" "results.jsonl written"
assert_eq "$SCENARIO_COUNT" "$(wc -l < "$jsonl" | tr -d ' ')" "one line per scenario"
assert_eq "$SCENARIO_COUNT" "$(grep -c '"verdict":"pass"' "$jsonl")" "every line records verdict pass"
assert_contains "$(cat "$jsonl")" '"driver":"mock"' "records the driver"
assert_contains "$(cat "$jsonl")" '"driver_version":"offline-mock"' "records actual driver version"
assert_contains "$(cat "$jsonl")" '"kit_dirty":' "does not confuse dirty source with a released revision"

it "comply run captures transcripts"
tr1="$(find "$RES1" -mindepth 2 -maxdepth 2 -name '01-open-change.transcript.txt' 2>/dev/null | head -n 1)"
assert_file "$tr1" "transcript written for 01"
assert_contains "$(cat "$tr1")" "prompt" "transcript includes the prompt echo"
assert_file "${tr1%.transcript.txt}.install-manifest" "installed input hashes preserved with the run"

# --- violate mode: every scenario's violation is caught ---
RES2="$(mktemp -d)"; track_tmp "$RES2"
it "mock driver (violate): every violation is caught and runner exits 1"
run env EVAL_RESULTS_DIR="$RES2" EVAL_MOCK_MODE=violate bash "$RUNNER" --driver mock
assert_eq 1 "$STATUS" "runner exits 1 when scenarios fail"
assert_contains "$OUTPUT" "0 passed, $SCENARIO_COUNT failed, 0 errored" "reports all failed"

it "violate run records fail verdicts in JSONL"
jsonl2="$(find "$RES2" -mindepth 2 -maxdepth 2 -name 'results.jsonl' 2>/dev/null | head -n 1)"
assert_file "$jsonl2" "results.jsonl written"
assert_eq "$SCENARIO_COUNT" "$(grep -c '"verdict":"fail"' "$jsonl2")" "every line records verdict fail"

# --- single-scenario selection ---
RES3="$(mktemp -d)"; track_tmp "$RES3"
it "--scenario runs exactly one scenario"
run env EVAL_RESULTS_DIR="$RES3" bash "$RUNNER" --driver mock --scenario 13-explicit-recovery-hold
assert_eq 0 "$STATUS" "single scenario passes"
assert_contains "$OUTPUT" "13-explicit-recovery-hold" "selected scenario ran"
assert_contains "$OUTPUT" "1 passed, 0 failed, 0 errored" "only one scenario ran"

it "--scenario with a bogus name errors"
run env EVAL_RESULTS_DIR="$RES3" bash "$RUNNER" --driver mock --scenario 99-does-not-exist
assert_eq 1 "$STATUS" "bogus scenario exits 1"
assert_contains "$OUTPUT" "No scenario matched" "explains the miss"

# --- fixture storage failure ---
# A failing mktemp first on PATH stands in for unavailable storage. An empty fixture path once
# made a scenario set up Git, install the kit and commit in the caller's current directory.
CALLER="$(make_project)"; track_tmp "$CALLER"
NOTMP="$(mktemp -d)"; track_tmp "$NOTMP"
printf '#!/bin/sh\nexit 1\n' > "$NOTMP/mktemp"; chmod +x "$NOTMP/mktemp"
RES4="$(mktemp -d)"; track_tmp "$RES4"
caller_state() {
    git -C "$CALLER" rev-parse HEAD
    git -C "$CALLER" show-ref
    git -C "$CALLER" config --local --list
    git -C "$CALLER" status --porcelain --untracked-files=all
}
state_before="$(caller_state)"

it "unavailable fixture storage stops the runner before it touches the caller repository"
run bash -c 'cd "$1" && PATH="$2:$PATH" EVAL_RESULTS_DIR="$3" bash "$4" --driver mock --scenario 01-open-change' \
    _ "$CALLER" "$NOTMP" "$RES4" "$RUNNER"
assert_eq 1 "$STATUS" "the runner stops"
assert_contains "$OUTPUT" "Cannot allocate an eval fixture for 01-open-change" "the failure is explicit"
assert_eq "$state_before" "$(caller_state)" "caller HEAD, refs, Git config and files untouched"

it "fixture setup refuses an empty, missing or non-empty fixture root"
for bad in "" "$NOTMP/missing" "$NOTMP"; do
    run bash -c 'cd "$1" && export FIXTURE="$2" PK_ROOT="$3" && source "$3/tests/evals/fixture.sh" && fixture_project' \
        _ "$CALLER" "$bad" "$PK_ROOT"
    assert_eq 1 "$STATUS" "refused: '$bad'"
    assert_contains "$OUTPUT" "must name a new, empty directory" "explicit refusal: '$bad'"
done
assert_eq "$state_before" "$(caller_state)" "caller repository still untouched"

finish
