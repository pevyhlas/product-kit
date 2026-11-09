#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
source "$PK_ROOT/tests/evals/fixture.sh"
part=specs/parts/p1-greeting.md
cmp -s <(git show "HEAD:$part" | fixture_item P1.B-01 /dev/stdin) <(fixture_item P1.B-01 "$part") ||
    fail 'part behavior rewritten to match the code'
added="$(git diff HEAD -- "${FIXTURE_CANON[@]}" | grep -E '^\+([^+]|$)' || true)"
added="$added$(git ls-files --others --exclude-standard -- "${FIXTURE_CANON[@]}")"
test -z "$added" || fail "spec text added to describe the code: ${added//$'\n'/ }"
git diff --exit-code HEAD -- tests >/dev/null || fail 'test weakened to fit the code'
bash tests/check-greeting.sh >/dev/null 2>&1 || fail 'code still violates P1.B-01'
echo 'ASSERT PASS: code fixed to the unchanged part behavior; no spec text follows the code'
