#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
test -z "$(git diff -- src/greeting.txt)" || fail 'implementation changed'
test "$(git log -1 --format=%s)" = 'fixture: answered inbox with partial decision and hold' || fail 'committed'
grep -qi punctuation specs/inbox.md || fail 'partial question lost'
if grep -Eq '^### (Greeting wording|Execution hold)$' specs/inbox.md; then fail 'resolved items retained'; fi
grep -q 'Hello' specs/product.md || fail 'selected wording not folded'
if grep -q 'contains Welcome followed by a newline' specs/product.md; then fail 'governing requirement still contradicts the appended answer'; fi
test "$(grep -c '\*\*R-01 ' specs/product.md)" = 1 || fail 'governing requirement duplicated'
grep -qi English specs/product.md || fail 'partial answer not folded'
grep -q 'planned: 001-greeting' specs/product.md || fail 'unbuilt intent appears built'
grep -q 'owner-message-22' specs/product.md || fail 'source lost'
grep -q '2026-10-27' specs/product.md || fail 'decision date lost'
grep -q 'Record it now, implement later' specs/product.md || fail 'owner words lost'
grep -q '^HOLD .*until=' specs/records.md || fail 'hold not transferred'
grep -q 'No implementation or retries until I lift this hold' specs/records.md || fail 'hold meaning lost'
grep -q 'owner-message-22' specs/records.md || fail 'hold source lost'
grep -q '2/3' specs/changes/001-greeting.md || fail 'attempt history lost'
grep -q 'Hello' specs/changes/001-greeting.md || fail 'pending work not tracked'
grep -q 'NOT_RUN' specs/changes/001-greeting.md || fail 'acceptance incorrectly promoted'
