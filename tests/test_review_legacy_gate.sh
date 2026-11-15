#!/usr/bin/env bash
# Native fixture receipts and legacy record history are independent evidence.
# shellcheck disable=SC2016 # jq programs use jq variables.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
source "$PK_ROOT/scripts/review-fingerprint-lib.sh"
source "$PK_ROOT/scripts/review-legacy-lib.sh"
STATUS=0; OUTPUT=""
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
CHECK="$PROJ/.prdkit/scripts/bash/check-review.sh"
cat >> .prdkit/memory/config.md <<'EOF'

## Configuration
- review-host: github
- review-publishers: bot:1001
- review-owner: user:1003
- review-publisher-isolation: required
- review-t0-paths: docs/
EOF
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n| security | reviewer |\n' >> .prdkit/memory/agents.md
git add -A; git commit -qm policy
ROOT="$(git rev-parse HEAD)"
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
A=specs/changes/001-original.md; B=specs/changes/002-carrier.md
PR=https://github.com/owner/repo/pull/7
CLEAN='0 critical, 0 high, 0 medium, 0 low'
FAIL="**Review**: round 1 · arbitrary · code · FAIL · $CLEAN · text-only"
OLD_PASS="**Review**: round 2 · arbitrary · code · PASS · $CLEAN · text-only"
commit() { git add -A && git commit -qm "$1" || exit 1; }
record() { printf '# Record\n**Tier**: %s\n## State\n%s\n' "${2:-T1}" "${3:-}" > "$1"; }
fresh() {
    git reset -q --hard "$ROOT" || exit 1
    mkdir -p specs/changes docs
    BASE="$ROOT"; ID=002-carrier; N=0
    git update-ref refs/remotes/origin/main "$BASE"
    use_gh_stub
}
host() { fx_pr 7 "$(git rev-parse HEAD)"; }
publish() { # reviewer [change] [head] [jq edit] [origin PR]
    local reviewer="$1" change="${2:-$ID}" at="${3:-HEAD}" edit="${4:-.}" pr="${5:-7}" fp body sha
    sha="$(git rev-parse "$at")"; fp="$(review_fingerprint "$PROJ" "$change" "$BASE" "$sha")" || exit 1
    N=$((N+1))
    body="$(jq -cn --arg id "$(printf '%032x' "$N")" --arg reviewer "$reviewer" --arg change "$change" \
        --arg head "$sha" --arg base "$BASE" --arg fp "$fp" --argjson pr "$pr" '
        {schema:"prdkit.review.v3",id:$id,repo:"owner/repo",pr:$pr,change:$change,reviewer:$reviewer,
         from:"start",to:$fp,head:$head,since:"",base:"refs/remotes/origin/main",base_at:$base,
         verdict:"PASS",critical:0,high:0,medium:0,low:0,report:"https://example.invalid/report"}' | jq -c "$edit")" || exit 1
    fx_review "$pr" "$(printf '<!-- prdkit-review\n%s\n-->\n' "$body")"
}
online() { host; run bash "$CHECK" --json --pr "$PR" "$@" "$ID"; }
standing() {
    assert_eq 1 "$STATUS" "$OUTPUT"
    assert_eq 1 "$(printf '%s' "$OUTPUT" | jq '[.legacy_blockers[]|select(.cleared==false)]|length')" 'one legacy blocker stands'
}
cleared() {
    assert_eq 0 "$STATUS" "$OUTPUT"
    assert_eq 1 "$(printf '%s' "$OUTPUT" | jq '[.legacy_blockers[]|select(.cleared==true)]|length')" 'clearance reported separately from coverage'
}

