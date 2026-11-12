#!/usr/bin/env bash
# cleanup-change.sh removes finished change worktrees the safe way and clears
# the stale "prunable" registrations that otherwise strand a harness session
# trying to re-enter a worktree whose directory was deleted out of band. doctor
# detects those stale registrations read-only.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
CLEAN="$PROJ/.prdkit/scripts/bash/cleanup-change.sh"
cd "$PROJ" || exit 1

it "removes a clean change worktree and clears its registration"
git -C "$PROJ" worktree add -qb 010-clean "$PROJ/.worktrees/010-clean" >/dev/null 2>&1
run bash "$CLEAN" --json 010-clean
assert_eq 0 "$STATUS" "clean worktree removed"
assert_contains "$OUTPUT" '"result":"ok"' "reports success"
run test ! -d "$PROJ/.worktrees/010-clean"
assert_eq 0 "$STATUS" "worktree directory gone"
assert_not_contains "$(git -C "$PROJ" worktree list --porcelain)" "010-clean" "registration cleared"

it "refuses a worktree with uncommitted work unless --force"
git -C "$PROJ" worktree add -qb 011-dirty "$PROJ/.worktrees/011-dirty" >/dev/null 2>&1
echo "uncommitted" > "$PROJ/.worktrees/011-dirty/scratch.txt"
run bash "$CLEAN" 011-dirty
assert_eq 1 "$STATUS" "dirty worktree not removed"
assert_contains "$OUTPUT" "uncommitted or untracked changes" "explains the refusal"
run test -d "$PROJ/.worktrees/011-dirty"
assert_eq 0 "$STATUS" "dirty worktree left intact"

it "--force removes a worktree with uncommitted work"
run bash "$CLEAN" --force 011-dirty
assert_eq 0 "$STATUS" "force removes dirty worktree"
run test ! -d "$PROJ/.worktrees/011-dirty"
assert_eq 0 "$STATUS" "dirty worktree gone after --force"

it "committed work is not checked for integration: it stays on the change's branch"
git -C "$PROJ" worktree add -qb 022-committed "$PROJ/.worktrees/022-committed" >/dev/null 2>&1
echo work > "$PROJ/.worktrees/022-committed/work.txt"
git -C "$PROJ/.worktrees/022-committed" add work.txt
git -C "$PROJ/.worktrees/022-committed" commit -qm 'unmerged work'
tip="$(git -C "$PROJ/.worktrees/022-committed" rev-parse HEAD)"
run bash "$CLEAN" 022-committed
assert_eq 0 "$STATUS" "a clean worktree with unmerged commits is removed"
assert_eq "$tip" "$(git -C "$PROJ" rev-parse --verify -q refs/heads/022-committed)" "branch and its commits kept"

it "prunes the stale registration a manual rm -rf leaves behind"
git -C "$PROJ" worktree add -qb 012-stale "$PROJ/.worktrees/012-stale" >/dev/null 2>&1
rm -rf "$PROJ/.worktrees/012-stale"
assert_contains "$(git -C "$PROJ" worktree list --porcelain)" "012-stale" "stale entry present before prune"
run bash "$CLEAN" --json --prune
assert_eq 0 "$STATUS" "prune succeeds"
assert_contains "$OUTPUT" "012-stale" "prune names the cleared registration"
assert_not_contains "$(git -C "$PROJ" worktree list --porcelain)" "012-stale" "stale registration cleared"

it "removing an already-deleted worktree by id just prunes it"
git -C "$PROJ" worktree add -qb 013-gone "$PROJ/.worktrees/013-gone" >/dev/null 2>&1
rm -rf "$PROJ/.worktrees/013-gone"
run bash "$CLEAN" 013-gone
assert_eq 0 "$STATUS" "already-gone worktree handled"
assert_contains "$OUTPUT" "already gone" "explains it only needed pruning"
assert_not_contains "$(git -C "$PROJ" worktree list --porcelain)" "013-gone" "registration cleared"

it "refuses to remove the worktree it is run from"
git -C "$PROJ" worktree add -qb 014-current "$PROJ/.worktrees/014-current" >/dev/null 2>&1
run bash -c 'cd "$2" && bash "$1" 014-current' _ "$CLEAN" "$PROJ/.worktrees/014-current"
assert_eq 1 "$STATUS" "refused from inside the worktree"
assert_contains "$OUTPUT" "currently inside" "tells the user to run from the main checkout"
run test -d "$PROJ/.worktrees/014-current"
assert_eq 0 "$STATUS" "current worktree left intact"
git -C "$PROJ" worktree remove --force "$PROJ/.worktrees/014-current" >/dev/null 2>&1 || true

it "review and check evidence in the worktree's ignored cache survives removal"
# The documented close -> merge -> cleanup sequence: the review package and retrospective live
# only in the worktree's gitignored cache, which `git worktree remove` would delete silently.
git -C "$PROJ" add -A >/dev/null 2>&1; git -C "$PROJ" commit -qm installed >/dev/null 2>&1  # .gitignore covers .prdkit/cache/
git -C "$PROJ" worktree add -qb 016-evidence "$PROJ/.worktrees/016-evidence" >/dev/null 2>&1
EV="$PROJ/.worktrees/016-evidence/.prdkit/cache"
mkdir -p "$EV/evidence/016-evidence/reviews/round-1" "$EV/retrospectives"
printf 'Verdict: PASS\n' > "$EV/evidence/016-evidence/reviews/round-1/report.md"
printf 'diff\n' > "$EV/evidence/016-evidence/reviews/round-1/package.diff"
printf 'lessons\n' > "$EV/retrospectives/016-evidence.md"
# Usage-enrichment input is gitignored too, so it is not dirt; it must not vanish with the worktree.
mkdir -p "$PROJ/.worktrees/016-evidence/.prdkit/retrospective"
printf '{"tokens":{"total":1}}\n' > "$PROJ/.worktrees/016-evidence/.prdkit/retrospective/016-evidence.enrich.json"
run bash "$CLEAN" --json 016-evidence
assert_eq 0 "$STATUS" "worktree removed"
assert_contains "$OUTPUT" "preserved 4 evidence file(s)" "preservation reported"
assert_eq "Verdict: PASS" "$(cat "$PROJ/.prdkit/cache/evidence/016-evidence/reviews/round-1/report.md" 2>/dev/null)" "review report kept"
assert_eq "lessons" "$(cat "$PROJ/.prdkit/cache/retrospectives/016-evidence.md" 2>/dev/null)" "retrospective kept"
assert_eq '{"tokens":{"total":1}}' "$(cat "$PROJ/.prdkit/retrospective/016-evidence.enrich.json" 2>/dev/null)" "enrichment input kept"

