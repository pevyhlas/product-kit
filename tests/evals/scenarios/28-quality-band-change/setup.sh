#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
printf -- '- [Qualities](product/qualities.md)\n' >> specs/product.md
cat > specs/product/qualities.md <<'EOF2'
# Fixture — qualities

- **Q-01 Greeting latency** (hypothesis): the greeting appears within 400 ms of start, p95 over 20 starts on the reference machine. Enforced by: unenforced.
EOF2
# Second homes for the band: the restatements a one-home edit has to resolve.
cat >> specs/parts/p1-greeting.md <<'EOF2'

## Budgets

- Start to greeting: within 400 ms p95 (Q-01).
EOF2
cat >> specs/architecture.md <<'EOF2'

## Key areas

| Area | In a line |
|------|-----------|
| Observability | start-up time is measured against Q-01's 400 ms band. |
EOF2
git add -A && git commit -qm 'fixture: a quality band restated beside its Q- item'
