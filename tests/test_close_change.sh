#!/usr/bin/env bash
# A PR-scoped change closes in its own PR with one helper commit after its final passing Review
# line; the merge gate notes a record still at the head, and status and doctor flag a reviewed
# record that reached the default branch without closing. Programme parents stay quiet.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TESTS_DIR/review-fixtures.sh"
source "$TESTS_DIR/lib/states.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
B="$PROJ/.prdkit/scripts/bash"
cd "$PROJ" || exit 1
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n' >> .prdkit/memory/agents.md
receipt_policy "$PROJ"
git add -A >/dev/null; git commit -qm installed >/dev/null
DEFAULT="$(git symbolic-ref --short HEAD)"
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$DEFAULT"
export PRDKIT_TODAY=2026-11-09

record() { # id tier parent, then State lines
    local id="$1" tier="$2" parent="$3"; shift 3
    mkdir -p specs/changes
    {
        printf '# Change: %s\n\n**Opened**: 2026-11-01 · **Parts**: P1 · **Tier**: %s · **Parent**: %s\n\n' "$id" "$tier" "$parent"
        printf '## State\n\n**Step**: review\n**Waiting on**: nothing\n**Next**: merge\n'
        for line in "$@"; do printf '%s\n' "$line"; done
    } > "specs/changes/$id.md"
}
pass_line() { # reviewer from to
    printf '**Receipt fixture**: round 1 · %s..%s · %s · PASS · 0 critical, 0 high, 0 medium, 0 low · https://example.invalid/pr/1#c1\n' "$2" "$3" "$1"
}
branch_with_code() { # id
    git checkout -q -b "$1" "$DEFAULT"
    mkdir -p src; printf '%s\n' "$1" > "src/$1.txt"
    record "$1" T1 none
    git add -A >/dev/null; git commit -qm "$1: code" >/dev/null
}

it "help documents the ambient Git identity and the agent overrides"
receipt_raw_run bash "$B/close-change.sh" --help
assert_eq 0 "$STATUS" "help succeeds without PR arguments"
assert_contains "$OUTPUT" "The closing commit uses the checkout's ambient Git identity."
assert_contains "$OUTPUT" "GIT_AUTHOR_NAME, GIT_AUTHOR_EMAIL, GIT_COMMITTER_NAME and GIT_COMMITTER_EMAIL"

it "one command closes a reviewed change: log entry, record deleted, one commit, gate passes"
branch_with_code 001-greet
START="$(git merge-base HEAD "$DEFAULT")"; REVIEWED="$(git rev-parse HEAD)"
run bash "$B/close-change.sh" 001-greet "warmer greeting — R-01 — #1"
assert_eq 1 "$STATUS" "refuses before a passing Review line is recorded"
assert_contains "$OUTPUT" "publish the remaining verdicts first" "says what is missing"
assert_eq "$REVIEWED" "$(git rev-parse HEAD)" "nothing committed on refusal"
assert_eq '' "$(git status --porcelain)" "nothing staged or written on refusal"
pass_line code "$START" "$REVIEWED" >> specs/changes/001-greet.md
run bash "$B/close-change.sh" 001-greet "warmer greeting — R-01 — #1"
assert_eq 1 "$STATUS" "refuses an uncommitted Review line"
assert_contains "$OUTPUT" "commit the record edits first" "the check reads committed state"
git commit -qam "001-greet: review PASS" >/dev/null
VERDICT="$(git rev-parse HEAD)"
it "generated close states preserve local history and unrelated work"
if receipt_host "$PROJ" 001-greet "$VERDICT"; then
    generated_states close "$PROJ"
else
    _no "could not prepare reviewed change for generated close states"