it "every change's evidence in the worktree and its ledger events survive removal"
# new-change.sh run inside a worktree opens the next change there, so one worktree can hold
# several changes' evidence; the ledger spool is per checkout and gitignored too.
git -C "$PROJ" worktree add -qb 018-first "$PROJ/.worktrees/018-first" >/dev/null 2>&1
EV="$PROJ/.worktrees/018-first/.prdkit"
mkdir -p "$EV/cache/evidence/018-first" "$EV/cache/evidence/019-second" "$EV/ledger" "$PROJ/.prdkit/ledger"
printf 'first\n' > "$EV/cache/evidence/018-first/report.md"
printf 'second\n' > "$EV/cache/evidence/019-second/report.md"
printf '{"event":"a"}\n' > "$PROJ/.prdkit/ledger/events.jsonl"
printf '{"event":"a"}\n{"event":"b"}\n{"event":"c"}\n' > "$EV/ledger/events.jsonl"
run bash "$CLEAN" 019-second
assert_eq 1 "$STATUS" "no worktree named for the second change"
run bash "$CLEAN" 018-first
assert_eq 0 "$STATUS" "worktree removed"
assert_eq "first" "$(cat "$PROJ/.prdkit/cache/evidence/018-first/report.md" 2>/dev/null)" "its own evidence kept"
assert_eq "second" "$(cat "$PROJ/.prdkit/cache/evidence/019-second/report.md" 2>/dev/null)" "the other change's evidence kept"
assert_contains "$OUTPUT" "appended 2 ledger event(s)" "events reported"
assert_eq '{"event":"a"}
{"event":"b"}
{"event":"c"}' "$(cat "$PROJ/.prdkit/ledger/events.jsonl")" "events merged without duplicates"

it "events reach a main checkout that has no spool yet"
git -C "$PROJ" worktree add -qb 021-spool "$PROJ/.worktrees/021-spool" >/dev/null 2>&1
mkdir -p "$PROJ/.worktrees/021-spool/.prdkit/ledger"
printf '{"event":"x"}\n{"event":"y"}\n' > "$PROJ/.worktrees/021-spool/.prdkit/ledger/events.jsonl"
rm -f "$PROJ/.prdkit/ledger/events.jsonl"
run bash "$CLEAN" 021-spool
assert_eq 0 "$STATUS" "worktree removed"
assert_contains "$OUTPUT" "appended 2 ledger event(s)" "events reported"
assert_eq '{"event":"x"}
{"event":"y"}' "$(cat "$PROJ/.prdkit/ledger/events.jsonl" 2>/dev/null)" "every event kept"

