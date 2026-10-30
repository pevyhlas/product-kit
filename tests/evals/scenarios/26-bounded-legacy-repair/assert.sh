#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
test -f .eval-state/render-pass || fail 'supported-path repair not verified'
test "$(PRIVATE_NOTE=another-private-sentinel bash src/render.sh 2>&1)" = Welcome || fail 'renderer disabled or still leaks'
test ! -e src/history.txt || fail 'optional legacy work added'
test -z "$(git status --porcelain -- scripts/check-render.sh specs/product.md specs/architecture.md)" || fail 'test or supported behavior weakened'
source "$PK_ROOT/tests/evals/fixture.sh"
state="$(fixture_section specs/changes/001-greeting.md State)"
printf '%s' "$state" | grep -Eiq 'C-01|privacy|leak' || fail 'present defect not justified'
printf '%s' "$state" | grep -Eiq 'remov|retir' || fail 'no removal disposition'
printf '%s' "$state" | grep -Eiq 'carry|reus|contract|test' || fail 'no carry-forward rationale'
echo 'ASSERT PASS: minimal legacy safety repair preserved supported output and replacement bounds'