fi
it "one command closes a reviewed change"
run bash "$B/check-review.sh" 001-greet
assert_eq 0 "$STATUS" "the gate passes with the record still present"
assert_contains "$OUTPUT" "Note: specs/changes/001-greet.md is still at this head" "the gate notes the open record"
run bash "$B/check-review.sh" --json 001-greet
assert_contains "$OUTPUT" '"record_open":true' "JSON names the open record"
echo stray > src/stray.txt; git add src/stray.txt
run bash "$B/close-change.sh" 001-greet "warmer greeting — R-01 — #1"
assert_eq 1 "$STATUS" "refuses with other staged changes"
git rm -q --cached src/stray.txt; rm -f src/stray.txt
outside="$(mktemp -d)"; track_tmp "$outside"
ln -s "$outside" specs/log
run bash "$B/close-change.sh" 001-greet "reviewed"
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'symlinked close path: specs/log'
assert_eq '' "$(ls -A "$outside")" 'log destination untouched'
assert_eq "$VERDICT" "$(git rev-parse HEAD)"
assert_file specs/changes/001-greet.md
rm specs/log
mkdir -p "$outside/specs/log"
# Observe the real successful write: each operation must use its open parent,
# including mkdir. A string-prefix containment check after mkdir is too late.
mkdir "$outside/bin"
cat > "$outside/bin/python3" <<'SH'
#!/usr/bin/env bash
exit 127
SH
export REAL_MKDIR; REAL_MKDIR="$(command -v mkdir)"
cat > "$outside/bin/mkdir" <<'SH'
#!/usr/bin/env bash
if [ "$*" = ./log ] && [ "$(pwd -P)" = "$CLOSE_SPECS" ]; then echo 'anchored mkdir' >&2; fi
exec "$REAL_MKDIR" "$@"
SH
export CLOSE_SPECS="$PROJ/specs"
REAL_LN="$(command -v ln)"; export REAL_LN
cat > "$outside/bin/ln" <<'SH'
#!/usr/bin/env bash
# Publication must use the pinned log as its destination.
if [ "$(pwd -P)" != "$CLOSE_SPECS/log" ] || [ "${2:-}" != . ]; then exit 1; fi
exec "$REAL_LN" "$@"
SH
chmod +x "$outside/bin/python3" "$outside/bin/mkdir" "$outside/bin/ln"
mkdir "$outside/no-links"
cat > "$outside/no-links/ln" <<'SH'
#!/bin/sh
echo 'ln: hard links not supported' >&2
exit 1
SH
chmod +x "$outside/no-links/ln"
run env PATH="$outside/no-links:$PATH" bash "$B/close-change.sh" 001-greet "warmer greeting — R-01 — #1"
assert_eq 1 "$STATUS" 'close refuses without hard links'
assert_contains "$OUTPUT" 'ln: hard links not supported' 'preserves the filesystem diagnostic'
assert_contains "$OUTPUT" 'could not create the hard link for specs/log/001-greet.md; nothing was deleted or committed'
assert_not_contains "$OUTPUT" 'already has an entry'
assert_eq "$VERDICT" "$(git rev-parse HEAD)" 'unsupported hard links leave HEAD unchanged'
run git diff --cached --quiet; assert_eq 0 "$STATUS" 'index unchanged'
run git diff --quiet HEAD -- specs/changes/001-greet.md; assert_eq 0 "$STATUS" 'open record unchanged'
run test ! -e specs/log; assert_eq 0 "$STATUS" 'no log directory or staging files left after refusal'
# Retry the same close with a working ln, without repairing the checkout.
CDPATH="$outside" PATH="$outside/bin:$PATH" run env \
    GIT_AUTHOR_NAME='Close Author' GIT_AUTHOR_EMAIL=close-author@example.com \
    GIT_COMMITTER_NAME='Close Committer' GIT_COMMITTER_EMAIL=close-committer@example.com \
    bash "$B/close-change.sh" 001-greet "warmer greeting — R-01 — #1"