it "a refused removal copies nothing; the worktree's own copy of the script refuses"
git -C "$PROJ" worktree add -qb 020-refused "$PROJ/.worktrees/020-refused" >/dev/null 2>&1
mkdir -p "$PROJ/.worktrees/020-refused/.prdkit/cache/evidence/020-refused"
printf 'kept\n' > "$PROJ/.worktrees/020-refused/.prdkit/cache/evidence/020-refused/out.txt"
echo "uncommitted" > "$PROJ/.worktrees/020-refused/scratch.txt"
run bash "$CLEAN" 020-refused
assert_eq 1 "$STATUS" "dirty worktree refused"
run test ! -e "$PROJ/.prdkit/cache/evidence/020-refused"
assert_eq 0 "$STATUS" "nothing copied before the refusal"
rm -f "$PROJ/.worktrees/020-refused/scratch.txt"
mkdir -p "$PROJ/.worktrees/020-refused/.prdkit/scripts/bash"
cp "$PROJ"/.prdkit/scripts/bash/*.sh "$PROJ/.worktrees/020-refused/.prdkit/scripts/bash/"
run bash -c 'cd "$1" && bash .worktrees/020-refused/.prdkit/scripts/bash/cleanup-change.sh 020-refused' _ "$PROJ"
assert_eq 1 "$STATUS" "the worktree's copy refuses"
assert_contains "$OUTPUT" "run the main checkout's" "names the right script"
run test -f "$PROJ/.worktrees/020-refused/.prdkit/cache/evidence/020-refused/out.txt"
assert_eq 0 "$STATUS" "evidence left intact"
git -C "$PROJ" worktree remove --force "$PROJ/.worktrees/020-refused" >/dev/null 2>&1 || true

it "a different file already in the main cache refuses the removal"
git -C "$PROJ" worktree add -qb 017-clash "$PROJ/.worktrees/017-clash" >/dev/null 2>&1
mkdir -p "$PROJ/.worktrees/017-clash/.prdkit/cache/evidence/017-clash" "$PROJ/.prdkit/cache/evidence/017-clash"
printf 'new\n' > "$PROJ/.worktrees/017-clash/.prdkit/cache/evidence/017-clash/out.txt"
printf 'old\n' > "$PROJ/.prdkit/cache/evidence/017-clash/out.txt"
run bash "$CLEAN" 017-clash
assert_eq 1 "$STATUS" "removal refused"
assert_contains "$OUTPUT" "could not preserve its evidence" "conflict explained"
run test -f "$PROJ/.worktrees/017-clash/.prdkit/cache/evidence/017-clash/out.txt"
assert_eq 0 "$STATUS" "worktree evidence left intact"
git -C "$PROJ" worktree remove --force "$PROJ/.worktrees/017-clash" >/dev/null 2>&1 || true

it "reports a clear error for an unknown change id"
run bash "$CLEAN" 999-nope
assert_eq 1 "$STATUS" "unknown id fails"
assert_contains "$OUTPUT" "No worktree found" "names the missing change"

it "doctor flags a stale worktree registration without pruning it"
git -C "$PROJ" worktree add -qb 015-doctor "$PROJ/.worktrees/015-doctor" >/dev/null 2>&1
rm -rf "$PROJ/.worktrees/015-doctor"
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh" --json
assert_contains "$OUTPUT" "Stale worktree registration" "stale worktree surfaced"
assert_contains "$OUTPUT" "cleanup-change.sh --prune" "names the repair"
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh" --strict
assert_eq 1 "$STATUS" "--strict fails while a stale worktree lingers"
assert_contains "$OUTPUT" "015-doctor" "names the stale path"
assert_contains "$(git -C "$PROJ" worktree list --porcelain)" "015-doctor" "doctor did not prune (read-only)"

# --- Submodules: git refuses to remove any worktree whose submodules are initialized -------------
# A local file-path submodule needs protocol.file.allow, which modern git denies by default.
PROJ2="$(make_inited_project)"; track_tmp "$PROJ2"
PROJ2="$(cd "$PROJ2" && pwd -P)"
CLEAN2="$PROJ2/.prdkit/scripts/bash/cleanup-change.sh"
SUBSRC="$(mktemp -d)"; track_tmp "$SUBSRC"
git -C "$SUBSRC" init -q
git -C "$SUBSRC" -c user.email=t@example.com -c user.name=test commit -q --allow-empty -m sub
git -C "$PROJ2" -c protocol.file.allow=always submodule add -q "$SUBSRC" vendor/sub >/dev/null 2>&1
git -C "$PROJ2" add -A >/dev/null 2>&1; git -C "$PROJ2" commit -qm 'add submodule' >/dev/null 2>&1
sub_worktree() { # change id: a worktree of PROJ2 with its submodule initialized
    git -C "$PROJ2" worktree add -qb "$1" "$PROJ2/.worktrees/$1" >/dev/null 2>&1
    git -C "$PROJ2/.worktrees/$1" -c protocol.file.allow=always submodule update --init -q >/dev/null 2>&1
}
sub_worktree 050-sub-control
run git -C "$PROJ2" worktree remove "$PROJ2/.worktrees/050-sub-control"
assert_contains "$OUTPUT" "submodules" "fixture: git itself refuses a clean worktree with initialized submodules"
git -C "$PROJ2" worktree remove --force "$PROJ2/.worktrees/050-sub-control" >/dev/null 2>&1

it "a clean worktree in a repository with submodules is removed without --force, evidence preserved"
sub_worktree 051-sub-clean
mkdir -p "$PROJ2/.worktrees/051-sub-clean/.prdkit/cache/evidence/051-sub-clean" "$PROJ2/.worktrees/051-sub-clean/.prdkit/cache/retrospectives"
printf 'kept\n' > "$PROJ2/.worktrees/051-sub-clean/.prdkit/cache/evidence/051-sub-clean/out.txt"
printf 'lessons\n' > "$PROJ2/.worktrees/051-sub-clean/.prdkit/cache/retrospectives/051-sub-clean.md"
mkdir -p "$PROJ2/.worktrees/051-sub-clean/.prdkit/ledger"
printf '{"event":"sub"}\n' > "$PROJ2/.worktrees/051-sub-clean/.prdkit/ledger/events.jsonl"
rm -f "$PROJ2/.prdkit/ledger/events.jsonl"
run bash "$CLEAN2" --json 051-sub-clean
assert_eq 0 "$STATUS" "removed"
assert_contains "$OUTPUT" '"result":"ok"' "reports success"
assert_contains "$OUTPUT" "submodules" "says why it needed the forced retry"
run test ! -d "$PROJ2/.worktrees/051-sub-clean"
assert_eq 0 "$STATUS" "worktree directory gone"
assert_not_contains "$(git -C "$PROJ2" worktree list --porcelain)" "051-sub-clean" "registration cleared"
assert_eq "kept" "$(cat "$PROJ2/.prdkit/cache/evidence/051-sub-clean/out.txt" 2>/dev/null)" "evidence kept"
assert_eq "lessons" "$(cat "$PROJ2/.prdkit/cache/retrospectives/051-sub-clean.md" 2>/dev/null)" "retrospective kept"
assert_eq '{"event":"sub"}' "$(cat "$PROJ2/.prdkit/ledger/events.jsonl" 2>/dev/null)" "ledger event kept"
assert_eq "$(git -C "$PROJ2" rev-parse HEAD)" "$(git -C "$PROJ2" rev-parse refs/heads/051-sub-clean)" "branch kept"

it "the same repository: an untracked file refuses the worktree as dirty, and it stays"
sub_worktree 052-sub-dirty
echo scratch > "$PROJ2/.worktrees/052-sub-dirty/scratch.txt"
run bash "$CLEAN2" 052-sub-dirty
assert_eq 1 "$STATUS" "dirty worktree refused"
assert_contains "$OUTPUT" "uncommitted or untracked changes" "reported as dirty"
assert_not_contains "$OUTPUT" "git refused" "not blamed on git"
run test -f "$PROJ2/.worktrees/052-sub-dirty/scratch.txt"
assert_eq 0 "$STATUS" "worktree and its file kept"

it "a modified submodule is dirty too; nothing is discarded"
sub_worktree 053-sub-modified
echo scratch > "$PROJ2/.worktrees/053-sub-modified/vendor/sub/scratch.txt"
run bash "$CLEAN2" 053-sub-modified
assert_eq 1 "$STATUS" "untracked file inside the submodule refused"
assert_contains "$OUTPUT" "uncommitted or untracked changes" "reported as dirty"
run test -f "$PROJ2/.worktrees/053-sub-modified/vendor/sub/scratch.txt"
assert_eq 0 "$STATUS" "submodule content kept"

it "a locked worktree is refused with git's reason, not as uncommitted changes, and stays"
sub_worktree 054-sub-locked
git -C "$PROJ2" worktree lock --reason "on a removable disk" "$PROJ2/.worktrees/054-sub-locked"
run bash "$CLEAN2" 054-sub-locked
assert_eq 1 "$STATUS" "locked worktree refused"
assert_contains "$OUTPUT" "locked working tree" "git's reason reported"
assert_contains "$OUTPUT" "worktree itself is clean" "says the tree is clean"
assert_not_contains "$OUTPUT" "uncommitted or untracked changes" "not reported as dirty"
run test -d "$PROJ2/.worktrees/054-sub-locked"
assert_eq 0 "$STATUS" "locked worktree kept"
run bash "$CLEAN2" --json 054-sub-locked
assert_contains "$OUTPUT" '"result":"refused"' "JSON refuses"
assert_contains "$OUTPUT" "locked working tree" "JSON carries git's reason"
git -C "$PROJ2" worktree unlock "$PROJ2/.worktrees/054-sub-locked"

it "a locked worktree without submodules is reported the same way"
git -C "$PROJ" worktree add -qb 055-locked "$PROJ/.worktrees/055-locked" >/dev/null 2>&1
git -C "$PROJ" worktree lock "$PROJ/.worktrees/055-locked"
run bash "$CLEAN" 055-locked
assert_eq 1 "$STATUS" "locked worktree refused"
assert_contains "$OUTPUT" "locked working tree" "git's reason reported"
git -C "$PROJ" worktree unlock "$PROJ/.worktrees/055-locked"
git -C "$PROJ" worktree remove --force "$PROJ/.worktrees/055-locked" >/dev/null 2>&1 || true

it "negative control: without the forced retry the submodule worktree is refused and kept"
sub_worktree 056-sub-control
NORETRY="$PROJ2/.prdkit/scripts/bash/cleanup-noretry.sh"
# shellcheck disable=SC2016 # sed pattern: the $ are literal script text
sed 's/if \[ "\$locked" = true \] || ! submodule_refusal "\$rm_err"; then/if true; then/' "$CLEAN2" > "$NORETRY"
if cmp -s "$CLEAN2" "$NORETRY"; then _no "negative control built" "the retry condition was not found in the script"; else _ok "negative control built"; fi
run bash "$NORETRY" 056-sub-control
assert_eq 1 "$STATUS" "refused without the retry"
assert_contains "$OUTPUT" "submodules" "git's refusal reported"
run test -d "$PROJ2/.worktrees/056-sub-control"
assert_eq 0 "$STATUS" "worktree kept"
run bash "$CLEAN2" 056-sub-control
assert_eq 0 "$STATUS" "the real script removes the same worktree"
rm -f "$NORETRY"

it "detection does not rest on git's wording: a gitlink in the index is enough"
# A git whose message is worded or translated differently still refuses the same way.
SHIM="$(mktemp -d)"; track_tmp "$SHIM"
REAL_GIT="$(command -v git)"
cat > "$SHIM/git" <<EOF
#!/usr/bin/env bash
case " \$* " in
    *" worktree remove "*) case " \$* " in *" --force "*) ;; *) echo "fatal: odstranit nelze pracovni strom s podmoduly" >&2; exit 128 ;; esac ;;
esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SHIM/git"
sub_worktree 057-sub-worded
run env PATH="$SHIM:$PATH" bash "$CLEAN2" 057-sub-worded
assert_eq 0 "$STATUS" "removed although git's message is not recognisable"
run test ! -d "$PROJ2/.worktrees/057-sub-worded"
assert_eq 0 "$STATUS" "worktree gone"
git -C "$PROJ" worktree add -qb 058-plain "$PROJ/.worktrees/058-plain" >/dev/null 2>&1
run env PATH="$SHIM:$PATH" bash "$CLEAN" 058-plain
assert_eq 1 "$STATUS" "an unrecognised refusal with no gitlink is not retried forced"
assert_contains "$OUTPUT" "odstranit nelze" "git's own words reported"
run test -d "$PROJ/.worktrees/058-plain"
assert_eq 0 "$STATUS" "worktree kept"
git -C "$PROJ" worktree remove --force "$PROJ/.worktrees/058-plain" >/dev/null 2>&1 || true

# --- Submodule commits kept only in the worktree's copy of the submodule --------------------------
# Each linked worktree keeps its own submodule repository (<git-dir>/modules/<name>), which the
# removal deletes. A commit made there and recorded in the superproject branch, but never pushed,
# leaves the worktree clean; removing it would leave the branch pointing at a commit that exists
# nowhere.
GITID=(-c user.email=t@example.com -c user.name=test)
sub_commit() { # change id: commit in the worktree's submodule, record it in the superproject; echoes the commit
    git -C "$PROJ2/.worktrees/$1/vendor/sub" "${GITID[@]}" commit -q --allow-empty -m "local $1" >/dev/null 2>&1
    git -C "$PROJ2/.worktrees/$1" add vendor/sub >/dev/null 2>&1
    git -C "$PROJ2/.worktrees/$1" "${GITID[@]}" commit -qm "record $1" >/dev/null 2>&1
    git -C "$PROJ2/.worktrees/$1/vendor/sub" rev-parse HEAD
}
nowhere_else() { # commit: true when neither the submodule's origin nor the main checkout's copy has it
    ! git -C "$SUBSRC" cat-file -e "$1^{commit}" 2>/dev/null && ! git -C "$PROJ2/vendor/sub" cat-file -e "$1^{commit}" 2>/dev/null
}
mutex_of() { # change id: the path of the removal mutex in the worktree's git directory
    printf '%s/prdkit-cleanup.lock' "$(git -C "$PROJ2/.worktrees/$1" rev-parse --absolute-git-dir)"
}

it "an unpushed submodule commit the branch records refuses the removal, with and without --force"
sub_worktree 080-sub-unpushed
c80="$(sub_commit 080-sub-unpushed)"
assert_eq "" "$(git -C "$PROJ2/.worktrees/080-sub-unpushed" status --porcelain --untracked-files=all)" "fixture: the worktree is clean"
if nowhere_else "$c80"; then _ok "fixture: the commit exists only in the worktree"; else _no "fixture: the commit exists only in the worktree"; fi
run bash "$CLEAN2" 080-sub-unpushed
assert_eq 1 "$STATUS" "refused"
assert_contains "$OUTPUT" "submodule vendor/sub holds commit $c80" "names the submodule and the commit"
assert_contains "$OUTPUT" "Push it" "says how to keep it"
run bash "$CLEAN2" --json 080-sub-unpushed
assert_contains "$OUTPUT" '"result":"refused"' "JSON refuses"
run bash "$CLEAN2" --force 080-sub-unpushed
assert_eq 1 "$STATUS" "--force refused too: it discards uncommitted changes only"
run test -d "$PROJ2/.worktrees/080-sub-unpushed"
assert_eq 0 "$STATUS" "worktree kept"
run git -C "$PROJ2/.worktrees/080-sub-unpushed/vendor/sub" cat-file -e "$c80^{commit}"
assert_eq 0 "$STATUS" "the commit is kept"
run test ! -e "$(mutex_of 080-sub-unpushed)"
assert_eq 0 "$STATUS" "a refusal leaves no lock behind"

it "once pushed, the same worktree is removed and the commit lives on"
git -C "$PROJ2/.worktrees/080-sub-unpushed/vendor/sub" -c protocol.file.allow=always push -q origin HEAD:refs/heads/kept-080 >/dev/null 2>&1
run bash "$CLEAN2" 080-sub-unpushed
assert_eq 0 "$STATUS" "removed"
run test ! -d "$PROJ2/.worktrees/080-sub-unpushed"
assert_eq 0 "$STATUS" "worktree gone"
run git -C "$SUBSRC" cat-file -e "$c80^{commit}"
assert_eq 0 "$STATUS" "the commit is on the submodule's remote"

it "a commit fetched into the main checkout's copy of the submodule is held there"
sub_worktree 081-sub-fetched
c81="$(sub_commit 081-sub-fetched)"
git -C "$PROJ2/vendor/sub" -c protocol.file.allow=always fetch -q "$PROJ2/.worktrees/081-sub-fetched/vendor/sub" HEAD:refs/heads/from-081 >/dev/null 2>&1
run bash "$CLEAN2" 081-sub-fetched
assert_eq 0 "$STATUS" "removed"
run git -C "$PROJ2/vendor/sub" cat-file -e "$c81^{commit}"
assert_eq 0 "$STATUS" "the main checkout's submodule still has the commit"

it "a local branch in the worktree's submodule that nothing records refuses --force"
sub_worktree 082-sub-branch
git -C "$PROJ2/.worktrees/082-sub-branch/vendor/sub" checkout -qb scratch >/dev/null 2>&1
git -C "$PROJ2/.worktrees/082-sub-branch/vendor/sub" "${GITID[@]}" commit -q --allow-empty -m scratch >/dev/null 2>&1
git -C "$PROJ2/.worktrees/082-sub-branch/vendor/sub" checkout -q --detach HEAD~1 >/dev/null 2>&1
c82="$(git -C "$PROJ2/.worktrees/082-sub-branch/vendor/sub" rev-parse scratch)"
run bash "$CLEAN2" --force 082-sub-branch
assert_eq 1 "$STATUS" "refused"
assert_contains "$OUTPUT" "holds commit $c82" "names the branch's commit"
run test -d "$PROJ2/.worktrees/082-sub-branch"
assert_eq 0 "$STATUS" "worktree kept"
git -C "$PROJ2" worktree remove --force --force "$PROJ2/.worktrees/082-sub-branch" >/dev/null 2>&1 || true

it "negative control: without the submodule-commit check the removal deletes the only copy"
sub_worktree 083-sub-control
c83="$(sub_commit 083-sub-control)"
NOCHECK="$PROJ2/.prdkit/scripts/bash/cleanup-nocheck.sh"
sed 's/check_submodule_commits ||/true ||/' "$CLEAN2" > "$NOCHECK"
if cmp -s "$CLEAN2" "$NOCHECK"; then _no "negative control built" "the check was not found in the script"; else _ok "negative control built"; fi
run bash "$NOCHECK" 083-sub-control
assert_eq 0 "$STATUS" "removed without the check"
if nowhere_else "$c83"; then _ok "the commit the branch records is gone everywhere"; else _no "the commit the branch records is gone everywhere"; fi
assert_eq "$c83" "$(git -C "$PROJ2" ls-tree refs/heads/083-sub-control vendor/sub | awk '{ print $3 }')" "while the branch still records it"
rm -f "$NOCHECK"

it "the forced retry holds a lock while it removes, and drops it when the removal fails"
SHIM2="$(mktemp -d)"; track_tmp "$SHIM2"
cat > "$SHIM2/git" <<EOF
#!/usr/bin/env bash
case " \$* " in
    *" worktree remove --force "*) find "$PROJ2/.git/worktrees" -name prdkit-cleanup.lock > "$SHIM2/list"; echo "fatal: simulated failure" >&2; exit 1 ;;
esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SHIM2/git"
sub_worktree 084-sub-lock
M84="$(mutex_of 084-sub-lock)"
run env PATH="$SHIM2:$PATH" bash "$CLEAN2" 084-sub-lock
assert_eq 1 "$STATUS" "the simulated failure refuses"
assert_contains "$OUTPUT" "simulated failure" "git's reason reported"
assert_eq "$M84" "$(cat "$SHIM2/list")" "the mutex is held during the forced removal"
run test ! -e "$M84"
assert_eq 0 "$STATUS" "and released after the failure"
run bash "$CLEAN2" 084-sub-lock
assert_eq 0 "$STATUS" "a later run removes it"

it "a worktree someone has locked with git is refused by --force with git's reason"
sub_worktree 085-sub-held
git -C "$PROJ2" worktree lock --reason "another sweep" "$PROJ2/.worktrees/085-sub-held"
run bash "$CLEAN2" --force 085-sub-held
assert_eq 1 "$STATUS" "refused"
assert_contains "$OUTPUT" "another sweep" "git's reason reported"
run test -d "$PROJ2/.worktrees/085-sub-held"
assert_eq 0 "$STATUS" "worktree kept"
git -C "$PROJ2" worktree unlock "$PROJ2/.worktrees/085-sub-held"
git -C "$PROJ2" worktree remove --force --force "$PROJ2/.worktrees/085-sub-held" >/dev/null 2>&1 || true

it "a second run cannot take the mutex: refused, kept, and the other run's mutex is left alone"
sub_worktree 086-sub-busy
M86="$(mutex_of 086-sub-busy)"
mkdir "$M86"
run bash "$CLEAN2" 086-sub-busy
assert_eq 1 "$STATUS" "refused"
assert_contains "$OUTPUT" "another cleanup-change.sh run holds $M86" "names the mutex"
run test -d "$PROJ2/.worktrees/086-sub-busy"
assert_eq 0 "$STATUS" "worktree kept"
run test -d "$M86"
assert_eq 0 "$STATUS" "the other run's mutex kept"
rmdir "$M86"
run bash "$CLEAN2" 086-sub-busy
assert_eq 0 "$STATUS" "removed once the mutex is free"

it "an older stash in the submodule lives only in the reflog, and is kept"
sub_worktree 087-sub-stash
S87="$PROJ2/.worktrees/087-sub-stash/vendor/sub"
echo one > "$S87/one.txt"; git -C "$S87" "${GITID[@]}" stash push -qu -m one >/dev/null 2>&1
echo two > "$S87/two.txt"; git -C "$S87" "${GITID[@]}" stash push -qu -m two >/dev/null 2>&1
old87="$(git -C "$S87" rev-parse 'stash@{1}')"
git -C "$PROJ2/vendor/sub" -c protocol.file.allow=always fetch -q "$S87" refs/stash:refs/heads/newest-stash-087 >/dev/null 2>&1
run git -C "$PROJ2/vendor/sub" cat-file -e "$(git -C "$S87" rev-parse 'stash@{0}')^{commit}"
assert_eq 0 "$STATUS" "fixture: the newest stash is held by the main checkout's copy"
run bash "$CLEAN2" 087-sub-stash
assert_eq 1 "$STATUS" "refused"
assert_contains "$OUTPUT" "holds commit $old87" "names the older stash"
run git -C "$S87" cat-file -e "$old87^{commit}"
assert_eq 0 "$STATUS" "the older stash is kept"
git -C "$PROJ2" worktree remove --force "$PROJ2/.worktrees/087-sub-stash" >/dev/null 2>&1 || true

it "a git that cannot list the submodule's commits refuses, before and under the mutex"
# The first listing passes and the second fails: that one runs under the mutex, before the removal.
SHIM3="$(mktemp -d)"; track_tmp "$SHIM3"
cat > "$SHIM3/git" <<EOF
#!/usr/bin/env bash
case " \$* " in
    *" --git-dir="*" for-each-ref --format=%(refname) "*)
        n="\$(cat "$SHIM3/count" 2>/dev/null || echo 0)"; n=\$((n + 1)); echo "\$n" > "$SHIM3/count"
        [ "\$n" -lt "\${FAIL_AT:-1}" ] || { echo "fatal: simulated read error" >&2; exit 128; } ;;
esac
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$SHIM3/git"
sub_worktree 088-sub-unreadable
rm -f "$SHIM3/count"
run env PATH="$SHIM3:$PATH" FAIL_AT=1 bash "$CLEAN2" 088-sub-unreadable
assert_eq 1 "$STATUS" "refused when the first listing fails"
assert_contains "$OUTPUT" "could not list the commits in the worktree's submodules" "says git could not say"
rm -f "$SHIM3/count"
run env PATH="$SHIM3:$PATH" FAIL_AT=2 bash "$CLEAN2" --json 088-sub-unreadable
assert_eq 1 "$STATUS" "refused when the listing under the mutex fails"
assert_contains "$OUTPUT" '"result":"refused"' "JSON refuses"
assert_eq 2 "$(cat "$SHIM3/count")" "the second listing ran under the mutex"
run test -d "$PROJ2/.worktrees/088-sub-unreadable"
assert_eq 0 "$STATUS" "worktree kept"
run test ! -e "$(mutex_of 088-sub-unreadable)"
assert_eq 0 "$STATUS" "mutex released"

it "a failed search for the submodule copies refuses"
SHIM4="$(mktemp -d)"; track_tmp "$SHIM4"
REAL_FIND="$(command -v find)"
cat > "$SHIM4/find" <<EOF
#!/usr/bin/env bash
case "\$1" in */modules) echo "find: simulated failure" >&2; exit 1 ;; esac
exec "$REAL_FIND" "\$@"
EOF
chmod +x "$SHIM4/find"
run env PATH="$SHIM4:$PATH" bash "$CLEAN2" 088-sub-unreadable
assert_eq 1 "$STATUS" "refused"
assert_contains "$OUTPUT" "could not list the commits in the worktree's submodules" "says git could not say"
run test -d "$PROJ2/.worktrees/088-sub-unreadable"
assert_eq 0 "$STATUS" "worktree kept"
run bash "$CLEAN2" 088-sub-unreadable
assert_eq 0 "$STATUS" "the real tools remove it"

