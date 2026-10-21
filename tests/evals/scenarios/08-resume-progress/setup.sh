#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
fixture_change
mkdir -p src
echo Welcome > src/greeting.txt
sed 's/\[ \] T001/[x] T001/' "$CHANGE_FILE" > "$CHANGE_FILE.tmp"
mv "$CHANGE_FILE.tmp" "$CHANGE_FILE"
git add -A && git commit -qm 'fixture: task progress on defined tasks'