assert_contains "$OUTPUT" 'anchored mkdir'
assert_eq 0 "$STATUS" "closes: $OUTPUT"
assert_contains "$OUTPUT" "PASS 001-greet" "reports the gate at the closed head"
assert_not_contains "$OUTPUT" "Note:" "no open-record note once closed"
assert_eq "$VERDICT" "$(git rev-parse HEAD~1)" "one commit on top of the verdict commit"
assert_eq 'Close Author' "$(git log -1 --format=%an HEAD)" "closing commit author name"
assert_eq 'close-author@example.com' "$(git log -1 --format=%ae HEAD)" "closing commit author email"
assert_eq 'Close Committer' "$(git log -1 --format=%cn HEAD)" "closing commit committer name"
assert_eq 'close-committer@example.com' "$(git log -1 --format=%ce HEAD)" "closing commit committer email"
assert_eq "$(printf 'specs/changes/001-greet.md\nspecs/log/001-greet.md')" "$(git diff --name-only HEAD~1 HEAD)" "the commit holds only the record and its log entry"
assert_eq '- 2026-11-09 001-greet: warmer greeting — R-01 — #1' "$(cat specs/log/001-greet.md)" "the log entry"
assert_eq '' "$(git ls-files specs/log.md)" "no specs/log.md is created"
run bash "$B/close-change.sh" 001-greet "again — #1"
assert_eq 1 "$STATUS" "a closed change cannot close twice"
printf -- '- 2026-11-09 099-other: not reviewed\n' > specs/log/099-other.md
git add specs/log; git commit -qm "another entry after review" >/dev/null
run bash "$B/check-review.sh" 001-greet
assert_eq 1 "$STATUS" "only the change's own entry is exempt from review coverage: $OUTPUT"
git reset -q --hard HEAD~1
git rm -q specs/log/001-greet.md; mkdir -p specs/log/001-greet.md
printf 'echo unreviewed\n' > specs/log/001-greet.md/unreviewed.sh
printf 'x\n' > "specs/log/001-greet.md/- 2026-11-09 001-greet: a name, not a line"
git add -A specs/log; git commit -qm "a directory where the entry goes" >/dev/null
run bash "$B/check-review.sh" 001-greet
assert_eq 1 "$STATUS" "a directory at the entry's path cannot carry unreviewed files past the gate: $OUTPUT"
assert_contains "$OUTPUT" "specs/log/001-greet.md at $(git rev-parse HEAD) is not a regular file" "names the path"
assert_contains "$OUTPUT" "has no '- <date> 001-greet: <what changed>' entry" "a file name is not a log line"
git reset -q --hard HEAD~1
rm specs/log/001-greet.md; ln -s ../../src/001-greet.txt specs/log/001-greet.md
git add -A specs/log; git commit -qm "a symlink where the entry goes" >/dev/null
run bash "$B/check-review.sh" 001-greet
assert_eq 1 "$STATUS" "a symlink is no entry"
assert_contains "$OUTPUT" "is not a regular file" "says why"
git reset -q --hard HEAD~1
printf -- '- 2026-11-09 001-greet: warmer greeting — R-01 — #1\nand a second line\n' > specs/log/001-greet.md
git commit -qam "a second line in the entry" >/dev/null
run bash "$B/check-review.sh" 001-greet
assert_eq 1 "$STATUS" "the entry is one line"
assert_contains "$OUTPUT" "specs/log/001-greet.md at $(git rev-parse HEAD) must hold one line" "says why"
git reset -q --hard HEAD~1
printf -- '- 2026-11-09 001-greet: warmer greeting — R-01 — #1\n\n\n' > specs/log/001-greet.md
git commit -qam "trailing blank lines in the entry" >/dev/null
run bash "$B/check-review.sh" 001-greet
assert_eq 1 "$STATUS" "trailing blank lines are lines too"
assert_contains "$OUTPUT" "must hold one line" "says why"
git reset -q --hard HEAD~1
# A Git without GIT_NO_LAZY_FETCH would fetch a missing object in a partial clone: the log stays unread.
FAKE="$(mktemp -d)"; track_tmp "$FAKE"
# shellcheck disable=SC2016  # the stub's own $1 and $@, expanded when it runs
printf '#!/bin/sh\nif [ "$1" = version ]; then echo "git version 2.39.3"; exit 0; fi\nexec "%s" "$@"\n' "$(command -v git)" > "$FAKE/git"
chmod +x "$FAKE/git"; git config remote.origin.promisor true
run env PATH="$FAKE:$PATH" bash "$B/check-review.sh" 001-greet
git config --unset remote.origin.promisor
assert_eq 1 "$STATUS" "an older Git in a partial clone fails closed"
assert_contains "$OUTPUT" "cannot be read without fetching from the promisor remote" "says why"
run bash "$B/check-review.sh" 001-greet
assert_eq 0 "$STATUS" "the closed head passes again: $OUTPUT"
# The same Git with the record still open: an entry it cannot read is never exempt unread.
git checkout -q -b 001-unread HEAD~1
mkdir -p specs/log; printf 'not a log entry\necho unreviewed\n' > specs/log/001-greet.md
git add specs/log; git commit -qm "an entry beside the open record" >/dev/null
git config remote.origin.promisor true
run env PATH="$FAKE:$PATH" bash "$B/check-review.sh" 001-greet
git config --unset remote.origin.promisor
assert_eq 1 "$STATUS" "an entry that cannot be checked fails closed"
assert_contains "$OUTPUT" "specs/log/001-greet.md at $(git rev-parse HEAD) cannot be checked without fetching" "says why"
run bash "$B/check-review.sh" 001-greet
assert_eq 1 "$STATUS" "with every object at hand it fails on the content"
assert_contains "$OUTPUT" "must hold one line" "says why"
git checkout -q 001-greet; git branch -q -D 001-unread

