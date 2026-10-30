#!/usr/bin/env bash
# One carrier record reviews a final child plus its programme. No sibling-record exemptions,
# missing owner verdicts or unresolved inherited failures are hidden by same-PR cleanup.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| integration | reviewer |\n' >> .prdkit/memory/agents.md
CHECK="$PROJ/.prdkit/scripts/bash/check-review.sh"
mkdir -p specs/changes src
cat > specs/changes/001-programme.md <<'EOF'
# Change: programme
**Opened**: 2026-10-25 · **Parts**: P1 P2 · **Tier**: T3 · **Parent**: none
## Acceptance
| Item | Proves | Check | Attempts | Result |
|------|--------|-------|----------|--------|
| A1 | R-01 | integrated outcome | 1 | FAIL |
## State
**Step**: waiting on final child
EOF
git add -A; git commit -qm baseline
BASE="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git checkout -qb 002-final-child
printf 'delivered\n' > src/app.txt
cat > specs/changes/002-final-child.md <<'EOF'
# Change: final child and programme disposition
**Opened**: 2026-10-25 · **Parts**: P1 P2 · **Tier**: T3 · **Parent**: 001-programme
## Intent
Final child carries the programme's integrated outcome, review concerns and owner gate.
## Acceptance
| Item | Proves | Check | Attempts | Result |
|------|--------|-------|----------|--------|
| A1 | R-01 | inherited 001-programme/A1 integrated outcome | 2 | PASS |
## State
**Step**: combined review
EOF
git add -A; git commit -qm 'child with inherited scope'
FAILED="$(git rev-parse HEAD)"
printf '**Review**: round 1 · %s..%s · integration · FAIL · 0 critical, 1 high, 0 medium, 0 low · fixture:inherited-report\n' "$BASE" "$FAILED" >> specs/changes/002-final-child.md
# Parent disposition/deletion is substantive reviewed content, before final review.
git rm -q specs/changes/001-programme.md
printf -- '- 2026-10-25 001-programme: integrated outcome — R-01 — delivered; runtime unverified — PR 1\n' > specs/log.md
git add -A; git commit -qm 'prepare parent disposition for combined review'
PREPARED="$(git rev-parse HEAD)"

it "an inherited unresolved FAIL still blocks the carrier"
run bash "$CHECK" --base "$BASE" 002-final-child
assert_eq 1 "$STATUS" "unresolved parent concern blocks"
assert_contains "$OUTPUT" 'integration (round 1): verdict FAIL' "inherited failure remains visible"

printf '**Review**: round 2 · %s..%s · integration · PASS · 0 critical, 0 high, 0 medium, 0 low · fixture:combined-report\n' "$BASE" "$PREPARED" >> specs/changes/002-final-child.md
git add specs/changes/002-final-child.md; git commit -qm 'combined independent pass'
it "the combined tier still requires owner approval"
run bash "$CHECK" --base "$BASE" 002-final-child
assert_eq 1 "$STATUS" "owner gate not lost with parent deletion"
assert_contains "$OUTPUT" "T3 needs the owner's verdict" "owner missing"

printf '**Review**: round 2 · %s..%s · owner · PASS · fixture:owner-words\n' "$BASE" "$PREPARED" >> specs/changes/002-final-child.md
git add specs/changes/002-final-child.md; git commit -qm 'owner verdict on combined scope'
git rm -q specs/changes/002-final-child.md
printf -- '- 2026-10-25 002-final-child: final implementation — R-01 — delivered; runtime unverified — PR 1\n' >> specs/log.md
git add specs/log.md; git commit -qm 'finalize carrier in same PR'

it "one exact-head gate covers the child and already-reviewed parent deletion"
run bash "$CHECK" --json --base "$BASE" --head HEAD 002-final-child
assert_eq 0 "$STATUS" "same-PR multi-record finalization passes"
assert_contains "$OUTPUT" '"record_only":false' "real source scope, not a cleanup exemption"
assert_contains "$OUTPUT" '"tier":"T3"' "combined tier retained"
assert_eq '' "$(git ls-tree -r --name-only HEAD specs/changes)" "no cleanup records remain"
assert_eq 2 "$(grep -c '^-' specs/log.md)" "both dispositions retained"

it "changes outside carrier metadata still need review"
printf 'unreviewed change\n' >> src/app.txt
git add src/app.txt; git commit -qm 'unreviewed post-pass edit'
run bash "$CHECK" --base "$BASE" 002-final-child
assert_eq 1 "$STATUS" "no broad finalization exemption"
assert_contains "$OUTPUT" 'src/app.txt' "unreviewed source identified"
finish
