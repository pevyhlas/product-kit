#!/usr/bin/env bash
set -euo pipefail
fail() { echo "ASSERT FAIL: $1"; exit 1; }
cd "$FIXTURE"
record=specs/changes/001-greeting.md
source "$PK_ROOT/tests/evals/fixture.sh"
if fixture_section "$record" Tasks | grep -q 'T001'; then fail 'delivered task returned'; fi
fixture_section "$record" Tasks | grep -qE '^- \[ \] (\([^)]+\) )?T002 ' || fail 'undelivered task was removed or checked off'
[ "$(cat src/greeting.txt)" = Welcome ] || fail 'completed work changed'
[ -z "$(git diff -- src/greeting.txt)" ] || fail 'completed artifact modified'
[ -z "$(git status --porcelain --untracked-files=all -- specs | grep -v " $record\$" || true)" ] || fail 'extra planning documents'
fixture_section "$record" Acceptance | grep -qi 'PASS' || fail 'verification not recorded'
echo 'ASSERT PASS: progress-safe resumption with evidence'
