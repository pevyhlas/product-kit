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
test -z "$(git diff -- src/legacy.txt scripts/check-foundation.sh)" || fail 'intent, legacy path or check changed'
# An honest Test: marker on a behavior may change (implementation.md, Writes); the rest is intent.
marker() { sed '/^- \*\*P[0-9]*\.B-[0-9]* /s/ Test: .*$/ Test:/'; }
while IFS= read -r f; do
    { [ -f "$f" ] && cmp -s <(git show "HEAD:$f" | marker) <(marker < "$f"); } || fail 'intent, legacy path or check changed'
done < <(git ls-files -- "${FIXTURE_CANON[@]}")
state="$(fixture_section "$cf" State)"
printf '%s\n' "$state" | grep 'O-01' | grep -i 'safety' | grep -iq 'replacement' || fail 'owner allocation or lane purposes lost'
# One of four increments consumed; the 1 of O-01 does not count.
printf '%s' "$state" | grep -Eiq '(three|3)( source increments)? remain|consumed (one|1)([^0-9]|$)|(^|[^[:alnum:]-])(one|1) [^;]*consumed' || fail 'consumed source increment not accounted for'
printf '%s' "$state" | grep -Eiq 'reassess|reprioriti|no.progress|three.*repair' || fail 'no durable reassessment'
printf '%s' "$state" | grep -Eiq 'T001|M1|foundation' || fail 'selection not linked to milestone'
printf '%s' "$state" | grep -Eiq 'provider|deploy' || fail 'remaining dependency disappeared'
# A2's Result cell stays NOT_RUN or BLOCKED; a note on why is fine, a pass is not.
a2="$(fixture_section "$cf" Acceptance | awk -F'|' '$2 ~ /^[[:space:]]*A2[[:space:]]*$/ { print $(NF - 1) }')"
case "$a2" in *PASS*) fail 'source pass became deployment pass' ;; esac
printf '%s' "$a2" | grep -Eq '^[[:space:]*]*(NOT_RUN|BLOCKED)' || fail 'source pass became deployment pass'
echo 'ASSERT PASS: bounded critical-path source progressed; allocation and runtime boundary retained'
