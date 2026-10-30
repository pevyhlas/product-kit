#!/usr/bin/env bash
# Outcome accounting is independent of passing child checks; missing data is never progress.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
mkdir -p specs/changes
record=specs/changes/001-programme.md
cat > "$record" <<'MD'
# Change: First useful answer
**Opened**: 2026-10-01 · **Tier**: T2 · **Parent**: none
## Intent
**No-progress changes**: 0
## Acceptance
| Item | Proves | Check | Attempts | Result |
|------|--------|-------|----------|--------|
| A1 | R-01 | source check | 1 | PASS |
## State
**Step**: build
**Waiting on**: provider provisioning
**Outcome**: Owner's "answer" through the new path — R-01
**Milestone**: A2 integrated answer; source contract check is its prerequisite
**Critical path**: source contract -> integration -> provider pass
**Allocation**: one repair lane; one foundation lane; elapsed cost unknown
**Progress**: none; three child repairs passed but A2 and its prerequisites did not advance
**No-progress changes**: 3
**Selection**: reassess against the independent source contract
<!-- Instructions/examples do not override real fields.
**No-progress changes**: 0
-->
```
**Progress limit**: 99
```
MD
cat > specs/log.md <<'MD'
- 2026-10-02 002-repair: repair one — R-01 — source PASS — PR 1
- 2026-10-03 003-repair: repair two — R-01 — source PASS — PR 2
- 2026-10-04 004-repair: repair three — R-01 — source PASS — PR 3
MD

status_json() { bash .prdkit/scripts/bash/status.sh --json; }
checkpoint() { printf '%s' "$OUTPUT" | jq -c '.outcome_progress[] | select(.id == "001-programme")'; }

it "passing repairs still trigger outcome reassessment at the default bound"
before="$(git status --porcelain; cat "$record" specs/log.md)"
run status_json
assert_eq 0 "$STATUS" "JSON status succeeds"
row="$(checkpoint)"
assert_eq reassess "$(printf '%s' "$row" | jq -r .count_signal)" "success train is flagged"
assert_eq 3 "$(printf '%s' "$row" | jq -r .progress_limit)" "absent limit defaults to three"
assert_eq 3 "$(printf '%s' "$row" | jq -r .no_progress_changes)" "only State data, not examples/Intent"
assert_contains "$row" 'Owner' "goal retained with JSON escaping"
assert_eq 'one repair lane; one foundation lane; elapsed cost unknown' "$(printf '%s' "$row" | jq -r .allocation)" "lane purposes preserved"
assert_eq 1 "$(printf '%s' "$OUTPUT" | jq -r '.changes[0].acceptance.passed')" "technical PASS is separate"
assert_eq "$before" "$(git status --porcelain; cat "$record" specs/log.md)" "status is read-only"
run bash .prdkit/scripts/bash/status.sh
assert_contains "$OUTPUT" 'REASSESS: 3 integrated changes' "human warning"
assert_contains "$OUTPUT" 'critical path: source contract -> integration -> provider pass' "critical path visible"
outcome_line="$(printf '%s\n' "$OUTPUT" | grep -n '^Outcome progress' | cut -d: -f1)"
inflight_line="$(printf '%s\n' "$OUTPUT" | grep -n '^In flight' | cut -d: -f1)"
assert_eq yes "$([ "$outcome_line" -lt "$inflight_line" ] && echo yes)" "outcome before task/test totals"

it "an older record with passing acceptance and merged children remains unknown"
cp "$record" record-original
sed '/^\*\*No-progress changes\*\*:/d' record-original > "$record"
run status_json
row="$(checkpoint)"
assert_eq unknown "$(printf '%s' "$row" | jq -r .count_signal)" "missing count is unknown"
assert_eq null "$(printf '%s' "$row" | jq -r .no_progress_changes)" "no inferred zero"
printf '\n**No-progress changes**: unknown\n' >> "$record"
run status_json
assert_eq unknown "$(checkpoint | jq -r .count_signal)" "explicit unreconciled history stays unknown"
cp record-original "$record"

