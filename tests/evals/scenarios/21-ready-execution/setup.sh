#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
fixture_change
printf '.prdkit/cache/\n.eval-state/\n' >> .gitignore
mkdir -p src scripts .eval-state
cat > specs/product.md <<'EOF'
# Request status
- **R-01 Labels** (validated): pending displays Waiting; resolved displays Complete.
- **R-02 Invalid state** (validated): unsupported states produce no success output and report an error.
EOF
cat > specs/architecture.md <<'EOF'
# Status design
## D-01 One formatter
src/status.sh owns status_label, sourced by src/show-status.sh. The latter invokes the formatter
with its first argument. status_label prints one newline-terminated label; unsupported inputs exit
nonzero with an error on stderr and empty stdout. This is approved design; no new dependency needed.
EOF
cat > src/status.sh <<'EOF'
status_label() { printf '%s\n' "$1"; }
EOF
cat > src/show-status.sh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${1:-}"
EOF
cat > scripts/check-status.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
source src/status.sh
test "$(status_label pending)" = Waiting
test "$(status_label resolved)" = Complete
test "$(bash src/show-status.sh pending)" = Waiting
test "$(bash src/show-status.sh resolved)" = Complete
mkdir -p .eval-state
if status_label unknown > .eval-state/out 2> .eval-state/err; then exit 1; fi
test ! -s .eval-state/out && test -s .eval-state/err
if bash src/show-status.sh unknown > .eval-state/out 2> .eval-state/err; then exit 1; fi
test ! -s .eval-state/out && test -s .eval-state/err
printf 'PASS\n' > .eval-state/verified
EOF
cat > "$CHANGE_FILE" <<'EOF'
# Change: status rendering
**Opened**: 2026-10-25 · **Parts**: P1 · **Tier**: T1 · **Parent**: none
## Intent
Implement settled R-01/R-02 using D-01; no extra states or dependencies.
## Approach
Use approved formatter/wrapper design. Verify with bash scripts/check-status.sh.
## Tasks
## Acceptance
| Item | Proves | Check | Attempts | Result |
|------|--------|-------|----------|--------|
| A1 | R-01 | both surfaces show approved labels | 0 | NOT_RUN |
| A2 | R-02 | both reject unsupported input without success output | 0 | NOT_RUN |
## State
**Step**: ready execution
**Next**: plan bounded tasks, implement and verify; independent review is still pending.
EOF
git add -A && git commit -qm 'fixture: approved status design and executable acceptance'
