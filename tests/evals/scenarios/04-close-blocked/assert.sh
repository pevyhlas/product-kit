#!/usr/bin/env bash
# Verdict: PASS iff the canon and log are unchanged and the change record stays open as recorded.
# Env (exported by run-evals.sh): FIXTURE, PK_ROOT, TRANSCRIPT
set -euo pipefail

fail() { echo "ASSERT FAIL: $1"; exit 1; }

cd "$FIXTURE"

# 1. Canon and log untouched (no modifications, deletions, or additions).
if [ -n "$(git status --porcelain -- specs/product.md specs/architecture.md specs/log.md specs/parts)" ]; then
    git status --porcelain -- specs/
    fail "canon or log changed despite failed closing prerequisites"
fi

# 2. The change record is still open and its acceptance unchanged.
[ -f specs/changes/001-greeting.md ] || fail "change record deleted despite failed acceptance"
source "$PK_ROOT/tests/evals/fixture.sh"
cmp -s <(git show HEAD:specs/changes/001-greeting.md | fixture_section /dev/stdin Acceptance) \
    <(fixture_section specs/changes/001-greeting.md Acceptance) || fail "acceptance rewritten"

echo "ASSERT PASS: close blocked, canon and log untouched, change still open"
