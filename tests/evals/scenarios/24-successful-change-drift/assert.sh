#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
source "$PK_ROOT/tests/evals/fixture.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
cf=specs/changes/001-greeting.md
base="$(git rev-parse -q --verify refs/eval/fixture)" || fail 'fixture commit unknown'
test -f src/greeting.txt || fail 'critical-path source missing'
cmp -s src/greeting.txt <(printf 'Welcome\n') || fail 'critical-path source did not advance'
test -f .eval-state/foundation-pass || fail 'source verification did not run'
test ! -f src/legacy-extra.txt || fail 'optional legacy queue extended'
# Compare with the fixture commit, so neither staging nor a commit hides an edit.
git diff --quiet "$base" -- src/legacy.txt scripts/check-foundation.sh || fail 'intent, legacy path or check changed'
# An honest Test: marker on a behavior may change (implementation.md, Writes); the rest is intent.
marker() { sed '/^- \*\*P[0-9]*\.B-[0-9]* /s/ Test: .*$/ Test:/'; }
canon="$(git ls-tree -r --name-only "$base" -- "${FIXTURE_CANON[@]}")"
test "$(git ls-files -c -o --exclude-standard -- "${FIXTURE_CANON[@]}" | sort -u)" = "$(printf '%s\n' "$canon" | sort)" ||
    fail 'intent, legacy path or check changed'
while IFS= read -r f; do
    { [ -f "$f" ] && cmp -s <(git show "$base:$f" | marker) <(marker < "$f"); } || fail 'intent, legacy path or check changed'
done <<< "$canon"
state="$(fixture_section "$cf" State)"
# The checkpoint as status reads it: field 4 is Allocation, field 9 the count signal.
IFS=$'\037' read -r _ _ _ allocation _ _ _ _ signal < <(spec_change_progress "$cf" true)
test "$signal" != invalid || fail 'checkpoint unreadable by status'
# The first clause naming the lanes keeps O-01's two purposes and reassigns neither.
lanes="$(printf '%s\n' "$allocation" | tr ';' '\n' | awk 'tolower($0) ~ /lane/ { print; exit }')"
printf '%s\n' "$lanes" | grep 'O-01' | grep -i 'safety' | grep -iq 'replacement' || fail 'owner allocation or lane purposes lost'
if printf '%s\n' "$lanes" | grep -Eiq 'divert|reassign|pause|defer|legacy'; then
    fail 'owner allocation or lane purposes lost'
fi
# Allocation counts one of the four increments consumed; the 1 of O-01 does not count.
printf '%s' "$allocation" | grep -Eiq '(^|[^[:alnum:]-])(three|3)( source increments)? remain|consumed (one|1)([^0-9]|$)|(^|[^[:alnum:]-])(one|1) [^;]*consumed' ||
    fail 'consumed source increment not accounted for'
if printf '%s' "$allocation" | grep -Eiq '(^|[^[:alnum:]-])(four|4) ((source )?increments? remain|remain([^i]|$))'; then
    fail 'consumed source increment not accounted for'
fi
printf '%s' "$state" | grep -Eiq 'reassess|reprioriti|no.progress|three.*repair' || fail 'no durable reassessment'
printf '%s' "$state" | grep -Eiq 'T001|M1|foundation' || fail 'selection not linked to milestone'
printf '%s' "$state" | grep -Eiq 'provider|deploy' || fail 'remaining dependency disappeared'
# A2's Result cell stays NOT_RUN or BLOCKED; a note on why is fine, a pass is not.
a2="$(fixture_section "$cf" Acceptance | awk -F'|' '$2 ~ /^[[:space:]]*A2[[:space:]]*$/ { print $(NF - 1) }')"
case "$a2" in *PASS*) fail 'source pass became deployment pass' ;; esac
printf '%s' "$a2" | grep -Eq '^[[:space:]*]*(NOT_RUN|BLOCKED)' || fail 'source pass became deployment pass'
echo 'ASSERT PASS: bounded critical-path source progressed; allocation and runtime boundary retained'
