#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TESTS_DIR/review-fixtures.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
CHECK="$PROJ/.prdkit/scripts/bash/check-review.sh"
cd "$PROJ" || exit 1
printf '\n## Configuration\n- review-integration-branches: origin/develop\n' > .prdkit/memory/config.md
review_policy "$PROJ"
git add -A >/dev/null; git commit -qm installed >/dev/null
DEFAULT="$(git symbolic-ref --short HEAD)"
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$DEFAULT"
git checkout -q -b 001-greet
mkdir -p src specs/changes; echo 'greet' > src/app.txt
git add -A >/dev/null; git commit -qm code >/dev/null
REVIEWED="$(git rev-parse --short HEAD)"

record() { # tier, then State review lines
    local tier="$1"; shift
    # Each call is a fresh scenario: replace the previous scenario's record commit, so its tier is
    # not part of this branch's history (a branch cannot lower a tier it named; tested below).
    [ "$(git log -1 --format=%s)" != record ] || git reset -q --soft HEAD~1
    mkdir -p specs/changes
    {
        printf '# Change: Warmer greeting\n\n**Opened**: 2026-10-15 · **Parts**: P1 · **Tier**: %s · **Parent**: none\n\n' "$tier"
        printf '## Acceptance\n\n| Item | Proves | Check | Attempts | Result |\n|---|---|---|---|---|\n| A1 | R-01 | test | 1 | PASS |\n\n'
        printf '## State\n\n**Step**: review\n'
        for line in "$@"; do printf '%s\n' "$line"; done
    } > specs/changes/001-greet.md
    git add specs/changes/001-greet.md; git commit -qm "record" >/dev/null
}
TRUSTED_TIP="$(git rev-parse origin/HEAD)"
it "the trusted constitution must name exactly one well-formed Rigor, even with no findings"
record T1
for rigor_lines in '' '- **Rigor**: light\n- **Rigor**: light\n' '- **Rigor**: light/full\n' '- **Rigor**: light1\n' \
    '- **Rigor**: light\n- **Rigor**:\n' '- **Rigor**: light\n- **Rigor**:   \n'; do
    { git show "$TRUSTED_TIP:.prdkit/memory/constitution.md" | sed '/\*\*Rigor\*\*:/d'; printf '%b' "$rigor_lines"; } |
        trusted_edit "refs/remotes/origin/$DEFAULT" .prdkit/memory/constitution.md
    run bash "$CHECK"
    assert_eq 1 "$STATUS" "Rigor lines [$rigor_lines] fail"
    assert_contains "$OUTPUT" "must name exactly one Rigor, light or full" "says why"
    git update-ref "refs/remotes/origin/$DEFAULT" "$TRUSTED_TIP"
done
{ git show "$TRUSTED_TIP:.prdkit/memory/constitution.md" | sed 's/^- \*\*Rigor\*\*: light/- **Rigor**: light (since the first release)/'; } |
    trusted_edit "refs/remotes/origin/$DEFAULT" .prdkit/memory/constitution.md
run bash "$CHECK"
assert_eq 3 "$STATUS" "a value followed by a note is still one Rigor"
git update-ref "refs/remotes/origin/$DEFAULT" "$TRUSTED_TIP"

it "a tier field must be exactly one tier"
for bad in 'T1/T3' 'T1-T3' 'T1x' 'T1, T3' 'T1; T3' 'T1 T3'; do
    record "$bad"
    run bash "$CHECK"
    assert_eq 1 "$STATUS" "**Tier**: $bad fails"
    assert_contains "$OUTPUT" "The record names no review tier" "says why"
done
record "\`T1\`"
run bash "$CHECK"
assert_eq 3 "$STATUS" "a tier in backticks reads the same"

it "an L0 edit is T3 whatever the first claim"
record T1
mkdir -p specs/product; echo '# Requirements' > specs/product/requirements.md
git add specs/product; git commit -qm "L0 edit" >/dev/null
record T1
run bash "$CHECK"
assert_eq 1 "$STATUS" "a T1 record with an L0 edit fails"
assert_contains "$OUTPUT" "its floor is T3, from its L0 edit (specs/product/requirements.md)" "names the L0 path"
git reset -q --hard "$REVIEWED"

it "the record's tier where the change left the base is a floor, even after the base closed it"
git checkout -q -b 004-floor "$DEFAULT"
mkdir -p specs/changes; printf '# Change: Floor\n\n**Tier**: T3\n\n## State\n' > specs/changes/004-floor.md
git add specs/changes; git commit -qm "T3 record on the base" >/dev/null
git update-ref "refs/remotes/origin/$DEFAULT" HEAD; FORK="$(git rev-parse HEAD)"
git rm -q specs/changes/004-floor.md; git commit -qm "the base closes it" >/dev/null
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
git checkout -q -b 004-floor-branch "$FORK"
mkdir -p src; echo 'code' > src/floor.txt; git add src/floor.txt; git commit -qm code >/dev/null
printf '# Change: Floor\n\n**Tier**: T1\n\n## State\n\n' > specs/changes/004-floor.md
git commit -qam "lower to T1" >/dev/null
run bash "$CHECK" 004-floor
assert_eq 1 "$STATUS" "the start's T3 still binds"
assert_contains "$OUTPUT" "its floor is T3, from the change's start" "names the start"
git checkout -q 001-greet; git branch -q -D 004-floor 004-floor-branch
git update-ref "refs/remotes/origin/$DEFAULT" "$TRUSTED_TIP"

