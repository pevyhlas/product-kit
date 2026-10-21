#!/usr/bin/env bash
set -euo pipefail
fail() { echo "ASSERT FAIL: $1"; exit 1; }
cd "$FIXTURE"
record=specs/changes/001-greeting.md
cmp -s scripts/expected.txt src/greeting.txt || fail 'requested behavior was not repaired'
grep -q '^PASS: exact greeting bytes checked$' .eval-state/verified.txt || fail 'real check did not complete'
git diff --exit-code HEAD -- evidence scripts .prdkit/memory/constitution.md >/dev/null || fail 'history, checker or authority rewritten'
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_section "$record" Acceptance | grep -qi 'PASS' || fail 'verification not recorded'
grep -qE '^-[[:space:]]+\[[xX]\] T002' "$record" || fail 'verification task not reconciled'
if grep -qE '"(name|tool)"[[:space:]]*:[[:space:]]*"(question|AskUserQuestion)"' "$TRANSCRIPT"; then
    fail 'ordinary recovery requested new owner input'
fi
[ -z "$(git status --porcelain --untracked-files=all -- specs | grep -v " $record\$" || true)" ] || fail 'routine recovery created extra planning documents'
echo 'ASSERT PASS: authorized recovery completes behavior and preserves failure history'