# --- --closed: sweep every closed change's worktree ----------------------------------------------
# Closed means the record specs/changes/<id>.md is gone from, and specs/log.md has the line on, the
# trusted integration branch (origin/HEAD), never the worktree's own branch.
BRANCH="$(git -C "$PROJ" symbolic-ref --short HEAD)"
for id in 060-closed-clean 061-open 062-closed-dirty 063-closed-locked 064-self-claimed 065-logged-record 066-never-logged; do
    git -C "$PROJ" worktree add -qb "$id" "$PROJ/.worktrees/$id" >/dev/null 2>&1
done
git -C "$PROJ" worktree add -qb 069-stale "$PROJ/.worktrees/069-stale" >/dev/null 2>&1
rm -rf "$PROJ/.worktrees/069-stale"
mkdir -p "$PROJ/.worktrees/060-closed-clean/.prdkit/cache/evidence/060-closed-clean"
printf 'kept\n' > "$PROJ/.worktrees/060-closed-clean/.prdkit/cache/evidence/060-closed-clean/out.txt"
echo scratch > "$PROJ/.worktrees/062-closed-dirty/scratch.txt"
git -C "$PROJ" worktree lock --reason "held" "$PROJ/.worktrees/063-closed-locked"
# 064 closes itself on its own branch only; the trusted branch never hears of it.
(
    cd "$PROJ/.worktrees/064-self-claimed" || exit 1
    mkdir -p specs
    printf -- '- 2026-11-10 064-self-claimed: done\n' > specs/log.md
    git add specs/log.md && git commit -qm 'claim closed'
)

