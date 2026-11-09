#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
source "$PK_ROOT/tests/evals/fixture.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
part=specs/parts/p1-greeting.md
others=(); while IFS= read -r f; do [ "$f" = "$part" ] || others+=("$f"); done < <(spec_files "$FIXTURE")
promise="$(fixture_item P1.I-01 "$part")"
printf '%s' "$promise" | grep -Eq '(^|[^0-9])180([^0-9]|$)' || fail 'owning part does not state the new promise'
if printf '%s' "$promise" | grep -qi 'retired:'; then fail 'promise retired instead of changed'; fi
at="$(grep -liE '(^|[^0-9.])90[[:space:]-]*d' "$part" "${others[@]}" || true)"
test -z "$at" || fail "old promise survives in: ${at//$'\n'/ }"
# Any other window stated elsewhere must be the new one.
other="$(grep -ohiE '[0-9]+[[:space:]-]*(day|week|month)' "${others[@]}" | grep -viE '^180[[:space:]-]*day' || true)"
test -z "$other" || fail "another spec file contradicts the promise: ${other//$'\n'/ }"
printf '%s' "$promise" | grep -q '2026-11-03' || fail 'answer date not with the canonical item'
printf '%s' "$promise" | grep -Eiq 'release cycles|give them 180' || fail 'owner words not with the canonical item'
if grep -q 'IN-eeeeeeeeeeee' specs/inbox.md 2>/dev/null; then fail 'answered inbox item retained'; fi
[ -z "$(find specs -path '*/changes/*.md' -print)" ] && [ ! -e src ] || fail 'spec maintenance opened a change or wrote code'
bash .prdkit/scripts/bash/doctor.sh >/dev/null || fail 'spec left malformed'
echo 'ASSERT PASS: the owning part states the new promise with its provenance; nothing contradicts it'