it 'native coverage cannot clear another reviewer, narrow, dirty, invalid or wrong-scope legacy clearance'
for kind in other narrow dirty invalid foreign closed merged; do
    fresh; record "$A" T1 "$FAIL"; record "$B"; printf code > source.txt; commit failure
    # The successor record need not retain the predecessor line or even its record.
    rm "$A"; printf -- '- 2026-01-01 001-original: transferred\n' > specs/log.md; commit carrier
    host; publish security
    case "$kind" in
        other) ;;
        narrow) publish code "$ID" HEAD '.from=.to|.since=.head' ;;
        dirty) publish code "$ID" HEAD '.high=1' ;;
        invalid) publish code "$ID" HEAD '.to="fp1:0000000000000000000000000000000000000000000000000000000000000000"' ;;
        foreign) publish code 003-unrelated ;;
        closed) fx_closed_pr 6 "$(git rev-parse HEAD)"; publish code "$ID" HEAD . 6 ;;
        merged) fx_closed_pr 6 "$(git rev-parse HEAD)" '{"merged_at":"2026-01-03T00:00:00Z"}'; publish code "$ID" HEAD . 6 ;;
    esac
    online; standing
done

it 'same-reviewer full PASS in origin or checked scope clears, but a later native FAIL still blocks'
for change in 001-original 002-carrier; do
    fresh; record "$A" T1 "$FAIL"; record "$B"; printf code > source.txt; commit failure
    host; publish security; publish code "$change"
    online; cleared
    publish code "$ID" HEAD '.verdict="FAIL"'
    online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'blocking verdict stands'
done

it 'inherited carrier deletion, move and edit require a fresh full PASS despite an old 1.x PASS'
for operation in untouched delete move edit; do
    fresh; record "$A" T1 "$FAIL"; printf '%s\n' "$OLD_PASS" >> "$A"; commit inherited
    BASE="$(git rev-parse HEAD)"; git update-ref refs/remotes/origin/main "$BASE"
    record "$B"; printf code > source.txt
    case "$operation" in
        delete) rm "$A"; printf -- '- 2026-01-01 001-original: transferred\n' > specs/log.md ;;
        move) mv "$A" specs/changes/003-moved.md ;;
        edit) record "$A" T1 "$OLD_PASS" ;;
    esac
    commit carrier; host; publish security; online
    if [ "$operation" = untouched ]; then
        assert_eq 0 "$STATUS" "$OUTPUT"; assert_contains "$OUTPUT" '"legacy_blockers":[]'
    else
        standing; publish code; online; cleared
    fi
done

it 'a full PASS must include the blocker in its own head/base_at history, even for equal fingerprints'
fresh; record "$B"; printf code > source.txt; commit content; BEFORE="$(git rev-parse HEAD)"
host; publish code
printf '%s\n' "$FAIL" >> "$B"; commit 'late FAIL'; record "$B"; commit 'delete FAIL'
assert_eq "$(review_fingerprint "$PROJ" "$ID" "$BASE" "$BEFORE")" "$(review_fingerprint "$PROJ" "$ID" "$BASE" HEAD)"
online; standing
publish code; online; cleared

it 'historical scans use base_at even when the trusted base now contains the line'
fresh; record "$A" T1 "$FAIL"; record "$B"; printf code > source.txt; commit delivery
REVIEWED="$(git rev-parse HEAD)"; host; publish code
# The base catches up to the old reviewed delivery. The next edit touches inherited A.
BASE="$REVIEWED"
git update-ref refs/remotes/origin/main "$BASE"
record "$A"; commit carrier
# Against today's base, the old head's unchanged sibling is excluded. Against the
# receipt's base_at, A's original introduction is included. Only that latter scan clears.
CACHE="$(mktemp -d)"; track_tmp "$CACHE"
run review_legacy_collect "$PROJ" "$ID" "$BASE" "$REVIEWED" light "$CACHE" "$CACHE/control"
assert_eq 0 "$STATUS"
assert_eq '' "$(cat "$CACHE/control")" 'using todays base would miss the reviewed blocker'
host; publish security
online
assert_eq true "$(printf '%s' "$OUTPUT" | jq '.legacy_blockers[0].cleared')" 'clearance uses base_at independently of current coverage'
publish code; online; cleared

it 'absent head/base evidence cannot clear, although authenticated coverage tokens may survive'
for field in head base_at; do
    fresh; record "$B" T1 "$FAIL"; printf code > source.txt; commit failure; host
    publish code "$ID" HEAD ".$field=\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""
    online; standing
    publish code; online; cleared
done

