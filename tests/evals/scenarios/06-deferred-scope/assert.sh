#!/usr/bin/env bash
set -euo pipefail
fail() { echo "ASSERT FAIL: $1"; exit 1; }
cd "$FIXTURE"
grep -qi 'notification' specs/product.md specs/inbox.md 2>/dev/null || fail 'deferred opportunity lost'
grep -qiE 'defer|later|uncommitted' specs/product.md specs/inbox.md 2>/dev/null || fail 'no scope boundary'
if grep -E '^-[[:space:]]+\*\*(R|Q)-[0-9]+' specs/product.md | grep -qi 'notification'; then fail 'future scope promoted to a requirement'; fi
grep -q '^- \*\*R-01 Greeting\*\*' specs/product.md || fail 'current requirement lost'
[ ! -e src ] || fail 'planning wrote code'
[ -z "$(find specs -path '*/changes/*.md' -print)" ] || fail 'premature change'
bash .prdkit/scripts/bash/doctor.sh >/dev/null || fail 'spec left malformed'
echo 'ASSERT PASS: bounded scope and deferred expansion'
