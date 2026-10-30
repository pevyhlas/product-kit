#!/usr/bin/env bash
# check-review.sh passes a change only when its recorded independent review covers the head being
# merged: PASS verdicts, nothing blocking for the rigor, only the record and the log changed since,
# the tier's reviewers present. It reads committed state, so a closing commit that deletes the
# record still checks against the record's last version.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
CHECK="$PROJ/.prdkit/scripts/bash/check-review.sh"
cd "$PROJ" || exit 1
printf '\n## Configuration\n- review-integration-branches: origin/develop\n' > .prdkit/memory/config.md
git add -A >/dev/null; git commit -qm installed >/dev/null
DEFAULT="$(git symbolic-ref --short HEAD)"
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$DEFAULT"
git checkout -q -b 001-greet
mkdir -p src specs/changes; echo 'greet' > src/app.txt
git add -A >/dev/null; git commit -qm code >/dev/null
BASE="$(git rev-parse --short HEAD~1)"; REVIEWED="$(git rev-parse --short HEAD)"

record() { # tier, then State review lines
    local tier="$1"; shift
    mkdir -p specs/changes
    {
        printf '# Change: Warmer greeting\n\n**Opened**: 2026-10-15 · **Parts**: P1 · **Tier**: %s · **Parent**: none\n\n' "$tier"
        printf '## Acceptance\n\n| Item | Proves | Check | Attempts | Result |\n|---|---|---|---|---|\n| A1 | R-01 | test | 1 | PASS |\n\n'
        printf '## State\n\n**Step**: review\n'
        for line in "$@"; do printf '%s\n' "$line"; done
    } > specs/changes/001-greet.md
    git add specs/changes/001-greet.md; git commit -qm "record" >/dev/null
}
verdict() { # reviewer verdict counts [range]
    printf '**Review**: round 1 · %s · %s · %s · %s · https://example.invalid/pr/1#c1' "${4:-$BASE..$REVIEWED}" "$1" "$2" "$3"
}
CLEAN='0 critical, 0 high, 0 medium, 0 low'

