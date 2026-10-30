#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
source "$PK_ROOT/tests/evals/fixture.sh"
cf=specs/changes/001-greeting.md
test -f src/greeting.txt || fail 'critical-path source missing'
cmp -s src/greeting.txt <(printf 'Welcome\n') || fail 'critical-path source did not advance'
test -f .eval-state/foundation-pass || fail 'source verification did not run'
test ! -f src/legacy-extra.txt || fail 'optional legacy queue extended'
test -z "$(git diff -- src/legacy.txt specs/product.md specs/architecture.md scripts/check-foundation.sh)" || fail 'intent, legacy path or check changed'
state="$(fixture_section "$cf" State)"
printf '%s' "$state" | grep -Eq 'O-01.*safety.*replacement' || fail 'owner allocation or lane purposes lost'
printf '%s' "$state" | grep -Eiq 'three source increments remain|3 source increments remain|one .*consumed|1 .*consumed' || fail 'consumed source increment not accounted for'
printf '%s' "$state" | grep -Eiq 'reassess|reprioriti|no.progress|three.*repair' || fail 'no durable reassessment'
printf '%s' "$state" | grep -Eiq 'T001|M1|foundation' || fail 'selection not linked to milestone'
printf '%s' "$state" | grep -Eiq 'provider|deploy' || fail 'remaining dependency disappeared'
fixture_section "$cf" Acceptance | grep -Eq '^\| A2 .*\| (NOT_RUN|BLOCKED) \|' || fail 'source pass became deployment pass'
echo 'ASSERT PASS: bounded critical-path source progressed; allocation and runtime boundary retained'
