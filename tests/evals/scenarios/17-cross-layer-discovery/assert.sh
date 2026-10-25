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
test -z "$(git status --porcelain -- specs/product.md specs/architecture.md specs/parts)" || fail 'canon changed during discovery'
test ! -d src || fail 'planning implemented code'
test ! -d specs/features || fail 'duplicate feature spec hierarchy'
echo 'ASSERT PASS: cross-layer coverage without canonical or implementation mutations'