it "a PASS covering the head passes; only the record changed since review"
record T1 "$(verdict code PASS '0 critical, 0 high, 1 medium, 2 low')"
run bash "$CHECK"
assert_eq 0 "$STATUS" "passes on the change branch"
assert_contains "$OUTPUT" "PASS 001-greet" "names the change"
assert_contains "$OUTPUT" "T1, Rigor light; 1 recorded verdict(s) cover this head" "states what it checked"
record T1 "$(verdict code PASS "$CLEAN" "\`$BASE..$REVIEWED\`")"
run bash "$CHECK"
assert_eq 0 "$STATUS" "a range in backticks reads the same"

it "code changed after the reviewed head fails"
echo 'warmer' > src/app.txt; git commit -qam "after review" >/dev/null
run bash "$CHECK"
assert_eq 1 "$STATUS" "fails"
assert_contains "$OUTPUT" "changed since the reviewed head $REVIEWED: src/app.txt" "names the unreviewed path"
git reset -q --hard HEAD~1

it "tracked execution-plan deletion needs coverage; same-PR finalization does not exempt it"
BEFORE_PLAN="$(git rev-parse HEAD)"
mkdir -p specs/changes/001-greet
printf 'Temporary plan with review-relevant choices\n' > specs/changes/001-greet/plan.md
git add specs/changes/001-greet/plan.md; git commit -qm 'tracked plan' >/dev/null
PLAN_HEAD="$(git rev-parse HEAD)"
record T1 "$(verdict code PASS "$CLEAN" "$BASE..$PLAN_HEAD")"
git rm -q specs/changes/001-greet/plan.md; git commit -qm 'delete plan after review' >/dev/null
run bash "$CHECK"
assert_eq 1 "$STATUS" "plan deletion after PASS is not metadata"
assert_contains "$OUTPUT" 'specs/changes/001-greet/plan.md' "unreviewed deletion identified"
REMOVED_HEAD="$(git rev-parse HEAD)"
record T1 "$(verdict code PASS "$CLEAN" "$BASE..$REMOVED_HEAD")"
run bash "$CHECK"
assert_eq 0 "$STATUS" "review after removing tracked detail covers the final PR diff"
git reset -q --hard "$BEFORE_PLAN"

it "the reviewed head must be a commit hash, never a name that moves"
for range in "$BASE..HEAD" "$BASE..001-greet" "$BASE..HEAD~1" "$BASE..@" "$REVIEWED"; do
    record T1 "$(verdict code PASS "$CLEAN" "$range")"
    run bash "$CHECK"
    assert_eq 1 "$STATUS" "range $range refused"
done
assert_contains "$OUTPUT" "is not a commit hash" "says why"

it "a three-dot range reads as two-dot; an empty range or one that skips the change's start fails"
record T1 "$(verdict code PASS "$CLEAN" "$BASE...$REVIEWED")"
run bash "$CHECK"
assert_eq 0 "$STATUS" "three dots accepted"
record T1 "$(verdict code PASS "$CLEAN" "$REVIEWED..$REVIEWED")"
run bash "$CHECK"
assert_eq 1 "$STATUS" "empty range fails"
assert_contains "$OUTPUT" "the range $REVIEWED..$REVIEWED is empty" "says why"
echo 'more' > src/more.txt; git add src/more.txt; git commit -qm "more code" >/dev/null; LAST="$(git rev-parse --short HEAD)"
record T1 "$(verdict code PASS "$CLEAN" "$REVIEWED..$LAST")"
run bash "$CHECK"
assert_eq 1 "$STATUS" "a review of the last commit alone fails"
assert_contains "$OUTPUT" "the recorded ranges do not chain from the change's start" "names the gap"
git reset -q --hard "$REVIEWED"

it "a FAIL verdict or a blocking finding fails; a later verdict from the same reviewer supersedes"
record T1 "$(verdict code FAIL '0 critical, 1 high, 0 medium, 0 low')"
run bash "$CHECK"
assert_eq 1 "$STATUS" "fails"
assert_contains "$OUTPUT" "code (round 1): verdict FAIL, not PASS" "verdict named"
assert_contains "$OUTPUT" "1 high finding(s) block" "blocking count named"
record T1 "$(verdict code FAIL '0 critical, 1 high, 0 medium, 0 low')" "$(verdict code PASS "$CLEAN")"
run bash "$CHECK"
assert_eq 0 "$STATUS" "the latest verdict counts"

it "medium findings block under Rigor: full, or when the constitution names no Rigor"
record T1 "$(verdict code PASS '0 critical, 0 high, 1 medium, 0 low')"
sed -i.bak 's/^- \*\*Rigor\*\*: light/- **Rigor**: full/' .prdkit/memory/constitution.md && rm -f .prdkit/memory/constitution.md.bak
git commit -qam "rigor full" >/dev/null
run bash "$CHECK"
assert_eq 1 "$STATUS" "fails under full"
assert_contains "$OUTPUT" "1 medium finding(s) block under Rigor: full" "rigor named"
sed -i.bak '/\*\*Rigor\*\*:/d' .prdkit/memory/constitution.md && rm -f .prdkit/memory/constitution.md.bak
git commit -qam "no rigor" >/dev/null
run bash "$CHECK"
assert_eq 1 "$STATUS" "fails closed without a Rigor"
assert_contains "$OUTPUT" "the constitution names no Rigor (light or full), so medium blocks" "says why"
git reset -q --hard HEAD~2

it "missing counts or a missing review fail; the tier must be named"
record T1 "$(verdict code PASS 'looks fine')"
run bash "$CHECK"
assert_contains "$OUTPUT" "? critical finding(s) block" "unreadable counts are not zero"
record T2
run bash "$CHECK"
assert_contains "$OUTPUT" "T2 needs a recorded independent review; none found in State" "no review"
record "" "$(verdict code PASS "$CLEAN")"
run bash "$CHECK"
assert_contains "$OUTPUT" "The record names no review tier" "tier required"

it "an example verdict inside a comment or code fence is never counted"
record T1 '<!-- example:' "$(verdict code PASS "$CLEAN")" '-->' '```' "$(verdict code PASS "$CLEAN")" '```'
run bash "$CHECK"
assert_contains "$OUTPUT" "T1 needs a recorded independent review; none found in State" "examples ignored"

it "T0 needs no review, but a recorded verdict still counts"
record T0
run bash "$CHECK"
assert_eq 0 "$STATUS" "T0 passes"
assert_contains "$OUTPUT" "tier T0 needs no independent review" "says why"
record T0 "$(verdict docs FAIL '0 critical, 1 high, 0 medium, 0 low')"
run bash "$CHECK"
assert_eq 1 "$STATUS" "a recorded FAIL fails T0 too"
assert_contains "$OUTPUT" "docs (round 1): verdict FAIL, not PASS" "the FAIL is named"

it "T3 also needs the owner's verdict, which carries no counts and covers the L0 and L1 spec"
record T3 "$(verdict design PASS "$CLEAN")"
run bash "$CHECK"
assert_contains "$OUTPUT" "T3 needs the owner's verdict too" "owner required"
OWNED="$REVIEWED"
record T3 "$(verdict design PASS "$CLEAN")" "**Review**: round 1 · $BASE..$OWNED · owner · PASS · https://example.invalid/pr/1#c2"
run bash "$CHECK"
assert_eq 0 "$STATUS" "design review plus owner passes"
mkdir -p specs; echo '# Product' > specs/product.md; git add specs/product.md; git commit -qm "L0 after the owner" >/dev/null
REVIEWED="$(git rev-parse --short HEAD)"
record T3 "$(verdict design PASS "$CLEAN")" "**Review**: round 1 · $BASE..$OWNED · owner · PASS · https://example.invalid/pr/1#c2"
run bash "$CHECK"
assert_eq 1 "$STATUS" "an L0 edit after the owner's head fails"
assert_contains "$OUTPUT" "the L0/L1 spec changed since the owner's head $OWNED: specs/product.md" "names the spec file"
git reset -q --hard "$OWNED"; REVIEWED="$OWNED"
mkdir -p specs/product/journeys; echo '# J-01 Ask (hypothesis)' > specs/product/journeys/j-01-ask.md
git add specs/product; git commit -qm "journey after the owner" >/dev/null
REVIEWED="$(git rev-parse --short HEAD)"
record T3 "$(verdict design PASS "$CLEAN")" "**Review**: round 1 · $BASE..$OWNED · owner · PASS · https://example.invalid/pr/1#c2"
run bash "$CHECK"
assert_contains "$OUTPUT" "the L0/L1 spec changed since the owner's head $OWNED: specs/product/journeys/j-01-ask.md" "a journey file is L0"
git reset -q --hard "$OWNED"; REVIEWED="$OWNED"

it "a scoped re-review covers an older reviewer's head when its range starts at or before it"
echo 'fix one' > src/fix.txt; git add src/fix.txt; git commit -qm "fix one" >/dev/null; FIX1="$(git rev-parse --short HEAD)"
echo 'fix two' >> src/fix.txt; git commit -qam "fix two" >/dev/null; FIX2="$(git rev-parse --short HEAD)"
record T2 "$(verdict security PASS "$CLEAN")" "$(verdict code FAIL '0 critical, 1 high, 0 medium, 0 low')" \
    "$(verdict code PASS "$CLEAN" "$REVIEWED..$FIX2")"
run bash "$CHECK"
assert_eq 0 "$STATUS" "the delta review covers the security head"
record T2 "$(verdict security PASS "$CLEAN")" "$(verdict code PASS "$CLEAN" "$FIX1..$FIX2")"
run bash "$CHECK"
assert_eq 1 "$STATUS" "a delta starting after the older head leaves a gap"
assert_contains "$OUTPUT" "security (round 1): changed since the reviewed head $REVIEWED: src/fix.txt" "names the gap"
record T1 "$(verdict code FAIL '0 critical, 1 high, 0 medium, 0 low')" "$(verdict code PASS "$CLEAN" "$REVIEWED..$FIX2")"
run bash "$CHECK"
assert_eq 0 "$STATUS" "one reviewer's FAIL, then a scoped PASS of the fix, passes"
record T1 "$(verdict code FAIL '0 critical, 1 high, 0 medium, 0 low')" "$(verdict code FAIL '0 critical, 1 high, 0 medium, 0 low' "$REVIEWED..$FIX1")" \
    "$(verdict code PASS "$CLEAN" "$FIX1..$FIX2")"
run bash "$CHECK"
assert_eq 0 "$STATUS" "three rounds by one reviewer chain from the start"
record T2 "$(verdict security PASS "$CLEAN")" "$(verdict code FAIL '0 critical, 1 high, 0 medium, 0 low')" \
    "$(verdict code FAIL '0 critical, 1 high, 0 medium, 0 low' "$REVIEWED..$FIX1")" "$(verdict code PASS "$CLEAN" "$FIX1..$FIX2")"
run bash "$CHECK"
assert_eq 0 "$STATUS" "the chain also covers another reviewer's older head"
record T1 "$(verdict code FAIL '1 critical, 0 high, 0 medium, 0 low' "$REVIEWED..$FIX2")" "$(verdict code PASS "$CLEAN")"
run bash "$CHECK"
assert_eq 1 "$STATUS" "a FAIL round its reviewer never passed past covers nothing"
assert_contains "$OUTPUT" "changed since the reviewed head $REVIEWED" "the failed code is unreviewed"
record T2 "$(verdict code PASS "$CLEAN")" "$(verdict security FAIL '1 critical, 0 high, 0 medium, 0 low' "$REVIEWED..$FIX2")" \
    "$(verdict security PASS "$CLEAN")"
run bash "$CHECK"
assert_eq 1 "$STATUS" "another reviewer's FAIL range covers nothing either"
record T2 "$(verdict code PASS "$CLEAN" "$BASE..$FIX2")" "$(verdict security FAIL '1 critical, 0 high, 0 medium, 0 low' "$REVIEWED..$FIX2")" \
    "$(verdict security PASS "$CLEAN")"
run bash "$CHECK"
assert_eq 1 "$STATUS" "a FAIL stands though another reviewer's PASS covers its head"
assert_contains "$OUTPUT" "security (round 1): its FAIL at" "the standing FAIL is named"
record T1 "$(verdict code PASS "$CLEAN" "$BASE..$FIX2")" "$(verdict code FAIL '1 critical, 0 high, 0 medium, 0 low' "$BASE..$FIX2")" \
    "$(verdict code PASS "$CLEAN")"
run bash "$CHECK"
assert_eq 1 "$STATUS" "a FAIL stands though the same reviewer passed that range earlier"
for bad in "$(verdict security FAIL '1 critical, 0 high, 0 medium, 0 low' "$REVIEWED..HEAD")" \
    "$(verdict security FAIL '1 critical, 0 high, 0 medium, 0 low' "$REVIEWED..$(printf '%s' "$FIX2" | tr 'a-f' 'A-F')")" \
    "$(verdict security PASS '1 critical, 0 high, 0 medium, 0 low' "$REVIEWED..$FIX2")"; do
    record T2 "$(verdict code PASS "$CLEAN" "$BASE..$FIX2")" "$bad" "$(verdict security PASS "$CLEAN")"
    run bash "$CHECK"
    assert_eq 1 "$STATUS" "a blocking line a later PASS does not reach stands: ${bad#*round 1 · }"
done
record T1 "$(verdict code FAIL '1 critical, 0 high, 0 medium, 0 low' "$REVIEWED..$FIX2")" "$(verdict code PASS "$CLEAN" "$FIX2..$FIX2")" \
    "$(verdict code PASS "$CLEAN")"
run bash "$CHECK"
assert_eq 1 "$STATUS" "an empty-range PASS resolves nothing"
record T1 "$(verdict code ERROR 'reviewer timed out')" "$(verdict code PASS "$CLEAN" "$REVIEWED..$FIX2")"
run bash "$CHECK"
assert_eq 1 "$STATUS" "a round with no verdict reviewed nothing, so it opens nothing"
record T1 "$(verdict code FAIL '0 critical, 1 high, 0 medium, 0 low')" "$(verdict code PASS "$CLEAN" "$FIX1..$FIX2")"
run bash "$CHECK"
assert_eq 1 "$STATUS" "a scoped PASS that starts after the first round's head leaves the change unopened"
assert_contains "$OUTPUT" "the recorded ranges do not chain from the change's start" "names the gap"
git reset -q --hard "$REVIEWED"

it "the closing commit deletes the record and appends the log; the last record still decides"
record T1 "$(verdict code PASS "$CLEAN")"
git rm -q specs/changes/001-greet.md; mkdir -p specs; printf -- '- 2026-10-18 001-greet: warmer greeting — R-01 — #1\n' >> specs/log.md
git add specs/log.md; git commit -qm close >/dev/null
run bash "$CHECK" --json
assert_eq 0 "$STATUS" "passes after the record is deleted"
assert_contains "$OUTPUT" '"result":"pass","change":"001-greet"' "JSON result"
assert_contains "$OUTPUT" '"record_only":false' "the merge carries code"
assert_contains "$OUTPUT" '"reviewer":"code","round":"round 1"' "JSON review row"
if command -v python3 >/dev/null 2>&1; then
    if printf '%s' "$OUTPUT" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then _ok "valid JSON"; else _no "valid JSON" "$OUTPUT"; fi
fi

it "a head already inside --base, or no base at all, cannot locate the change's start"
run bash "$CHECK" --base 001-greet
assert_eq 1 "$STATUS" "the change's own branch as base fails"
assert_contains "$OUTPUT" "is already in 001-greet" "says why"
TRUNK="$(mktemp -d)"; track_tmp "$TRUNK"
( cd "$TRUNK" && git init -q && git config user.name test && git config user.email test@example.invalid &&
  git checkout -q -b trunk && echo base > base.txt && git add base.txt && git commit -qm base &&
  git checkout -q -b 008-solo && mkdir -p src specs/changes && echo solo > src/solo.txt && git add src && git commit -qm code ) >/dev/null 2>&1
SOLO_BASE="$(git -C "$TRUNK" rev-parse --short trunk)"; SOLO_HEAD="$(git -C "$TRUNK" rev-parse --short HEAD)"
printf '# Change: Solo\n\n**Tier**: T1\n\n## State\n\n**Review**: round 1 · %s..%s · code · PASS · %s · https://example.invalid/pr/8#c1\n' \
    "$SOLO_BASE" "$SOLO_HEAD" "$CLEAN" > "$TRUNK/specs/changes/008-solo.md"
git -C "$TRUNK" add specs; git -C "$TRUNK" commit -qm record >/dev/null
run bash "$CHECK" --repo "$TRUNK" 008-solo
assert_eq 1 "$STATUS" "no default branch and no --base fails"
assert_contains "$OUTPUT" "no base to find the change's start" "asks for --base"
run bash "$CHECK" --repo "$TRUNK" --base trunk 008-solo
assert_eq 0 "$STATUS" "with --base it passes"

it "a --base inside the change's own history cannot hide its code"
echo 'unreviewed' > src/evil.txt; git add src/evil.txt; git commit -qm "after review" >/dev/null
printf -- '- note\n' >> specs/log.md; git add specs/log.md; git commit -qm "log only" >/dev/null
run bash "$CHECK" --base HEAD~1
assert_eq 1 "$STATUS" "falls back to coverage"
assert_contains "$OUTPUT" "src/evil.txt" "the unreviewed code is named"
git branch -q wip-001 HEAD~1
run bash "$CHECK" --base wip-001
assert_eq 1 "$STATUS" "a local branch inside the change is no trusted base"
git branch -q -D wip-001
git reset -q --hard HEAD~2

it "the head and change id can be given, as CI does for a pull request"
git checkout -q "$DEFAULT"
run bash "$CHECK" --head 001-greet --base "$DEFAULT" 001-greet
assert_eq 0 "$STATUS" "explicit head, base and id"
run bash "$CHECK"
assert_eq 2 "$STATUS" "the default branch is not a change id"
run bash "$CHECK" --head 001-greet 002-other
assert_contains "$OUTPUT" "No change record specs/changes/002-other.md" "an unknown change fails"

it "a change closed after its code merged carries only the record and the log"
# Squash-merge the code with its open record, then close it from a new branch: the reviewed
# heads are gone from this history, and nothing but the record and the log is merged.
git checkout -q 001-greet~1 -- src specs/changes; git commit -qm "001-greet (#1)" >/dev/null
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
git checkout -q -b 001-close
git rm -q specs/changes/001-greet.md; mkdir -p specs; printf -- '- 2026-10-19 001-greet: warmer greeting — R-01 — #2\n' >> specs/log.md
git add specs/log.md; git commit -qm close >/dev/null
run bash "$CHECK" 001-greet
assert_eq 0 "$STATUS" "passes"
assert_contains "$OUTPUT" "carries only the record and the log" "says why"
git checkout -q "$DEFAULT"; git branch -q -D 001-close
git checkout -q -b 001-close
sed -i.bak "s/· code · PASS · $CLEAN/· code · FAIL · 0 critical, 1 high, 0 medium, 0 low/" specs/changes/001-greet.md && rm -f specs/changes/001-greet.md.bak
git commit -qam "record a FAIL" >/dev/null
run bash "$CHECK" 001-greet
assert_eq 1 "$STATUS" "a recorded FAIL still fails"
git checkout -q "$DEFAULT"; git branch -q -D 001-close
git checkout -q -b 001-close
sed -i.bak '/^\*\*Review\*\*:/d' specs/changes/001-greet.md && rm -f specs/changes/001-greet.md.bak
git commit -qam "no verdicts" >/dev/null
run bash "$CHECK" 001-greet
assert_eq 0 "$STATUS" "a record-only close passes"
assert_contains "$OUTPUT" "a T1 record with no verdict, so its code merged unreviewed" "but says the code had no verdict"
# An integration branch other than the default one, named as a remote-tracking --base, is trusted.
git checkout -q -b develop "$DEFAULT"; echo d > dev.txt; git add dev.txt; git commit -qm develop >/dev/null
git update-ref refs/remotes/origin/develop develop
git checkout -q -b 001-close-dev develop
git rm -q specs/changes/001-greet.md; mkdir -p specs; printf -- '- 2026-10-19 001-greet: warmer greeting — R-01 — #3\n' >> specs/log.md
git add specs/log.md; git commit -qm close >/dev/null
run bash "$CHECK" --base origin/develop 001-greet
assert_eq 0 "$STATUS" "a record-only close into develop passes"
assert_contains "$OUTPUT" "since origin/develop it carries only the record and the log" "names the base"
git checkout -q "$DEFAULT"; git branch -q -D 001-close-dev develop; git update-ref -d refs/remotes/origin/develop

it "a close finds its log line in a large log"
git checkout -q -b 001-close-biglog "$DEFAULT"
git rm -q specs/changes/001-greet.md; mkdir -p specs
{ printf -- '- 2026-10-19 001-greet: warmer greeting — R-01 — #4\n'; i=0; while [ "$i" -lt 4000 ]; do printf -- '- 2026-10-01 %03d-old-change: an older change with a long enough summary line — #%d\n' "$((i % 900 + 100))" "$i"; i=$((i + 1)); done; } >> specs/log.md
git add specs/log.md; git commit -qm close >/dev/null
run bash "$CHECK" 001-greet
assert_not_contains "$OUTPUT" "has no '- <date> 001-greet" "no SIGPIPE false alarm past 64 KiB"
git checkout -q "$DEFAULT"; git branch -q -D 001-close-biglog

it "closing a change without its log line fails"
git checkout -q -b 001-close-nolog "$DEFAULT"
git rm -q specs/changes/001-greet.md; git commit -qm close >/dev/null
run bash "$CHECK" 001-greet
assert_eq 1 "$STATUS" "fails"
assert_contains "$OUTPUT" "001-greet is closed (its record is deleted) but specs/log.md" "names the missing log line"
git checkout -q "$DEFAULT"; git branch -q -D 001-close-nolog

it "a reviewed head outside the history fails"
git checkout -q 001-greet
git checkout -q -b side HEAD~3; echo other > other.txt; git add other.txt; git commit -qm other >/dev/null
REVIEWED="$(git rev-parse --short HEAD)"; git checkout -q 001-greet
record T1 "$(verdict code PASS "$CLEAN")"
run bash "$CHECK"
assert_contains "$OUTPUT" "commit $REVIEWED is not in the history" "foreign head refused"

it "a 0.x feature without a record is told it becomes one at the cutover"
mkdir -p specs/features/002-legacy; echo '# Legacy' > specs/features/002-legacy/spec.md
git add specs/features; git commit -qm legacy >/dev/null
run bash "$CHECK" 002-legacy
assert_eq 1 "$STATUS" "fails"
assert_contains "$OUTPUT" "a 0.x feature the owner keeps open becomes a change record at the cutover or restructure" "names the remedy"

finish
