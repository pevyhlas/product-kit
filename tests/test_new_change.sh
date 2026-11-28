#!/usr/bin/env bash
# Tests for new-change.sh: numbering across every claimed identity, slug cleaning, the change
# record from its template, JSON output, worktree isolation and branch creation.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"  # physical path: macOS mktemp dirs live under /var -> /private/var
git -C "$PROJ" add -A >/dev/null 2>&1; git -C "$PROJ" commit -qm installed >/dev/null 2>&1
SCRIPT="$PROJ/.prdkit/scripts/bash/new-change.sh"
MAIN_BRANCH="$(git -C "$PROJ" branch --show-current)"
cd "$PROJ" || exit 1

it "explicit numbering in an empty project emits no error diagnostic"
run bash -c 'exec bash "$1" --json --no-branch --number 7 --short-name fresh-number desc 2>.git/fresh-number.err' _ "$SCRIPT"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '"CHANGE_ID":"007-fresh-number"'
assert_eq "[prdkit] Continue all work for this change inside: $PROJ" "$(cat .git/fresh-number.err)" 'stderr only contains the normal location notice'
rm -f specs/changes/007-fresh-number.md

it "first change is numbered 001 and isolated in a worktree"
run env PRDKIT_TODAY=2026-10-17 bash "$SCRIPT" --json --short-name "user-auth" "Add user authentication"
assert_eq 0 "$STATUS" "script exits 0"
WT="$PROJ/.worktrees/001-user-auth"
assert_contains "$OUTPUT" '"CHANGE_ID":"001-user-auth"' "change id 001-user-auth"
assert_contains "$OUTPUT" '"BRANCH_NAME":"001-user-auth"' "branch named after the change"
assert_contains "$OUTPUT" "\"CHANGE_FILE\":\"$WT/specs/changes/001-user-auth.md\"" "record path emitted"
assert_contains "$OUTPUT" "\"WORKTREE_PATH\":\"$WT\"" "worktree path emitted"
assert_contains "$OUTPUT" "Continue all work" "output points at the worktree"
assert_eq "001-user-auth" "$(git -C "$WT" branch --show-current)" "branch checked out in the worktree"
assert_eq "$MAIN_BRANCH" "$(git -C "$PROJ" branch --show-current)" "main checkout stays on its branch"

it "the record comes from the change template with intent and date filled in"
REC="$WT/specs/changes/001-user-auth.md"
assert_file "$REC" "record created inside the worktree"
assert_eq "# Change: Add user authentication" "$(head -n 1 "$REC")" "title is the intent"
assert_contains "$(cat "$REC")" "**Opened**: 2026-10-17" "opened date filled in"
assert_contains "$(cat "$REC")" "## Acceptance" "template sections present"
assert_contains "$(cat "$REC")" "**Waiting on**: nothing" "State fields present"

it ".gitignore keeps .worktrees/ ignored"
assert_contains "$(cat "$PROJ/.gitignore")" ".worktrees/" ".worktrees/ is ignored"

it "numbering increments to 002 even when 001 lives only in a worktree"
assert_contains "$OUTPUT" '"UNCARRIED_SPECS":[]' "nothing left behind on a clean checkout"
mkdir -p specs; printf '### Make export async\n*2026-10-17 · owner · processing*\n' > specs/inbox.md
run bash "$SCRIPT" --json --short-name "next-thing" "Another change entirely"
assert_contains "$OUTPUT" '"CHANGE_ID":"002-next-thing"' "second change is 002"

it "uncommitted spec context left in the main checkout is named, not silently lost"
assert_contains "$OUTPUT" '"UNCARRIED_SPECS":["specs/inbox.md"]' "the uncommitted inbox is listed"
assert_contains "$OUTPUT" "is not in the new worktree, which starts from committed HEAD" "the agent is warned"
assert_eq "" "$(ls "$PROJ/.worktrees/002-next-thing/specs/inbox.md" 2>/dev/null)" "the worktree really lacks it"
rm -f specs/inbox.md

it "short-name is slugified (lowercase, non-alnum -> hyphen, collapsed)"
run bash "$SCRIPT" --json --short-name "Fix   Payment_Bug!!" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"003-fix-payment-bug"' "slug cleaned to fix-payment-bug"

it "auto-derives a slug from the intent, filtering stop words"
run bash "$SCRIPT" --json "Build the analytics dashboard"
assert_contains "$OUTPUT" '"CHANGE_ID":"004-build-analytics-dashboard"' "stop-word 'the' filtered out"

it "automatic slugs retain short uppercase acronyms portably"
run bash "$SCRIPT" --json --number 6 "Build UI tools"
assert_eq 0 "$STATUS" "acronym slug generation succeeds"
assert_contains "$OUTPUT" '"CHANGE_ID":"006-build-ui-tools"' "short uppercase UI retained"
assert_not_contains "$OUTPUT" 'bad substitution' "no Bash 4-only expansion"

it "invalid template tags cannot create a record, branch or worktree"
TAG_PROJ="$(make_inited_project)"; track_tmp "$TAG_PROJ"
TAG_PROJ="$(cd "$TAG_PROJ" && pwd -P)"
cd "$TAG_PROJ" || exit 1
git add -A && git commit -qm installed || exit 1
tag_script=.prdkit/scripts/bash/new-change.sh
tag_template=.prdkit/templates/change-template.md
printf '# Change: template\n\n**Opened**: <date> ·**Tags**: cli/v2 · **Tier**: T1\n' > "$tag_template"
git add "$tag_template" && git commit -qm "invalid template tags" || exit 1
printf '# Change: template\n\n**Tags**: cli-v2_1.0, small batch\n' > "$tag_template"
run bash "$tag_script" --number 51 --short-name "invalid-tags" "desc"
assert_eq 1 "$STATUS" "isolated changes validate the committed template, not the local edit"
assert_contains "$OUTPUT" "Malformed Tags"
assert_not_contains "$(git branch --list)" "051-invalid-tags"
assert_eq absent "$([ -e .worktrees/051-invalid-tags ] && echo present || echo absent)"
run bash "$tag_script" --no-branch --number 52 --short-name "valid-tags" "desc"
assert_eq 0 "$STATUS" "record-only changes use the local template"
assert_contains "$(cat specs/changes/052-valid-tags.md)" '**Tags**: cli-v2_1.0, small batch'
printf '# Change: template\n\n**Tags**: cli/v2\n' > "$tag_template"
run bash "$tag_script" --no-branch --number 53 --short-name "invalid-local-tags" "desc"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "Malformed Tags"
assert_eq absent "$([ -e specs/changes/053-invalid-local-tags.md ] && echo present || echo absent)"
cd "$PROJ" || exit 1

it "a missing pinned template object refuses sparse allocation without a promisor fetch"
partial="$(mktemp -d)" || exit 1
track_tmp "$partial"
git -C "$TAG_PROJ" config uploadpack.allowFilter true || exit 1
if git clone -q --filter=blob:none --no-checkout "file://$TAG_PROJ" "$partial/clone" &&
    [ "$(git -C "$partial/clone" config --bool --get remote.origin.promisor)" = true ]; then
    (
        cd "$partial/clone" || exit 1
        git sparse-checkout set specs .prdkit/scripts .prdkit/memory &&
            git checkout -q "$(git symbolic-ref --short HEAD)" &&
            git init -q --bare --template= "$partial/local.git" &&
            git rev-parse --path-format=absolute --git-path objects > "$partial/local.git/objects/info/alternates" || exit 1
    ) || exit 1
    template_oid="$(git -C "$TAG_PROJ" rev-parse "HEAD:$tag_template")" || exit 1
    run git --git-dir="$partial/local.git" cat-file -e "$template_oid"
    assert_eq 1 "$STATUS" "the committed template blob is actually absent"

    # Exercise the pre-2.45 fallback even on runners with newer Git.
    mkdir "$partial/bin" || exit 1
    PARTIAL_REAL_GIT="$(command -v git)"; export PARTIAL_REAL_GIT
    cat > "$partial/bin/git" <<'SH'
#!/bin/sh
if [ "$1" = version ]; then echo 'git version 2.39.5'; exit 0; fi
exec "$PARTIAL_REAL_GIT" "$@"
SH
    chmod +x "$partial/bin/git" || exit 1
    run_sparse_allocator() (
        cd "$partial/clone" || exit 1
        PATH="$1" GIT_ALLOW_PROTOCOL='' GIT_TRACE="$partial/trace" \
            bash .prdkit/scripts/bash/new-change.sh --json --short-name missing-template desc
    )
    before="$(git -C "$partial/clone" worktree list --porcelain)"
    for git_path in "$partial/bin:$PATH" "$PATH"; do
        : > "$partial/trace"
        run run_sparse_allocator "$git_path"
        assert_eq 1 "$STATUS"
        assert_contains "$OUTPUT" "cannot read $tag_template at"
        assert_contains "$OUTPUT" 'make the committed file available locally'
        assert_not_contains "$(cat "$partial/trace")" 'built-in: git fetch '
        assert_eq "$before" "$(git -C "$partial/clone" worktree list --porcelain)"
        assert_eq "$MAIN_BRANCH" "$(git -C "$partial/clone" branch --list --format='%(refname:short)')"
        assert_eq absent "$([ -e "$partial/clone/.worktrees" ] && echo present || echo absent)"
        assert_eq '' "$(git -C "$partial/clone" status --short)" 'no record or other change was made'
    done
