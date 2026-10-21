#!/usr/bin/env bash
set -euo pipefail
source "$PK_ROOT/tests/evals/fixture.sh"
fixture_project
fixture_change
# This review exercises a stdout producer, rather than the file-writing execution fixture.
sed 's/^- \*\*R-01 Greeting\*\* (hypothesis):.*/- **R-01 Greeting** (hypothesis): bash src\/greeting.sh emits exactly Welcome followed by one newline./' \
    specs/product.md > specs/product.md.tmp
mv specs/product.md.tmp specs/product.md
cat > "$CHANGE_FILE" <<'EOF'
# Change: greeting producer

**Opened**: 2026-10-01 · **Parts**: P1 · **Tier**: T1 · **Parent**: none

## Intent

Provide one English greeting on standard output (R-01). Localization is future/uncommitted.

## Approach

Use a local shell producer and standard byte-comparison utilities.

## Tasks

- [x] T001 Implement src/greeting.sh; review its exact output contract.
- [ ] T002 Verify the producer's exact stdout bytes; depends on T001.

## Acceptance

| Item | Proves | Check | Attempts | Result |
|------|--------|-------|----------|--------|
| A1 | R-01 | Capture stdout and compare its exact bytes with the required greeting | 0 | NOT_RUN |

## State

**Step**: review
**Waiting on**: independent review
**Next**: T002 after review.
EOF
mkdir -p src evidence
cat > src/greeting.sh <<'EOF'
#!/usr/bin/env bash
printf 'Welcome'
EOF
cat > evidence/review-scope.md <<'EOF'
# Current change package
Source: src/greeting.sh, a new local stdout-only greeting producer.
Requirement: R-01 (acceptance A1) requires exactly Welcome followed by one newline.
Review phase: current implementation correctness before task completion.
The author has not supplied passing exact-byte verification. Do not invent execution.
There are no external services, secrets or personal data. Localization is future/uncommitted.
The prior security review is unchanged and applies to this same source; only its table
alignment was criticized. No source, authority, claim or trusted evidence changed since it.

## Candidate observations to adjudicate
F1: The implementation may omit the required trailing newline.
F2: No tests exist for localized greetings.
F3: The previous security report's Markdown columns are not visually aligned.
EOF
cat > evidence/security-review.md <<'EOF'
# Original independent security review
Scope: exact src/greeting.sh bytes in the fixture baseline; local stdout only, no other effects.
| Domain |Result|
|---|---|
| Security |APPROVED|
No security findings for this scope. This does not establish output correctness or test passes.
EOF
git add -A && git commit -qm 'fixture: change package and original security review'
