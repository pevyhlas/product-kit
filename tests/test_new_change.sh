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

it "a retired checkpoint scaffold fails with the current template format"
printf '%s\n' '## State' '<!-- A programme or continuing follow-up queue (workflows/planning.md):' '### Outcome checkpoint' '-->' > "$TEMPLATE"
run bash .prdkit/scripts/bash/new-change.sh --no-branch --number 2 --short-name obsolete "Check an unsupported template"
assert_eq 1 "$STATUS" 'unsupported stock scaffold rejected'
assert_contains "$OUTPUT" 'current outcome checkpoint pointer'
printf '%s\n' '## State' '### Outcome checkpoint' '**Outcome**: The result' > "$TEMPLATE"

it "--programme keeps a checkpoint already present in a custom change template"
run bash .prdkit/scripts/bash/new-change.sh --programme --no-branch --number 4 --short-name existing "Keep the existing scaffold"
assert_eq 0 "$STATUS" "the custom template already has a checkpoint"
run cmp -s "$TEMPLATE" specs/changes/004-existing.md
assert_eq 0 "$STATUS" "no second scaffold or changes to the custom checkpoint"

it "--programme ignores example headings and inserts before the next real section"
N=6
for heading in '### Outcome checkpoint' '## Example output' '### Outcome checkpoint'; do
    case "$N" in
        6|7) START='```markdown'; END='```' ;;
        8) START='<!-- Example output'; END='-->' ;;
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
    run cmp -s .git/expected "specs/changes/00$N-example.md"
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
    --number 9 --short-name tagged "Tagged programme"
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
run cmp -s .git/expected specs/changes/009-tagged.md
assert_eq 0 "$STATUS" "exact scaffold, fence, spacing and final LF are preserved"
sed 's/release-notes/release\/notes/' "$TEMPLATE" > .git/invalid-tag-template
cp .git/invalid-tag-template "$TEMPLATE"
run bash .prdkit/scripts/bash/new-change.sh --programme --no-worktree --number 10 --short-name bad-tags "Invalid programme"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'Malformed Tags'
assert_eq absent "$([ -e specs/changes/010-bad-tags.md ] && echo present || echo absent)"
assert_not_contains "$(git branch --list)" '010-bad-tags'

# --- Numbering across every claimed identity -----------------------------------------------
PROJ2="$(make_inited_project)"; track_tmp "$PROJ2"
PROJ2="$(cd "$PROJ2" && pwd -P)"
git -C "$PROJ2" add -A >/dev/null 2>&1; git -C "$PROJ2" commit -qm installed >/dev/null 2>&1
SCRIPT2="$PROJ2/.prdkit/scripts/bash/new-change.sh"
cd "$PROJ2" || exit 1

it "a stray numbered branch raises the next number"
git -C "$PROJ2" branch 007-stray-branch
run bash "$SCRIPT2" --json --no-worktree --short-name "first" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"008-first"' "stray 007 branch forces 008"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"

it "closed changes in specs/log.md stay reserved"
mkdir -p "$PROJ2/specs"
printf '%s\n' '- 2026-10-01 012-old-change: did a thing — R-01 — https://example.invalid/pr/1' > "$PROJ2/specs/log.md"
run bash "$SCRIPT2" --json --no-worktree --short-name "after-log" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"013-after-log"' "log entry 012 forces 013"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"
mkdir -p "$PROJ2/specs/log"
printf '%s\n' '- 2026-10-02 020-entry-closed: did another — R-01 — #2' > "$PROJ2/specs/log/020-entry-closed.md"
run bash "$SCRIPT2" --json --no-worktree --short-name "after-entry" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"021-after-entry"' "an entry file in specs/log/ reserves 020 too"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; git -C "$PROJ2" branch -q -D 021-after-entry
rm -rf "$PROJ2/specs/changes" "$PROJ2/specs/log"

