#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
record=specs/changes/001-greeting.md
for id in R-01 R-02 D-01 P2.I-01; do
    grep -q "$id" "$record" || fail "planning missed $id"
done
grep -Eiq 'replay|dedup|idempoten' "$record" || fail 'architecture-only enabling work missing'
grep -Eiq 'depend|prerequisite' "$record" || fail 'no dependency reasoning'
grep -Eiq 'merged|reviewed|contract.*(pass|verif)|interface.*(pass|verif)' "$record" || fail 'no dependency outcome'
grep -Eiq 'check|test|proof' "$record" || fail 'no completion checks'
source "$PK_ROOT/scripts/spec-lib.sh"
row="$(spec_changes "$FIXTURE")"
IFS="$SPEC_SEP" read -r _id _title _opened _step _wait _next _parent total passed _failed _attempts _stalled <<< "$row"
test "$total" -gt 0 || fail 'no machine-readable acceptance items'
test "$passed" -eq 0 || fail 'planning claimed delivered acceptance'
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_section "$record" Acceptance | grep -Eq '^\| *Item *\| *Proves *\| *Check *\| *Attempts *\| *Result *\|' || fail 'acceptance table incompatible with status helpers'
test -z "$(git status --porcelain -- specs/product.md specs/architecture.md specs/parts)" || fail 'canon changed during discovery'
test ! -d src || fail 'planning implemented code'
test ! -d specs/features || fail 'duplicate feature spec hierarchy'
echo 'ASSERT PASS: cross-layer coverage without canonical or implementation mutations'
