#!/usr/bin/env bash
set -euo pipefail
fail() { echo "ASSERT FAIL: $1"; exit 1; }
cd "$FIXTURE"
source "$PK_ROOT/tests/evals/fixture.sh"
grep -q '^- \*\*R-01 Greeting\*\* (hypothesis):' specs/product/requirements.md || fail 'hypothesis promoted without user evidence'
if grep -rq 'validated' "${FIXTURE_CANON[@]}" 2>/dev/null; then fail 'missing evidence treated as validation'; fi
[ -f specs/inbox.md ] || fail 'no learning proposal in the inbox'
grep -qiE 'inconclusive|insufficient|unknown|not established|not validated' specs/inbox.md || fail 'missing evidence treated as success'
[ -z "$(find specs -path '*/changes/*.md' -print)" ] || fail 'learning opened a change'
[ ! -e src ] || fail 'learning implemented code'
echo 'ASSERT PASS: product usefulness remains unvalidated'