it "a newest-first log is left as it is; the entry is its own file"
git checkout -q "$DEFAULT"; mkdir -p specs
printf '# Closed changes\n\n- 2026-11-02 000-b: later — #2\n- 2026-11-01 000-a: earlier — #1\n' > specs/log.md
git add specs/log.md; git commit -qm log >/dev/null
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
branch_with_code 002-greet
pass_line code "$(git merge-base HEAD "$DEFAULT")" "$(git rev-parse HEAD)" >> specs/changes/002-greet.md
git commit -qam "002-greet: review PASS" >/dev/null
run bash "$B/close-change.sh" --date 2026-11-03 -m "002-greet: close" 002-greet "warmer — R-01 — #3"
assert_eq 0 "$STATUS" "closes"
assert_eq '' "$(git diff HEAD~1 HEAD -- specs/log.md)" "specs/log.md is untouched"
assert_eq '- 2026-11-03 002-greet: warmer — R-01 — #3' "$(cat specs/log/002-greet.md)" "the entry"
assert_eq '002-greet: close' "$(git log -1 --format=%s)" "custom message"

it "a log text over 300 characters is refused; 300 close"
git checkout -q "$DEFAULT"
printf '# Closed changes\n\n- 2026-11-01 000-a: earlier — #1\n- 2026-11-02 000-b: later — #2\n' > specs/log.md
git add specs/log.md; git commit -qm 'oldest-first log' >/dev/null
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
branch_with_code 014-order
pass_line code "$(git merge-base HEAD "$DEFAULT")" "$(git rev-parse HEAD)" >> specs/changes/014-order.md
git commit -qam "014-order: review PASS" >/dev/null
ORDERED="$(git rev-parse HEAD)"
TEXT="ordered — R-01 — #9 — "; i=22; while [ "$i" -lt 300 ]; do TEXT="${TEXT}é"; i=$((i + 1)); done
assert_eq 300 "$(printf '%s' "$TEXT" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')" "300 characters, many of them two bytes"
run bash "$B/close-change.sh" --date 2026-11-03 014-order "${TEXT}x"
assert_eq 1 "$STATUS" "301 characters are refused"
assert_contains "$OUTPUT" "the log text is 301 characters, over 300" "says the length and the cap"
assert_contains "$OUTPUT" "carried findings and follow-ups go to the parent's row or the spec" "says where the rest goes"
assert_eq "$ORDERED" "$(git rev-parse HEAD)" "nothing committed"
assert_eq '' "$(git status --porcelain)" "nothing written"
run bash "$B/close-change.sh" --date 2026-11-03 014-order "$TEXT"
assert_eq 0 "$STATUS" "300 characters close, counted as characters, not bytes: $OUTPUT"
assert_eq "- 2026-11-03 014-order: $TEXT" "$(cat specs/log/014-order.md)" "the entry"
assert_eq '- 2026-11-01 000-a: earlier — #1' "$(sed -n 3p specs/log.md)" "specs/log.md keeps its entries"

it "an entry that cannot be written stops the close before anything changes"
git checkout -q "$DEFAULT"
printf '# Closed changes\n\n- 2026-11-01 000-d: same day\n- 2026-11-01 000-c: same day\n' > specs/log.md
git add specs/log.md; git commit -qm 'shared log' >/dev/null
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
branch_with_code 013-guard
pass_line code "$(git merge-base HEAD "$DEFAULT")" "$(git rev-parse HEAD)" >> specs/changes/013-guard.md
git commit -qam "013-guard: review PASS" >/dev/null
GUARDED="$(git rev-parse HEAD)"
chmod a-w specs
if ( : > specs/.probe ) 2>/dev/null; then
    rm -f specs/.probe; chmod u+w specs; _ok "skipped: directory permissions are not enforced for this user"
