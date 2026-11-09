#!/usr/bin/env bash
set -euo pipefail
fail() { echo "ASSERT FAIL: $1"; exit 1; }
cd "$FIXTURE"
git for-each-ref refs/heads --format='%(refname:short)' | grep -qE '^[0-9]{3}-' || fail 'no change branch'
record="$(find "$FIXTURE" -path '*/specs/changes/[0-9][0-9][0-9]-*.md' | head -n 1)"
[ -n "$record" ] || fail 'no change record'
case "$record" in "$FIXTURE/.worktrees/"*) ;; *) fail 'change record outside its worktree' ;; esac
grep -q '^\*\*Opened\*\*: [0-9]\{4\}-' "$record" || fail 'record header not filled'
source "$PK_ROOT/tests/evals/fixture.sh"
# The exact output is R-01 at L0 and P1.B-01 at L2; acceptance may prove either.
fixture_section "$record" Acceptance | awk -F '|' '$3 ~ /(^|[^0-9A-Za-z.])(R-01|P1[.]B-01)([^0-9]|$)/ { f = 1 } END { exit !f }' ||
    fail 'acceptance not mapped to R-01 or P1.B-01'
[ -z "$(find "$FIXTURE" -path '*/src/greeting.txt')" ] || fail 'planning implemented code'
[ -z "$(find "$FIXTURE" -path '*/specs/features' -o -path '*/tasks.md' | head -n 1)" ] || fail '0.x workspace created'
echo 'ASSERT PASS: change opened with mapped acceptance and no implementation'
