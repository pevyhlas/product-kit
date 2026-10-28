#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
DIR="$(mktemp -d)"; track_tmp "$DIR"
REPORT="$PK_ROOT/tests/benchmarks/report.sh"
EXAMPLE="$PK_ROOT/tests/benchmarks/example.json"
it "failed work and independent review contribute to accepted-change economics"
run bash "$REPORT" "$EXAMPLE"
assert_eq 0 "$STATUS" "valid fixture: $OUTPUT"
run jq -e '.kind=="fixture" and .matrix_complete and (.arms[0].metrics | .accepted==1 and .failed==1 and .attempts==3 and .total_tokens==610 and .cost_per_accepted_change==3.2 and .tokens_per_accepted_change==610 and .roles[0].role=="reviewer")' <<< "$OUTPUT"
assert_eq 0 "$STATUS" 'portfolio numerator includes failed work and the reviewer'

it "invalid later evidence produces no partial report"
for mutation in \
    '.runs[1].attempts[0].messages[0].meter_id="call-a"' \
    '.runs[0].acceptance.reviewer="worker-a"' \
    '.runs[0].attempts[1].session="session-a"' \
    '.runs[0].acceptance.revision="old-head"' \
    '.runs[0].attempts[0].messages[0].tokens.cache_read=-1' \
    '.runs[0].attempts[0].messages[0].tokens.output=1.5' \
    '.runs[1].attempts[0].messages[0].cost.reference=""' \
    '.runs += [.runs[0]]' \
    '.runs[1].replicate=2' \
    '.runs[0].attempts[0].usage_status="none"' \
    '.schema_version=2'; do
    jq "$mutation" "$EXAMPLE" > "$DIR/study.json"
    if bash "$REPORT" "$DIR/study.json" > "$DIR/out" 2> "$DIR/err"; then _no "rejected $mutation"; else _ok "rejected $mutation"; fi
    assert_eq '' "$(cat "$DIR/out")" 'invalid input never publishes a partial result'
done

it "unknown telemetry is not zero and missing matrix cells prevent completeness"
jq '.runs[1].attempts[0].usage_status="partial" | .runs[1].attempts[0].messages[0].tokens.reasoning=null | .runs[1].attempts[0].messages[0].cost={amount:null,basis:"unknown",reference:null} | .repetitions=2' "$EXAMPLE" > "$DIR/study.json"
run bash "$REPORT" "$DIR/study.json"
assert_eq 0 "$STATUS" 'partial observations are valid data'
run jq -e '(.matrix_complete|not) and (.arms[0].metrics | (.usage_complete|not) and (.cost_complete|not) and .observed_cost==1.2 and .total_cost==null and .cost_per_accepted_change==null and .tokens_per_accepted_change==null and .observed_tokens.reasoning==10)' <<< "$OUTPUT"
assert_eq 0 "$STATUS" 'partial known totals remain separate from complete portfolio metrics'

it "zero accepted changes cannot produce a cost-per-acceptance claim"
jq '.runs[0].outcome="abandoned" | .runs[0].acceptance=null' "$EXAMPLE" > "$DIR/study.json"
run bash "$REPORT" "$DIR/study.json"
run jq -e '.arms[0].metrics | .accepted==0 and .abandoned==1 and .total_cost==3.2 and .cost_per_accepted_change==null' <<< "$OUTPUT"
assert_eq 0 "$STATUS" 'zero denominator is unknown, not free success'
it "multiple documents and malformed JSON are rejected"
cat "$EXAMPLE" "$EXAMPLE" > "$DIR/study.json"
run bash "$REPORT" "$DIR/study.json"
if [ "$STATUS" -ne 0 ]; then _ok 'multiple study objects rejected'; else _no 'multiple study objects accepted'; fi
printf '{broken' > "$DIR/study.json"
run bash "$REPORT" "$DIR/study.json"
if [ "$STATUS" -ne 0 ]; then _ok 'malformed JSON rejected'; else _no 'malformed JSON accepted'; fi
finish