it 'empty-content native full PASS clears a merged-open record with no artificial delta'
fresh; ID=001-original; record "$A" T1 "$FAIL"; printf '%s\n' "$OLD_PASS" >> "$A"; commit inherited
BASE="$(git rev-parse HEAD)"; git update-ref refs/remotes/origin/main "$BASE"
rm "$A"; printf -- '- 2026-01-01 001-original: closed\n' > specs/log.md; commit closing
online; standing; assert_contains "$OUTPUT" '"record_only":true'
host; publish security; online; standing
printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
publish code; online --save-receipts .git/snapshot; cleared
assert_eq "start..$REVIEW_FP_EMPTY" "$(printf '%s' "$OUTPUT" | jq -r '.reviews[]|select(.reviewer=="code")|.range')" 'empty clearance retains its start-to-start verdict without a coverage edge'
assert_eq "$REVIEW_FP_EMPTY" "$(jq -r '.[-1].body|split("\n")[1]|fromjson|.to' "$GH_STUB_DIR/reviews/7.json")"
: > "$GH_STUB_DIR/requests"
run bash "$CHECK" --json --receipts .git/snapshot "$ID"
assert_eq 3 "$STATUS" "$OUTPUT"
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

# Exercise actual legacy clearance with only the offline standard-tool contract on PATH.
TOOLS="$(mktemp -d)"; track_tmp "$TOOLS"
sha_tool=sha256sum; command -v sha256sum >/dev/null 2>&1 || sha_tool=shasum
for cmd in bash dirname git sed awk tr head tail grep cat mktemp rm mv mkdir wc sort "$sha_tool"; do
    ln -s "$(command -v "$cmd")" "$TOOLS/$cmd"
done
run env PATH="$TOOLS" bash "$CHECK" --json --receipts .git/snapshot "$ID"
assert_eq 3 "$STATUS" 'empty-content clearance is a jq-free, gh-free snapshot preview'
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

it 'adding content expires empty clearance without turning the receipt into a blocker'
EMPTY_HEAD="$(git rev-parse HEAD)"
printf implementation > source.txt; commit 'add content after empty clearance'
online; standing
assert_contains "$OUTPUT" '"record_only":false'
assert_contains "$OUTPUT" '"invalid_receipts":0'
assert_not_contains "$OUTPUT" 'empty-content clearance requires' 'the historical empty PASS is not invalidated'
assert_not_contains "$OUTPUT" ' is empty' 'start-to-start is not a permanently invalid range'
assert_contains "$OUTPUT" 'the recorded ranges do not chain' 'the empty PASS grants no coverage edge'
# Another reviewer supplies coverage, but only R can clear the legacy blocker from R.
publish security; online --save-receipts .git/content-snapshot; standing
assert_eq 1 "$(printf '%s' "$OUTPUT" | jq '.problems|length')" 'only the standing legacy blocker remains; the latest start for R is covered'
assert_contains "$(printf '%s' "$OUTPUT" | jq -r '.problems[0]')" 'legacy blocker'
: > "$GH_STUB_DIR/requests"
run env PATH="$TOOLS" bash "$CHECK" --json --receipts .git/content-snapshot "$ID"
standing
assert_eq 1 "$(printf '%s' "$OUTPUT" | jq '.problems|length')" 'snapshot also treats the old empty PASS as non-blocking'
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

it 'a later native full PASS clears the restored blocker and supersedes the empty verdict'
publish code; online --save-receipts .git/full-snapshot; cleared
FULL_FP="$(review_fingerprint "$PROJ" "$ID" "$BASE" HEAD)"
assert_eq "start..$FULL_FP" "$(printf '%s' "$OUTPUT" | jq -r '.reviews[]|select(.reviewer=="code")|.range')" 'the later full PASS is the latest covered verdict for R'
assert_contains "$OUTPUT" '"receipts":3' 'the earlier empty receipt remains in the authenticated history'
assert_eq '[]' "$(printf '%s' "$OUTPUT" | jq -c '.problems')"
: > "$GH_STUB_DIR/requests"
run env PATH="$TOOLS" bash "$CHECK" --json --receipts .git/full-snapshot "$ID"
assert_eq 3 "$STATUS" 'the full-PASS repair also succeeds in a jq-free snapshot preview'
assert_eq true "$(printf '%s' "$OUTPUT" | jq '.legacy_blockers[0].cleared')"
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

