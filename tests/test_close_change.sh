#!/usr/bin/env bash
# A PR-scoped change closes in its own PR with one helper commit after its final passing Review
# line; the merge gate notes a record still at the head, and status and doctor flag a reviewed
# record that reached the default branch without closing. Programme parents stay quiet.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
B="$PROJ/.prdkit/scripts/bash"
cd "$PROJ" || exit 1
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n' >> .prdkit/memory/agents.md
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
        printf '## State\n\n**Step**: review\n**Next**: merge\n'
        for line in "$@"; do printf '%s\n' "$line"; done
    } > "specs/changes/$id.md"
}
pass_line() { # reviewer from to
    printf '**Review**: round 1 · %s..%s · %s · PASS · 0 critical, 0 high, 0 medium, 0 low · https://example.invalid/pr/1#c1\n' "$2" "$3" "$1"
}
branch_with_code() { # id
    git checkout -q -b "$1" "$DEFAULT"
    mkdir -p src; printf '%s\n' "$1" > "src/$1.txt"
    record "$1" T1 none
    git add -A >/dev/null; git commit -qm "$1: code" >/dev/null
}

it "one command closes a reviewed change: log line, record deleted, one commit, gate passes"
branch_with_code 001-greet
START="$(git merge-base HEAD "$DEFAULT")"; REVIEWED="$(git rev-parse HEAD)"
run bash "$B/close-change.sh" 001-greet "warmer greeting — R-01 — #1"
assert_eq 1 "$STATUS" "refuses before a passing Review line is recorded"
assert_contains "$OUTPUT" "commit the final passing Review line first" "says what is missing"
assert_eq "$REVIEWED" "$(git rev-parse HEAD)" "nothing committed on refusal"
assert_eq '' "$(git status --porcelain)" "nothing staged or written on refusal"
pass_line code "$START" "$REVIEWED" >> specs/changes/001-greet.md
run bash "$B/close-change.sh" 001-greet "warmer greeting — R-01 — #1"
assert_eq 1 "$STATUS" "refuses an uncommitted Review line"
assert_contains "$OUTPUT" "commit the final Review line first" "the check reads committed state"
git commit -qam "001-greet: review PASS" >/dev/null
VERDICT="$(git rev-parse HEAD)"
run bash "$B/check-review.sh" 001-greet
assert_eq 0 "$STATUS" "the gate passes with the record still present"
assert_contains "$OUTPUT" "Note: specs/changes/001-greet.md is still at this head" "the gate notes the open record"
run bash "$B/check-review.sh" --json 001-greet
assert_contains "$OUTPUT" '"record_open":true' "JSON names the open record"
echo stray > src/stray.txt; git add src/stray.txt
run bash "$B/close-change.sh" 001-greet "warmer greeting — R-01 — #1"
assert_eq 1 "$STATUS" "refuses with other staged changes"
git rm -q --cached src/stray.txt; rm -f src/stray.txt
run bash "$B/close-change.sh" 001-greet "warmer greeting — R-01 — #1"
assert_eq 0 "$STATUS" "closes: $OUTPUT"
assert_contains "$OUTPUT" "PASS 001-greet" "reports the gate at the closed head"
assert_not_contains "$OUTPUT" "Note:" "no open-record note once closed"
assert_eq "$VERDICT" "$(git rev-parse HEAD~1)" "one commit on top of the verdict commit"
assert_eq "$(printf 'specs/changes/001-greet.md\nspecs/log.md')" "$(git diff --name-only HEAD~1 HEAD)" "the commit holds only the record and the log"
assert_eq '- 2026-11-09 001-greet: warmer greeting — R-01 — #1' "$(cat specs/log.md)" "the log line"
run bash "$B/close-change.sh" 001-greet "again — #1"
assert_eq 1 "$STATUS" "a closed change cannot close twice"

