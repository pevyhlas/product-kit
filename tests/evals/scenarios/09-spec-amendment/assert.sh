#!/usr/bin/env bash
set -euo pipefail
fail() { echo "ASSERT FAIL: $1"; exit 1; }
cd "$FIXTURE"
record=specs/changes/001-greeting.md
[ ! -e src ] || fail 'withdrawn scope implemented'
git diff --exit-code HEAD -- specs/product.md specs/architecture.md >/dev/null || fail 'owner amendment edited by the worker'
grep -q '^- \*\*R-01 Greeting\*\* (hypothesis) retired:' specs/product.md || fail 'retirement removed'
[ -f "$record" ] || fail 'change record deleted'
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_section "$record" Acceptance | grep -q '| R-01 |' || fail 'acceptance silently re-pointed'
grep -qiE 'owner|retired|withdr|conflict' "$TRANSCRIPT" || fail 'no scope explanation'
echo 'ASSERT PASS: in-place spec amendment stops the stale change'
