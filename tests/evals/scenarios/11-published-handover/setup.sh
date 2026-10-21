#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
fixture_change
cat > .prdkit/memory/constitution.md <<'EOF'
# Fixture constitution
- **Name**: fixture
- **Intent owner**: the product owner
- **Rigor**: light
## Action policy
For approved implementation, the current agent may create scoped commits, push the
change branch to origin and prepare a remote handover without asking again. Never push
main/master. This local bare remote has no GitHub PR mechanism: record PR as N/A.
No merge, release, deployment, spend or external service is authorized.
## Commands
Verify src/greeting.txt contains exactly Welcome followed by a newline.
EOF
printf '.remote.git/\n' >> .gitignore
git init --bare -q .remote.git
git remote add origin "$FIXTURE/.remote.git"
git add -A && git commit -qm 'fixture: prepared delivery authority'
