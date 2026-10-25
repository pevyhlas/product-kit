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
for item in A1 A2; do
    fixture_section "$record" Acceptance | awk -F '|' -v item="$item" '
        function trim(s) { gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        trim($2) == item && trim($6) == "PASS" { found = 1 }
        END { exit !found }
    ' || fail "$item Result is not PASS"
done
source "$PK_ROOT/scripts/spec-lib.sh"
row="$(spec_changes "$FIXTURE")"
IFS="$SPEC_SEP" read -r _id _title _opened _step _wait _next _parent total passed _failed _attempts _stalled <<< "$row"
test "$total" -eq 2 && test "$passed" -eq 2 || fail 'verified acceptance is not readable by status helpers'
fixture_section "$record" State | grep -Eiq 'review.*(pending|next)|pending.*review|review' || fail 'no review handover'
test ! -d specs/features || fail 'second feature specification created'
echo 'ASSERT PASS: settled feature executed and checked without redefining product intent'
