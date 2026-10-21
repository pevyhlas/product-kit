#!/usr/bin/env bash
set -euo pipefail
fail() { echo "ASSERT FAIL: $1"; exit 1; }
cd "$FIXTURE"
record=specs/changes/001-greeting.md
grep -qE '^-[[:space:]]+\[[xX]\] T002' "$record" || fail 'fresh worker did not resume verification'
[ "$(cat src/greeting.txt)" = Welcome ] || fail 'completed work changed'
[ -z "$(git diff -- src/greeting.txt)" ] || fail 'completed artifact modified'
[ -z "$(git status --porcelain --untracked-files=all -- specs | grep -v " $record\$" || true)" ] || fail 'extra planning documents'
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_section "$record" Acceptance | grep -qi 'PASS' || fail 'verification not recorded'
echo 'ASSERT PASS: progress-safe resumption with evidence'
