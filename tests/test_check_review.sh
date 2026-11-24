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
it "the trusted-ref reader includes locally configured refs on older partial-clone Git"
mkdir "$_SCRATCH_CWD/old-git" || exit 1
REVIEW_REAL_GIT="$(command -v git)"; export REVIEW_REAL_GIT
cat > "$_SCRATCH_CWD/old-git/git" <<'SH'
#!/bin/sh
if [ "$1" = version ]; then echo 'git version 2.39.5'; exit 0; fi
exec "$REVIEW_REAL_GIT" "$@"
SH
chmod +x "$_SCRATCH_CWD/old-git/git" &&
    git config remote.origin.promisor true &&
    git update-ref refs/remotes/origin/develop "$TRUSTED_TIP" || exit 1
read_trusted_refs() (
    source .prdkit/scripts/bash/spec-lib.sh
    PATH="$_SCRATCH_CWD/old-git:$PATH" GIT_ALLOW_PROTOCOL='' GIT_TRACE="$_SCRATCH_CWD/trusted.trace" \
        spec_trusted_refs "$PWD"
)
run read_trusted_refs
assert_eq 0 "$STATUS"
assert_eq "refs/remotes/origin/$DEFAULT"$'\n'refs/remotes/origin/develop "$OUTPUT"
assert_not_contains "$(cat "$_SCRATCH_CWD/trusted.trace")" 'built-in: git fetch '
git config --unset remote.origin.promisor &&
    git update-ref -d refs/remotes/origin/develop || exit 1

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

it "a label inside a Tags value cannot supply a tier claim or floor"
record T1
awk 'NR == 2 { print "**Tags**: sample **Tier**: T3" } { print }' \
    specs/changes/001-greet.md > specs/changes/001.tmp
mv specs/changes/001.tmp specs/changes/001-greet.md
git commit -qa --amend --no-edit >/dev/null
run bash "$CHECK" --json
assert_eq 3 "$STATUS"
assert_not_contains "$OUTPUT" 'more than one review tier'

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
mkdir -p .prdkit/history/log; printf -- '- 2026-10-20 003-docs: docs — #3\n' > .prdkit/history/log/003-docs.md
git add .prdkit/history/log/003-docs.md; git commit -qm "the change's log entry" >/dev/null
run bash "$CHECK" 003-docs
assert_eq 3 "$STATUS" "the change's own log entry file is outside T0's paths, like the log"
chmod +x .prdkit/history/log/003-docs.md; git add .prdkit/history/log/003-docs.md; git commit -qm "executable entry" >/dev/null
run bash "$CHECK" 003-docs
assert_eq 1 "$STATUS" "an executable log entry fails"
assert_contains "$OUTPUT" ".prdkit/history/log/003-docs.md must stay a regular, non-executable file" "says why"
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
it "the optional L1 design summary is excluded from T0 even under a trusted prefix"
{ git show "$TRUSTED_TIP:.prdkit/memory/config.md"; printf -- '- review-t0-paths: docs/, README.md, specs/\n'; } |
    trusted_edit "refs/remotes/origin/$DEFAULT" .prdkit/memory/config.md
run bash "$CHECK" 003-docs
assert_eq 3 "$STATUS" "the docs-only branch passes native-gate structure checks"
printf '# UI design\n' > specs/design.md
git add specs/design.md; git commit -qm "L1 UI design"
run bash "$CHECK" 003-docs
assert_eq 1 "$STATUS" "the UI spec is L1 even under a trusted T0 prefix"
assert_contains "$OUTPUT" "or the L0/L1 spec): specs/design.md. Claim T1 or higher" "only the L1 path is rejected"
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

it "untouched records do not affect the carrier's tier"
git checkout -q -b multiple-records "$DEFAULT"
OTHER=specs/changes/002-other.md
RENAMED=specs/changes/004-renamed.md
mkdir -p specs/changes
printf '# Change: Other\n\n**Tier**: T3\n' > "$OTHER"
printf '# Change: Low\n\n**Tier**: T1\n' > specs/changes/003-low.md
git add specs/changes; git commit -qm "open records on the base"
MULTI_BASE="$(git rev-parse HEAD)"
git update-ref "refs/remotes/origin/$DEFAULT" "$MULTI_BASE"
record T1
CARRIER_HEAD="$(git rev-parse HEAD)"
run bash "$CHECK" --json 001-greet
assert_eq 3 "$STATUS"
assert_contains "$OUTPUT" '"tier":"T1"'

it "downgrading another open record requires its trusted tier"
printf '# Change: Other\n\n**Tier**: T1\n' > "$OTHER"
git commit -qam "lower the other record"
run bash "$CHECK" --json 001-greet
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" '"tier":"T3"'
assert_contains "$OUTPUT" "its floor is T3, from the trusted base (origin/$DEFAULT) ($OTHER)"
use_gh_stub; approve_head
run bash "$CHECK" --json --pr https://github.com/owner/repo/pull/7 001-greet
assert_eq 1 "$STATUS" "a publisher's exact-head approval is not sufficient"
assert_contains "$OUTPUT" '"authority":"host"'
assert_contains "$OUTPUT" "T3 also requires a review-owner APPROVED review"
git reset -q --hard "$CARRIER_HEAD"

it "a deleted-and-recreated record counts even with no net diff for it"
git rm -q "$OTHER"; git commit -qm "delete the other record"
git show "$MULTI_BASE:$OTHER" > "$OTHER"
git add "$OTHER"; git commit -qm "recreate the other record"
run bash "$CHECK" --json 001-greet
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" '"tier":"T3"'
assert_contains "$OUTPUT" "its floor is T3, from the trusted base (origin/$DEFAULT) ($OTHER)"
git reset -q --hard "$CARRIER_HEAD"