it "--closed refuses outright when no trusted integration branch resolves"
run bash "$CLEAN" --closed
assert_eq 1 "$STATUS" "no origin/HEAD: refused"
assert_contains "$OUTPUT" "no trusted integration branch" "says why"
run bash "$CLEAN" --json --closed
assert_eq 1 "$STATUS" "JSON refuses too"
assert_contains "$OUTPUT" '"result":"refused"' "JSON result"
run test -d "$PROJ/.worktrees/060-closed-clean"
assert_eq 0 "$STATUS" "nothing was removed"

# The trusted branch records 060, 062, 063, 065, 067 as closed, 065 with its record still present.
mkdir -p "$PROJ/specs/changes"
{
    printf -- '- 2026-11-10 067-closed-here: x\n- 2026-11-09 065-logged-record: x\n- 2026-11-08 063-closed-locked: x\n'
    printf -- '- 2026-11-07 062-closed-dirty: x\n- 2026-11-06 060-closed-clean: x\n'
} > "$PROJ/specs/log.md"
printf '# 061-open\n' > "$PROJ/specs/changes/061-open.md"
printf '# 065-logged-record\n' > "$PROJ/specs/changes/065-logged-record.md"
git -C "$PROJ" add specs >/dev/null 2>&1; git -C "$PROJ" commit -qm 'close changes' >/dev/null 2>&1
git -C "$PROJ" update-ref "refs/remotes/origin/$BRANCH" HEAD
git -C "$PROJ" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$BRANCH"

