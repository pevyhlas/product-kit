#!/usr/bin/env bash
set -euo pipefail
fail() { echo "ASSERT FAIL: $1"; exit 1; }
cd "$FIXTURE"
record=specs/changes/001-greeting.md
source "$PK_ROOT/tests/evals/fixture.sh"
cmp -s src/greeting.txt <(printf 'Welcome\n') || fail 'requested exact bytes missing'
state="$(fixture_section "$record" State)"
[ -n "$state" ] || fail 'handover state missing'
printf '%s' "$state" | grep -qi 'constitution.md' || fail 'actual policy source lost'
printf '%s' "$state" | grep -qi 'commit' || fail 'commit authority lost'
printf '%s' "$state" | grep -qi 'push' || fail 'push authority lost'
printf '%s' "$state" | grep -qi 'merge' || fail 'separate integration hold lost'
printf '%s' "$state" | grep -qE '[0-9a-f]{40}' || fail 'checkpoint revision missing'
if grep -q '"tool":"question"' "$TRANSCRIPT"; then fail 'routine checkpoint requested new input'; fi
fixture_section "$record" Acceptance | grep -qi 'PASS' || fail 'actual verification missing'
bash .prdkit/scripts/bash/check-delivery.sh --json || fail 'checkpoint not remotely available'
[ -z "$(git status --porcelain)" ] || fail 'handover or intended work left unpublished'
echo 'ASSERT PASS: verified remote handover under standing authority'
