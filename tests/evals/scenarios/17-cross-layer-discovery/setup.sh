#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
fixture_change
fixture_clear_spec
mkdir -p specs/product/journeys
cat > specs/product.md <<'EOF'
# Request product

Requesters get their requests resolved by a coordinator and see the outcome.

**Stage**: MVP · next: GA ([lifecycle](product/lifecycle.md))

## Journeys

**Core loop**: [J-01 Resolve a request](product/journeys/j-01-resolve-a-request.md).

## What must be true

- A requester submits and reads a request; a coordinator resolves it (R-01, R-02).
- No notifications in MVP (N-01).

Detail:

- [Requirements](product/requirements.md)
- [Non-goals](product/non-goals.md)
EOF
cat > specs/product/lifecycle.md <<'EOF'
# Request product — lifecycle

**Now**: MVP · **Next**: GA
EOF
cat > specs/product/journeys/j-01-resolve-a-request.md <<'EOF'
# J-01 Resolve a request (validated)

**Who**: requester

## Scenario

1. The requester submits a request.
2. A coordinator resolves it.
3. The requester sees the outcome.
EOF
cat > specs/product/requirements.md <<'EOF'
# Request product — requirements

- **R-01 Submit and read** (validated): requester submits and sees their request. Journeys: J-01.
- **R-02 Resolve** (validated): coordinator resolves a request and requester sees its outcome. Journeys: J-01.
- **R-03 Bulk import** (hypothesis, from: ga): import requests in bulk.
EOF
cat > specs/product/non-goals.md <<'EOF'
# Request product — non-goals

- **N-01 Notifications**: no notifications in MVP. Scope: all. Source: owner.
EOF
cat > specs/architecture.md <<'EOF'
# Request architecture

**Inherits**: none

P1 client -> P2 service -> P3 store. All serve J-01.

## Parts

| Part | What it is | Why it exists | Maturity | Spec |
|------|------------|---------------|----------|------|
| P1 Client | where requesters and coordinators work | J-01 | hypothesis | none yet |
| P2 Service | owns request transitions; reads and writes P3 | J-01: R-01, R-02 | hypothesis | [p2-service](parts/p2-service.md) |
| P3 Store | keeps requests | J-01 | hypothesis | none yet |

P1 reads P2's compatible interface; client work depends on that interface, not its deployment by default.

## Key decisions

### D-01 Durable delivery

Requests cross a retrying queue. The service preserves request identity across replay.
EOF
cat > specs/parts/p2-service.md <<'EOF'
# P2 Service

**What it is**: the request service · **Maturity**: hypothesis · **Code**: none yet

## Components

### Transitions

- **P2.B-01 Transition**: only pending requests can be resolved (R-02). Test: unenforced.
- **P2.I-01 Replay safety**: queue replay cannot create a second request or duplicate resolution (D-01). Enforced by: unenforced.
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