else
    _ok 'blob-filtered clones unavailable; skipped'
fi

it "a linked change template with an unfetched link or target refuses instead of falling back"
LINK_PROJ="$(make_inited_project)"; track_tmp "$LINK_PROJ"
LINK_PROJ="$(cd "$LINK_PROJ" && pwd -P)"
cd "$LINK_PROJ" || exit 1
mkdir -p docs && mv "$tag_template" docs/custom-change.md || exit 1
ln -s custom-change.md docs/intermediate.md &&
    ln -s ../../docs/intermediate.md "$tag_template" &&
    git add -A && git commit -qm "two-hop linked change template" && git config uploadpack.allowFilter true || exit 1
link_partial="$(mktemp -d)" || exit 1
track_tmp "$link_partial"
mkdir "$link_partial/bin" || exit 1
PARTIAL_REAL_GIT="$(command -v git)"; export PARTIAL_REAL_GIT
cat > "$link_partial/bin/git" <<'SH'
#!/bin/sh
if [ "$1" = version ]; then echo 'git version 2.39.5'; exit 0; fi
exec "$PARTIAL_REAL_GIT" "$@"
SH
chmod +x "$link_partial/bin/git" || exit 1
run_linked_allocator() ( # clone, PATH
    cd "$1" || exit 1
    PATH="$2" GIT_ALLOW_PROTOCOL='' GIT_TRACE="$link_partial/trace" \
        bash .prdkit/scripts/bash/new-change.sh --json --short-name linked-template desc
)
# Sparse layouts: the original link absent, or the original link local and the
# intermediate link and target absent.
for layout in without-templates with-templates; do
    clone="$link_partial/$layout"
    if ! git clone -q --filter=blob:none --no-checkout "file://$LINK_PROJ" "$clone" ||
        [ "$(git -C "$clone" config --bool --get remote.origin.promisor)" != true ]; then
        _ok 'blob-filtered clones unavailable; skipped'
        continue
    fi
    sparse=(specs .prdkit/scripts .prdkit/memory)
    [ "$layout" = without-templates ] || sparse+=(.prdkit/templates)
    (
        cd "$clone" || exit 1
        git sparse-checkout set "${sparse[@]}" &&
            git checkout -q "$(git symbolic-ref --short HEAD)" &&
            git init -q --bare --template= "$clone.objects.git" &&
            git rev-parse --path-format=absolute --git-path objects > "$clone.objects.git/objects/info/alternates" || exit 1
    ) || exit 1
    for blob_path in "$tag_template" docs/intermediate.md docs/custom-change.md; do
        expected=1
        [ "$layout:$blob_path" != "with-templates:$tag_template" ] || expected=0
        blob_oid="$(git -C "$LINK_PROJ" rev-parse "HEAD:$blob_path")" || exit 1
        run git --git-dir="$clone.objects.git" cat-file -e "$blob_oid"
        assert_eq "$expected" "$STATUS" "$layout: the $blob_path blob local state is as arranged"
    done
    for git_path in "$link_partial/bin:$PATH" "$PATH"; do
        : > "$link_partial/trace"
        run run_linked_allocator "$clone" "$git_path"
        assert_eq 1 "$STATUS" "$layout: no silent built-in fallback for an unavailable link"
        assert_contains "$OUTPUT" "cannot read $tag_template at"
        assert_not_contains "$(cat "$link_partial/trace")" 'built-in: git fetch '
        assert_eq absent "$([ -e "$clone/.worktrees" ] && echo present || echo absent)"
        assert_eq '' "$(git -C "$clone" status --short)" 'no record or other change was made'
    done
done
git rm -qf docs/custom-change.md && git commit -qm "dangling linked template" || exit 1
run bash .prdkit/scripts/bash/new-change.sh --json --number 57 --short-name "dangling-link" "desc"
assert_eq 0 "$STATUS" "a genuinely dangling link in an ordinary clone still falls back"
assert_contains "$OUTPUT" '"CHANGE_ID":"057-dangling-link"'
cd "$PROJ" || exit 1

it "an uncommitted change template falls back despite unrelated template symlinks"
cd "$TAG_PROJ" || exit 1
git rm -qf "$tag_template" &&
    ln -sf ../memory/config.md .prdkit/templates/architecture-template.md &&
    git add -A && git commit -qm "drop change template; link a sibling" || exit 1
run bash "$tag_script" --json --number 54 --short-name "sibling-link" "desc"
assert_eq 0 "$STATUS" "a sibling symlink is not on the template path"
assert_contains "$OUTPUT" '"CHANGE_ID":"054-sibling-link"'
assert_not_contains "$OUTPUT" 'make the committed file available locally'
ln -s missing-dir .prdkit/linked && git add .prdkit/linked && git commit -qm "dangling sibling dir link" || exit 1
run bash "$tag_script" --json --number 55 --short-name "sibling-dir-link" "desc"
assert_eq 0 "$STATUS" "a symlink beside an ancestor is not an ancestor"
cd "$PROJ" || exit 1

it "an empty intent or a non-numeric --number is rejected"
run bash "$SCRIPT" --json --short-name "x"
assert_eq 1 "$STATUS" "missing intent exits non-zero"
run bash "$SCRIPT" --json --number "1/../x" --short-name "x" "desc"
assert_eq 1 "$STATUS" "path-shaped number rejected"
run bash "$SCRIPT" --json --short-name "!!!" "!!!"
assert_eq 1 "$STATUS" "an intent with no usable slug is rejected"
assert_contains "$OUTPUT" "--short-name" "asks for a short name"

it "--number overrides auto-detection"
run bash "$SCRIPT" --json --number 42 --short-name "manual-num" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"042-manual-num"' "explicit number zero-padded to 042"

it "fails with an actionable message if the branch already exists"
git -C "$PROJ" branch 043-dup-branch >/dev/null 2>&1
run bash "$SCRIPT" --json --number 43 --short-name "dup-branch" "desc"
assert_eq 1 "$STATUS" "exits non-zero when branch exists"
assert_contains "$OUTPUT" "already exists" "error mentions branch exists"
assert_contains "$OUTPUT" "git checkout" "suggests checkout command"
assert_eq "absent" "$([ -d "$PROJ/.worktrees/043-dup-branch" ] && echo present || echo absent)" "no worktree created for duplicate"

it "never overwrites an existing change record"
mkdir -p "$PROJ/specs/changes"
echo "DRAFTED RECORD — do not lose" > "$PROJ/specs/changes/044-drafted.md"
run bash "$SCRIPT" --json --no-worktree --number 44 --short-name "drafted" "desc"
assert_eq 1 "$STATUS" "refuses to reuse a drafted record"
assert_contains "$OUTPUT" "never overwritten" "explains the refusal"
assert_eq "DRAFTED RECORD — do not lose" "$(cat "$PROJ/specs/changes/044-drafted.md")" "drafted record untouched"
assert_eq "$MAIN_BRANCH" "$(git -C "$PROJ" branch --show-current)" "no branch switch on refusal"
rm -rf "$PROJ/specs/changes"

it "--no-worktree creates the branch and record in the current checkout"
run bash "$SCRIPT" --json --no-worktree --number 50 --short-name "in-place" "desc"
assert_eq 0 "$STATUS" "script exits 0"
assert_eq "050-in-place" "$(git -C "$PROJ" branch --show-current)" "branch checked out in the main checkout"
assert_file "$PROJ/specs/changes/050-in-place.md" "record created in the main checkout"
assert_contains "$OUTPUT" "\"WORKTREE_PATH\":\"$PROJ\"" "WORKTREE_PATH is the current root"
git -C "$PROJ" checkout -q "$MAIN_BRANCH" >/dev/null 2>&1; rm -rf "$PROJ/specs/changes"

it "running inside a linked worktree creates the branch in place (no nesting)"
cd "$WT" || exit 1
run bash "$SCRIPT" --json --number 60 --short-name "from-worktree" "desc"
assert_eq 0 "$STATUS" "script exits 0"
assert_eq "060-from-worktree" "$(git -C "$WT" branch --show-current)" "branch checked out in the same worktree"
assert_eq "absent" "$([ -d "$WT/.worktrees" ] && echo present || echo absent)" "no nested worktree created"
assert_file "$WT/specs/changes/060-from-worktree.md" "record created in the current worktree"
cd "$PROJ" || exit 1

it "ordinary changes get a one-line pointer, not the programme checkpoint"
POINTER='<!-- Outcome checkpoint format: .prdkit/scripts/bash/outcome-checkpoint.md -->'
assert_eq 1 "$(grep -cxF "$POINTER" "$REC")" "one pointer to the canonical scaffold"
assert_not_contains "$(cat "$REC")" '### Outcome checkpoint' "no scaffold heading"
assert_not_contains "$(cat "$REC")" '**Selection**:' "no trailing scaffold fields"
assert_contains "$(cat "$REC")" '<!-- Verdicts live' "the next template comment is preserved"

it "doctor and status leave a pointer-only record alone"
run bash -c 'cd "$1" && bash .prdkit/scripts/bash/doctor.sh --json' _ "$WT"
assert_eq 0 "$STATUS" "doctor passes in the record's worktree: $OUTPUT"
# The default Bounds example can have a trace advisory; it is unrelated to the pointer.
assert_eq '[]' "$(printf '%s\n' "$OUTPUT" | jq -c '[.advisories[] | select(test("checkpoint"; "i"))]')" "no checkpoint advisory"
run bash .prdkit/scripts/bash/status.sh --json
assert_eq 0 "$STATUS" "status succeeds"
assert_eq '[]' "$(printf '%s\n' "$OUTPUT" | jq -c '.outcome_progress')" "no outcome row"

