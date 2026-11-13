#!/usr/bin/env bash
# Content fingerprints: a verdict binds the change's content (its delta from where it leaves the
# trusted base, outside its record and log), never commit ancestry. It survives record-only
# commits, reverted edits, non-overlapping base merges, rebases and squashes; it lapses on a real
# fix, an overlapping base merge, or a binary, mode or link change. record-review.sh writes every
# line here; check-review.sh only reads them.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
cd "$PROJ" || exit 1
CHECK="$PROJ/.prdkit/scripts/bash/check-review.sh"
RECORD="$PROJ/.prdkit/scripts/bash/record-review.sh"
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n| security | reviewer |\n| design | reviewer |\n' >> .prdkit/memory/agents.md
mkdir -p src assets specs
i=1; while [ "$i" -le 30 ]; do echo "line $i"; i=$((i + 1)); done > src/app.txt
printf 'notes\n' > src/other.txt
printf 'a\nb\nc\nDENY\nd\ne\nf\na\nb\nc\nDENY\nd\ne\nf\n' > src/policy.txt
i=1; while [ "$i" -le 10 ]; do echo "step $i"; i=$((i + 1)); done > src/tool.sh
printf 'bin\000one\n' > assets/blob.bin
printf '# Product\n\nThe product.\n' > specs/product.md
git add -A >/dev/null; git commit -qm installed >/dev/null
DEFAULT="$(git symbolic-ref --short HEAD)"
TRUSTED="refs/remotes/origin/$DEFAULT"
git update-ref "$TRUSTED" HEAD
git symbolic-ref refs/remotes/origin/HEAD "$TRUSTED"
TIP="$(git rev-parse HEAD)"
LINK=https://example.invalid/pr/1#c1

set_line() { # file line text: replace one line in the working tree
    awk -v n="$2" -v t="$3" 'NR == n { print t; next } { print }' "$1" > "$1.next" && mv "$1.next" "$1"
}
base_line() { # file line text: the trusted base gains a commit that replaces one line
    git show "$TRUSTED:$1" | awk -v n="$2" -v t="$3" 'NR == n { print t; next } { print }' | trusted_edit "$TRUSTED" "$1"
}
begin() { # id [tier]: a fresh change from the original base: line 15 edited, then its record
    ID="$1"
    git update-ref "$TRUSTED" "$TIP"
    git checkout -q -b "$ID" "$TIP"
    set_line src/app.txt 15 'line fifteen, changed'
    git commit -qam "$ID: change" >/dev/null
    mkdir -p specs/changes
    printf '# Change: %s\n\n**Tier**: %s\n\n## State\n\n**Step**: review\n' "$ID" "${2:-T2}" > "specs/changes/$ID.md"
    git add specs/changes; git commit -qm "$ID: record" >/dev/null
}
rec() { # record-review.sh arguments after the id; commits the record when it succeeds
    run bash "$RECORD" "$ID" --link "$LINK" "$@"
    [ "$STATUS" -ne 0 ] || git commit -qam "review line" >/dev/null
}
pass() { rec --reviewer "$1" --verdict PASS --counts 0,0,0,0 --head "${2:-HEAD}" ${3:+--since "$3"}; }
fail() { rec --reviewer "$1" --verdict FAIL --counts 0,1,0,0 --head "${2:-HEAD}" ${3:+--since "$3"}; }
check() { run bash "$CHECK" "$ID"; }
last_to() { # the to fingerprint of the record's last Review line
    grep '^\*\*Review\*\*:' "specs/changes/$ID.md" | tail -n 1 | awk -F ' · ' '{ sub(/^.*\.\./, "", $2); print $2 }'
}
shown() { local hex="${1#fp1:}"; printf '%s…' "${hex:0:12}"; }
json_fp() { run bash "$CHECK" --json "$ID"; printf '%s' "$OUTPUT" | sed -n 's/.*"fingerprint":"\([^"]*\)".*/\1/p'; }
done_with() { git checkout -q "$DEFAULT"; git update-ref "$TRUSTED" "$TIP"; }