it "invalid CRLF logs stop number allocation"
badlog="$(make_inited_project)" || exit 1
track_tmp "$badlog"
mkdir -p "$badlog/specs"
printf -- '- 2026-10-01 001-repeat: already closed\r\n' > "$badlog/specs/log.md"
git -C "$badlog" -c core.autocrlf=false add -A && git -C "$badlog" commit -qm installed || exit 1
run bash -c 'cd "$1" && bash .prdkit/scripts/bash/new-change.sh --json Repeat' _ "$badlog"
assert_eq 1 "$STATUS" "unsupported text stops allocation"
assert_contains "$OUTPUT" "expected LF-terminated Markdown"
[ ! -e "$badlog/.worktrees/002-repeat" ] || _no "no worktree is created"
[ ! -e "$badlog/.worktrees/001-repeat" ] || _no 'no worktree reuses the closed ID'

it "a log condensed into specs/archive.md keeps its numbers reserved"
# shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
printf '# Demo — archive\n\n**Log condensed through**: 040; those entries: `git show abc1234:specs/log.md`.\n' > "$PROJ2/specs/archive.md"
run bash "$SCRIPT2" --json --no-worktree --short-name "after-condensed" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"041-after-condensed"' "condensed through 040 forces 041"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; git -C "$PROJ2" branch -qD 041-after-condensed; rm -rf "$PROJ2/specs/changes"
run bash "$SCRIPT2" --json --no-worktree --number 35 --short-name "explicit-old" "desc"
assert_eq 1 "$STATUS" "an explicit number at or below the mark is refused"
assert_contains "$OUTPUT" 'change number 035 is reserved: specs/archive.md condenses the log through 040' "the refusal names the mark"
assert_eq absent "$([ -e "$PROJ2/specs/changes/035-explicit-old.md" ] && echo present || echo absent)" "no record is created"
# shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
for value in '040 — entries at `git show 9f81234:specs/log.md`' '040 as of 2026-10-30'; do
    printf '# Demo — archive\n\n**Log condensed through**: %s\n' "$value" > "$PROJ2/specs/archive.md"
    run bash "$SCRIPT2" --json --no-worktree --short-name "after-mark" "desc"
    assert_contains "$OUTPUT" '"CHANGE_ID":"041-after-mark"' "a sha or date after the number is no number: $value"
    git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; git -C "$PROJ2" branch -qD 041-after-mark; rm -rf "$PROJ2/specs/changes"
done
rm -f "$PROJ2/specs/archive.md"

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

it "an explicit --number overrides a reservation with a notice naming its holder; its own planned marker is none"
mkdir -p "$PROJ2/specs/product"
printf '%s\n' '- **R-04 Export** (validated, planned: 060-export): the owner exports.' > "$PROJ2/specs/product/requirements.md"
run bash "$SCRIPT2" --json --no-worktree --number 60 --short-name export "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"060-export"' "the planned change opens under its own number"
assert_not_contains "$OUTPUT" "Notice" "its own planned marker holds nothing against it"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"
run bash "$SCRIPT2" --json --no-worktree --number 12 --short-name other "desc"
assert_eq 0 "$STATUS" "the override proceeds"
assert_contains "$OUTPUT" "Notice: change number 012 is also held by closed change 012-old-change; --number overrides it" "a closed change"
assert_contains "$OUTPUT" '"CHANGE_ID":"012-other"' "on the asked number"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"
run bash "$SCRIPT2" --json --no-worktree --number 60 --short-name other "desc"
assert_contains "$OUTPUT" "Notice: change number 060 is also held by planned in the spec 060-export" "another planned slug"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"
printf '**Last 0.x feature**: 036\n' > "$PROJ2/specs/archive.md"
run bash "$SCRIPT2" --json --no-worktree --number 20 --short-name other "desc"
assert_eq 1 "$STATUS" "unsupported archive counter is refused"
assert_contains "$OUTPUT" "Log condensed through"
rm -rf "$PROJ2/specs/changes" "$PROJ2/specs/product" "$PROJ2/specs/archive.md"
git -C "$PROJ2" branch -qD 060-export 012-other 060-other

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
