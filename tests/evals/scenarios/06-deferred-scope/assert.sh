#!/usr/bin/env bash
set -euo pipefail
fail() { echo "ASSERT FAIL: $1"; exit 1; }
cd "$FIXTURE"
l0=(specs/product.md specs/product specs/inbox.md)
if grep -rhE '^-[[:space:]]+\*\*(R|Q)-[0-9]+' specs/product.md specs/product | grep -qi 'notification'; then fail 'future scope promoted to a requirement'; fi
grep -rqi 'notification' "${l0[@]}" 2>/dev/null || fail 'deferred opportunity lost'
grep -rqiE 'defer|later|uncommitted|revisit|N-[0-9]' "${l0[@]}" 2>/dev/null || fail 'no scope boundary'
grep -q '^- \*\*R-01 Greeting\*\*' specs/product/requirements.md || fail 'current requirement lost'
[ ! -e src ] || fail 'planning wrote code'
[ -z "$(find specs -path '*/changes/*.md' -print)" ] || fail 'premature change'
bash .prdkit/scripts/bash/doctor.sh >/dev/null || fail 'spec left malformed'
echo 'ASSERT PASS: bounded scope and deferred expansion'
