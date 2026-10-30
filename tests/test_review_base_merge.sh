#!/usr/bin/env bash
# Review provenance across base updates: exact branch deltas, not commit-message heuristics.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SEED="$(make_inited_project)"; track_tmp "$SEED"
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n| security | reviewer |\n' >> "$SEED/.prdkit/memory/agents.md"
mkdir -p "$SEED/src" "$SEED/docs" "$SEED/specs"
printf 'base source\n' > "$SEED/src/owned.txt"
printf 'base contract\n' > "$SEED/specs/product.md"
printf 'old documentation\n' > "$SEED/docs/existing.md"
printf 'obsolete documentation\n' > "$SEED/docs/remove.md"
git -C "$SEED" add -A
git -C "$SEED" commit -qm 'installed baseline'
DEFAULT="$(git -C "$SEED" branch --show-current)"
CLEAN='0 critical, 0 high, 0 medium, 0 low'

start_case() {
    PROJ="$(mktemp -d)"; track_tmp "$PROJ"
    git -c protocol.file.allow=always clone -q "file://$SEED" "$PROJ"
    cd "$PROJ" || exit 1
    git config user.name test; git config user.email test@example.invalid
    BASE="$(git rev-parse HEAD)"
    git checkout -qb 001-reviewed
    printf 'reviewed source\n' > src/owned.txt
    printf 'reviewed contract\n' > specs/product.md
    git commit -qam 'feature'; REVIEWED="$(git rev-parse HEAD)"
    mkdir -p specs/changes
    RECORD=specs/changes/001-reviewed.md
    cat > "$RECORD" <<EOF
# Change: Reviewed feature
**Tier**: T3
## State
**Review**: round 1 · $BASE..$REVIEWED · code · PASS · $CLEAN · https://example.invalid/review/1
**Review**: round 1 · $BASE..$REVIEWED · security · PASS · $CLEAN · https://example.invalid/review/2
**Review**: round 1 · $BASE..$REVIEWED · owner · PASS · https://example.invalid/review/3
EOF
    git add "$RECORD"; git commit -qm 'record verdicts'
    CHECK="$PROJ/.prdkit/scripts/bash/check-review.sh"
}
advance_base() {
    git checkout -q "$DEFAULT"
    printf 'new documentation\n' > docs/new.md
    printf 'updated documentation\n' > docs/existing.md
    git rm -q docs/remove.md
    git add docs; git commit -qm 'unrelated base changes'
    git update-ref refs/remotes/origin/integration HEAD
    git checkout -q 001-reviewed
}
check() { run bash "$CHECK" --json --base origin/integration 001-reviewed; }

it "unrelated base additions, edits and deletions preserve every verdict and start coverage"
start_case
run bash "$CHECK" --json --base "origin/$DEFAULT" 001-reviewed
assert_eq 0 "$STATUS" 'fixture passes before base update'
advance_base
git merge -q --no-edit origin/integration
before="$(git status --porcelain; git ls-files --stage; git show-ref; git count-objects -v)"
check
assert_eq 0 "$STATUS" "base-only import passes: $OUTPUT"
assert_contains "$OUTPUT" '"record_only":false' 'coverage is proven, not bypassed as metadata'
assert_eq "$before" "$(git status --porcelain; git ls-files --stage; git show-ref; git count-objects -v)" 'review gate changes no files, index, refs or objects'
printf '\nFinalization context.\n' >> "$RECORD"
printf -- '- 2026-10-30 001-reviewed: metadata only\n' > specs/log.md
git add specs; git commit -qm 'metadata after base import'
check
assert_eq 0 "$STATUS" 'metadata after import stays covered'
git checkout -q "$DEFAULT"
printf 'second update\n' > docs/second.md
git add docs; git commit -qm 'second base update'
git update-ref refs/remotes/origin/integration HEAD
git checkout -q 001-reviewed
git merge -q --no-edit origin/integration
check
assert_eq 0 "$STATUS" 'multiple base imports stay covered'
GOOD="$(git rev-parse HEAD)"

it "source edits, mode changes and standing FAILs remain gating after a base import"
printf 'unreviewed edit\n' >> src/owned.txt
git commit -qam 'unreviewed source'
check
assert_eq 1 "$STATUS" 'actual edit fails'
assert_contains "$OUTPUT" 'src/owned.txt' 'unreviewed path named'
FIXED="$(git rev-parse HEAD)"
printf '\n**Review**: round 2 · %s..%s · code · PASS · %s · https://example.invalid/review/4\n' "$REVIEWED" "$FIXED" "$CLEAN" >> "$RECORD"
git add "$RECORD"; git commit -qm 'scoped review of actual edit'
check
assert_eq 0 "$STATUS" 'scoped re-review covers the older reviewer and the imported base'
git reset -q --hard "$GOOD"
git update-index --chmod=+x src/owned.txt
git commit -qm 'unreviewed executable bit'
check
assert_eq 1 "$STATUS" 'mode-only change fails'
git reset -q --hard "$GOOD"
printf '\n**Review**: round 2 · %s..%s · security · FAIL · 0 critical, 1 high, 0 medium, 0 low · https://example.invalid/review/5\n' "$BASE" "$REVIEWED" >> "$RECORD"
git add "$RECORD"; git commit -qm 'standing failure'
check
assert_eq 1 "$STATUS" 'base import cannot clear a standing FAIL'
assert_contains "$OUTPUT" 'stands: no later clean PASS' 'failure provenance retained'