it "retrying the same ordinary change leaves its linked-worktree record alone"
cp "$REC" .git/ordinary-before
run bash "$SCRIPT" --no-branch --number 1 --short-name user-auth "Different intent"
assert_eq 1 "$STATUS" "the existing identity is refused"
assert_contains "$OUTPUT" "never overwritten" "the refusal explains why"
run cmp -s .git/ordinary-before "$REC"
assert_eq 0 "$STATUS" "ordinary record is byte-for-byte unchanged"

it "--programme emits the full commented scaffold with unknown history"
PROGRAMME_REC=specs/changes/061-programme.md
run bash "$SCRIPT" --json --programme --no-branch --number 61 --short-name programme "Coordinate related changes"
assert_eq 0 "$STATUS" "programme opens: $OUTPUT"
assert_file "$PROGRAMME_REC" "programme record exists"
if [ -f "$PROGRAMME_REC" ]; then
    assert_not_contains "$(cat "$PROGRAMME_REC")" "$POINTER" "the scaffold replaces the pointer"
    SCAFFOLD="$(sed -n '/^<!-- A programme or continuing follow-up queue/,/^-->$/p' "$PROGRAMME_REC")"
    assert_eq 8 "$(printf '%s\n' "$SCAFFOLD" | grep -c '^\*\*')" "all checkpoint fields are in the comment"
    assert_contains "$SCAFFOLD" '### Outcome checkpoint' "scaffold heading"
    assert_contains "$SCAFFOLD" '**Selection**:' "scaffold includes its last field"
    assert_contains "$SCAFFOLD" '**Progress**: unknown' "no unevidenced advance is assumed"
    assert_contains "$SCAFFOLD" '**No-progress changes**: unknown' "unknown history is not a zero count"
    assert_contains "$(cat "$PROGRAMME_REC")" '<!-- Verdicts live' "the next template comment is preserved"
fi

it "retrying creation cannot rewrite a filled checkpoint"
mkdir -p specs/changes
cat > "$PROGRAMME_REC" <<'MD'
# Change: Coordinate related changes

## State

### Outcome checkpoint
**Outcome**: A verified path
**Milestone**: An integrated interface
**Critical path**: Review the interface contract
**Allocation**: One contract lane
**Progress**: unknown
**No-progress changes**: unknown
**Progress limit**: 4
MD
# Deliberately omit the final newline, so a render pass cannot masquerade as a no-op.
printf '**Selection**: Verify the interface contract  ' >> "$PROGRAMME_REC"
cp "$PROGRAMME_REC" .git/programme-before
for mode in '' --programme; do
    run bash "$SCRIPT" ${mode:+"$mode"} --no-branch --number 61 --short-name programme "Different intent"
    assert_eq 1 "$STATUS" "retry ${mode:-without opt-in} refuses the existing record"
    assert_contains "$OUTPUT" 'never overwritten' "refusal happens at the record"
    run cmp -s .git/programme-before "$PROGRAMME_REC"
    assert_eq 0 "$STATUS" "filled record is byte-for-byte unchanged"
done
# The verifier requires LF-terminated Markdown. The retry checks above use a deliberately partial line.
printf '\n' >> "$PROGRAMME_REC"
run bash .prdkit/scripts/bash/status.sh --json
assert_eq 0 "$STATUS" "status can read the resumed programme"
assert_eq '["unknown",null]' "$(printf '%s\n' "$OUTPUT" | jq -c '.outcome_progress[] | select(.id == "061-programme") | [.count_signal, .no_progress_changes]')" "resume preserves unknown history"

it "upgrade supplies a programme scaffold when a customized change template has no block"
CUSTOM="$(make_project)"; track_tmp "$CUSTOM"
cd "$CUSTOM" || exit 1
SOURCE_TEMPLATE=.product-kit/templates/change-template.md
TEMPLATE=.prdkit/templates/change-template.md
SOURCE_SNIPPET=.product-kit/scripts/outcome-checkpoint.md
SNIPPET=.prdkit/scripts/bash/outcome-checkpoint.md
if [ -f "$SOURCE_SNIPPET" ]; then mv "$SOURCE_SNIPPET" .git/kit-scaffold; fi
cat > "$SOURCE_TEMPLATE" <<'MD'
# Change: <short name>
**Opened**: <date>
## State
**Next**: Check the result
<!-- A programme or continuing follow-up queue (workflows/planning.md, Protect the outcome):
### Outcome checkpoint
-->
## Notes
Keep this section.
MD
run bash .product-kit/scripts/init.sh
assert_eq 0 "$STATUS" "pre-upgrade install succeeds: $OUTPUT"
sed '/^<!-- A programme or continuing follow-up queue/,/^-->$/d' "$TEMPLATE" > .git/custom-template
cp .git/custom-template "$TEMPLATE"
cp "$PK_ROOT/templates/change-template.md" "$SOURCE_TEMPLATE"
if [ -f .git/kit-scaffold ]; then mv .git/kit-scaffold "$SOURCE_SNIPPET"; fi
snapshot_upgrade_fixture "$CUSTOM" || exit 1
run bash .product-kit/scripts/init.sh --upgrade
assert_eq 0 "$STATUS" "upgrade succeeds: $OUTPUT"
run cmp -s .git/custom-template "$TEMPLATE"
assert_eq 0 "$STATUS" "upgrade keeps the consumer template byte-for-byte"
assert_file "$SNIPPET" "upgrade installs the canonical snippet"
if [ -f "$SNIPPET" ]; then
    HASH="$(source .prdkit/scripts/bash/install-lib.sh && install_hash_stream < "$SNIPPET")"
    assert_contains "$(cat .prdkit/.manifest)" "$HASH  $SNIPPET" "manifest records the snippet's content"
    printf '\nLocal edit.\n' >> "$SNIPPET"
    run bash .prdkit/scripts/bash/doctor.sh --json
    assert_contains "$OUTPUT" "Kit-owned content drift: $SNIPPET" "doctor detects snippet drift"
    cp "$SOURCE_SNIPPET" "$SNIPPET"
    printf '\n<!-- Revised kit snippet -->\n' >> "$SOURCE_SNIPPET"
    snapshot_upgrade_fixture "$CUSTOM" || exit 1
    run bash .product-kit/scripts/init.sh --upgrade
    assert_eq 0 "$STATUS" "another upgrade refreshes kit-owned content: $OUTPUT"
    run cmp -s "$SOURCE_SNIPPET" "$SNIPPET"
    assert_eq 0 "$STATUS" "upgrade installs the revised canonical snippet"
fi
run env PRDKIT_TODAY=2026-10-17 bash .prdkit/scripts/bash/new-change.sh --programme --no-branch --number 1 --short-name custom "Custom programme"
assert_eq 0 "$STATUS" "programme opens with the consumer template: $OUTPUT"
CUSTOM_RECORD=specs/changes/001-custom.md
assert_contains "$(cat "$CUSTOM_RECORD")" '**No-progress changes**: unknown' "missing history is still initialized as unknown"
if [ -f "$SNIPPET" ]; then
    {
        printf '# Change: Custom programme\n**Opened**: 2026-10-17\n## State\n**Next**: Check the result\n'
        cat "$SNIPPET"
        printf '## Notes\nKeep this section.\n'
    } > .git/expected
    run cmp -s .git/expected "$CUSTOM_RECORD"
    assert_eq 0 "$STATUS" "the canonical snippet is inserted in State, before the next section"
fi

it "a template missing only its final LF produces a record both verifiers can read"
TEXT=$'# Change: Check record text\n\n**Opened**: 2026-10-17\n\n## State\n\n**Step**: intent\n**Waiting on**: nothing\n**Next**: Check the result  '
printf '%s' "$TEXT" > "$TEMPLATE"
printf '%s\n' "$TEXT" > .git/expected
run bash .prdkit/scripts/bash/new-change.sh --no-branch --number 5 --short-name final-lf "Check record text"
assert_eq 0 "$STATUS" "creation succeeds: $OUTPUT"
run cmp -s .git/expected specs/changes/005-final-lf.md
assert_eq 0 "$STATUS" "creation adds only the final LF"
run bash .prdkit/scripts/bash/status.sh --json
assert_eq 0 "$STATUS" "status reads the created record: $OUTPUT"
run jq -e '.changes | any(.id == "005-final-lf")' <<< "$OUTPUT"
assert_eq 0 "$STATUS" "status lists the created record"
run bash .prdkit/scripts/bash/doctor.sh --json
assert_eq 0 "$STATUS" "doctor reads the created record: $OUTPUT"
run jq -e '.result == "pass"' <<< "$OUTPUT"
assert_eq 0 "$STATUS" "doctor emits a passing JSON report"

it "retired checkpoint scaffolds fail with the current template format"
for opener in \
    '<!-- A programme or continuing follow-up queue (workflows/planning.md):' \
    '<!-- For a programme/continuing follow-up queue,'; do
    printf '%s\n' '## State' "$opener" '### Outcome checkpoint' '-->' > "$TEMPLATE"
    run bash .prdkit/scripts/bash/new-change.sh --no-branch --number 6 --short-name obsolete "Check an unsupported template"
    assert_eq 1 "$STATUS" 'unsupported stock scaffold rejected'
    assert_contains "$OUTPUT" 'current outcome checkpoint pointer'
    assert_eq absent "$([ -e specs/changes/006-obsolete.md ] && echo present || echo absent)"