it "record-review.sh writes the line and the v2 receipt; nobody types a fingerprint"
begin 001-write
F1="$(git rev-parse HEAD)"
run bash "$RECORD" "$ID" --reviewer code --verdict pass --counts 0,0,01,2 --head HEAD --link "$LINK"
assert_eq 0 "$STATUS" "records: $OUTPUT"
TO="$(last_to)"
assert_eq "**Review**: round 1 · start..$TO · code · PASS · 0 critical, 0 high, 1 medium, 2 low · $LINK
<!-- prdkit-review
{\"schema\":\"prdkit.review.v2\",\"reviewer\":\"code\",\"from\":\"start\",\"to\":\"$TO\",\"head\":\"$F1\",\"verdict\":\"PASS\",\"critical\":0,\"high\":0,\"medium\":1,\"low\":2}
-->" "$OUTPUT" "prints the exact line and receipt"
assert_contains "$TO" "fp1:" "the end is a content fingerprint"
assert_eq "$(sed -n '$p' "specs/changes/$ID.md")" "**Review**: round 1 · start..$TO · code · PASS · 0 critical, 0 high, 1 medium, 2 low · $LINK" "appended to State"
assert_eq "$TO" "$(json_fp)" "check-review.sh computes the same fingerprint for the head"
git commit -qam "review line" >/dev/null
check
assert_eq 0 "$STATUS" "the verdict covers the head: $OUTPUT"
pass code
assert_contains "$(sed -n '$p' "specs/changes/$ID.md")" "**Review**: round 2 · start..$TO · code" "the round counts the reviewer's earlier lines"
done_with

it "record-review.sh refuses an untrusted base, an unchanged --since, a missing State, bad input"
begin 002-refuse
git branch -q wip HEAD
run bash "$RECORD" "$ID" --reviewer code --verdict PASS --counts 0,0,0,0 --head HEAD --link "$LINK" --base wip
assert_eq 1 "$STATUS" "an untrusted base is refused"
assert_eq "record-review.sh: --base wip is not a trusted integration branch (origin/HEAD's target, or one named by review-integration-branches in its committed config); pass the branch this change merges into" "$OUTPUT" "says why"
git branch -q -D wip
REC_COMMIT="$(git rev-parse HEAD)"
run bash "$RECORD" "$ID" --reviewer code --verdict PASS --counts 0,0,0,0 --head HEAD --link "$LINK" --since HEAD~1
assert_eq 1 "$STATUS" "a --since with the same content is refused"
assert_eq "record-review.sh: nothing changed since --since HEAD~1; no round needed" "$OUTPUT" "says why"
run bash "$RECORD" "$ID" --reviewer owner --verdict PASS --head HEAD --link "$LINK" --since HEAD~1
assert_eq 1 "$STATUS" "the owner takes no --since"
run bash "$RECORD" "$ID" --reviewer code --verdict PASS --head HEAD --link "$LINK"
assert_eq "record-review.sh: --counts is required: the reviewer's <critical>,<high>,<medium>,<low> findings" "$OUTPUT" "counts required"
run bash "$RECORD" "$ID" --reviewer code --verdict PASS --counts 0,0,0,0 --head HEAD --link "https://example.invalid/a · b"
assert_eq "record-review.sh: the link must be one field: no ' · ' and no line break" "$OUTPUT" "the link stays one field"
run bash "$RECORD" "$ID" --reviewer Code --verdict PASS --counts 0,0,0,0 --head HEAD --link "$LINK"
assert_eq 1 "$STATUS" "an identity is lowercase"
printf '# Change: no state\n\n**Tier**: T2\n' > "specs/changes/$ID.md"
run bash "$RECORD" "$ID" --reviewer code --verdict PASS --counts 0,0,0,0 --head HEAD --link "$LINK"
assert_eq 1 "$STATUS" "a record without State is refused"
assert_eq "record-review.sh: specs/changes/$ID.md needs exactly one '## State' section to record into (found 0)" "$OUTPUT" "says why"
assert_eq "$REC_COMMIT" "$(git rev-parse HEAD)" "nothing is committed"
git checkout -q -- "specs/changes/$ID.md"
# shellcheck disable=SC2016 # a literal Markdown fence, not command substitution
printf '\n```text\n## State\n**Review**: round 1 · start..x · code · PASS · example\n```\n' >> "specs/changes/$ID.md"
pass code
assert_eq 0 "$STATUS" "a fenced example neither counts as a section nor as a round: $OUTPUT"
assert_contains "$(grep -n '^\*\*Review\*\*: round 1 · start..fp1' "specs/changes/$ID.md")" "8:" "the line lands after **Step**, before the fence"
done_with

it "record-only commits and the log keep the verdict"
begin 003-record
pass code
printf '\nMore context after review.\n' >> "specs/changes/$ID.md"; git commit -qam "record note" >/dev/null
mkdir -p specs/log; printf -- '- 2026-11-01 %s: done\n' "$ID" > "specs/log/$ID.md"; git add specs/log; git commit -qm log >/dev/null
check
assert_eq 0 "$STATUS" "record and log edits keep the verdict: $OUTPUT"
done_with

it "an edit and its revert keep the verdict, also across a non-overlapping base merge (#86)"
begin 004-revert
pass code
set_line src/app.txt 15 'line fifteen, tried'; git commit -qam try >/dev/null
git revert --no-edit HEAD >/dev/null
check
assert_eq 0 "$STATUS" "edit plus revert: $OUTPUT"
base_line src/other.txt 1 'base notes'
git merge -q --no-edit "$TRUSTED" >/dev/null
check
assert_eq 0 "$STATUS" "then a base merge editing another file: $OUTPUT"
done_with

it "a narrow range may start at a record-only commit (#66)"
begin 005-narrow
fail code
RECORDED="$(git rev-parse HEAD)"
set_line src/app.txt 16 'line sixteen, fixed'; git commit -qam fix >/dev/null
pass code HEAD "$RECORDED"
assert_contains "$(sed -n '$p' "specs/changes/$ID.md")" "round 2 · fp1:" "the range starts at the record commit's content"
check
assert_eq 0 "$STATUS" "the FAIL is resolved through the reviewer's own step: $OUTPUT"
done_with

it "a base merge elsewhere in the same file keeps the verdict; one within the hunk or its context voids it"
begin 006-same-file
pass code
REVIEWED_TO="$(last_to)"
base_line src/app.txt 25 'base twenty-five'
git merge -q --no-edit "$TRUSTED" >/dev/null
check
assert_eq 0 "$STATUS" "an edit 10 lines away keeps the verdict: $OUTPUT"
base_line src/app.txt 18 'base eighteen'
git merge -q --no-edit "$TRUSTED" >/dev/null
assert_eq 'base eighteen' "$(sed -n 18p src/app.txt)" "the merge is clean"
HEAD_FP="$(json_fp)"
check
assert_eq 1 "$STATUS" "an edit to a context line the reviewer saw voids it"
assert_contains "$OUTPUT" "code (round 1): changed since the reviewed content $(shown "$REVIEWED_TO"): no recorded verdict carries it to this head's content ($(shown "$HEAD_FP"))" "exact message"
pass code HEAD HEAD~1
check
assert_eq 0 "$STATUS" "a narrow round over the merge restores it: $OUTPUT"
done_with

it "a conflict resolved by choosing the reviewed version voids the verdict"
begin 007-conflict
pass code
base_line src/app.txt 15 'line fifteen, base'
run git merge --no-edit "$TRUSTED"
assert_eq 1 "$STATUS" "the merge conflicts"
git checkout -q --ours src/app.txt; git add src/app.txt; git commit -qm "keep the reviewed line" --no-edit >/dev/null
assert_eq 'line fifteen, changed' "$(sed -n 15p src/app.txt)" "the reviewed bytes are kept"
check
assert_eq 1 "$STATUS" "the hunk now replaces the base's line, not the line reviewed"
assert_contains "$OUTPUT" "code (round 1): changed since the reviewed content" "names the reviewer"
done_with

it "a rebase onto a newer base and a squash keep the verdict"
begin 008-rebase
pass code
pass security
base_line src/other.txt 1 'base notes'
git rebase -q "$TRUSTED" >/dev/null 2>&1
assert_eq "$(git rev-parse "$TRUSTED")" "$(git merge-base HEAD "$TRUSTED")" "rebased"
check
assert_eq 0 "$STATUS" "rebase: $OUTPUT"
git reset -q --soft "$TRUSTED"; git commit -qm "$ID (squashed)" >/dev/null
check
assert_eq 0 "$STATUS" "squash: $OUTPUT"
done_with

it "a real fix voids the verdict"
begin 009-fix
pass code
set_line src/app.txt 15 'line fifteen, changed again'; git commit -qam fix >/dev/null
check
assert_eq 1 "$STATUS" "fails"
assert_contains "$OUTPUT" "code (round 1): changed since the reviewed content" "names the reviewer"
done_with

it "a failing reviewer's narrow verdict on the fix carries the other approvals"
begin 010-carry
pass security; F1="$(git rev-parse HEAD)"
fail code
set_line src/app.txt 16 'line sixteen, fixed'; git commit -qam fix >/dev/null
pass code HEAD "$F1"
check
assert_eq 0 "$STATUS" "security PASS start..F1, code FAIL start..F1, code PASS F1..F2: $OUTPUT"
done_with

it "a FAIL stands after a rebase and after reverting to earlier content"
begin 011-stands
pass security
fail code
FAILED_TO="$(last_to)"
base_line src/other.txt 1 'base notes'
git rebase -q "$TRUSTED" >/dev/null 2>&1
check
assert_eq 1 "$STATUS" "a rebase does not clear it"
assert_contains "$OUTPUT" "code (round 1): its FAIL at $(shown "$FAILED_TO") stands: no later clean PASS from code reaches that content" "exact message"
pass code; F2="$(git rev-parse HEAD)"
set_line src/app.txt 16 'line sixteen, tried'; git commit -qam try >/dev/null
fail code HEAD "$F2"
git revert --no-edit HEAD~1 >/dev/null
check
assert_eq 1 "$STATUS" "returning to approved content does not clear a later FAIL"
assert_contains "$OUTPUT" "code (round 3): verdict FAIL, not PASS" "the FAIL is the latest"
assert_contains "$OUTPUT" "code (round 3): its FAIL at" "and stands"
done_with

it "binary, mode and link changes after review void the verdict"
begin 012-binary
printf 'bin\000two\n' > assets/blob.bin; git commit -qam "binary" >/dev/null
pass code
printf 'bin\000three\n' > assets/blob.bin; git commit -qam "binary again" >/dev/null
check
assert_eq 1 "$STATUS" "a binary change voids"
git reset -q --hard HEAD~1
git update-index --chmod=+x src/app.txt; git commit -qm "mode only" >/dev/null
check
assert_eq 1 "$STATUS" "a mode-only change voids"
git reset -q --hard HEAD~1
ln -s app.txt src/link.txt; git add src/link.txt; git commit -qm link >/dev/null
check
assert_eq 1 "$STATUS" "a symbolic link voids"
done_with

it "worktree and repository attributes do not change the fingerprint"
begin 013-attributes
printf 'text with\ttabs\r\nand CRLF\r\n' > src/crlf.txt; git add src/crlf.txt; git commit -qm crlf >/dev/null
PLAIN="$(json_fp)"
for attrs in '* diff' '* -diff' '* binary' '* text eol=crlf' '* diff=nonesuch'; do
    printf '%s\n' "$attrs" > .gitattributes
    printf '%s\n' "$attrs" > .git/info/attributes
    assert_eq "$PLAIN" "$(json_fp)" "attributes [$attrs] leave it unchanged"
done
rm -f .gitattributes .git/info/attributes
done_with

it "a criss-cross merge base fails closed"
begin 014-criss
C1="$(git rev-parse HEAD~1)"
base_line src/other.txt 1 'base notes'; B1="$(git rev-parse "$TRUSTED")"
git merge -q --no-edit "$TRUSTED" >/dev/null
git update-ref "$TRUSTED" "$(git commit-tree "$(git rev-parse "$B1^{tree}")" -p "$B1" -p "$C1" -m 'the base merges the branch')"
assert_eq 2 "$(git merge-base --all HEAD "$TRUSTED" | wc -l | tr -d ' ')" "two merge bases"
run bash "$RECORD" "$ID" --reviewer code --verdict PASS --counts 0,0,0,0 --head HEAD --link "$LINK"
assert_eq 1 "$STATUS" "record-review.sh refuses"
assert_contains "$OUTPUT" "have more than one merge base (a criss-cross history), so the change's start is ambiguous; merge origin/$DEFAULT into the branch again to give it one" "says why"
check
assert_eq 1 "$STATUS" "check-review.sh fails"
assert_contains "$OUTPUT" "This head's content cannot be fingerprinted against origin/$DEFAULT: $(git rev-parse HEAD | cut -c1-12) and origin/$DEFAULT have more than one merge base" "says why"
done_with

it "legacy range lines still pass; one whose commit is gone fails closed"
begin 015-legacy
START="$(git rev-parse --short "$TIP")"; REVIEWED="$(git rev-parse --short HEAD~1)"
printf '**Review**: round 1 · %s..%s · code · PASS · 0 critical, 0 high, 0 medium, 0 low · %s\n' "$START" "$REVIEWED" "$LINK" >> "specs/changes/$ID.md"
git commit -qam legacy >/dev/null
check
assert_eq 0 "$STATUS" "a commit range is read by its commits' content: $OUTPUT"
base_line src/other.txt 1 'base notes'
git rebase -q "$TRUSTED" >/dev/null 2>&1
check
assert_eq 0 "$STATUS" "and survives a rebase while its commits are here: $OUTPUT"
set_line src/app.txt 15 'line fifteen, changed again'; git commit -qam fix >/dev/null
check
assert_contains "$OUTPUT" "code (round 1): changed since the reviewed head $REVIEWED: src/app.txt" "a later fix names the path"
git reset -q --hard HEAD~1
sed "s/$REVIEWED/0123456789abcdef0123456789abcdef01234567/" "specs/changes/$ID.md" > .git/rec && cp .git/rec "specs/changes/$ID.md"
git commit -qam gone >/dev/null
check
assert_eq 1 "$STATUS" "fails closed"
assert_contains "$OUTPUT" "code (round 1): commit 0123456789abcdef0123456789abcdef01234567 is not here: a range recorded before content fingerprints needs its commits; fetch them or record a new verdict with record-review.sh" "exact message"
done_with

it "the owner's approval survives a code fix and a rebase, and lapses on an L0 edit"
begin 016-owner T3
printf '# Product\n\nThe product, refined.\n' > specs/product.md; git commit -qam "L0 edit" >/dev/null
pass design
rec --reviewer owner --verdict PASS --head HEAD
assert_eq 0 "$STATUS" "the owner's line records without counts: $OUTPUT"
assert_contains "$OUTPUT" "· owner · PASS · $LINK" "no counts on the line"
assert_contains "$OUTPUT" '"verdict":"PASS"}' "no counts in the receipt"
OWNER_TO="$(last_to)"
check
assert_eq 0 "$STATUS" "T3 passes: $OUTPUT"
F1="$(git rev-parse HEAD)"
set_line src/app.txt 16 'line sixteen, fixed'; git commit -qam "code fix" >/dev/null
pass design HEAD "$F1"
check
assert_eq 0 "$STATUS" "a code fix keeps the owner's approval: $OUTPUT"
base_line src/other.txt 1 'base notes'
git rebase -q "$TRUSTED" >/dev/null 2>&1
check
assert_eq 0 "$STATUS" "so does a rebase: $OUTPUT"
F2="$(git rev-parse HEAD)"
printf '# Product\n\nThe product, refined again.\n' > specs/product.md; git commit -qam "another L0 edit" >/dev/null
pass design HEAD "$F2"
check
assert_eq 1 "$STATUS" "an L0 edit needs the owner again"
assert_contains "$OUTPUT" "owner (round 1): the L0/L1 spec changed since the owner's approval ($(shown "$OWNER_TO"))" "exact message"
done_with

it "a stale PASS from an earlier delivery of the same change fails closed"
# The first delivery merged with its record open; the next PR on the same change carries that
# PASS, whose content is not the new delta. (C1(c) binds verdicts to their PR.)
begin 017-stale
pass code
git update-ref "$TRUSTED" HEAD
set_line src/app.txt 20 'line twenty, second delivery'; git commit -qam "second delivery" >/dev/null
check
assert_eq 1 "$STATUS" "the earlier verdict does not cover the new delta"
assert_contains "$OUTPUT" "code (round 1): changed since the reviewed content" "names the stale verdict"
assert_contains "$OUTPUT" "T2: the recorded ranges do not chain from the change's start" "and the uncovered start"
done_with

it "where the edited lines' surroundings repeat, the file is bound to its exact objects"
begin 018-repeat
set_line src/policy.txt 4 ALLOW; git commit -qam "allow in the first block" >/dev/null
pass code
REVIEWED_TO="$(last_to)"
base_line src/app.txt 28 'base twenty-eight'
git merge -q --no-edit "$TRUSTED" >/dev/null
check
assert_eq 0 "$STATUS" "a base edit elsewhere in a file with unique anchors keeps the verdict: $OUTPUT"
set_line src/policy.txt 4 DENY; set_line src/policy.txt 11 ALLOW; git commit -qam "allow in the second block instead" >/dev/null
HEAD_FP="$(json_fp)"
check
assert_eq 1 "$STATUS" "the same hunk text in the other block is other content"
assert_contains "$OUTPUT" "code (round 1): changed since the reviewed content $(shown "$REVIEWED_TO"): no recorded verdict carries it to this head's content ($(shown "$HEAD_FP"))" "exact message"
done_with

it "a mode change binds the file's exact objects: a base edit elsewhere in it voids the verdict"
begin 019-mode
chmod +x src/tool.sh; git update-index --chmod=+x src/tool.sh; git commit -qm "make the tool executable" >/dev/null
pass code
REVIEWED_TO="$(last_to)"
base_line src/tool.sh 9 'base step 9'
git merge -q --no-edit "$TRUSTED" >/dev/null
assert_eq 'base step 9' "$(sed -n 9p src/tool.sh)" "the merge is clean"
assert_eq 100755 "$(git ls-files -s src/tool.sh | cut -d' ' -f1)" "and keeps the reviewed mode"
HEAD_FP="$(json_fp)"
check
assert_eq 1 "$STATUS" "voids"
assert_contains "$OUTPUT" "code (round 1): changed since the reviewed content $(shown "$REVIEWED_TO"): no recorded verdict carries it to this head's content ($(shown "$HEAD_FP"))" "exact message"
done_with

it "a merge carrying only the record and the log still fails on a standing FAIL"
begin 020-closed
pass code; X="$(git rev-parse HEAD)"
set_line src/app.txt 16 'line sixteen, A'; git commit -qam A >/dev/null
pass code HEAD "$X"; A="$(git rev-parse HEAD)"
set_line src/app.txt 17 'line seventeen, B'; git commit -qam B >/dev/null
fail code HEAD "$A"
FAILED_TO="$(last_to)"
git revert --no-edit HEAD~1 >/dev/null
pass code HEAD "$X"
check
assert_eq 1 "$STATUS" "the FAIL at B stands: the narrow PASS from X does not continue from B"
assert_contains "$OUTPUT" "code (round 3): its FAIL at $(shown "$FAILED_TO") stands: no later clean PASS from code reaches that content" "exact message"
git update-ref "$TRUSTED" HEAD
printf '\nMerged with the record open.\n' >> "specs/changes/$ID.md"; git commit -qam "record note" >/dev/null
run bash "$CHECK" --json "$ID"
assert_contains "$OUTPUT" '"record_only":true' "the merge carries only the record"
check
assert_eq 1 "$STATUS" "record-only exempts coverage, not a standing FAIL"
assert_contains "$OUTPUT" "code (round 3): its FAIL at $(shown "$FAILED_TO") stands: no later clean PASS from code reaches that content" "exact message"
done_with

it "a legacy FAIL resolved under the commit-range rule stays resolved when the change closes after merge"
legacy_line() { # verdict from to
    local counts='0 critical, 0 high, 0 medium, 0 low'
    [ "$1" = PASS ] || counts='0 critical, 1 high, 0 medium, 0 low'
    printf '**Review**: round 1 · %s..%s · code · %s · %s · %s\n' "$2" "$3" "$1" "$counts" "$LINK" >> "specs/changes/$ID.md"
    git commit -qam "legacy $1 $2..$3" >/dev/null
}
close_after_merge() { # the code merged with its record open; a record-only PR closes it
    git update-ref "$TRUSTED" HEAD
    git rm -q "specs/changes/$ID.md"; mkdir -p specs/log
    printf -- '- 2026-11-01 %s: closed\n' "$ID" > "specs/log/$ID.md"; git add specs/log; git commit -qm close >/dev/null
    run bash "$CHECK" --json "$ID"
}
for shape in full narrow; do
    begin "02$([ "$shape" = full ] && echo 1 || echo 2)-legacy-$shape"
    S="$(git rev-parse --short "$TIP")"; B="$(git rev-parse --short HEAD~1)"
    legacy_line FAIL "$S" "$B"
    set_line src/app.txt 16 'line sixteen, fixed'; git commit -qam fix >/dev/null; C="$(git rev-parse --short HEAD)"
    if [ "$shape" = full ]; then legacy_line PASS "$S" "$C"; else legacy_line PASS "$B" "$C"; fi
    check
    assert_eq 0 "$STATUS" "$shape: the gate passes before merge: $OUTPUT"
    close_after_merge
    assert_eq 0 "$STATUS" "$shape: the record-only close passes after the base advances: $OUTPUT"
    assert_contains "$OUTPUT" '"record_only":true' "$shape: record-only"
    done_with
done
begin 023-legacy-stands
S="$(git rev-parse --short "$TIP")"; B="$(git rev-parse --short HEAD~1)"
set_line src/app.txt 16 'line sixteen, fixed'; git commit -qam fix >/dev/null; C="$(git rev-parse --short HEAD)"
legacy_line FAIL "$S" "$C"
legacy_line PASS "$S" "$B"
close_after_merge
assert_eq 1 "$STATUS" "a later PASS on an older commit does not resolve a legacy FAIL after merge"
assert_contains "$OUTPUT" "code (round 1): its FAIL at ${C:0:12} stands: no later clean PASS from code reaches that content" "exact message"
done_with

finish
