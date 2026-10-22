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
mkdir -p specs; printf '2026-10-17 owner "make export async" → open\n' > specs/inbox.md
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
assert_contains "$OUTPUT" "Notice: change number 020 is also held by specs/archive.md, 0.x features through 036-" "a number the archive's 0.x features cover"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes" "$PROJ2/specs/product" "$PROJ2/specs/archive.md"
git -C "$PROJ2" branch -qD 060-export 012-other 060-other 020-other

it "0.x feature folders still on disk (before the cutover), live or archived, stay reserved"
mkdir -p "$PROJ2/specs/features/_archive/020-old-feature"
run bash "$SCRIPT2" --json --no-worktree --short-name "after-features" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"021-after-features"' "archived feature 020 forces 021"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"
mkdir -p "$PROJ2/specs/archive/features/_archive/030-cut-over"
run bash "$SCRIPT2" --json --no-worktree --short-name "after-cutover" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"031-after-cutover"' "archived canon 030 forces 031"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"

it "an archive.md that yields no 0.x feature number stops auto-numbering instead of reusing one"
rm -rf "$PROJ2/specs/features" "$PROJ2/specs/archive"
cp "$PROJ2/.prdkit/templates/archive-template.md" "$PROJ2/specs/archive.md"
run bash "$SCRIPT2" --json --no-worktree --short-name "from-template" "desc"
assert_eq 1 "$STATUS" "the unfilled template fails closed"
assert_contains "$OUTPUT" "names no **Base** commit in this repository and no readable **Last 0.x feature** line" "the cause is named"
assert_contains "$OUTPUT" "or pass --number" "the way out is named"
assert_eq "$MAIN_BRANCH" "$(git -C "$PROJ2" branch --show-current)" "no branch was created"
run bash "$SCRIPT2" --json --no-worktree --number 32 --short-name "from-template" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"032-from-template"' "an explicit --number still works"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes"
# shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
printf '# Demo — archive\n\n**Base**: `abc1234`, main before the cutover.\n**Last 0.x feature**: 036; new changes number above it.\n' > "$PROJ2/specs/archive.md"
run bash "$SCRIPT2" --json --no-worktree --short-name "after-archive" "desc"
assert_contains "$OUTPUT" '"CHANGE_ID":"037-after-archive"' "the last 0.x feature 036 forces 037"
git -C "$PROJ2" checkout -q "$MAIN_BRANCH"; rm -rf "$PROJ2/specs/changes" "$PROJ2/specs/archive.md"

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

