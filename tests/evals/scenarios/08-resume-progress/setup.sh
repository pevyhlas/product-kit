#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
fixture_change
git add "$CHANGE_FILE" && git commit -qm 'fixture: planned tasks'
mkdir -p src
echo Welcome > src/greeting.txt
sed -e '/^- \[ \] T001 /d' -e 's/^\*\*Next\*\*: T001\./**Next**: T002./' "$CHANGE_FILE" > "$CHANGE_FILE.tmp"
mv "$CHANGE_FILE.tmp" "$CHANGE_FILE"
git add -A && git commit -qm 'fixture: first delivery deleted its task'