it "a non-carrier change discarded by a merge still counts"
git checkout -q -b side-record-edit
git rm -q "$OTHER"; git commit -qm "remove the other record on the side branch"
git checkout -q multiple-records
git commit --allow-empty -qm "advance the carrier branch"
git merge -qs ours side-record-edit
run bash "$CHECK" --json 001-greet
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "its floor is T3, from the trusted base (origin/$DEFAULT) ($OTHER)"
git reset -q --hard "$CARRIER_HEAD"
git branch -q -D side-record-edit

it "both sides of a non-carrier rename count"
git mv "$OTHER" "$RENAMED"; git commit -qm "rename the other record"
run bash "$CHECK" --json 001-greet
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" '"tier":"T3"'
assert_contains "$OUTPUT" "its floor is T3, from the trusted base (origin/$DEFAULT) ($OTHER)"
git reset -q --hard "$CARRIER_HEAD"
git show "$MULTI_BASE:$OTHER" | trusted_edit "refs/remotes/origin/$DEFAULT" "$RENAMED"
git mv specs/changes/003-low.md "$RENAMED"; git commit -qm "move to a path with a trusted record"
run bash "$CHECK" --json 001-greet
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" '"tier":"T3"'
assert_contains "$OUTPUT" "its floor is T3, from the trusted base (origin/$DEFAULT) ($RENAMED)"
git reset -q --hard "$CARRIER_HEAD"
git update-ref "refs/remotes/origin/$DEFAULT" "$MULTI_BASE"

it "non-carriers do not supply floors from candidate-only tiers"
printf '# Change: New\n\n**Tier**: T3\n' > "$RENAMED"
git add "$RENAMED"; git commit -qm "add a non-carrier record"
run bash "$CHECK" --json 001-greet
assert_eq 3 "$STATUS"
assert_contains "$OUTPUT" '"tier":"T1"'
git reset -q --hard "$CARRIER_HEAD"

it "editing another record without changing its tier still raises the floor"
printf '\n## Notes\n\nA clarification.\n' >> "$OTHER"
git commit -qam "clarify the other record"
run bash "$CHECK" --json 001-greet
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" '"tier":"T3"'
assert_contains "$OUTPUT" "its floor is T3, from the trusted base (origin/$DEFAULT) ($OTHER)"
OTHER_EDIT="$(git rev-parse HEAD)"

it "an ambiguous or unreadable tier in a touched trusted record fails closed"
for trusted_text in '**Tier**: T3\n**Tier**: T1\n' '**Tier**: T3'; do
    printf '%b' "$trusted_text" | trusted_edit "refs/remotes/origin/$DEFAULT" "$OTHER"
    run bash "$CHECK" 001-greet
    assert_eq 1 "$STATUS"
    assert_contains "$OUTPUT" "The record at the trusted base (origin/$DEFAULT) names no readable tier"
    assert_contains "$OUTPUT" "$OTHER"
    git update-ref "refs/remotes/origin/$DEFAULT" "$MULTI_BASE"
done

it "the import base and the change's start also supply non-carrier floors"
git update-ref "refs/remotes/origin/$DEFAULT" "$TRUSTED_TIP"
git update-ref refs/remotes/origin/develop "$MULTI_BASE"
run bash "$CHECK" --json --base origin/develop 001-greet
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "its floor is T3, from the base (origin/develop) ($OTHER)"
git checkout -q --detach "$MULTI_BASE"
git rm -q "$OTHER"; git commit -qm "the integration branch closes the other record"
git update-ref refs/remotes/origin/develop HEAD
run bash "$CHECK" --json --head "$OTHER_EDIT" --base origin/develop 001-greet
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "its floor is T3, from the change's start ${MULTI_BASE:0:12} ($OTHER)"
git update-ref -d refs/remotes/origin/develop
git checkout -q 001-greet; git branch -q -D multiple-records

it "the closing commit deletes the record and appends the log; the last record still decides"
record T1
git rm -q specs/changes/001-greet.md; mkdir -p .prdkit/history/log; printf -- '- 2026-10-18 001-greet: warmer greeting — R-01 — #1\n' > .prdkit/history/log/001-greet.md
git add .prdkit/history/log; git commit -qm close >/dev/null
run bash "$CHECK" --json
assert_eq 3 "$STATUS" "passes after the record is deleted"
assert_contains "$OUTPUT" '"result":"preview","change":"001-greet"' "JSON result"
assert_contains "$OUTPUT" '"record_only":false' "the merge carries code"
git reset -q --hard HEAD^
git rm -q specs/changes/001-greet.md
mkdir -p .prdkit/history
printf -- '- 2026-10-18 001-greet: direct folded close\n' > .prdkit/history/log.md
git add .prdkit/history/log.md; git commit -qm 'unsupported direct close'
run bash "$CHECK"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'use the current per-change entry format'
git reset -q --hard HEAD^
it "the head and change id can be given, as CI does for a pull request"
git checkout -q "$DEFAULT"
run bash "$CHECK" --head 001-greet --base "origin/$DEFAULT" 001-greet
assert_eq 3 "$STATUS" "explicit head, base and id"
run bash "$CHECK"
assert_eq 2 "$STATUS" "the default branch is not a change id"
run bash "$CHECK" --head 001-greet 002-other
assert_contains "$OUTPUT" "No change record specs/changes/002-other.md" "an unknown change fails"

finish