else
    run bash "$B/close-change.sh" 013-guard "guarded — R-01 — #6"
    chmod u+w specs
    assert_eq 1 "$STATUS" "a log that cannot be written is refused"
    assert_contains "$OUTPUT" "could not write specs/log/013-guard.md; nothing was deleted or committed" "says nothing changed"
    assert_eq "$GUARDED" "$(git rev-parse HEAD)" "nothing committed"
    assert_eq '' "$(git status --porcelain)" "record and log untouched"
fi

it "moving the staging directory during publication cannot redirect the entry"
mkdir -p specs/log
mkdir "$outside/collision"
cat > "$outside/collision/ln" <<'SH'
#!/usr/bin/env bash
case "$COLLISION" in
    move)
        for stage in "$CLOSE_SPECS"/log/.close-*; do mv "$stage" "$MOVE_TO/stage" || exit 1; done ;;
    file) echo 'another writer' > "$CLOSE_SPECS/log/013-guard.md" ;;
    fifo) mkfifo "$CLOSE_SPECS/log/013-guard.md" ;;
esac
exec "$REAL_LN" "$@"
SH
chmod +x "$outside/collision/ln"
mkdir "$outside/moved"
run env PATH="$outside/collision:$PATH" COLLISION=move MOVE_TO="$outside/moved" bash "$B/close-change.sh" 013-guard "guarded — R-01 — #6"
assert_eq 1 "$STATUS" 'publication refuses a moved stage'
assert_eq 'stage' "$(ls -A "$outside/moved")" 'no entry published in the new parent'
assert_eq '' "$(ls -A "$outside/moved/stage")" 'staged bytes cleaned from the original private directory'
assert_eq '' "$(ls -A specs/log)" 'nothing published in the log'
assert_eq "$GUARDED" "$(git rev-parse HEAD)" 'HEAD unchanged'
run git diff --cached --quiet; assert_eq 0 "$STATUS" 'index unchanged'
run git diff --quiet HEAD -- specs/changes/013-guard.md; assert_eq 0 "$STATUS" 'open record unchanged'

it "publication preserves another writer's entry, including a FIFO"
for kind in file fifo; do
    run env PATH="$outside/collision:$PATH" COLLISION="$kind" bash "$B/close-change.sh" 013-guard "guarded — R-01 — #6"
    assert_eq 1 "$STATUS" "refuses a concurrent $kind"
    assert_contains "$OUTPUT" 'the log already has an entry for 013-guard'
    assert_not_contains "$OUTPUT" 'Closing requires hard-link support'
    if [ "$kind" = fifo ]; then
        run test -p specs/log/013-guard.md; assert_eq 0 "$STATUS" 'FIFO is still there'
    else
        assert_eq 'another writer' "$(cat specs/log/013-guard.md)" 'preserves the winning entry'
    fi
    rm -f specs/log/013-guard.md
done

it "a failed entry write leaves the change open for an ordinary retry"
printf -- '- 2026-11-01 099-other: elsewhere\n' > specs/log/099-other.md
other_blob="$(git hash-object specs/log/099-other.md)"
cat > "$outside/limit-write" <<'SH'
cat() (
    if [[ $PWD = "$CLOSE_SPECS"/log/.close-* ]]; then
        trap '' XFSZ
        ulimit -f 0 || exit 1
        command cat "$@" || { echo 'limited entry write failed' >&2; exit 1; }
        exit 0
    fi
    command cat "$@"
)
SH
run env BASH_ENV="$outside/limit-write" bash "$B/close-change.sh" --date 2026-11-01 013-guard "guarded — R-01 — #6"
assert_eq 1 "$STATUS" 'the limited write refuses close'
assert_contains "$OUTPUT" 'limited entry write failed'
assert_contains "$OUTPUT" 'could not write specs/log/013-guard.md'
assert_eq "$GUARDED" "$(git rev-parse HEAD)" 'HEAD unchanged'
run git diff --cached --quiet; assert_eq 0 "$STATUS" 'index unchanged'
run git diff --quiet HEAD -- specs/changes/013-guard.md; assert_eq 0 "$STATUS" 'open record unchanged'
assert_eq '099-other.md' "$(ls -A specs/log)" 'no failed entry or staging file blocks retry'
assert_eq "$other_blob" "$(git hash-object specs/log/099-other.md)" 'unrelated entry unchanged'