done
printf '%s\n' '## State' '### Outcome checkpoint' '**Outcome**: The result' > "$TEMPLATE"

it "--programme keeps a checkpoint already present in a custom change template"
run bash .prdkit/scripts/bash/new-change.sh --programme --no-branch --number 8 --short-name existing "Keep the existing scaffold"
assert_eq 0 "$STATUS" "the custom template already has a checkpoint"
run cmp -s "$TEMPLATE" specs/changes/008-existing.md
assert_eq 0 "$STATUS" "no second scaffold or changes to the custom checkpoint"

it "--programme ignores example headings and inserts before the next real section"
N=9
for heading in '### Outcome checkpoint' '## Example output' '### Outcome checkpoint'; do
    case "$N" in
        9|10) START='```markdown'; END='```' ;;
        11) START='<!-- Example output'; END='-->' ;;
    esac
    {
        sed '/^## Notes/,$d' .git/custom-template
        printf '\n%s\n%s\n%s\n\n' "$START" "$heading" "$END"
    } > .git/state
    printf '## Notes\nKeep this section.\n' > .git/notes
    cat .git/state .git/notes > "$TEMPLATE"
    {
        printf '# Change: Example headings\n**Opened**: 2026-10-17\n'
        tail -n +3 .git/state
        cat "$SNIPPET" .git/notes
    } > .git/expected
    run env PRDKIT_TODAY=2026-10-17 bash .prdkit/scripts/bash/new-change.sh --programme --no-branch \
        --number "$N" --short-name example "Example headings"
    assert_eq 0 "$STATUS" "creation succeeds for $START / $heading"
    run cmp -s .git/expected "specs/changes/$(printf '%03d' "$N")-example.md"
    assert_eq 0 "$STATUS" "the scaffold is in State outside $START / $heading"
    N=$((N + 1))
done

it "--programme validates real header tags after rendering LF text and skipping fenced examples"
render_tagged_fixture() { # line ending; omit the final terminator
    printf '%s%s' '# Change: Example template' "$1" \
        '**Opened**: <date>' "$1" '```markdown' "$1" '**Tags**: fenced/example' "$1" '```' "$1" \
        '**Tags**: release-notes, batch_1.0' "$1" '## State' "$1" \
        '```markdown' "$1" '### Outcome checkpoint' "$1" '```' "$1" "$POINTER" "$1"
    printf '%s' '**Next**: Verify the change  '
}
render_tagged_fixture $'\r\n' > "$TEMPLATE"
run env PRDKIT_TODAY=2026-10-17 bash .prdkit/scripts/bash/new-change.sh --programme --no-branch \
    --number 12 --short-name tagged "Tagged programme"
assert_eq 0 "$STATUS" "valid header tags are accepted; fenced example is ignored"
{
    render_tagged_fixture $'\n'
    printf '\n'
} | awk -v pointer="$POINTER" -v snippet="$SNIPPET" '
    NR == 1 { print "# Change: Tagged programme"; next }
    NR == 2 { print "**Opened**: 2026-10-17"; next }
    $0 == pointer { while ((getline row < snippet) > 0) print row; next }
    { print }
' > .git/expected
run cmp -s .git/expected specs/changes/012-tagged.md
assert_eq 0 "$STATUS" "exact scaffold, fence, spacing and final LF are preserved"
sed 's/release-notes/release\/notes/' "$TEMPLATE" > .git/invalid-tag-template
cp .git/invalid-tag-template "$TEMPLATE"
run bash .prdkit/scripts/bash/new-change.sh --programme --no-worktree --number 13 --short-name bad-tags "Invalid programme"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'Malformed Tags'
assert_eq absent "$([ -e specs/changes/013-bad-tags.md ] && echo present || echo absent)"
assert_not_contains "$(git branch --list)" '013-bad-tags'

# --- Numbering across every claimed identity -----------------------------------------------
PROJ2="$(make_inited_project)"; track_tmp "$PROJ2"
PROJ2="$(cd "$PROJ2" && pwd -P)"
git -C "$PROJ2" add -A >/dev/null 2>&1; git -C "$PROJ2" commit -qm installed >/dev/null 2>&1
SCRIPT2="$PROJ2/.prdkit/scripts/bash/new-change.sh"
cd "$PROJ2" || exit 1

it "old history paths in the current checkout or integration tips still block numbering"
mkdir -p specs
for legacy in specs/log.md specs/log specs/archive.md; do
    if [ "$legacy" = specs/log ]; then mkdir "$legacy"; else : > "$legacy"; fi
    run bash "$SCRIPT2" --json --no-branch --short-name reused "desc"
    assert_eq 1 "$STATUS" "$legacy blocks allocation"
    assert_contains "$OUTPUT" 'git mv specs/log.md .prdkit/history/log.md'
    assert_contains "$OUTPUT" 'git mv specs/log .prdkit/history/log'
    assert_contains "$OUTPUT" 'git mv specs/archive.md .prdkit/history/archive.md'
    assert_not_contains "$OUTPUT" 'CHANGE_ID'
    if [ "$legacy" = specs/log ]; then rmdir "$legacy"; else rm "$legacy"; fi
done
printf -- '- 2026-10-17 001-done: closed\n' > specs/log.md
run bash "$SCRIPT2" --no-worktree --short-name current-old "desc"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "Old history paths remain ($PROJ2)"
rm specs/log.md
git checkout -qb history-old-tip
printf '%s\n' '**Allocated through**: 090' > specs/archive.md
git add specs/archive.md && git commit -qm 'old archive' || exit 1
git sparse-checkout set --no-cone '/*' '!/specs/archive.md' || exit 1
assert_eq 'S specs/archive.md' "$(git ls-files -t -- specs/archive.md)"
run bash "$SCRIPT2" --no-branch --number 89 --short-name hidden "desc"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'git mv specs/archive.md .prdkit/history/archive.md'
git sparse-checkout disable || exit 1
git update-ref refs/remotes/origin/main HEAD
git checkout -q "$MAIN_BRANCH"
run bash "$SCRIPT2" --no-branch --number 89 --short-name integration "desc"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'update stale branches and refs after moving'
assert_contains "$OUTPUT" 'git mv specs/archive.md .prdkit/history/archive.md'
git update-ref -d refs/remotes/origin/main
git branch -q -D history-old-tip

it "a close in an unrelated old-layout HEAD stays reserved after a staged deletion"
sibling="$PROJ2/.worktrees/maintenance"
git worktree add -qb maintenance "$sibling" HEAD || exit 1
mkdir -p "$sibling/specs"
printf -- '- 2026-10-17 001-done: closed\n' > "$sibling/specs/log.md"
git -C "$sibling" add specs/log.md && git -C "$sibling" commit -qm 'old close' &&
    git -C "$sibling" rm -q specs/log.md || exit 1
assert_eq 'D  specs/log.md' "$(git -C "$sibling" status --porcelain)"
run bash "$SCRIPT2" --json --no-branch --short-name staged-delete "desc"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '"CHANGE_ID":"002-staged-delete"'
assert_contains "$OUTPUT" "git worktree remove"
assert_contains "$OUTPUT" 'cleanup-change.sh --closed'
if [ "$STATUS" -eq 0 ]; then rm specs/changes/002-staged-delete.md; fi
run bash -c 'cd "$1" && bash .prdkit/scripts/bash/doctor.sh --json' _ "$sibling"
assert_eq 1 "$STATUS"
assert_eq 1 "$(jq '.findings | length' <<< "$OUTPUT")"
assert_contains "$OUTPUT" 'git mv specs/log.md .prdkit/history/log.md'
assert_eq 'D  specs/log.md' "$(git -C "$sibling" status --porcelain)"
git -C "$sibling" restore --source=HEAD --staged --worktree -- specs/log.md &&
    git worktree remove "$sibling" && git branch -qD maintenance || exit 1

