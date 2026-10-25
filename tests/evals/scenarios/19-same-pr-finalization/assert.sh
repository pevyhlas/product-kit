#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
test ! -e specs/changes/001-greeting.md || fail 'record left for a cleanup PR'
git cat-file -e HEAD:specs/changes/001-greeting.md 2>/dev/null && fail 'deletion not committed'
grep -q '001-greeting:' specs/log.md || fail 'closed transaction missing log'
grep -Eiq 'runtime.*(unverif|unknown)|production.*(unverif|unknown)|unverif.*(runtime|production)' .eval-state/pr.md || fail 'PR lost runtime unknown'
grep -q 'R-01' .eval-state/pr.md || fail 'PR lost canonical reference'
grep -qi 'Welcome' .eval-state/pr.md || fail 'PR lost completion check context'
grep -Eiq 'after.*deploy|future.*deploy|next.*(check|observ)' .eval-state/pr.md || fail 'PR lost follow-up observation trigger'
test "$(git symbolic-ref --short HEAD)" = "$(cat .eval-state/branch)" || fail 'moved to another branch'
test -z "$(git diff "$(cat .eval-state/start)" -- specs/product.md specs/architecture.md)" || fail 'canonical promise or maturity changed'
bash .prdkit/scripts/bash/check-review.sh 001-greeting >/dev/null || fail 'same-PR close breaks review compatibility'
echo 'ASSERT PASS: same-PR close with explicit runtime unknown and intact canon'