run bash "$B/close-change.sh" --date 2026-11-01 013-guard "guarded — R-01 — #6"
assert_eq 0 "$STATUS" "closes: $OUTPUT"
assert_eq "$GUARDED" "$(git rev-parse HEAD~1)" 'retry creates one close commit'
assert_eq '- 2026-11-01 013-guard: guarded — R-01 — #6' "$(git show HEAD:specs/log/013-guard.md)" 'retry commits the expected entry'
assert_eq "$other_blob" "$(git hash-object specs/log/099-other.md)" 'retry preserves unrelated entry'
rm specs/log/099-other.md
assert_eq '' "$(git diff HEAD~1 HEAD -- specs/log.md)" "the shared log is untouched"
git checkout -q -b 013-again HEAD~1
mkdir -p specs/log; printf -- '- 2026-11-01 013-guard: elsewhere\n' > specs/log/013-guard.md
run bash "$B/close-change.sh" 013-guard "again — R-01 — #6"
assert_eq 1 "$STATUS" "an entry file already there is refused"
assert_contains "$OUTPUT" "the log already has an entry for 013-guard" "names the change"
rm -rf specs/log; git checkout -q 013-guard; git branch -q -D 013-again
git checkout -q -b 013-logged HEAD~1
printf -- '- 2026-11-01 013-guard: by hand\n' >> specs/log.md; git commit -qam 'hand-written line' >/dev/null
run bash "$B/close-change.sh" 013-guard "again — R-01 — #6"
assert_eq 1 "$STATUS" "a line already in specs/log.md is refused"
assert_contains "$OUTPUT" "the log already has an entry for 013-guard" "names the change"
git checkout -q 013-guard; git branch -q -D 013-logged

it "two branches that each close a change merge without a log conflict"
git checkout -q "$DEFAULT"
BASE_LOG="$(git rev-parse "$DEFAULT:specs/log.md")"
closed_branch() { # id
    branch_with_code "$1"
    pass_line code "$(git merge-base HEAD "$DEFAULT")" "$(git rev-parse HEAD)" >> "specs/changes/$1.md"
    git commit -qam "$1: review PASS" >/dev/null
    run bash "$B/close-change.sh" --date 2026-11-04 "$1" "$1 — R-01 — #$2"
    assert_eq 0 "$STATUS" "$1 closes on its own branch: $OUTPUT"
}
closed_branch 015-left 10
closed_branch 016-right 11
git checkout -q -b merge-both "$DEFAULT"
run git merge --no-ff -m "015-left (#10)" 015-left
assert_eq 0 "$STATUS" "the first merges: $OUTPUT"
run git merge --no-ff -m "016-right (#11)" 016-right
assert_eq 0 "$STATUS" "the second merges without a conflict: $OUTPUT"
assert_eq '- 2026-11-04 015-left: 015-left — R-01 — #10' "$(cat specs/log/015-left.md)" "the first entry"
assert_eq '- 2026-11-04 016-right: 016-right — R-01 — #11' "$(cat specs/log/016-right.md)" "the second entry"
assert_eq "$BASE_LOG" "$(git rev-parse HEAD:specs/log.md)" "specs/log.md is the base's"
git checkout -q -b squash-both "$DEFAULT"
for id in 016-right 015-left; do
    run git merge --squash "$id"
    assert_eq 0 "$STATUS" "a squash of $id applies cleanly, in the other order too: $OUTPUT"
    git commit -qm "$id" >/dev/null