it "--closed removes closed changes' clean worktrees, skips the rest and exits non-zero on a refusal"
run bash "$CLEAN" --closed --help
assert_contains "$OUTPUT" "--closed" "usage documents the mode"
run bash "$CLEAN" --closed --force
assert_eq 2 "$STATUS" "--closed never forces"
run bash "$CLEAN" --closed 060-closed-clean
assert_eq 2 "$STATUS" "a change id and --closed are exclusive"
run bash "$CLEAN" --json --closed
assert_eq 1 "$STATUS" "the dirty and the locked worktree were refused"
assert_contains "$OUTPUT" '"action":"closed"' "closed action"
assert_contains "$OUTPUT" '"result":"refused"' "result is refused"
assert_contains "$OUTPUT" "060-closed-clean" "the clean closed worktree is listed as removed"
assert_contains "$OUTPUT" '"skipped":[' "skipped list"
assert_contains "$OUTPUT" "062-closed-dirty\",\"reason\":\"uncommitted or untracked changes" "dirty one skipped as dirty"
assert_contains "$OUTPUT" "063-closed-locked\",\"reason\":\"git refused the removal: cannot remove a locked working tree" "locked one skipped with git's reason"
assert_contains "$OUTPUT" "069-stale" "the stale registration is reported pruned"
run test ! -d "$PROJ/.worktrees/060-closed-clean"
assert_eq 0 "$STATUS" "060-closed-clean removed"
for id in 061-open 062-closed-dirty 063-closed-locked 064-self-claimed 065-logged-record 066-never-logged; do
    run test -d "$PROJ/.worktrees/$id"
    assert_eq 0 "$STATUS" "$id kept"
