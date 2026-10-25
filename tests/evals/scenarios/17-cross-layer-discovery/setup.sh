#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
fixture_change
mkdir -p specs/parts
cat > specs/product.md <<'EOF'
# Request product
**Stage**: MVP
## Journeys
- **J-01 Resolve a request** (validated): requester submits, coordinator resolves, requester sees outcome.
## Requirements
- **R-01 Submit and read** (validated): requester submits and sees their request.
- **R-02 Resolve** (validated): coordinator resolves a request and requester sees its outcome.
- **R-03 Bulk import** (hypothesis, from: ga): import requests in bulk.
## Non-goals
- **N-01 Notifications**: no notifications in MVP. Scope: all. Source: owner.
EOF
cat > specs/architecture.md <<'EOF'
# Request architecture
P1 client -> P2 service -> P3 store. All serve J-01.
## Decisions
## D-01 Durable delivery
Requests cross a retrying queue. The service preserves request identity across replay.
## Parts
- [P2 service](parts/p2-service.md) owns request transitions; reads/writes P3 store.
- P1 client reads P2's compatible interface; client work depends on that interface, not its deployment by default.
EOF
cat > specs/parts/p2-service.md <<'EOF'
# P2 service
- **P2.B-01 Transition**: only pending requests can be resolved (R-02).
- **P2.I-01 Replay safety**: queue replay cannot create a second request or duplicate resolution (D-01).
EOF
cat > "$CHANGE_FILE" <<'EOF'
# Change: request programme
**Opened**: 2026-10-25 · **Parts**: P1 P2 P3 · **Journeys**: J-01 · **Tier**: T2 · **Parent**: none
## Intent
Discover implementation work for approved J-01/R-01/R-02 and D-01. No implementation yet.
## Tasks
## State
**Step**: planning
**Next**: discover justified work across product and design.
EOF
git add -A && git commit -qm 'fixture: approved product and design, unplanned programme'