it "read-only old-layout sources reserve folded and per-file closes, archive bounds, records and plans"
legacy_repo="$(make_inited_project)"; track_tmp "$legacy_repo"
legacy_parent="$(mktemp -d)" || exit 1
track_tmp "$legacy_parent"
(
    cd "$legacy_repo" || exit 1
    git add -A && git commit -qm installed &&
        git worktree add -qb maintenance "$legacy_parent/outside worktree" HEAD || exit 1
) || exit 1
legacy_repo="$(cd "$legacy_repo" && pwd -P)"
legacy_parent="$(cd "$legacy_parent" && pwd -P)"
outside="$legacy_parent/outside worktree"
diag="$legacy_parent/diagnostic"
capture_diagnostics() { "$@" 2>"$diag"; }
cd "$legacy_repo" || exit 1
legacy_next() { # expected number with optional extra description; leave no new claim
    local id="$1-probe"
    run capture_diagnostics bash .prdkit/scripts/bash/new-change.sh --json --no-branch --short-name probe "desc"
    assert_eq 0 "$STATUS" "${2:-legacy numbering source is readable}"
    assert_contains "$OUTPUT" "\"CHANGE_ID\":\"$id\""
    if [ "$STATUS" -eq 0 ]; then rm -f specs/changes/*-probe.md; fi
}
mkdir -p "$outside/specs/log" "$outside/specs/changes"
printf -- '- 2026-10-17 010-folded: closed\n' > "$outside/specs/log.md"
legacy_next 011 'a folded old log raises the allocation floor'
printf -- '- 2026-10-17 020-entry: closed\n' > "$outside/specs/log/020-entry.md"
legacy_next 021 'a per-change old log file raises the allocation floor'
cat > "$outside/specs/archive.md" <<'MD'
**Log condensed through**: 009; also 030-039; those entries: `git show abc1234:specs/log.md`.
**Allocated through**: 040
MD
legacy_next 041 'an old condensed index and its independent floor count'
printf '# Change: Open\n' > "$outside/specs/changes/050-open.md"
legacy_next 051 'an old checkout record raises the allocation floor'
printf '# Product spec\n\n- A future change (planned: 060-planned)\n' > "$outside/specs/product.md"
(
    cd "$outside" || exit 1
    git add specs && git commit -qm 'old claims' &&
        git sparse-checkout set --no-cone '/*' '!/specs/archive.md' '!/specs/changes/050-open.md' '!/specs/product.md'
) || exit 1
assert_eq 'S specs/archive.md' "$(git -C "$outside" ls-files -t -- specs/archive.md)"
assert_eq 'S specs/product.md' "$(git -C "$outside" ls-files -t -- specs/product.md)"
old_status="$(git -C "$outside" status --porcelain=v1)"
old_index="$(git -C "$outside" ls-files --stage -t)"
# .worktrees/* can also hold an unregistered checkout. A numbered branch must not
# stand in for its record or for the outside worktree's plan.
mkdir -p .worktrees/unregistered/specs/changes
printf -- '- 2026-10-17 055-standalone: closed\n' > .worktrees/unregistered/specs/log.md
for number in 009 039 055; do
    run capture_diagnostics bash .prdkit/scripts/bash/new-change.sh --no-worktree --number "$number" --short-name claimed "desc"
    assert_eq 1 "$STATUS" "$number is already allocated"
    assert_contains "$(cat "$diag")" "change number $number is "
done
ln -s "$outside" .worktrees/alias
run capture_diagnostics bash .prdkit/scripts/bash/new-change.sh --json --short-name legacy-next "desc"
assert_eq 0 "$STATUS" 'default allocation proceeds past the old plan'
assert_contains "$OUTPUT" '"CHANGE_ID":"061-legacy-next"'
assert_file "$legacy_repo/.worktrees/061-legacy-next/specs/changes/061-legacy-next.md"
assert_contains "$(cat "$diag")" "git worktree remove '$outside'"
assert_contains "$(cat "$diag")" 'cleanup-change.sh --closed'
assert_eq 1 "$(grep -Fc "$outside" "$diag")" 'one warning for the outside worktree'
assert_eq 1 "$(grep -c 'Warning:.*unregistered' "$diag")" 'one warning for the unregistered checkout'
run capture_diagnostics bash .prdkit/scripts/bash/new-change.sh --json --no-worktree --short-name in-place-legacy "desc"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '"CHANGE_ID":"062-in-place-legacy"'
assert_eq 1 "$(grep -Fc '.worktrees/unregistered' "$diag")"
assert_eq "$old_status" "$(git -C "$outside" status --porcelain=v1)"
assert_eq "$old_index" "$(git -C "$outside" ls-files --stage -t)"

it "an unreadable or ambiguous old index fails closed with cleanup remedies"
bad_sibling="$legacy_repo/.worktrees/broken"
mkdir -p "$bad_sibling/specs"
for problem in missing-target duplicate; do
    if [ "$problem" = missing-target ]; then
        ln -s nowhere "$bad_sibling/specs/archive.md"
    else
        printf '**Allocated through**: 100\n**Allocated through**: 200\n' > "$bad_sibling/specs/archive.md"
    fi
    run capture_diagnostics bash .prdkit/scripts/bash/new-change.sh --json --no-worktree --short-name refused "desc"
    assert_eq 1 "$STATUS"
    assert_eq '' "$OUTPUT" 'no result on stdout'
    assert_contains "$(cat "$diag")" "$bad_sibling"
    assert_contains "$(cat "$diag")" 'git worktree remove'
    assert_contains "$(cat "$diag")" 'cleanup-change.sh --closed'
    rm "$bad_sibling/specs/archive.md"
done
assert_eq '' "$(git branch --list '*-refused')"
cd "$PROJ2" || exit 1

it "only committed integration policy adds trusted un-checked-out tips to the history snapshot"
primary=refs/remotes/origin/main
secondary=refs/remotes/origin/develop
git update-ref "$primary" HEAD && git update-ref "$secondary" HEAD &&
    git symbolic-ref refs/remotes/origin/HEAD "$primary" || exit 1
printf -- '- 2026-10-17 091-done: closed\n' | trusted_edit "$secondary" specs/log.md || exit 1
# Neither an unconfigured remote ref nor a working config can affect numbering.
printf '\n## Configuration\n- review-integration-branches: origin/develop\n' >> .prdkit/memory/config.md
run bash "$SCRIPT2" --json --no-branch --short-name untrusted "desc"
assert_eq 0 "$STATUS" 'a working config does not establish trust'
assert_contains "$OUTPUT" '"CHANGE_ID":"001-untrusted"'
rm -f specs/changes/001-untrusted.md
trusted_edit "$primary" .prdkit/memory/config.md <<'MD' || exit 1
## Configuration
- review-integration-branches: origin/develop, origin/missing
MD
git restore -- .prdkit/memory/config.md
assert_not_contains "$(git worktree list --porcelain)" 'develop'
run bash "$SCRIPT2" --json --no-branch --short-name trusted-old "desc"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'git mv specs/log.md .prdkit/history/log.md'
assert_not_contains "$OUTPUT" 'CHANGE_ID'
assert_eq '' "$(find specs -type f -print)"
git update-ref "$secondary" HEAD || exit 1
printf '**Allocated through**: 089\n' | trusted_edit "$secondary" .prdkit/history/archive.md || exit 1
run bash "$SCRIPT2" --json --no-branch --number 89 --short-name trusted-floor "desc"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'allocated high-water mark 089'
printf -- '- 2026-10-17 091-done: closed\n' | trusted_edit "$secondary" .prdkit/history/log.md || exit 1
run bash "$SCRIPT2" --json --no-branch --number 91 --short-name trusted-closed "desc"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'allocated high-water mark 091'
run bash "$SCRIPT2" --json --no-branch --short-name trusted-next "desc"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '"CHANGE_ID":"092-trusted-next"'
rm -f specs/changes/092-trusted-next.md

it "a tracked config symlink does not establish trust or block allocation"
git checkout -qb linked-config || exit 1
mv .prdkit/memory/config.md .prdkit/memory/shared-config.md
printf '\n## Configuration\n- review-integration-branches: origin/develop\n' >> .prdkit/memory/shared-config.md
ln -s shared-config.md .prdkit/memory/config.md
git add .prdkit/memory && git commit -qm 'link the memory config' && git update-ref "$primary" HEAD || exit 1
printf -- '- 2026-10-17 093-done: closed\n' | trusted_edit "$secondary" specs/log.md || exit 1
run bash "$SCRIPT2" --json --no-branch --short-name config-link "desc"
assert_eq 0 "$STATUS" "the policy reader does not follow the config symlink"
assert_contains "$OUTPUT" '"CHANGE_ID":"001-config-link"'
rm -f specs/changes/001-config-link.md
git checkout -q "$MAIN_BRANCH" || exit 1
git symbolic-ref --delete refs/remotes/origin/HEAD &&
    git update-ref -d "$primary" && git update-ref -d "$secondary" && git branch -qD linked-config || exit 1

it "a bare common repo is not a checkout even when its HEAD has legacy history"
bare_fixture="$(mktemp -d)" || exit 1
track_tmp "$bare_fixture"
git clone -q --bare "$PROJ2" "$bare_fixture/common.git" &&
    git -C "$bare_fixture/common.git" worktree add -qb linked "$bare_fixture/linked" "$MAIN_BRANCH" || exit 1
(
    cd "$bare_fixture/linked" || exit 1
    git config user.name test && git config user.email t@example.com &&
        git branch archived-maintenance &&
        printf -- '- 2026-10-17 001-done: closed\n' | trusted_edit refs/heads/archived-maintenance specs/log.md
) || exit 1
git -C "$bare_fixture/common.git" symbolic-ref HEAD refs/heads/archived-maintenance || exit 1
assert_eq false "$(git -C "$bare_fixture/common.git" rev-parse --is-inside-work-tree)"
mkdir -p "$bare_fixture/common.git/specs"
: > "$bare_fixture/common.git/specs/log.md"
run bash -c 'cd "$1" && bash .prdkit/scripts/bash/new-change.sh --json --no-branch --short-name bare-linked desc' _ "$bare_fixture/linked"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '"CHANGE_ID":"001-bare-linked"'

it "a stray numbered branch raises the next number"
git -C "$PROJ2" branch 007-stray-branch
run bash "$SCRIPT2" --json --no-worktree --short-name "first" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"008-first"' "stray 007 branch forces 008"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"

it "closed changes in .prdkit/history/log.md stay reserved"
mkdir -p "$PROJ2/.prdkit/history"
printf '%s\n' '- 2026-10-01 012-old-change: did a thing — R-01 — https://example.invalid/pr/1' > "$PROJ2/.prdkit/history/log.md"
run bash "$SCRIPT2" --json --no-worktree --short-name "after-log" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"013-after-log"' "log entry 012 forces 013"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"
mkdir -p "$PROJ2/.prdkit/history/log"
printf '%s\n' '- 2026-10-02 020-entry-closed: did another — R-01 — #2' > "$PROJ2/.prdkit/history/log/020-entry-closed.md"
run bash "$SCRIPT2" --json --no-worktree --short-name "after-entry" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"021-after-entry"' "an entry file in .prdkit/history/log/ reserves 020 too"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; git -C "$PROJ2" branch -q -D 021-after-entry
rm -rf "$PROJ2/specs/changes" "$PROJ2/.prdkit/history/log"

it "invalid CRLF logs stop number allocation"
badlog="$(make_inited_project)" || exit 1
track_tmp "$badlog"
mkdir -p "$badlog/.prdkit/history"
printf -- '- 2026-10-01 001-repeat: already closed\r\n' > "$badlog/.prdkit/history/log.md"
git -C "$badlog" -c core.autocrlf=false add -A && git -C "$badlog" commit -qm installed || exit 1
run bash -c 'cd "$1" && bash .prdkit/scripts/bash/new-change.sh --json Repeat' _ "$badlog"
assert_eq 1 "$STATUS" "unsupported text stops allocation"
assert_contains "$OUTPUT" "expected LF-terminated Markdown"
[ ! -e "$badlog/.worktrees/002-repeat" ] || _no "no worktree is created"
[ ! -e "$badlog/.worktrees/001-repeat" ] || _no 'no worktree reuses the closed ID'

it "a log condensed into .prdkit/history/archive.md keeps its numbers reserved"
# shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
printf '# Demo — archive\n\n**Log condensed through**: 040; those entries: `git show abc1234:.prdkit/history/log.md`.\n' > "$PROJ2/.prdkit/history/archive.md"
run bash "$SCRIPT2" --json --no-worktree --short-name "after-condensed" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"041-after-condensed"' "condensed through 040 forces 041"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; git -C "$PROJ2" branch -qD 041-after-condensed; rm -rf "$PROJ2/specs/changes"
run bash "$SCRIPT2" --json --no-worktree --number 35 --short-name "explicit-old" "desc"
assert_eq 1 "$STATUS" "an explicit number at or below the mark is refused"
assert_contains "$OUTPUT" 'change number 035 is reserved: .prdkit/history/archive.md condenses the log through 040' "the refusal names the mark"
assert_eq absent "$([ -e "$PROJ2/specs/changes/035-explicit-old.md" ] && echo present || echo absent)" "no record is created"
run bash "$SCRIPT2" --no-branch --number 000 --short-name zero "desc"
assert_eq 1 "$STATUS" '000 is refused under a positive cutoff'
assert_contains "$OUTPUT" 'change number 000 is reserved: .prdkit/history/archive.md condenses the log through 040'
rm -f "$PROJ2/specs/changes/000-zero.md"
# shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
for value in '040 — entries at `git show 9f81234:.prdkit/history/log.md`' '040 as of 2026-10-30' \
             '**040**; those entries: `git show abc1234:.prdkit/history/log.md`.' '_040_' '`040`'; do
    printf '# Demo — archive\n\n**Log condensed through**: %s\n' "$value" > "$PROJ2/.prdkit/history/archive.md"
    run bash "$SCRIPT2" --json --no-worktree --short-name "after-mark" "desc"
    assert_contains "$OUTPUT" '"CHANGE_ID":"041-after-mark"' "a sha or date after the number is no number: $value"
    git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; git -C "$PROJ2" branch -qD 041-after-mark; rm -rf "$PROJ2/specs/changes"
done
rm -f "$PROJ2/.prdkit/history/archive.md"

it "sparse archive bounds automatic numbering and forbids filling earlier gaps"
sparse_project="$(make_inited_project)" || exit 1
track_tmp "$sparse_project"
cd "$sparse_project" || exit 1
sparse_new="$sparse_project/.prdkit/scripts/bash/new-change.sh"
mkdir -p .prdkit/history
# shellcheck disable=SC2016 # Markdown code span
printf '**Log condensed through**: none; also 030-033, 035; those entries: `git show abc1234:.prdkit/history/log.md`.\n**Allocated through**: 035\n' > .prdkit/history/archive.md
for num in 30 31 33 35; do
    run bash "$sparse_new" --no-branch --number "$num" --short-name never-reuse "desc"
    assert_eq 1 "$STATUS" "cannot reuse sparse number $num"
    assert_contains "$OUTPUT" 'reserved by the condensed log index' 'the archive refusal is explicit'
done
run bash "$sparse_new" --json --no-branch --number 34 --short-name spare-gap "desc"
assert_eq 1 "$STATUS" 'an unallocated gap below the sparse maximum cannot be filled'
assert_contains "$OUTPUT" 'high-water mark 035; omit --number or use a number above 035'
run bash "$sparse_new" --json --no-branch --short-name sparse-next "desc"
assert_eq 0 "$STATUS" "valid sparse index without a cutoff"
assert_contains "$OUTPUT" '"CHANGE_ID":"036-sparse-next"' "highest sparse member sets the next number"
archive_ref=refs/remotes/origin/main
git update-ref "$archive_ref" HEAD
archive_text="$(cat .prdkit/history/archive.md)"
trusted_edit "$archive_ref" .prdkit/history/archive.md <<< "$archive_text" || exit 1
rm .prdkit/history/archive.md
run bash "$sparse_new" --no-branch --number 31 --short-name stale "desc"
assert_eq 1 "$STATUS" "a stale branch honors fetched origin/main without a symbolic origin/HEAD"
assert_contains "$OUTPUT" 'reserved by the condensed log index'
rm -f specs/changes/031-stale.md
custom_ref=refs/remotes/origin/integration
git update-ref "$custom_ref" HEAD
git symbolic-ref refs/remotes/origin/HEAD "$custom_ref"
# shellcheck disable=SC2016 # Markdown code span
trusted_edit "$custom_ref" .prdkit/history/archive.md <<'MD' || exit 1
**Log condensed through**: 020; also 050; those entries: `git show abc1234:.prdkit/history/log.md`.
**Allocated through**: 052
MD
for num in 20 31 50; do
    run bash "$sparse_new" --no-branch --number "$num" --short-name union "desc"
    assert_eq 1 "$STATUS" "the union of integration refs reserves $num"
    rm -f "specs/changes/0$num-union.md"
done
run bash "$sparse_new" --json --no-branch --short-name union-next "desc"
assert_eq 0 "$STATUS" 'automatic allocation works with different integration tips'
assert_contains "$OUTPUT" '"CHANGE_ID":"053-union-next"' 'the persisted floor on another tip determines allocation'
git symbolic-ref --delete refs/remotes/origin/HEAD
git update-ref -d "$custom_ref"
git update-ref -d "$archive_ref"
printf '**Log condensed through**: 002; also 030-033, 032;\n' > .prdkit/history/archive.md
for num in auto explicit; do
    if [ "$num" = auto ]; then run bash "$sparse_new" --no-branch "desc"
    else run bash "$sparse_new" --number 34 --no-branch "desc"; fi
    assert_eq 1 "$STATUS" "$num numbering cannot fall back to the cutoff"
    assert_contains "$OUTPUT" '.prdkit/history/archive.md:1:' 'line-numbered error'
done
cd "$PROJ2" || exit 1

it "committed log and record claims on a fetched integration ref raise the allocation floor"
git update-ref refs/remotes/origin/main HEAD
for claim in '.prdkit/history/log.md 070' '.prdkit/history/log/080-entry.md 080' 'specs/changes/090-record.md 090'; do
    read -r path floor <<< "$claim"
    case "$path" in
        .prdkit/history/log.md) printf -- '- 2026-10-01 070-folded: already closed\r\n' ;;
        *) printf '\n' ;; # The filename reserves the number, independently of its contents.
    esac | trusted_edit refs/remotes/origin/main "$path" || exit 1
    run bash "$SCRIPT2" --no-branch --number 69 --short-name gap "desc"
    assert_eq 1 "$STATUS" "a stale checkout refuses the gap below $path"
    assert_contains "$OUTPUT" "high-water mark $floor"
    rm -f specs/changes/069-gap.md # Keep the replay independent when the refusal is broken.
done
run bash "$SCRIPT2" --json --no-branch --short-name fetched-next "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"091-fetched-next"' 'automatic numbering also sees committed claims'
rm -f specs/changes/{091,014}-fetched-next.md
git update-ref -d refs/remotes/origin/main

it "successive compactions cannot reissue the highest allocated number, even in a shallow clone"
pass_project="$(make_inited_project)" || exit 1
track_tmp "$pass_project"
cd "$pass_project" || exit 1
pass_new=.prdkit/scripts/bash/new-change.sh
mkdir -p .prdkit/history
printf -- '- 2026-10-01 005-first: original close\n' > .prdkit/history/log.md
git add -A && git commit -qm 'first folded snapshot' || exit 1
snapshot="$(git rev-parse HEAD)"
# shellcheck disable=SC2016 # Markdown code span
printf '**Log condensed through**: 002; also 005; those entries: `git show %s:.prdkit/history/log.md`.\n**Allocated through**: 005\n' "$snapshot" > .prdkit/history/archive.md
printf -- '- 2026-10-02 compaction: first pass\n' > .prdkit/history/log.md
git add .prdkit/history && git commit -qm 'index first sparse close' || exit 1
first_pass="$(git rev-parse HEAD)"
run bash "$pass_new" --no-branch --number 005 --short-name reused "desc"
assert_contains "$OUTPUT" 'reserved by the condensed log index'
printf -- '- 2026-10-03 004-second: older change closes later\n' > .prdkit/history/log.md
git add .prdkit/history/log.md && git commit -qm 'second folded snapshot' || exit 1
snapshot="$(git rev-parse HEAD)"
# A bad pass forgets to carry 005 forward in the index, but keeps the allocation floor.
# shellcheck disable=SC2016 # Markdown code span
printf '**Log condensed through**: 002; also 004; those entries: `git show %s:.prdkit/history/log.md`.\n**Allocated through**: 005\n' "$snapshot" > .prdkit/history/archive.md
printf -- '- 2026-10-04 compaction: second pass\n' > .prdkit/history/log.md
git add .prdkit/history && git commit -qm 'second pass omits first close' || exit 1
shallow_pass="$(mktemp -d)"; track_tmp "$shallow_pass"
git clone -q --depth 2 "file://$pass_project" "$shallow_pass" || exit 1
assert_eq true "$(git -C "$shallow_pass" rev-parse --is-shallow-repository)"
assert_eq commit "$(git -C "$shallow_pass" cat-file -t "$snapshot")" 'the latest snapshot is present'
run git -C "$shallow_pass" cat-file -e "$first_pass"
assert_eq 1 "$STATUS" 'the first index commit is not present'
git -C "$shallow_pass" sparse-checkout set --no-cone '/*' '!/.prdkit/history/archive.md' || exit 1
assert_eq 'S .prdkit/history/archive.md' "$(git -C "$shallow_pass" ls-files -t -- .prdkit/history/archive.md)" \
    'the new archive path is in the index but not materialized'
for checkout in "$pass_project" "$shallow_pass"; do
    cd "$checkout" || exit 1
    run bash "$pass_new" --no-branch --number 005 --short-name reused "desc"
    assert_eq 1 "$STATUS" 'the omitted sparse member is below the current floor'
    assert_contains "$OUTPUT" 'high-water mark 005'
    assert_eq absent "$([ -e specs/changes/005-reused.md ] && echo present || echo absent)"
    rm -f specs/changes/005-reused.md # Test the automatic path independently.
    run bash "$pass_new" --json --no-branch --short-name after-pass "desc"
    assert_contains "$OUTPUT" '"CHANGE_ID":"006-after-pass"' 'automatic allocation uses the persisted floor plus one'
done
cd "$PROJ2" || exit 1

it "changes the spec's planned: markers name stay reserved; comments and code blocks do not count"
mkdir -p "$PROJ2/specs/product" "$PROJ2/specs/parts"
cat > "$PROJ2/specs/product/requirements.md" <<'EOF'
# Demo — requirements

<!-- Example: - **R-04 Title** (validated, planned: 090-example): ... -->

- **R-10 Insight** (validated, planned: 015-insight): the owner sees it.
- **R-11 Infer** (validated, planned: 014-infer): earlier records fill the form.
EOF
cat > "$PROJ2/specs/product/qualities.md" <<'EOF'
# Demo — qualities

- **Q-04 Bad connection** (validated, planned: 016): records survive a dropped signal.

```text
planned: 080-in-a-code-block
```
EOF
# shellcheck disable=SC2016 # backticks are a Markdown code span, not command substitution
printf '# P1 App\n\nThe retry waits for it (planned: `014-infer`).\n' > "$PROJ2/specs/parts/p1-app.md"
run bash "$SCRIPT2" --json --no-worktree --short-name "after-planned" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"017-after-planned"' "planned 014-016 force 017, past the log's 012"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes" "$PROJ2/specs/product" "$PROJ2/specs/parts"

it "a planned: marker that wraps inside its item stays reserved; one in a comment or code block does not"
planned_next() { # requirements.md content; sets ID to the change id new-change.sh picks, then undoes it
    mkdir -p "$PROJ2/specs/product"; printf '%s\n' "$1" > "$PROJ2/specs/product/requirements.md"
    run bash "$SCRIPT2" --json --no-worktree --short-name "wrapped" "desc"
    ID="$(printf '%s' "$OUTPUT" | sed -n 's/.*"CHANGE_ID":"\([^"]*\)".*/\1/p')"
    git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; [ -z "$ID" ] || git -C "$PROJ2" branch -qD "$ID"
    rm -rf "$PROJ2/specs/changes" "$PROJ2/specs/product"
}
planned_next "$(printf -- '- **R-21 Pull** (hypothesis, planned:\n  030-accidental-pull-default): the owner sees it.')"
assert_eq "031-wrapped" "$ID" "wrapped after planned:"
planned_next "$(printf -- '- **R-21 Pull** (hypothesis, planned\n  : 031-accidental-pull-default): the owner sees it.')"
assert_eq "032-wrapped" "$ID" "wrapped between planned and the colon"
# shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
planned_next "$(printf -- '- **R-21 Pull** (hypothesis, `planned:\n  032-accidental-pull-default`): the owner sees it.')"
assert_eq "033-wrapped" "$ID" "wrapped inside the code span"
# shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
planned_next "$(printf -- '- **R-22 Sync** (hypothesis, planned: 025-sync): it syncs.\n\n<!-- Example: - **R-04 Title** (validated, planned:\n  090-example) -->\n\n```text\n- **R-05** (validated, planned:\n  091-in-a-code-block)\n```')"
assert_eq "026-wrapped" "$ID" "a wrapped marker in a comment or a fence does not count"

