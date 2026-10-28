#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
it "current artifact installs, upgrades twice and diagnoses without the source checkout"
run bash "$PK_ROOT/tests/evals/consumer-smoke.sh"
assert_eq 0 "$STATUS" "consumer smoke: $OUTPUT"
run jq -e '.kind == "deterministic-consumer-smoke" and .result == "pass" and (.targets | length) == 4 and all(.targets[]; .result == "pass" and .native_loading == "unknown" and .agent_execution == "unknown")' <<< "$OUTPUT"
assert_eq 0 "$STATUS" 'machine evidence separates filesystem contracts from actual agent behavior'
finish
