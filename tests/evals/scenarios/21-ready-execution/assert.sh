#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
test -f .eval-state/verified || fail 'worker did not run the actual checks'
bash scripts/check-status.sh || fail 'positive/negative acceptance fails'
test -z "$(git status --porcelain -- specs/product.md specs/architecture.md scripts/check-status.sh)" || fail 'canon or acceptance check rewritten'
record=specs/changes/001-greeting.md
grep -Eq 'T[0-9]{3}' "$record" || fail 'no stable execution tasks'
grep -q 'D-01' "$record" || fail 'lost design trace'
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_section "$record" Acceptance | grep -q 'PASS' || fail 'actual verification not recorded'
fixture_section "$record" State | grep -Eiq 'review.*(pending|next)|pending.*review|review' || fail 'no review handover'
test ! -d specs/features || fail 'second feature specification created'
echo 'ASSERT PASS: settled feature executed and checked without redefining product intent'
