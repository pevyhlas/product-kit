#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
source "$PK_ROOT/tests/evals/fixture.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
files=(); while IFS= read -r f; do files+=("$f"); done < <(spec_files "$FIXTURE")
# The band as a number in ms or s; a neighbouring digit or dot means another number.
new='(^|[^0-9.])(250|0?\.25)([^0-9]|$)'
old='(^|[^0-9.])(400|0?\.4)([^0-9]|$)'
q=specs/product/qualities.md
test "$(awk '/^[-*][[:space:]]+[*][*]Q-[0-9]/ { n++ } END { print n + 0 }' "${files[@]}")" = 1 || fail 'band moved to another Q- item'
fixture_item Q-01 "$q" | grep -Eq "$new" || fail 'Q-01 does not state the new band'
at="$(fixture_stale "$old" "$new" "${files[@]}")"
test -z "$at" || fail "old band survives in: ${at//$'\n'/ }"
at="$(grep -lE "$new" "${files[@]}" || true)"
test "$at" = "$q" || fail "new band restated outside its Q- item: ${at//$'\n'/ }"
grep -q 'Q-01' specs/parts/p1-greeting.md || fail 'part no longer cites Q-01'
[ -z "$(find specs -path '*/changes/*.md' -print)" ] && [ ! -e src ] || fail 'spec maintenance opened a change or wrote code'
bash .prdkit/scripts/bash/doctor.sh >/dev/null || fail 'spec left malformed'
echo 'ASSERT PASS: the band changed in its one home; the part cites Q-01'
