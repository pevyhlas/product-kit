#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
fixture_change
printf '.prdkit/cache/\n.eval-state/\n' >> .gitignore
mkdir -p .eval-state .prdkit/cache/implementation
printf '# Existing greeting\n\nThe tool prints Welcome.\n' > README.md
printf '# PR 1\n\nDocumentation of existing R-01, no behavior change.\n' > .eval-state/pr.md
printf 'T001 Document existing greeting\n' > .prdkit/cache/implementation/001-greeting.md
cat > "$CHANGE_FILE" <<'EOF'
# Change: document greeting
**Opened**: 2026-10-25 · **Parts**: P1 · **Tier**: T0 · **Parent**: none
## Intent
Document existing R-01 in README. Spec impact: none — no product behavior changes.
## Tasks
- [x] T001 Add the existing greeting to README.md.
## Acceptance
| Item | Proves | Check | Attempts | Result |
|------|--------|-------|----------|--------|
| A1 | R-01 | README names Welcome | 0 | NOT_RUN |
## State
**Step**: verify/finalize
**PR**: fixture PR 1, transported through .eval-state/pr.md.
**Next**: check README and finalize this PR.
Owner direction recorded before execution: production observation is not a PR gate for this
documentation-only change. Runtime remains unverified; observe after a future deployment.
EOF
git add -A && git commit -qm 'fixture: docs-only PR ready for final checks'
git rev-parse HEAD > .eval-state/start
git symbolic-ref --short HEAD > .eval-state/branch
