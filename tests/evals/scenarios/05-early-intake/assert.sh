#!/usr/bin/env bash
set -euo pipefail
fail() { echo "ASSERT FAIL: $1"; exit 1; }
cd "$FIXTURE"
[ -z "$(git status --porcelain)" ] || fail 'exploration changed files'
[ -z "$(git for-each-ref refs/heads --format='%(refname:short)' | grep -E '^[0-9]{3}-' || true)" ] || fail 'premature change branch'
grep -q '?' "$TRANSCRIPT" || fail 'no clarification question'
grep -qiE 'individual|coordinator|audience' "$TRANSCRIPT" || fail 'consequential audience choice ignored'
echo 'ASSERT PASS: early clarification without premature artifacts'