it "an explicit --number cannot fill allocated history but can open an unallocated planned change"
mkdir -p "$PROJ2/specs/product"
printf '%s\n' '- **R-04 Export** (validated, planned: 060-export): the owner exports.' > "$PROJ2/specs/product/requirements.md"
run bash "$SCRIPT2" --json --no-worktree --number 60 --short-name export "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"060-export"' "the planned change opens under its own number"
assert_not_contains "$OUTPUT" "Notice" "its own planned marker holds nothing against it"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"
run bash "$SCRIPT2" --json --no-worktree --number 12 --short-name other "desc"
assert_eq 1 "$STATUS" "a closed change cannot be overridden"
assert_contains "$OUTPUT" "high-water mark 012"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"
run bash "$SCRIPT2" --json --no-worktree --number 60 --short-name other "desc"
assert_contains "$OUTPUT" "Notice: change number 060 is also held by planned in the spec 060-export" "another planned slug"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"

it "retired counters in bold, inline code and table cells all block allocation"
# shellcheck disable=SC2016 # The backticks are literal Markdown.
for counter in '**Last 0.x feature**: 036' '- **`Last 0.x feature`**: 036' '| Last 0.x feature | 036 |'; do
    printf '# Archive\n\n%s\n' "$counter" > "$PROJ2/.prdkit/history/archive.md"
    branch_before="$(git -C "$PROJ2" for-each-ref refs/heads)"
    run bash "$SCRIPT2" --json --no-worktree --short-name reserved "desc"
    assert_eq 1 "$STATUS" "unsupported archive counter is refused: $counter"
    assert_contains "$OUTPUT" ".prdkit/history/archive.md:3"
    assert_contains "$OUTPUT" "Log condensed through"
    assert_eq "$branch_before" "$(git -C "$PROJ2" for-each-ref refs/heads)" 'no branch allocated'
    run test ! -d "$PROJ2/specs/changes"
    assert_eq 0 "$STATUS" 'no record allocated'