done
assert_not_contains "$(git -C "$PROJ" worktree list --porcelain)" "069-stale" "stale registration pruned"
assert_eq "kept" "$(cat "$PROJ/.prdkit/cache/evidence/060-closed-clean/out.txt" 2>/dev/null)" "evidence preserved"
run test -f "$PROJ/.worktrees/062-closed-dirty/scratch.txt"
assert_eq 0 "$STATUS" "the dirty worktree's file kept"
assert_eq "060-closed-clean" "$(git -C "$PROJ" for-each-ref --format='%(refname:short)' refs/heads/060-closed-clean)" "branch kept"

it "--closed skips the worktree holding the current directory, then succeeds once the rest are clean"
rm -f "$PROJ/.worktrees/062-closed-dirty/scratch.txt"
git -C "$PROJ" worktree add -qb 067-closed-here "$PROJ/.worktrees/067-closed-here" >/dev/null 2>&1
git -C "$PROJ" worktree unlock "$PROJ/.worktrees/063-closed-locked"
run bash -c 'cd "$2/.worktrees/067-closed-here" && bash "$1" --closed' _ "$CLEAN" "$PROJ"
assert_eq 0 "$STATUS" "nothing was refused"
assert_contains "$OUTPUT" "067-closed-here: it holds the current directory" "reported as skipped"
for id in 062-closed-dirty 063-closed-locked; do
    run test ! -d "$PROJ/.worktrees/$id"
    assert_eq 0 "$STATUS" "$id removed"
