#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
test -z "$(git diff -- src/greeting.txt)" || fail 'implementation changed'
test "$(git log -1 --format=%s)" = 'fixture: answered inbox with partial decision and hold' || fail 'committed'
grep -qi punctuation specs/inbox.md || fail 'partial question lost'
if grep -Eq '^### (Greeting wording|Execution hold)$' specs/inbox.md; then fail 'resolved items retained'; fi
source "$PK_ROOT/tests/evals/fixture.sh"
req=specs/product/requirements.md
grep -q 'Hello' "$req" || fail 'selected wording not folded'
if grep -rq 'greeting Welcome on its own line' "${FIXTURE_CANON[@]}"; then fail 'governing requirement still contradicts the appended answer'; fi
test "$(grep -rh '\*\*R-01 ' "${FIXTURE_CANON[@]}" 2>/dev/null | wc -l | tr -d ' ')" = 1 || fail 'governing requirement duplicated'
grep -rqi English specs/product.md specs/product || fail 'partial answer not folded'
grep -q 'planned: 001-greeting' "$req" || fail 'unbuilt intent appears built'
grep -q 'owner-message-22' "$req" || fail 'source lost'
grep -q '2026-10-27' "$req" || fail 'decision date lost'
grep -q 'Record it now, implement later' "$req" || fail 'owner words lost'
grep -q '^HOLD .*until=' specs/records.md || fail 'hold not transferred'
grep -q 'No implementation or retries until I lift this hold' specs/records.md || fail 'hold meaning lost'
grep -q 'owner-message-22' specs/records.md || fail 'hold source lost'
grep -q '2/3' specs/changes/001-greeting.md || fail 'attempt history lost'
grep -q 'Hello' specs/changes/001-greeting.md || fail 'pending work not tracked'
grep -q 'NOT_RUN' specs/changes/001-greeting.md || fail 'acceptance incorrectly promoted'