it "an extra source edit hidden inside a merge commit is not a base-only import"
start_case; advance_base
git merge -q --no-commit origin/integration 2>/dev/null
printf 'unreviewed merge content\n' > src/extra.txt
git add src/extra.txt; git commit -qm 'merge with extra edit'
check
assert_eq 1 "$STATUS" 'extra merge edit fails'
assert_contains "$OUTPUT" 'src/extra.txt' 'extra source named'

it "a conflicting resolution needs review even when it selects the old reviewed bytes"
start_case
git checkout -q "$DEFAULT"
printf 'upstream replacement\n' > src/owned.txt
git commit -qam 'conflicting base edit'
git update-ref refs/remotes/origin/integration HEAD
git checkout -q 001-reviewed
run git merge --no-edit origin/integration
assert_eq 1 "$STATUS" 'fixture genuinely conflicts'
printf 'reviewed source\n' > src/owned.txt
git add src/owned.txt; git commit -qm 'resolve by keeping reviewed bytes'
assert_eq '' "$(git diff --name-only "$REVIEWED" HEAD -- src)" 'source bytes equal reviewed head'
check
assert_eq 1 "$STATUS" 'resolution still requires coverage'
assert_contains "$OUTPUT" 'merge integration is not covered' 'explains unchanged-tree integration gap'
MERGED="$(git rev-parse HEAD)"
printf '\n**Review**: round 2 · %s..%s · code · PASS · %s · https://example.invalid/review/6\n' "$REVIEWED" "$MERGED" "$CLEAN" >> "$RECORD"
git add "$RECORD"; git commit -qm 'review integration decision'
check
assert_eq 0 "$STATUS" 'review of the resolution restores coverage'

it "upstream-only L0 additions retain owner approval, but overlapping L0 decisions do not"
start_case
git checkout -q "$DEFAULT"
mkdir -p specs/product
printf 'upstream journey\n' > specs/product/journey.md
git add specs; git commit -qm 'upstream-only L0 addition'
git update-ref refs/remotes/origin/integration HEAD
git checkout -q 001-reviewed
git merge -q --no-edit origin/integration
check
assert_eq 0 "$STATUS" 'independent upstream L0 addition does not reset owner verdict'
git checkout -q "$DEFAULT"
printf 'upstream contract\n' > specs/product.md
git commit -qam 'conflicting L0 decision'
git update-ref refs/remotes/origin/integration HEAD
git checkout -q 001-reviewed
run git merge --no-edit origin/integration
assert_eq 1 "$STATUS" 'L0 fixture conflicts'
printf 'reviewed contract\n' > specs/product.md
git add specs/product.md; git commit -qm 'resolve L0 with old bytes'
MERGED="$(git rev-parse HEAD)"
printf '\n**Review**: round 2 · %s..%s · code · PASS · %s · https://example.invalid/review/7\n' "$REVIEWED" "$MERGED" "$CLEAN" >> "$RECORD"
git add "$RECORD"; git commit -qm 'code review after resolution'
check
assert_eq 1 "$STATUS" 'code review cannot replace owner approval for L0 integration'
assert_contains "$OUTPUT" "L0/L1 spec changed since the owner's head" 'owner gap named'

it "an arbitrary local base cannot manufacture a trusted import"
start_case
git checkout -qb untrusted-base "$BASE"
printf 'unreviewed side change\n' > docs/side.md
git add docs; git commit -qm 'side change'
git checkout -q 001-reviewed
git merge -q --no-edit untrusted-base
run bash "$CHECK" --json --base untrusted-base 001-reviewed
assert_eq 1 "$STATUS" 'local side branch is not a trusted import base'
run bash "$CHECK" --json --base "origin/$DEFAULT" 001-reviewed
assert_eq 1 "$STATUS" 'side branch is not in the actual declared base history'

it "renames and gitlink updates imported from the base retain coverage"
start_case
git checkout -q "$DEFAULT"
git mv docs/existing.md docs/renamed.md
git update-index --add --cacheinfo "160000,$BASE,vendor"
git commit -qm 'base rename and gitlink'
git update-ref refs/remotes/origin/integration HEAD
git checkout -q 001-reviewed
git merge -q --no-edit origin/integration
check
assert_eq 0 "$STATUS" 'base rename and gitlink pass'
git update-index --cacheinfo "160000,$REVIEWED,vendor"
git commit -qm 'unreviewed gitlink update'
check
assert_eq 1 "$STATUS" 'branch gitlink update still fails'

it "missing review history in a shallow checkout cannot establish coverage"
SHALLOW="$(mktemp -d)"; track_tmp "$SHALLOW"
git -c protocol.file.allow=always clone -q --depth 1 --branch 001-reviewed "file://$PROJ" "$SHALLOW"
run bash "$SHALLOW/.prdkit/scripts/bash/check-review.sh" --repo "$SHALLOW" --json 001-reviewed
assert_eq 1 "$STATUS" 'shallow history fails closed'
assert_contains "$OUTPUT" 'shallow clone needs the branch history' 'names the missing history'

finish