# --- After the cutover the folders are gone from main: git keeps their numbers --------------------
PROJ4="$(make_inited_project)"; track_tmp "$PROJ4"
PROJ4="$(cd "$PROJ4" && pwd -P)"
cd "$PROJ4" || exit 1
mkdir -p specs/features/012-mid specs/features/036-last
echo '# x' > specs/features/012-mid/spec.md; echo '# y' > specs/features/036-last/spec.md
git add -A >/dev/null 2>&1; git commit -qm "0.x" >/dev/null
BASE4="$(git rev-parse HEAD)"
git rm -rq specs/features; git commit -qm cutover >/dev/null
MAIN4="$(git branch --show-current)"
next4() { # dir archive.md-content ('' = no file): the change id new-change.sh picks there
    mkdir -p "$1/specs"; rm -f "$1/specs/archive.md"; [ -z "$2" ] || printf '%s\n' "$2" > "$1/specs/archive.md"
    run bash -c 'cd "$1" && bash .prdkit/scripts/bash/new-change.sh --json --no-worktree --short-name probe probe' _ "$1"
    ID4="$(printf '%s' "$OUTPUT" | sed -n 's/.*"CHANGE_ID":"\([^"]*\)".*/\1/p')"
    git -C "$1" checkout -q "$MAIN4"; [ -z "$ID4" ] || git -C "$1" branch -qD "$ID4"; rm -rf "$1/specs/changes"
}
# shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
VARIANTS=("" '**Last 0.x feature**: 036; new changes number above it.' '- **Last 0.x feature**: 036'
    '**Last 0.x feature:** 036' '**Last 0.x feature** — 036' '**Last 0.x features**: 001–036'
    '**Last 0.x feature number**: 036' '## Last 0.x feature: 036' "$(printf '**Last 0.x feature**:\n036')"
    '**Last 0.X feature**: 036' '**Last 0.x feature**: `036-last`' '**Last 0.x feature**: 001-036 (036-last)'
    '**Last 0.x feature**: none before 2026-10-20' '| Last 0.x feature | 036 |')

it "removed 0.x feature numbers stay reserved from git history, whatever archive.md says"
for variant in "${VARIANTS[@]}"; do
    next4 "$PROJ4" "$variant"; assert_eq "037-probe" "$ID4" "archive.md: ${variant:-missing}"
done

it "the base commit archive.md records reserves the feature folders it held"
git checkout -q -b side "$BASE4"; mkdir -p specs/features/050-side; echo '# z' > specs/features/050-side/spec.md
git add -A >/dev/null 2>&1; git commit -qm side >/dev/null; SIDE4="$(git rev-parse HEAD)"; git checkout -q "$MAIN4"
next4 "$PROJ4" "$(printf '# Demo — archive\n\n**Base**: %s, main before the cutover.' "$SIDE4")"
assert_eq "051-probe" "$ID4" "050 at the base forces 051, though history on main never removed it"

it "in a shallow clone, without that history, archive.md reserves the numbers or numbering stops"
echo x > later.txt; git add later.txt; git commit -qm later >/dev/null
SHALLOW="$(mktemp -d)"; track_tmp "$SHALLOW"; rmdir "$SHALLOW"
git clone -q --depth 1 "file://$PROJ4" "$SHALLOW" 2>/dev/null; SHALLOW="$(cd "$SHALLOW" && pwd -P)"
for variant in "${VARIANTS[@]:1:11}" "${VARIANTS[13]}"; do
    next4 "$SHALLOW" "$variant"; assert_eq "037-probe" "$ID4" "shallow, archive.md: $variant"
done
next4 "$SHALLOW" '**Last 0.x feature**: none'
assert_eq "001-probe" "$ID4" "none says there were no 0.x features"
next4 "$SHALLOW" ""
assert_eq "001-probe" "$ID4" "no archive.md: numbering goes on"
assert_contains "$OUTPUT" "Warning: shallow clone" "with a warning that removed folders are not in its history"
next4 "$SHALLOW" "$(printf '# Demo — archive\n\n**Base**: %s.' "$BASE4")"
assert_eq "" "$ID4" "a base the clone lacks and no Last line: numbering stops"
assert_contains "$OUTPUT" "an old feature number could be reused" "and says why"


it "a submodule install keeps its slash commands in a new change worktree"
# The documented install: the kit as a real submodule, the default installer, a committed install,
# then a change in its own worktree, where git leaves the submodule uninitialized.
KITSRC="$(mktemp -d)"; track_tmp "$KITSRC"
cp -r "$PK_ROOT/commands" "$PK_ROOT/workflows" "$PK_ROOT/scripts" "$PK_ROOT/templates" "$PK_ROOT/VERSION" "$KITSRC/"
git -C "$KITSRC" init -q
git -C "$KITSRC" add -A
git -C "$KITSRC" -c user.email=t@example.com -c user.name=test commit -qm kit
sub_project() { # [init.sh options] -> SUB: a project with a committed submodule install
    SUB="$(mktemp -d)"; track_tmp "$SUB"; SUB="$(cd "$SUB" && pwd -P)"
    git -C "$SUB" init -q
    git -C "$SUB" config user.email t@example.com
    git -C "$SUB" config user.name test
    git -C "$SUB" commit -q --allow-empty -m init
    git -C "$SUB" -c protocol.file.allow=always submodule add -q "$KITSRC" .product-kit >/dev/null 2>&1
    ( cd "$SUB" && bash .product-kit/scripts/init.sh "$@" ) >/dev/null 2>&1
    git -C "$SUB" add -A >/dev/null 2>&1
    git -C "$SUB" commit -qm installed >/dev/null 2>&1
}
sub_project
run bash -c 'cd "$1" && bash .prdkit/scripts/bash/new-change.sh --short-name sub-default "Use the kit"' _ "$SUB"
assert_eq 0 "$STATUS" "change opened"
SWT="$SUB/.worktrees/001-sub-default"
if [ -f "$SWT/.claude/commands/prdkit.md" ] && [ ! -L "$SWT/.claude/commands/prdkit.md" ]; then
    _ok "the worktree has command copies"
else
    _no "the worktree has command copies"
fi
assert_not_contains "$OUTPUT" "do not resolve" "no dangling-link warning"
run bash -c 'cd "$1" && bash .prdkit/scripts/bash/doctor.sh' _ "$SWT"
assert_eq 0 "$STATUS" "doctor passes inside the change worktree"

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

finish
