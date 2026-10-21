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
assert_contains "$OUTPUT" "uncommitted or unintegrated" "explains the refusal"
run test -d "$PROJ/.worktrees/011-dirty"
assert_eq 0 "$STATUS" "dirty worktree left intact"

it "--force removes a worktree with uncommitted work"
run bash "$CLEAN" --force 011-dirty
assert_eq 0 "$STATUS" "force removes dirty worktree"
run test ! -d "$PROJ/.worktrees/011-dirty"
assert_eq 0 "$STATUS" "dirty worktree gone after --force"

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
run bash "$CLEAN" --json 016-evidence
assert_eq 0 "$STATUS" "worktree removed"
assert_contains "$OUTPUT" "preserved 3 evidence file(s)" "preservation reported"
assert_eq "Verdict: PASS" "$(cat "$PROJ/.prdkit/cache/evidence/016-evidence/reviews/round-1/report.md" 2>/dev/null)" "review report kept"
assert_eq "lessons" "$(cat "$PROJ/.prdkit/cache/retrospectives/016-evidence.md" 2>/dev/null)" "retrospective kept"

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

finish
