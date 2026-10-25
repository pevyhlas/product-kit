#!/usr/bin/env bash
set -euo pipefail
cd "$FIXTURE"
fail() { echo "ASSERT FAIL: $1"; exit 1; }
test ! -f src/client.txt || fail 'merged interface mistaken for deployed dependency'
test -f src/greeting.txt || fail 'independent ready work stopped unnecessarily'
cmp -s src/greeting.txt <(printf 'Welcome\n') || fail 'independent work incorrect'
test -z "$(git status --porcelain -- specs/product.md specs/architecture.md specs/parts)" || fail 'canonical contract rewritten'
record=specs/changes/001-greeting.md
for key in T001 T002; do grep -q "$key" "$record" || fail 'task identity lost'; done
grep -Eiq 'v2|D-02|P2.B-01' "$record" || fail 'current contract not acknowledged'
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_section "$record" State | grep -Eiq 'deploy|blocked|waiting' || fail 'dependency wait not resumable'
echo 'ASSERT PASS: changed contract and deployment gate respected; independent work completed'