it "a record on a trusted branch must name a readable tier, or the minimum is unknown"
record T1
for bad in T4 TBD T1junk T4/T1 'TBD (formerly T1)' 'T1, T3' 'T1; T3' 'T1 T3'; do
    git show HEAD:specs/changes/001-greet.md | sed "s|\*\*Tier\*\*: T[0-3]|**Tier**: $bad|" |
        trusted_edit "refs/remotes/origin/$DEFAULT" specs/changes/001-greet.md
    run bash "$CHECK"
    assert_eq 1 "$STATUS" "a trusted record with **Tier**: $bad fails"
    assert_contains "$OUTPUT" "The record at the trusted base (origin/$DEFAULT) names no readable tier" "says why"
    git update-ref "refs/remotes/origin/$DEFAULT" "$TRUSTED_TIP"
done

it "a self-declared T0 on code fails: T0 is checked against the trusted review-t0-paths"
record T0
run bash "$CHECK"
assert_eq 1 "$STATUS" "T0 with code and no T0 paths configured fails"
assert_contains "$OUTPUT" "lists no review-t0-paths, so T0 covers only the record and its validated closing metadata; this change also touches: src/app.txt" "says why"
assert_not_contains "$OUTPUT" "PASS 001-greet" "never the old claim-based pass"
TRUSTED_TIP="$(git rev-parse "refs/remotes/origin/$DEFAULT")"
{ git show "$TRUSTED_TIP:.prdkit/memory/config.md"; printf -- '- review-t0-paths: docs/, README.md\n'; } |
    trusted_edit "refs/remotes/origin/$DEFAULT" .prdkit/memory/config.md
run bash "$CHECK"
assert_eq 1 "$STATUS" "code outside the T0 paths still fails"
assert_contains "$OUTPUT" "not regular files under the trusted base's review-t0-paths" "says why"
assert_contains "$OUTPUT" "src/app.txt" "names the code path"
git update-ref "refs/remotes/origin/$DEFAULT" "$TRUSTED_TIP"

it "a branch cannot widen its own T0 paths; only docs under the trusted paths are T0"
git checkout -q -b 003-docs "$DEFAULT"
mkdir -p docs specs/changes; echo 'how to' > docs/guide.md; echo 'readme' > README.md
printf '# Change: Docs\n\n**Tier**: T0\n\n## State\n\n**Step**: review\n' > specs/changes/003-docs.md
git add -A >/dev/null; git commit -qm docs >/dev/null
run bash "$CHECK" 003-docs
assert_eq 1 "$STATUS" "no trusted T0 paths: docs are not T0 by name"
assert_contains "$OUTPUT" "this change also touches: README.md docs/guide.md" "names the docs"
printf '\n## Configuration\n- review-integration-branches: origin/develop\n- review-t0-paths: docs/, README.md, src/\n' > .prdkit/memory/config.md
git commit -qam "the branch lists its own T0 paths" >/dev/null
run bash "$CHECK" 003-docs
assert_eq 1 "$STATUS" "the branch's own config is not trusted"
assert_contains "$OUTPUT" ".prdkit/memory/config.md" "and editing the policy is never docs only"
git reset -q --hard HEAD~1
{ git show "$TRUSTED_TIP:.prdkit/memory/config.md"; printf -- '- review-t0-paths: docs/, README.md\n'; } |
    trusted_edit "refs/remotes/origin/$DEFAULT" .prdkit/memory/config.md