done
rm -rf "$PROJ2/specs/changes" "$PROJ2/specs/product" "$PROJ2/.prdkit/history/archive.md"
git -C "$PROJ2" branch -qD 060-export 060-other

it "unsupported feature folders block numbering before a record is written"
mkdir -p "$PROJ2/specs/features/020-previous"
printf '# Unsupported folder\n' > "$PROJ2/specs/features/020-previous/spec.md"
run bash "$SCRIPT2" --json --no-worktree --short-name current "desc"
assert_eq 1 "$STATUS" 'unsupported layout refused'
assert_contains "$OUTPUT" 'specs/changes/<id>.md records'
assert_eq "$MAIN_BRANCH" "$(git -C "$PROJ2" branch --show-current)" 'no branch was created'
rm -rf "$PROJ2/specs/features"

it "a sibling worktree's open change raises the next number"
SIB_PARENT="$(mktemp -d)"; track_tmp "$SIB_PARENT"
git -C "$PROJ2" worktree add "$SIB_PARENT/sibling" -b sibling-helper >/dev/null 2>&1
mkdir -p "$SIB_PARENT/sibling/specs/changes"; : > "$SIB_PARENT/sibling/specs/changes/040-elsewhere.md"
run bash "$SCRIPT2" --json --no-worktree --short-name "after-sibling" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"041-after-sibling"' "sibling record 040 forces 041"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"

it "a remote-tracking numbered branch raises the next number"
git -C "$PROJ2" update-ref refs/remotes/origin/055-remote HEAD
run bash "$SCRIPT2" --json --no-worktree --short-name "after-remote" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"056-after-remote"' "remote branch 055 forces 056"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"

