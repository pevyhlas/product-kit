#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
fixture_change
mkdir -p src .prdkit/cache/evidence
printf 'Welcome\n' > src/greeting.txt
printf 'verification started; still running; no exit status\n' > .prdkit/cache/evidence/verification.log
cat >> "$CHANGE_FILE" <<'EOF'

Review preparation: the required verification process is still running; its partial log is
.prdkit/cache/evidence/verification.log. A dependency's required compatibility proof is only
referenced at ../unavailable-sibling/evidence.txt; it has not been copied or checked.
Reviewer capabilities: reads only this checkout's packaged files, no shell or network,
no write access; report must be returned as text. Review has not started.
EOF
git add -A && git commit -qm 'fixture: incomplete review inputs'