done
assert_eq "$(git rev-parse 'merge-both^{tree}')" "$(git rev-parse 'squash-both^{tree}')" "both styles give the same tree"
# Where the host requires an up-to-date branch: the first lands, the second merges the base.
git checkout -q "$DEFAULT"; git merge -q --squash 015-left >/dev/null; git commit -qm "015-left (#10)" >/dev/null
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
git checkout -q 016-right
run git merge --no-edit "$DEFAULT"
assert_eq 0 "$STATUS" "the second branch takes the base without a conflict: $OUTPUT"
run bash "$B/check-review.sh" 016-right
assert_eq 0 "$STATUS" "and its gate still passes: $OUTPUT"
git checkout -q "$DEFAULT"; run git merge --squash 016-right
assert_eq 0 "$STATUS" "then lands cleanly: $OUTPUT"
git commit -qm "016-right (#11)" >/dev/null; git update-ref "refs/remotes/origin/$DEFAULT" HEAD
run bash "$B/doctor.sh"
assert_not_contains "$OUTPUT" "Closed without" "doctor reads both entries"
assert_not_contains "$OUTPUT" "Malformed log entry" "both entries are well formed"
run bash "$B/status.sh" --json
assert_contains "$OUTPUT" '"closed_since_last":4' "status counts the two entry files with the two lines of specs/log.md toward compaction"
# The same two closes written as lines on top of one log conflict: the entry files are what avoid it.
for id in 017-a 018-b; do
    git checkout -q -b "$id" "$DEFAULT"
    awk -v line="- 2026-11-05 $id: on top — #1" '!done && /^- / { print line; done = 1 } { print }' specs/log.md > specs/log.tmp
    mv specs/log.tmp specs/log.md; git commit -qam "$id" >/dev/null
done
git checkout -q -b merge-lines 017-a
run git merge --no-edit 018-b
assert_eq 1 "$STATUS" "two lines on top of specs/log.md conflict"
git merge --abort; git checkout -q "$DEFAULT"; git branch -q -D merge-both squash-both merge-lines 017-a 018-b

it "a T3 owner verdict on the reviewed head still passes after the record-only close"
branch_with_code 003-owner
sed -i.bak 's/Tier\*\*: T1/Tier**: T3/' specs/changes/003-owner.md; rm -f specs/changes/003-owner.md.bak
git commit -qam "003-owner: T3" >/dev/null
START="$(git merge-base HEAD "$DEFAULT")"; REVIEWED="$(git rev-parse HEAD)"
pass_line code "$START" "$REVIEWED" >> specs/changes/003-owner.md
printf '**Receipt fixture**: round 1 · %s..%s · owner · PASS · https://example.invalid/pr/3#approval\n' "$START" "$REVIEWED" >> specs/changes/003-owner.md
git commit -qam "003-owner: verdicts" >/dev/null
run bash "$B/close-change.sh" 003-owner "owner-shaped — R-01 — #4"
assert_eq 0 "$STATUS" "owner approval of the reviewed head survives the closing commit: $OUTPUT"

it "close carries header tags to the same one-line log entry"
branch_with_code 019-tagged
sed -i.bak 's/ · \*\*Tier\*\*/ · **Tags**: cleanup, small batch, _literal_, www.example.test · **Tier**/' specs/changes/019-tagged.md
rm specs/changes/019-tagged.md.bak
git commit -qam "019-tagged: tags" >/dev/null
pass_line code "$(git merge-base HEAD "$DEFAULT")" "$(git rev-parse HEAD)" >> specs/changes/019-tagged.md
printf '\n## Notes\n**Tags**: not header metadata\n' >> specs/changes/019-tagged.md
git commit -qam "019-tagged: review PASS" >/dev/null
run bash "$B/close-change.sh" 019-tagged "tagged — R-01 — #19 · **Tags**: caller text"
assert_eq 1 "$STATUS" "the description cannot supply a tag suffix"
assert_contains "$OUTPUT" "omit **Tags** from the description"
# Continue independently if the old implementation accepted the caller's suffix.
if [ ! -f specs/changes/019-tagged.md ]; then git checkout -qb 019-retry HEAD~1 || exit 1; fi
run bash "$B/close-change.sh" 019-tagged "tagged — R-01 — #19"
assert_eq 0 "$STATUS" "tags do not change acceptance or review: $OUTPUT"
assert_eq '- 2026-11-09 019-tagged: tagged — R-01 — #19 · **Tags**: cleanup, small batch, \_literal\_, www\.example.test' \
    "$(git show HEAD:specs/log/019-tagged.md)" "only header tags are preserved"