it 'a latest start-to-start receipt is covered by ordinary start coverage and adds no edge'
publish code "$ID" "$EMPTY_HEAD"; online; cleared
assert_eq "start..$REVIEW_FP_EMPTY" "$(printf '%s' "$OUTPUT" | jq -r '.reviews[]|select(.reviewer=="code")|.range')" 'the latest-covered rule sees the empty receipt, not a silently retained older verdict'
printf '\nmore content\n' >> source.txt; commit 'unreviewed content after full PASS'
online
assert_eq 1 "$STATUS" 'an empty latest verdict cannot cover subsequently added content'
assert_eq true "$(printf '%s' "$OUTPUT" | jq '.legacy_blockers[0].cleared')" 'the earlier non-empty full PASS still clears through its own B-H2 scan'
assert_contains "$OUTPUT" 'the recorded ranges do not chain' 'coverage, not an empty-receipt validity problem, fails'
assert_not_contains "$OUTPUT" 'empty-content clearance requires'
assert_not_contains "$OUTPUT" ' is empty'

it 'empty narrow PASS is refused and cannot clear'
fresh; ID=001-original; record "$A" T1 "$FAIL"; commit inherited
BASE="$(git rev-parse HEAD)"; git update-ref refs/remotes/origin/main "$BASE"
printf note >> "$A"; commit note; host; publish code "$ID" HEAD '.from=.to|.since=.head'
online; standing
assert_contains "$OUTPUT" 'empty-content clearance requires a full PASS'

it 'T0 and record-only blockers stand online, in snapshots and with no receipt source'
for mode in docs record; do
    fresh; record "$B" T0 "$FAIL"
    if [ "$mode" = docs ]; then printf documentation > docs/guide.md; fi
    commit "$mode"; host
    online --save-receipts .git/snapshot; standing
    for source in snapshot none; do
        : > "$GH_STUB_DIR/requests"
        if [ "$source" = snapshot ]; then run bash "$CHECK" --json --receipts .git/snapshot "$ID"
        else run bash "$CHECK" --json "$ID"; fi
        standing; assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
        if [ "$source" = snapshot ]; then run env PATH="$TOOLS" bash "$CHECK" --json --receipts .git/snapshot "$ID"
        else run env PATH="$TOOLS" bash "$CHECK" --json "$ID"; fi
        standing; assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
    done
done

it 'owner FAIL and unnamed blockers fail closed without a confirmed activity witness'
for reviewer in owner ''; do
    for mode in closing carrier; do
        fresh; record "$A" T0 "**Review**: round 1 · ignored · $reviewer · FAIL"
        printf '**Review**: round 2 · ignored · owner · PASS\n' >> "$A"; commit inherited
        BASE="$(git rev-parse HEAD)"; git update-ref refs/remotes/origin/main "$BASE"
        # Even an earlier approval plus unchanged L0/L1 cannot authorize a later blocker.
        host; fx_owner_review 7 APPROVED "$BASE"
        rm "$A"; printf -- '- 2026-01-01 001-original: closed\n' > specs/log.md
        if [ "$mode" = closing ]; then ID=001-original; else record "$B"; printf code > source.txt; fi
        commit "$mode"; host
        if [ "$mode" = carrier ]; then publish code; fi
        online; standing; assert_contains "$OUTPUT" 'native owner approval'
        fx_owner_review 7 DISMISSED "$(git rev-parse HEAD)"; online; standing
        fx_owner_review 7 APPROVED "$(git rev-parse HEAD)"; online; standing
    done
done

it 'an owner or unnamed FAIL added after an approval and then removed stays blocked'
for reviewer in owner ''; do
    fresh; record "$B" T0; commit content; BEFORE="$(git rev-parse HEAD)"
    host; fx_owner_review 7 APPROVED "$BEFORE"
    printf '**Review**: round 1 · ignored · %s · FAIL\n' "$reviewer" >> "$B"; commit blocker
    record "$B" T0; commit removed
    assert_eq "$(review_fingerprint "$PROJ" "$ID" "$BASE" "$BEFORE")" "$(review_fingerprint "$PROJ" "$ID" "$BASE" HEAD)"
    online; standing
done
finish