it "an explicit --number collision still hard-errors (no silent bump)"
git -C "$PROJ2" branch 070-dup-explicit
run bash "$SCRIPT2" --json --number 70 --short-name "dup-explicit" "desc"
assert_eq 1 "$STATUS" "exits non-zero when explicit number collides"
assert_contains "$OUTPUT" "already exists" "error mentions branch exists"
assert_not_contains "$OUTPUT" "using 071" "no auto-bump for explicit --number"

it "auto-numbering bumps past a number grabbed by a concurrent run"
# The bump loop fires only when a source claims the computed number after the max scan: a git
# shim reports 001-raced from the second `for-each-ref refs/heads` call on.
PROJ3="$(make_inited_project)"; track_tmp "$PROJ3"
PROJ3="$(cd "$PROJ3" && pwd -P)"
STUB_DIR="$(mktemp -d)"; track_tmp "$STUB_DIR"
REAL_GIT="$(command -v git)"
cat > "$STUB_DIR/git" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "for-each-ref" ]; then
    case "\$*" in
        *refs/heads*)
            n=0
            [ -f "$STUB_DIR/calls" ] && n=\$(cat "$STUB_DIR/calls")
            echo \$((n + 1)) > "$STUB_DIR/calls"
            "$REAL_GIT" "\$@"
            [ "\$n" -ge 1 ] && echo "local branch 001-raced"
            exit 0
            ;;
    esac
fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$STUB_DIR/git"
cd "$PROJ3" || exit 1
run env PATH="$STUB_DIR:$PATH" bash "$PROJ3/.prdkit/scripts/bash/new-change.sh" --json --no-worktree --short-name "raced" "desc"
assert_eq 0 "$STATUS" "script exits 0 despite the collision"
assert_contains "$OUTPUT" "change number 001 taken by local branch 001-raced, using 002" "notice names the source and the new number"
assert_contains "$OUTPUT" '"CHANGE_ID":"002-raced"' "change lands on the bumped number"

it "a submodule install keeps its slash commands in a new change worktree"
# The documented install: the kit as a real submodule, the default installer, a committed install,
# then a change in its own worktree, where git leaves the submodule uninitialized.
KITSRC="$(mktemp -d)"; track_tmp "$KITSRC"
cp -r "$PK_ROOT/commands" "$PK_ROOT/workflows" "$PK_ROOT/scripts" "$PK_ROOT/templates" "$PK_ROOT/VERSION" "$KITSRC/"
git -C "$KITSRC" init -q
git -C "$KITSRC" add -A
git -C "$KITSRC" -c user.email=t@example.com -c user.name=test commit -qm kit
sub_step() { # Stop at the original fixture failure instead of reporting missing installed files.
    run "$@"
    if [ "$STATUS" -ne 0 ]; then
        _no "submodule fixture setup failed (exit $STATUS): $*" "$OUTPUT"
        finish
    fi
}
sub_project() { # [init.sh options] -> SUB: a project with a committed submodule install
    SUB="$(mktemp -d)" || exit 1
    track_tmp "$SUB"; SUB="$(cd "$SUB" && pwd -P)" || exit 1
    sub_step git -C "$SUB" init -q
    sub_step git -C "$SUB" config user.email t@example.com
    sub_step git -C "$SUB" config user.name test
    sub_step git -C "$SUB" commit -q --allow-empty -m init
    # Use Git's transport, not the local-clone loose-object copy optimization.
    # Hosted Linux has intermittently failed inside that copy before init.sh runs.
    sub_step git -C "$SUB" -c protocol.file.allow=always submodule add -q "file://$KITSRC" .product-kit
    # shellcheck disable=SC2016 # Positional arguments are expanded by the child shell.
    sub_step bash -c 'cd "$1" && shift && bash .product-kit/scripts/init.sh "$@"' _ "$SUB" "$@"
    sub_step git -C "$SUB" add -A
    sub_step git -C "$SUB" commit -qm installed
}
sub_project
run bash -c 'cd "$1" && bash .prdkit/scripts/bash/new-change.sh --short-name sub-default "Use the kit"' _ "$SUB"
assert_eq 0 "$STATUS" "change opened: $OUTPUT"
SWT="$SUB/.worktrees/001-sub-default"
if [ -f "$SWT/.claude/commands/prdkit.md" ] && [ ! -L "$SWT/.claude/commands/prdkit.md" ]; then
    _ok "the worktree has command copies"
else
    _no "the worktree has command copies"
fi
assert_not_contains "$OUTPUT" "do not resolve" "no dangling-link warning"
run bash -c 'cd "$1" && bash .prdkit/scripts/bash/doctor.sh' _ "$SWT"
assert_eq 0 "$STATUS" "doctor passes inside the change worktree: $OUTPUT"

it "symlinked commands are opt-in, and a worktree that cannot resolve them says how to fix it"
sub_project --symlink
assert_symlink "$SUB/.claude/commands/prdkit.md" "--symlink installs links"
run bash -c 'cd "$1" && bash .prdkit/scripts/bash/new-change.sh --short-name sub-links "Use the kit"' _ "$SUB"
assert_eq 0 "$STATUS" "the change still opens"
SWT="$SUB/.worktrees/001-sub-links"
assert_contains "$OUTPUT" "slash-command link(s) in the new worktree do not resolve" "dangling links reported"
assert_contains "$OUTPUT" "git -C $SWT submodule update --init .product-kit" "submodule fix named"
assert_contains "$OUTPUT" "--upgrade --copy" "copy fix named"
git -C "$SWT" -c protocol.file.allow=always submodule update --init -q .product-kit >/dev/null 2>&1
run bash -c 'cd "$1" && bash .prdkit/scripts/bash/doctor.sh' _ "$SWT"
assert_eq 0 "$STATUS" "the named fix makes doctor pass"
# --- Concurrent runs serialize on the change-number lock in the Git common directory -----------
it "concurrent runs with different short names get distinct numbers, even where mkdir is not exclusive"
PROJ6="$(make_inited_project)"; track_tmp "$PROJ6"
PROJ6="$(cd "$PROJ6" && pwd -P)"
git -C "$PROJ6" add -A >/dev/null 2>&1; git -C "$PROJ6" commit -qm installed >/dev/null 2>&1
# uutils mkdir (Ubuntu 26.04's default) can report success to two runs creating one directory;
# this shim always does, so the lock must not depend on mkdir.
MKDIR_SHIM="$(mktemp -d)"; track_tmp "$MKDIR_SHIM"
printf '#!/bin/sh\nexec "%s" -p "$@"\n' "$(command -v mkdir)" > "$MKDIR_SHIM/mkdir"
chmod +x "$MKDIR_SHIM/mkdir"
cd "$PROJ6" || exit 1
PIDS=()
for i in 0 1 2 3 4 5; do
    PATH="$MKDIR_SHIM:$PATH" bash "$PROJ6/.prdkit/scripts/bash/new-change.sh" --json \
        --short-name "parallel-$i" "parallel $i" > "$PROJ6/.git/par-$i.out" 2>&1 &
    PIDS+=("$!")
done
FAILED=0
for pid in "${PIDS[@]}"; do wait "$pid" || FAILED=$((FAILED + 1)); done
assert_eq 0 "$FAILED" "all six runs succeed"
NUMS="$(cat "$PROJ6"/.git/par-*.out | sed -n 's/.*"CHANGE_ID":"\([0-9]*\)-.*/\1/p' | sort | tr '\n' ' ')"
assert_eq "001 002 003 004 005 006 " "$NUMS" "six distinct numbers, 001 to 006"
assert_eq 6 "$(git -C "$PROJ6" for-each-ref refs/heads | grep -c 'parallel-')" "six change branches"
if [ ! -e "$PROJ6/.git/prdkit-change-number.lock" ]; then _ok "the lock is released"; else _no "the lock is released"; fi

it "a lock left by an ended run is reclaimed; a live holder makes the run wait, then stop"
sleep 0 & DEAD_PID=$!; wait "$DEAD_PID"
printf '%s %s\n' "$DEAD_PID" "$(uname -n)" > "$PROJ6/.git/prdkit-change-number.lock"
run bash "$PROJ6/.prdkit/scripts/bash/new-change.sh" --json --short-name "after-crash" "after a crash"
assert_eq 0 "$STATUS" "a stale lock does not block the run"
assert_contains "$OUTPUT" "removed a stale change-number lock" "the reclaim is reported"
assert_contains "$OUTPUT" '"CHANGE_ID":"007-after-crash"' "numbering continues"
printf '%s %s\n' "$$" "$(uname -n)" > "$PROJ6/.git/prdkit-change-number.lock"
run env PRDKIT_NUMBER_LOCK_WAIT=1 bash "$PROJ6/.prdkit/scripts/bash/new-change.sh" --json --short-name "blocked" "blocked"
assert_eq 1 "$STATUS" "a live holder past the wait stops the run"
assert_contains "$OUTPUT" "$PROJ6/.git/prdkit-change-number.lock" "the error names the lock"
assert_file "$PROJ6/.git/prdkit-change-number.lock" "a live holder's lock is never removed"
assert_contains "$OUTPUT" "holder: $$ $(uname -n)" "the error names the holder"
if ! git -C "$PROJ6" show-ref --verify --quiet refs/heads/008-blocked; then _ok "no branch was created"; else _no "no branch was created"; fi
rm -f "$PROJ6/.git/prdkit-change-number.lock"

finish