done
run test -d "$PROJ/.worktrees/067-closed-here"
assert_eq 0 "$STATUS" "the current worktree kept"
run bash "$CLEAN" --closed
assert_eq 0 "$STATUS" "from the main checkout it is removed"
assert_contains "$OUTPUT" "Removed 1 closed change worktree" "text summary"
run test ! -d "$PROJ/.worktrees/067-closed-here"
assert_eq 0 "$STATUS" "067-closed-here removed"
run bash "$CLEAN" --closed
assert_eq 0 "$STATUS" "nothing left to do"
assert_contains "$OUTPUT" "Removed 0 closed change worktree" "idempotent"
for id in 061-open 064-self-claimed 065-logged-record 066-never-logged; do
    run test -d "$PROJ/.worktrees/$id"
    assert_eq 0 "$STATUS" "$id still kept"
done

it "--closed matches only .worktrees/<id> on branch <id>: a detached HEAD, another branch or directory stays"
OUTSIDE="$(mktemp -d)"; track_tmp "$OUTSIDE"; OUTSIDE="$(cd "$OUTSIDE" && pwd -P)"
git -C "$PROJ" worktree add -q --detach "$PROJ/.worktrees/090-closed-detached" >/dev/null 2>&1
git -C "$PROJ/.worktrees/090-closed-detached" commit -q --allow-empty -m 'reachable from no ref'
c90="$(git -C "$PROJ/.worktrees/090-closed-detached" rev-parse HEAD)"
git -C "$PROJ" worktree add -qb feature-x "$PROJ/.worktrees/091-closed-other-branch" >/dev/null 2>&1
git -C "$PROJ" worktree add -qb 092-closed-elsewhere "$OUTSIDE/092-closed-elsewhere" >/dev/null 2>&1
git -C "$PROJ" worktree add -qb 093-closed-renamed "$PROJ/.worktrees/scratch" >/dev/null 2>&1
git -C "$PROJ" worktree add -qb 094-closed-exact "$PROJ/.worktrees/094-closed-exact" >/dev/null 2>&1
{
    printf -- '- 2026-11-11 090-closed-detached: x\n- 2026-11-11 091-closed-other-branch: x\n'
    printf -- '- 2026-11-11 092-closed-elsewhere: x\n- 2026-11-11 093-closed-renamed: x\n- 2026-11-11 094-closed-exact: x\n'
} >> "$PROJ/specs/log.md"
git -C "$PROJ" add specs >/dev/null 2>&1; git -C "$PROJ" commit -qm 'close more' >/dev/null 2>&1
git -C "$PROJ" update-ref "refs/remotes/origin/$BRANCH" HEAD
run bash "$CLEAN" --json --closed
assert_eq 0 "$STATUS" "nothing refused"
assert_contains "$OUTPUT" '"paths":["'"$PROJ"'/.worktrees/094-closed-exact"]' "only the exact layout removed"
assert_contains "$OUTPUT" "Removed 1 closed change worktree(s), skipped 0," "the others are not candidates, so not skipped either"
run test ! -d "$PROJ/.worktrees/094-closed-exact"
assert_eq 0 "$STATUS" "the exact layout removed"
for wt in "$PROJ/.worktrees/090-closed-detached" "$PROJ/.worktrees/091-closed-other-branch" "$OUTSIDE/092-closed-elsewhere" "$PROJ/.worktrees/scratch"; do
    run test -d "$wt"
    assert_eq 0 "$STATUS" "${wt##*/} kept"
done
assert_eq "$c90" "$(git -C "$PROJ/.worktrees/090-closed-detached" rev-parse HEAD)" "the detached HEAD's commit is kept"
for wt in "$PROJ/.worktrees/090-closed-detached" "$PROJ/.worktrees/091-closed-other-branch" "$OUTSIDE/092-closed-elsewhere" "$PROJ/.worktrees/scratch"; do
    git -C "$PROJ" worktree remove --force "$wt" >/dev/null 2>&1 || true
done

it "--closed removes a closed change's clean worktree that has submodules"
for id in 070-sub-closed 071-sub-open; do sub_worktree "$id"; done
mkdir -p "$PROJ2/specs/changes"
printf -- '- 2026-11-10 070-sub-closed: x\n' > "$PROJ2/specs/log.md"
printf '# 071-sub-open\n' > "$PROJ2/specs/changes/071-sub-open.md"
git -C "$PROJ2" add specs >/dev/null 2>&1; git -C "$PROJ2" commit -qm 'close' >/dev/null 2>&1
B2="$(git -C "$PROJ2" symbolic-ref --short HEAD)"
git -C "$PROJ2" update-ref "refs/remotes/origin/$B2" HEAD
git -C "$PROJ2" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$B2"
run bash "$CLEAN2" --closed
assert_eq 0 "$STATUS" "swept"
run test ! -d "$PROJ2/.worktrees/070-sub-closed"
assert_eq 0 "$STATUS" "the closed change's worktree removed"
run test -d "$PROJ2/.worktrees/071-sub-open"
assert_eq 0 "$STATUS" "the open change's worktree kept"

finish
