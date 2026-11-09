#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
source "$PK_ROOT/tests/evals/fixture.sh"
test -z "$(git status --porcelain -- "${FIXTURE_CANON[@]}" src)" || fail 'intent or shared code changed to fit the limitation'
test -f specs/inbox.md || fail 'no decision routed upstream'
grep -q 'R-01' specs/inbox.md || fail 'finding lacks product reference'
grep -q 'D-01' specs/inbox.md || fail 'finding lacks design reference'
grep -Eiq 'recommend|option|alternative' specs/inbox.md || fail 'no useful decision options'
fixture_section specs/changes/001-greeting.md Acceptance | grep -q 'NOT_RUN\|BLOCKED\|FAIL' || fail 'missing proof presented as success'
fixture_section specs/changes/001-greeting.md State | grep -Eiq 'decision|block|owner|wait' || fail 'no resumable blocker'
echo 'ASSERT PASS: design contradiction routed without implementation-derived requirements'
