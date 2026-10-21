#!/usr/bin/env bash
# Context-budget diagnostics: doctor reports oversized agent context files as advisories that
# never fail by default; --strict promotes them to failing findings. Doctor stays read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
DOCTOR="$PROJ/.prdkit/scripts/bash/doctor.sh"
CONFIG="$PROJ/.prdkit/memory/config.md"
cd "$PROJ" || exit 1
set_config() { # key value
    sed -i.bak "s|^- $1:.*|- $1: $2|" "$CONFIG" && rm -f "$CONFIG.bak"
}
filler() { head -c "$1" /dev/zero | tr '\0' 'x' | fold -w 100; }

it "a fresh install has no advisories"
run bash "$DOCTOR" --json
assert_eq 0 "$STATUS" "fresh install passes doctor"
assert_contains "$OUTPUT" '"advisories":[]' "no advisories on a fresh install"
assert_contains "$OUTPUT" '"strict":false' "strict mode is off by default"
assert_contains "$(cat "$CONFIG")" "context-budget-bytes: 16384" "budget key seeded with its default"

it "an over-budget agent context file is an advisory, not a failure"
{ printf '# Project\n\n'; filler 20000; } > "$PROJ/CLAUDE.md"
BEFORE="$(cat "$PROJ/CLAUDE.md")"
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "advisory does not fail doctor"
assert_contains "$OUTPUT" "advisory: Context budget: CLAUDE.md is" "over-budget file reported"
assert_contains "$OUTPUT" "over context-budget-bytes 16384" "default budget named"
assert_contains "$OUTPUT" "--strict" "strict mode explained"
assert_eq "$BEFORE" "$(cat "$PROJ/CLAUDE.md")" "doctor leaves the context file unchanged"

it "--strict turns context-budget advisories into failing findings"
run bash "$DOCTOR" --json --strict
assert_eq 1 "$STATUS" "strict doctor fails on an over-budget file"
assert_contains "$OUTPUT" '"result":"fail"' "strict result is fail"
assert_contains "$OUTPUT" '"findings":["Context budget: CLAUDE.md is' "advisory promoted to a finding"
assert_contains "$OUTPUT" '"strict":true' "strict flag reported"

it "the configured budget is honored and 0 disables the byte check"
set_config context-budget-bytes 65536
run bash "$DOCTOR" --json --strict
assert_eq 0 "$STATUS" "a file within a raised budget passes strict doctor"
set_config context-budget-bytes 0
{ printf '# Project\n\n'; filler 90000; } > "$PROJ/CLAUDE.md"
run bash "$DOCTOR" --json --strict
assert_eq 0 "$STATUS" "budget 0 disables the agent-file byte check"

it "an invalid budget falls back to the default with an advisory"
set_config context-budget-bytes lots
run bash "$DOCTOR"
assert_eq 0 "$STATUS" "invalid value does not fail doctor"
assert_contains "$OUTPUT" "invalid context-budget-bytes 'lots'" "invalid value reported"
assert_contains "$OUTPUT" "over context-budget-bytes 16384" "default budget applies"

finish
