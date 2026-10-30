#!/usr/bin/env bash
# Shared real/mock eval fixture, only inside the runner's throwaway project.
fixture_project() {
    # The runner allocates FIXTURE fresh and empty. Refuse anything else, so an empty or wrong
    # path can never turn the setup below on the caller's checkout (`cd ""` stays put).
    if [ -z "${FIXTURE:-}" ] || [ ! -d "$FIXTURE" ] || [ -n "$(ls -A "$FIXTURE")" ]; then
        echo "fixture_project: FIXTURE must name a new, empty directory; got '${FIXTURE:-}'" >&2
        exit 1
    fi
    cd "$FIXTURE" || exit 1
    git init -q
    git config user.email eval@example.com
    git config user.name eval
    bash "$PK_ROOT/scripts/init.sh" --target "$FIXTURE" --copy >/dev/null
    printf '.worktrees/\n' > .gitignore
    cat > .prdkit/memory/constitution.md <<'EOF'
# Fixture constitution
- **Name**: fixture
- **Intent owner**: the product owner
- **Rigor**: light
## Action policy
The user owns intent. The current session coordinates. Do not commit, push, integrate,
or publish unless the scenario explicitly requests that action. Planning and source edits
follow the scenario's mode. Independent reviews must be actual independent contexts.
## Commands
For the greeting fixture, verify exact text using the standard test utility.
## Principles
Produce only the requested plain-text output. No external services or dependencies.
EOF
    mkdir -p specs
    cat > specs/product.md <<'EOF'
# Fixture — product
**Owner**: the product owner · **Last owner review**: 2026-10-01
## Problem
People starting the tool want a concise, predictable greeting.
## Requirements
- **R-01 Greeting** (hypothesis): src/greeting.txt contains Welcome followed by a newline.
## Thesis
A predictable greeting is enough for the first release.
## Left open
- Later opportunities such as notifications are uncommitted.
EOF
    cat > specs/architecture.md <<'EOF'
# Fixture — architecture
**Inherits**: none
## Parts
| Part | Purpose | Maturity | Owns data | Serves | Spec |
|------|---------|----------|-----------|--------|------|
| P1 greeting | Writes the greeting text | hypothesis | none | R-01 | note below |
## Hypothesis notes
P1 is one plain text file checked with standard utilities.
EOF
    git add -A && git commit -qm 'fixture: installed baseline'
}

# Opens change 001-greeting in place; CHANGE_FILE names its record.
fixture_change() {
    git checkout -qb 001-greeting
    CHANGE_FILE=specs/changes/001-greeting.md
    mkdir -p specs/changes
    cat > "$CHANGE_FILE" <<'EOF'
# Change: greeting

**Opened**: 2026-10-01 · **Parts**: P1 · **Tier**: T1 · **Parent**: none

## Intent

Provide the exact greeting Welcome in a plain text file (R-01). No other behavior.

## Approach

Write the plain text file; verify its exact contents using standard utilities.

## Tasks

- [ ] T001 Write Welcome with a newline to src/greeting.txt.
- [ ] T002 Check src/greeting.txt has the exact requested contents; depends on T001.

## Acceptance

| Item | Proves | Check | Attempts | Result |
|------|--------|-------|----------|--------|
| A1 | R-01 | Inspect exact file text | 0 | NOT_RUN |

## State

**Step**: build
**Waiting on**: nothing
**Next**: T001.
EOF
}

# Prints one change-record section (Acceptance or State) for assertions.
fixture_section() { # file heading
    awk -v h="## $2" '$0 == h { s = 1; next } /^## / { s = 0 } s' "$1"
}

# Programme with successful adjacent repairs but no progress along its declared critical path.
fixture_outcome_programme() {
    fixture_project
    fixture_change
    printf '.eval-state/\n' >> .gitignore
    mkdir -p src scripts .eval-state
    printf 'Legacy greeting\n' > src/legacy.txt
    cat >> specs/architecture.md <<'EOF'
## D-02 Replacement path
The first release uses src/greeting.txt, replacing src/legacy.txt. No legacy data migration is
required. The replacement source check is independent of provider provisioning. Legacy display
metadata is optional; no supported-path defect currently requires another legacy repair.
EOF
    cat > "$CHANGE_FILE" <<'EOF'
# Change: first useful greeting
**Opened**: 2026-10-01 · **Parts**: P1 · **Tier**: T1 · **Parent**: none
## Intent
Owner decision O-01: deliver R-01 on the D-02 replacement path, then validate its deployment.
## Tasks
- [ ] T001 Write src/greeting.txt and run bash scripts/check-foundation.sh. Independent of provider; predeclared source milestone M1.
- [ ] T002 Validate deployed greeting. Depends on T001 and owner-authorized provider provisioning.
- [ ] T003 Optional legacy display metadata in src/legacy-extra.txt; not a prerequisite.
## Acceptance
| Item | Proves | Check | Attempts | Result |
|------|--------|-------|----------|--------|
| A1 | R-01 | M1 source foundation check | 0 | NOT_RUN |
| A2 | R-01 | deployed greeting | 0 | NOT_RUN |
## State
**Step**: choose next work
**Waiting on**: provider provisioning for T002 only
**Next**: previous worker suggested T003
**Outcome**: O-01 first useful greeting through D-02 replacement; first release
**Milestone**: M1 source foundation check, then A2 deployed greeting
**Critical path**: T001 source -> provider provisioning -> T002 deployed validation
**Allocation**: O-01 two lanes: safety and replacement; four source increments remain; cost unknown
**Progress**: none; PR 2, PR 3 and PR 4 passed adjacent legacy repairs; M1 unchanged
**No-progress changes**: 3
**Progress limit**: 3
**Selection**: previous worker suggests another optional legacy field while provider is blocked
EOF
    cat > scripts/check-foundation.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cmp -s src/greeting.txt <(printf 'Welcome\n')
mkdir -p .eval-state
printf 'M1 source verified; deployment unknown\n' > .eval-state/foundation-pass
EOF
    printf 'Provider is unprovisioned; deployment is not authorized. Source T001 is independent.\n' > .eval-state/provider.txt
    cat > specs/log.md <<'EOF'
- 2026-10-02 002-legacy: display label — R-01 — source PASS — PR 2
- 2026-10-03 003-legacy: display width — R-01 — source PASS — PR 3
- 2026-10-04 004-legacy: display ordering — R-01 — source PASS — PR 4
EOF
    git add -A && git commit -qm 'fixture: successful repairs left the replacement milestone untouched'
}
