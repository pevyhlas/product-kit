#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
mkdir -p specs/architecture
cat >> specs/parts/p1-greeting.md <<'EOF2'

## Interface guarantees

- **P1.I-01 Format compatibility**: after a new greeting file format ships, readers of the previous format keep working for 90 days. Enforced by: owner review.
EOF2
awk '{ print } /^\| P1 / { print "| P2 Launcher | a start-up script | R-01: shows the greeting | hypothesis | none yet |" }' \
    specs/architecture.md > specs/architecture.md.tmp
mv specs/architecture.md.tmp specs/architecture.md
cat >> specs/architecture.md <<'EOF2'

## Key areas

| Area | In a line |
|------|-----------|
| Interfaces | [the greeting file format](architecture/interfaces.md), owned by P1 and read by P2. |
EOF2
# A second home for the promise: the restatement a one-home edit has to resolve.
cat > specs/architecture/interfaces.md <<'EOF2'
# Fixture — interfaces

| Interface | Owner part | Consumers | Promise | Schema in code |
|-----------|------------|-----------|---------|----------------|
| Greeting file format | P1 | P2 | previous format readable for 90 days (P1.I-01) | src/greeting.txt |
EOF2
cat > specs/inbox.md <<'EOF2'
# Owner inbox

## Waiting for you

### Greeting format compatibility window
*2026-11-01 · agent · open*

**ID**: IN-eeeeeeeeeeee
**Revision**: 1
**Kind**: decision
**Tags**: interfaces
**Related**: [P1.I-01](parts/p1-greeting.md)

A new greeting file format is planned. P1.I-01 keeps the previous format readable for 90 days;
slower readers may need longer.

1. **keep — Keep 90 days**: no change.
2. **extend — 180 days (Recommended)**: two release cycles for slower readers.

**Answer**: extend. "Readers need two release cycles; give them 180 days."
**Answer date**: 2026-11-03
**Answer source**: owner-message-29
**Answer revision**: 1

## To incorporate
EOF2
git add -A && git commit -qm 'fixture: an answered interface promise, restated in a topic'
