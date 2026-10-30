#!/usr/bin/env bash
# Record-only creation preserves the caller's checkout and serializes record identities.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
PROJ="$(pwd -P)"
SCRIPT="$PROJ/.prdkit/scripts/bash/new-change.sh"
printf 'baseline\n' > tracked.txt
git add -A; git commit -qm installed
git checkout -qb existing-work
printf 'staged\n' > tracked.txt; git add tracked.txt
printf 'unstaged\n' >> tracked.txt
printf 'untracked\n' > untracked.txt

snapshot() {
    git symbolic-ref HEAD
    git rev-parse HEAD
    git show-ref
    git hash-object "$(git rev-parse --git-path index)" tracked.txt untracked.txt .gitignore
    git worktree list --porcelain
}
before="$(snapshot)"
it "record-only mode preserves branch, HEAD, refs, raw index and existing file bytes"
run bash "$SCRIPT" --json --no-branch --short-name recorded 'Record on this checkout'
assert_eq 0 "$STATUS" "creation succeeds: $OUTPUT"
assert_eq "$before" "$(snapshot)" 'existing checkout state is byte-for-byte preserved'
assert_file specs/changes/001-recorded.md
json="$(printf '%s\n' "$OUTPUT" | grep '^{')"
run jq -e --arg root "$PROJ" '.CHANGE_ID == "001-recorded" and .BRANCH_NAME == "existing-work" and .WORKTREE_PATH == $root and .CHANGE_FILE == ($root + "/specs/changes/001-recorded.md") and .UNCARRIED_SPECS == []' <<< "$json"
assert_eq 0 "$STATUS" 'JSON reports actual branch and record location'
assert_eq no "$([ -d .worktrees ] && echo yes || echo no)" 'no worktree directory created'
run bash "$SCRIPT" --no-branch --number 1 --short-name recorded duplicate
assert_eq 1 "$STATUS" 'duplicate record refused'
assert_contains "$(cat specs/changes/001-recorded.md)" '# Change: Record on this checkout' 'original record preserved'

it "unknown options and contradictory modes fail before mutation; -- ends options"
for flag in --no-brnach --unknown; do
    run bash "$SCRIPT" "$flag" text
    assert_eq 2 "$STATUS" 'unknown option rejected'
done
run bash "$SCRIPT" --no-branch --no-worktree text
assert_eq 2 "$STATUS" 'contradictory modes rejected'
assert_eq "$before" "$(snapshot)" 'invalid options leave existing Git state intact'
run bash "$SCRIPT" --no-branch --short-name dash -- --literal-intent
assert_eq 0 "$STATUS" 'explicit option terminator accepts dash-leading prose'
assert_contains "$(cat specs/changes/002-dash.md)" '# Change: --literal-intent' 'literal intent retained'

it "an existing matching branch is allowed, and detached HEAD remains detached"
git branch 040-existing
git checkout -q 040-existing
before="$(snapshot)"
run bash "$SCRIPT" --json --no-branch --number 40 --short-name existing existing
assert_eq 0 "$STATUS" 'record on matching existing branch allowed'
assert_eq "$before" "$(snapshot)" 'matching branch and existing edits preserved'
git checkout -q --detach
head="$(git rev-parse HEAD)"
run bash "$SCRIPT" --json --no-branch --short-name detached detached
assert_eq 0 "$STATUS" 'detached checkout can hold a record'
assert_contains "$OUTPUT" '"BRANCH_NAME":""' 'no invented branch name'
assert_eq "$head" "$(git rev-parse HEAD)" 'detached revision preserved'
run git symbolic-ref --quiet HEAD
assert_eq 1 "$STATUS" 'still detached'
git checkout -q existing-work

it "linked checkouts keep their existing branch and see record reservations elsewhere"
WT="$(mktemp -d)"; track_tmp "$WT"; rmdir "$WT"
git worktree add -q -b other-work "$WT" HEAD
run bash -c 'cd "$1" && bash "$2" --json --no-branch --short-name linked linked' _ "$WT" "$SCRIPT"
assert_eq 0 "$STATUS" 'record-only in a linked checkout succeeds'
assert_contains "$OUTPUT" '"BRANCH_NAME":"other-work"' 'linked branch retained'
assert_file "$WT/specs/changes/042-linked.md" 'reserves numbers from other checkout records'
run bash "$SCRIPT" --no-branch --number 42 --short-name linked duplicate
assert_eq 1 "$STATUS" 'same ID in another registered checkout is protected'