it "a log listing the newest change first gets the line on top"
git checkout -q "$DEFAULT"; mkdir -p specs
printf '# Closed changes\n\n- 2026-11-02 000-b: later — #2\n- 2026-11-01 000-a: earlier — #1\n' > specs/log.md
git add specs/log.md; git commit -qm log >/dev/null
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
branch_with_code 002-greet
pass_line code "$(git merge-base HEAD "$DEFAULT")" "$(git rev-parse HEAD)" >> specs/changes/002-greet.md
git commit -qam "002-greet: review PASS" >/dev/null
run bash "$B/close-change.sh" --date 2026-11-03 -m "002-greet: close" 002-greet "warmer — R-01 — #3"
assert_eq 0 "$STATUS" "closes"
assert_eq '- 2026-11-03 002-greet: warmer — R-01 — #3' "$(sed -n 3p specs/log.md)" "first entry"
assert_eq '002-greet: close' "$(git log -1 --format=%s)" "custom message"

it "a T3 owner verdict on the reviewed head still passes after the record-only close"
branch_with_code 003-owner
sed -i.bak 's/Tier\*\*: T1/Tier**: T3/' specs/changes/003-owner.md; rm -f specs/changes/003-owner.md.bak
git commit -qam "003-owner: T3" >/dev/null
START="$(git merge-base HEAD "$DEFAULT")"; REVIEWED="$(git rev-parse HEAD)"
pass_line code "$START" "$REVIEWED" >> specs/changes/003-owner.md
printf '**Review**: round 1 · %s..%s · owner · PASS · https://example.invalid/pr/3#approval\n' "$START" "$REVIEWED" >> specs/changes/003-owner.md
git commit -qam "003-owner: verdicts" >/dev/null
run bash "$B/close-change.sh" 003-owner "owner-shaped — R-01 — #4"
assert_eq 0 "$STATUS" "owner approval of the reviewed head survives the closing commit: $OUTPUT"

it "status and doctor flag a reviewed record that merged without closing; parents stay quiet"
branch_with_code 004-left; pass_line code "$(git merge-base HEAD "$DEFAULT")" "$(git rev-parse HEAD)" >> specs/changes/004-left.md
git commit -qam "004-left: review PASS" >/dev/null
git checkout -q "$DEFAULT"; git merge -q --squash 004-left >/dev/null; git commit -qm "004-left (#5)" >/dev/null
record 005-programme T2 none "$(pass_line code "$START" "$REVIEWED")" '### Outcome checkpoint' '**Outcome**: owner goal' '**Progress limit**: 3'
record 006-parent T2 none "$(pass_line code "$START" "$REVIEWED")"
record 007-child T1 006-parent
record 008-planned T1 none
git add -A >/dev/null; git commit -qm "records on the default branch" >/dev/null
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
run bash "$B/status.sh"
assert_contains "$OUTPUT" "merged without closing: reviewed and on origin/$DEFAULT" "status flags the left record"
assert_eq 1 "$(printf '%s\n' "$OUTPUT" | grep -c 'merged without closing')" "only that record: parents, children and unreviewed records are quiet"
run bash "$B/status.sh" --json
assert_contains "$OUTPUT" '"id":"004-left","title":"004-left"' "JSON row"
assert_contains "$OUTPUT" '"merged_unclosed":true' "JSON flag"
run bash "$B/doctor.sh"
assert_contains "$OUTPUT" "advisory: Merged without closing: 004-left passed review" "doctor advises"
assert_not_contains "$OUTPUT" "005-programme passed" "a programme with a checkpoint is quiet"
assert_not_contains "$OUTPUT" "006-parent" "a parent named by a child is quiet"
git checkout -q -b 009-next
run bash "$B/close-change.sh" 004-left "left open — R-01 — #5"
assert_eq 1 "$STATUS" "the helper refuses a record already merged"
assert_contains "$OUTPUT" "closes inside the next relevant PR" "and names the remedy"
finish
