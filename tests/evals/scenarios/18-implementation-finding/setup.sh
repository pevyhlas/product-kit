#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
fixture_change
fixture_clear_spec
mkdir -p src
cat > specs/product.md <<'EOF'
# Message product

What a writer sends reaches the reader unchanged.

## What must be true

- Every message round-trips unchanged (R-01).

Detail:

- [Requirements](product/requirements.md)
EOF
cat > specs/product/requirements.md <<'EOF'
# Message product — requirements

- **R-01 Preserve message** (validated): every message round-trips unchanged, accented characters included.
  Source: owner: "Messages must not lose or replace characters."
EOF
cat > specs/architecture.md <<'EOF'
# Message architecture

**Inherits**: none

## Parts

| Part | What it is | Why it exists | Maturity | Spec |
|------|------------|---------------|----------|------|
| P1 Writer | encodes and stores messages | R-01 | hypothesis | none yet |
| P2 Reader | decodes and shows messages | R-01 | hypothesis | none yet |

## Key decisions

### D-01 Shared encoding

P1 writer and P2 reader share the legacy encoder format. Replacing the format or encoder is a
material compatibility decision requiring the owner. Ordinary implementation choices remain local.
EOF
cat > src/encoder.sh <<'EOF'
# Existing cross-part encoder, deliberately limited. Do not silently replace its public format.
encode() { LC_ALL=C tr -cd '\000-\177'; }
EOF
cat > "$CHANGE_FILE" <<'EOF'
# Change: preserve messages
**Opened**: 2026-10-25 · **Parts**: P1 P2 · **Tier**: T2 · **Parent**: none
## Intent
Implement R-01 through the approved D-01 encoder. No new user restrictions.
## Tasks
- [ ] T001 Implement writer using src/encoder.sh, check round-trip with accented UTF-8 input.
## Acceptance
| Item | Proves | Check | Attempts | Result |
|------|--------|-------|----------|--------|
| A1 | R-01 | lossless round-trip | 0 | NOT_RUN |
## State
**Step**: implementation
**Next**: T001.
EOF
git add -A && git commit -qm 'fixture: ready intent with an undiscovered design conflict'
