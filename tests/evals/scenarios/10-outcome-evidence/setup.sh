#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
mkdir -p evidence
printf -- '- 2026-10-12 001-greeting: greeting file — R-01 — N/A\n' > specs/log.md
cat > evidence/acceptance.md <<'EOF'
# Fixture acceptance
The greeting passes its technical acceptance check in the fixture environment.
There are no real users, interviews, usage observations, or adoption measurements.
EOF
git add -A && git commit -qm 'fixture: technical pass without user evidence'