run bash "$CHECK" 003-docs
assert_eq 3 "$STATUS" "docs under the trusted T0 paths pass"
assert_contains "$OUTPUT" "PREVIEW" "says why"
mkdir -p specs/log; printf -- '- 2026-10-20 003-docs: docs — #3\n' > specs/log/003-docs.md
git add specs/log/003-docs.md; git commit -qm "the change's log entry" >/dev/null
run bash "$CHECK" 003-docs
assert_eq 3 "$STATUS" "the change's own log entry file is outside T0's paths, like the log"
chmod +x specs/log/003-docs.md; git add specs/log/003-docs.md; git commit -qm "executable entry" >/dev/null
run bash "$CHECK" 003-docs
assert_eq 1 "$STATUS" "an executable log entry fails"
assert_contains "$OUTPUT" "specs/log/003-docs.md must stay a regular, non-executable file" "says why"
git reset -q --hard HEAD~2
chmod +x docs/guide.md; git commit -qam "executable doc" >/dev/null
run bash "$CHECK" 003-docs
assert_eq 1 "$STATUS" "an executable file is not docs only"
assert_contains "$OUTPUT" "docs/guide.md" "names it"
git reset -q --hard HEAD~1
ln -s ../src/app.txt docs/link.md; git add docs/link.md; git commit -qm "symlink doc" >/dev/null
run bash "$CHECK" 003-docs
assert_eq 1 "$STATUS" "a symlink is not docs only"
assert_contains "$OUTPUT" "docs/link.md" "names it"
git reset -q --hard HEAD~1
mkdir -p docs/sub; echo x > docs/sub/a.md; echo y > docsx.md; git add -A >/dev/null; git commit -qm "prefix edge" >/dev/null
run bash "$CHECK" 003-docs
assert_eq 1 "$STATUS" "a directory entry matches only paths inside it"
assert_contains "$OUTPUT" "docsx.md" "names the near miss"
assert_not_contains "$OUTPUT" "docs/sub/a.md" "nested docs are inside the entry"
git reset -q --hard HEAD~1
echo '# Product' > specs/product.md; git add specs/product.md; git commit -qm "L0" >/dev/null
run bash "$CHECK" 003-docs
assert_eq 1 "$STATUS" "an L0 spec edit is never T0"
git reset -q --hard HEAD~1
git update-ref "refs/remotes/origin/$DEFAULT" "$TRUSTED_TIP"
git checkout -q 001-greet; git branch -q -D 003-docs

it "a branch may raise its tier but never lower it, even by a record-only commit after review"
record T3
sed -i.bak 's/\*\*Tier\*\*: T3/**Tier**: T1/' specs/changes/001-greet.md && rm -f specs/changes/001-greet.md.bak
git commit -qam "lower the tier after review" >/dev/null
run bash "$CHECK" --json
assert_eq 1 "$STATUS" "a record-only T3-to-T1 commit does not drop the tier floor"
assert_contains "$OUTPUT" "The record claims T1, but its floor is T3, from commit" "names the lowering"
assert_contains "$OUTPUT" '"tier":"T3"' "the effective tier is the floor"
git reset -q --hard HEAD~1
sed -i.bak 's/\*\*Tier\*\*: T3/**Tier**: T1 <!-- **Tier**: T0 -->/' specs/changes/001-greet.md && rm -f specs/changes/001-greet.md.bak
git commit -qam "a decoy tier" >/dev/null
run bash "$CHECK"
assert_eq 1 "$STATUS" "a second tier field, even in a comment, fails"
assert_contains "$OUTPUT" "The record names more than one review tier" "says why"
git reset -q --hard HEAD~1
record T1
sed -i.bak 's/\*\*Tier\*\*: T1/**Tier**: T2/' specs/changes/001-greet.md && rm -f specs/changes/001-greet.md.bak
git commit -qam "raise the tier" >/dev/null
run bash "$CHECK"
assert_contains "$OUTPUT" "PREVIEW" "checked at the raised tier"
git reset -q --hard HEAD~1
# The trusted base's copy of the record is a floor too, for a change merged with its record open.
git show HEAD:specs/changes/001-greet.md | sed 's/\*\*Tier\*\*: T1/**Tier**: T2/' |
    trusted_edit "refs/remotes/origin/$DEFAULT" specs/changes/001-greet.md
run bash "$CHECK"
assert_eq 1 "$STATUS" "a tier below the trusted base's record fails"
assert_contains "$OUTPUT" "The record claims T1, but its floor is T2, from the trusted base (origin/$DEFAULT)" "names the trusted floor"
git update-ref "refs/remotes/origin/$DEFAULT" "$TRUSTED_TIP"

it "the closing commit deletes the record and appends the log; the last record still decides"
record T1
git rm -q specs/changes/001-greet.md; mkdir -p specs; printf -- '- 2026-10-18 001-greet: warmer greeting — R-01 — #1\n' >> specs/log.md
git add specs/log.md; git commit -qm close >/dev/null
run bash "$CHECK" --json
assert_eq 3 "$STATUS" "passes after the record is deleted"
assert_contains "$OUTPUT" '"result":"preview","change":"001-greet"' "JSON result"
assert_contains "$OUTPUT" '"record_only":false' "the merge carries code"
it "the head and change id can be given, as CI does for a pull request"
git checkout -q "$DEFAULT"
run bash "$CHECK" --head 001-greet --base "origin/$DEFAULT" 001-greet
assert_eq 3 "$STATUS" "explicit head, base and id"
run bash "$CHECK"
assert_eq 2 "$STATUS" "the default branch is not a change id"
run bash "$CHECK" --head 001-greet 002-other
assert_contains "$OUTPUT" "No change record specs/changes/002-other.md" "an unknown change fails"

finish