it "close refuses tags containing Markdown or HTML before writing"
branch_with_code 020-markup
awk 'NR == 2 { print "**Tags**: [runbook](https://example.test/docs), <br>, <!-- note -->" } { print }' \
    specs/changes/020-markup.md > specs/changes/020.tmp
mv specs/changes/020.tmp specs/changes/020-markup.md
git commit -qam "020-markup: tags" >/dev/null
pass_line code "$(git merge-base HEAD "$DEFAULT")" "$(git rev-parse HEAD)" >> specs/changes/020-markup.md
git commit -qam "020-markup: review PASS" >/dev/null
TAG_HEAD="$(git rev-parse HEAD)"
run bash "$B/close-change.sh" 020-markup "markup — R-01 — #20"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "Malformed Tags"
assert_eq "$TAG_HEAD" "$(git rev-parse HEAD)" "refusal leaves HEAD unchanged"
assert_file specs/changes/020-markup.md
run test ! -e specs/log/020-markup.md
assert_eq 0 "$STATUS" "no log entry written"

it "status and doctor flag merged-open records including T0 and unreviewed ones; parents stay quiet"
branch_with_code 004-left; pass_line code "$(git merge-base HEAD "$DEFAULT")" "$(git rev-parse HEAD)" >> specs/changes/004-left.md
git commit -qam "004-left: review PASS" >/dev/null
git checkout -q "$DEFAULT"; git merge -q --squash 004-left >/dev/null; git commit -qm "004-left (#5)" >/dev/null
record 005-programme T2 none "$(pass_line code "$START" "$REVIEWED")" '### Outcome checkpoint' '**Outcome**: owner goal' '**Progress limit**: 3'
record 006-parent T2 none "$(pass_line code "$START" "$REVIEWED")"
record 007-child T1 006-parent
record 008-planned T1 none
record 010-tzero T0 none
record 012-prog T2 none "$(pass_line code "$START" "$REVIEWED")"
record 011-child T1 "\`012-prog\`"
git add -A >/dev/null; git commit -qm "records on the default branch" >/dev/null
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
run bash "$B/status.sh"
assert_contains "$OUTPUT" "merged without closing: record on origin/$DEFAULT" "status flags the left record"
assert_eq 5 "$(printf '%s\n' "$OUTPUT" | grep -c 'merged without closing')" "all leaf records, including T0 and unreviewed ones; parents and checkpoints are quiet"
run bash "$B/status.sh" --json
assert_contains "$OUTPUT" '"id":"004-left","title":"004-left"' "JSON row"
assert_contains "$OUTPUT" '"merged_unclosed":true' "JSON flag"
run bash "$B/doctor.sh"
assert_contains "$OUTPUT" "advisory: Merged without closing: 004-left, 007-child, 008-planned, 010-tzero, 011-child records" "doctor advises for all leaf records"
assert_not_contains "$OUTPUT" "005-programme" "a programme with a checkpoint is quiet"
assert_not_contains "$OUTPUT" "006-parent" "a parent named by a child is quiet"
git checkout -q -b 009-next
run bash "$B/close-change.sh" 004-left "left open — R-01 — #5"
assert_eq 1 "$STATUS" "the helper refuses a record already merged"
assert_contains "$OUTPUT" "closes inside the next relevant PR" "and names the remedy"
run bash "$B/close-change.sh" 010-tzero "unreviewed — #7"
assert_eq 1 "$STATUS" "a merged T0 record is refused too, before check-review could pass it"
assert_contains "$OUTPUT" "is already on origin/$DEFAULT" "the default-branch refusal comes first"

it "closing the left record removes only its advisory, not other open leaves"
git rm -q specs/changes/004-left.md
mkdir -p specs/log
printf -- '- 2026-11-09 004-left: left open — R-01 — #5; closed in #8\n' > specs/log/004-left.md
git add specs/log; git commit -qm "close 004-left in the next PR" >/dev/null
run bash "$B/doctor.sh"
assert_not_contains "$OUTPUT" "004-left" "doctor reads the checkout, not only the default branch"
assert_contains "$OUTPUT" 'Merged without closing: 007-child, 008-planned, 010-tzero, 011-child records' 'other open leaves remain'
run bash "$B/status.sh"
assert_eq 4 "$(printf '%s\n' "$OUTPUT" | grep -c 'merged without closing')" "status agrees that only one record closed"
finish
