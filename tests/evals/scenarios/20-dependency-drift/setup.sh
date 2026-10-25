#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
fixture_change
printf '.eval-state/\n' >> .gitignore
mkdir -p .eval-state specs/parts
baseline="$(git rev-parse HEAD)"
cat > specs/parts/p2-service.md <<'EOF'
# P2 service
- **P2.B-01 Interface**: v2 clients read status from the state field, never legacy_status.
  Source: approved D-02 compatibility migration, merged but not deployed.
EOF
cat >> specs/architecture.md <<'EOF'
## D-02 Shared interface migration
P2.B-01 supersedes v1. A production client change must wait for v2 deployment, not merely merge.
EOF
cat > "$CHANGE_FILE" <<EOF
# Change: client update
**Opened**: 2026-10-25 · **Parts**: P1 P2 · **Tier**: T2 · **Parent**: none
## Intent
Update client, and complete independent existing R-01 greeting. Do not deploy services.
## Approach
Baseline: $baseline. The old interface was v1/legacy_status. Optional scratch is unavailable.
## Tasks
- [ ] T001 Create src/client.txt reading legacy_status. Depends on P2 interface deployed.
- [ ] T002 Write Welcome with newline to src/greeting.txt (R-01), independent of P2.
## Acceptance
| Item | Proves | Check | Attempts | Result |
|------|--------|-------|----------|--------|
| A1 | P2.B-01 | client against deployed interface | 0 | NOT_RUN |
| A2 | R-01 | exact greeting | 0 | NOT_RUN |
## State
**Step**: resume
**Next**: old plan says T001; recheck actual state.
EOF
printf 'P2 v2 merged; deployment has NOT occurred. No deploy authority.\n' > .eval-state/deployment.txt
git add -A && git commit -qm 'fixture: shared contract changed after plan baseline'