it "concurrent automatic and explicit creations preserve distinct records"
for n in 1 2; do
    bash "$SCRIPT" --json --no-branch --short-name "parallel-$n" "parallel-$n" > ".git/parallel-$n.json" 2> ".git/parallel-$n.err" &
done
wait
# Scheduling is arbitrary: identities must be distinct whichever process wins.
ids="$(jq -r .CHANGE_ID .git/parallel-1.json .git/parallel-2.json | cut -d- -f1 | sort -u)"
assert_eq "$(printf '043\n044')" "$ids" 'concurrent automatic numbers are distinct'
for n in 1 2; do
    (
        rc=0
        bash "$SCRIPT" --json --no-branch --number 70 --short-name same "writer-$n" > ".git/explicit-$n.json" 2> ".git/explicit-$n.err" || rc=$?
        printf '%s\n' "$rc" > ".git/explicit-$n.status"
    ) &
done
wait
assert_eq "$(printf '0\n1')" "$(cat .git/explicit-*.status | sort)" 'exactly one explicit-ID creator wins'
assert_file specs/changes/070-same.md 'winner publishes one record'
assert_eq no "$([ -e .git/prdkit-change-number.lock ] && echo yes || echo no)" 'number lock released'

it "explicit IDs serialize across branch-creating and record-only modes"
# Pause the branch creator after its collision check. The record-only creator must wait for
# its reservation rather than publish a duplicate while git checkout is still in progress.
mkdir .git/bin
REAL_GIT="$(command -v git)"; export REAL_GIT
RACE_ROOT="$PROJ/.git"; export RACE_ROOT
cat > .git/bin/git <<'EOF'
#!/usr/bin/env bash
if [ "$*" = 'checkout -q -b 075-mixed' ]; then
    touch "$RACE_ROOT/branch-ready"
    while [ ! -f "$RACE_ROOT/branch-continue" ]; do sleep 0.1; done
fi
exec "$REAL_GIT" "$@"
EOF
chmod +x .git/bin/git
(
    cd "$WT" || exit 1
    rc=0
    PATH="$PROJ/.git/bin:$PATH" bash "$SCRIPT" --no-worktree --number 75 --short-name mixed 'branch creator' > "$PROJ/.git/mixed-branch.log" 2>&1 || rc=$?
    printf '%s\n' "$rc" > "$PROJ/.git/mixed-branch.status"
) &
branch_pid=$!
for ((attempt=0; attempt<100; attempt++)); do
    [ ! -f .git/branch-ready ] || break
    sleep 0.1
done
assert_file .git/branch-ready 'branch creator reaches collision-check barrier'
run env PRDKIT_NUMBER_LOCK_WAIT=0 bash "$SCRIPT" --no-branch --number 75 --short-name mixed 'record-only creator'
assert_eq 1 "$STATUS" 'record-only creator cannot race past an explicit branch reservation'
assert_contains "$OUTPUT" 'another run has held the change-number lock' 'shared lock prevents the race'
touch .git/branch-continue
wait "$branch_pid"
assert_eq 0 "$(cat .git/mixed-branch.status)" 'branch creator completes'
run bash "$SCRIPT" --no-branch --number 75 --short-name mixed duplicate
assert_eq 1 "$STATUS" 'finished branch-owned record also prevents the duplicate'
assert_file "$WT/specs/changes/075-mixed.md" 'only the branch creator publishes the record'
assert_eq no "$([ -e specs/changes/075-mixed.md ] && echo yes || echo no)" 'no duplicate record in caller checkout'

it "dangling record symlinks are refused without writing through them"
ln -s "$PROJ/missing-target" specs/changes/080-link.md
run bash "$SCRIPT" --no-branch --number 80 --short-name link text
assert_eq 1 "$STATUS" 'dangling record refused'
assert_eq no "$([ -e missing-target ] && echo yes || echo no)" 'symlink target untouched'

finish