it "explicit limits and a reported enabling advance do not claim product acceptance"
printf '\n**Progress limit**: 4\n' >> "$record"
run status_json
assert_eq below-limit "$(checkpoint | jq -r .count_signal)" "explicit limit respected"
sed 's/^\*\*No-progress changes\*\*: 3/**No-progress changes**: 0/; s/^\*\*Progress\*\*: none.*/**Progress**: source contract verified at abc123; local only, integration pending/' "$record" > record-next
mv record-next "$record"
run status_json
row="$(checkpoint)"
assert_eq 0 "$(printf '%s' "$row" | jq -r .no_progress_changes)" "reported dependency advance projected"
assert_contains "$row" 'local only, integration pending' "scope of evidence retained"
assert_contains "$OUTPUT" '"readiness":"requires-evidence-review"' "no readiness granted"

it "invalid or ambiguous accounting cannot silently disable reassessment"
for extra in '**No-progress changes**: -1' '**No-progress changes**: 1.5' '**No-progress changes**: 01' '**No-progress changes**: ' '**Progress limit**: 0' '**Progress limit**: unlimited' '**Milestone**: conflicting checkpoint'; do
    cp record-original "$record"
    case "$extra" in
        '**No-progress changes**:'*) sed '/^\*\*No-progress changes\*\*:/d' "$record" > record-next; mv record-next "$record" ;;
    esac
    printf '\n%s\n' "$extra" >> "$record"
    run status_json
    assert_eq invalid "$(checkpoint | jq -r .count_signal)" "invalid: $extra"
done
cp record-original "$record"
printf '\n**No-progress changes**: 0\n' >> "$record"
run status_json
assert_eq invalid "$(checkpoint | jq -r .count_signal)" "duplicate count does not replace three with zero"
assert_eq null "$(checkpoint | jq -r .no_progress_changes)" "ambiguous count not projected as a number"

it "large decimal counters compare exactly without integer overflow"
sed '/^\*\*No-progress changes\*\*:/d' record-original > "$record"
printf '\n**No-progress changes**: 999999999999999999999999999999\n**Progress limit**: 1000000000000000000000000000000\n' >> "$record"
run status_json
assert_eq below-limit "$(checkpoint | jq -r .count_signal)" "longer decimal bound wins"
sed '/^\*\*No-progress changes\*\*:/d' record-original > "$record"
printf '\n**No-progress changes**: 100000000000000000000000000001\n**Progress limit**: 100000000000000000000000000002\n' >> "$record"
run status_json
assert_eq below-limit "$(checkpoint | jq -r .count_signal)" "equal-length decimals do not round up to the bound"

it "progress uses the same winning worktree copy as ordinary status"
cp record-original "$record"
git add -A && git commit -qm 'programme baseline'
WT="$(mktemp -d)"; track_tmp "$WT"; rmdir "$WT"
git worktree add -q -b 001-programme "$WT" HEAD
sed 's/^\*\*No-progress changes\*\*: 3/**No-progress changes**: 2/' "$record" > "$WT/$record"
run status_json
row="$(checkpoint)"
assert_eq 2 "$(printf '%s' "$row" | jq -r .no_progress_changes)" "own branch wins over stale root"
assert_eq "$(printf '%s' "$OUTPUT" | jq -r '.changes[0].location')" "$(printf '%s' "$row" | jq -r .location)" "same provenance"
printf -- '- 2026-10-05 001-programme: complete — R-01 — PR 4\n' >> specs/log.md
run status_json
assert_eq 1 "$(printf '%s' "$OUTPUT" | jq '.outcome_progress | length')" "root open record still projected"
rm "$record"
run status_json
assert_eq 0 "$(printf '%s' "$OUTPUT" | jq '.outcome_progress | length')" "closed stale worktree is not resurrected"

finish
