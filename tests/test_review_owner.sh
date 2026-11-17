#!/usr/bin/env bash
# Native owner state and activity witness, independent from receipt text and record lines.
# shellcheck disable=SC2016 # jq programs use jq variables.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
source "$PK_ROOT/scripts/review-fingerprint-lib.sh"
STATUS=0
PROJ="$(make_inited_project)"; track_tmp "$PROJ"; cd "$PROJ" || exit 1
CHECK="$PROJ/.prdkit/scripts/bash/check-review.sh"
cat >> .prdkit/memory/config.md <<'EOF'

## Configuration
- review-host: github
- review-publishers: bot:1001
- review-owner: user:1003
- review-publisher-isolation: required
- review-t0-paths: docs/
EOF
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n' >> .prdkit/memory/agents.md
mkdir -p specs/changes
printf '# Product\nOriginal.\n' > specs/product.md
git add -A; git commit -qm baseline; BASE="$(git rev-parse HEAD)"
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git update-ref refs/remotes/origin/main "$BASE"
git checkout -qb 001-reviewed
printf '# Record\n**Tier**: T3\n## State\n' > specs/changes/001-reviewed.md
printf '# Product\nRefined.\n' > specs/product.md
printf implementation > source.txt
git add -A; git commit -qm implementation; A="$(git rev-parse HEAD)"
PR=https://github.com/owner/repo/pull/7
fresh() {
    git reset -q --hard "$A"
    git update-ref refs/remotes/origin/main "$BASE"
    use_gh_stub; fx_pr 7 "$A"; N=0; AUTHOR_OVERRIDE=""
    fx_activity 0000000000000000000000000000000000000000 "$A" '{"activity_type":"branch_creation","timestamp":"2026-01-01T00:00:00Z"}'
}
approve() { fx_owner_review 7 APPROVED "${1:-$A}" "${2:-}"; }
online() {
    local at fp body
    at="$(git rev-parse HEAD)"; fx_pr 7 "$at" "$AUTHOR_OVERRIDE"
    fp="$(review_fingerprint "$PROJ" 001-reviewed "$BASE" "$at")"; N=$((N+1))
    body="$(jq -cn --arg id "$(printf '%032x' "$N")" --arg head "$at" --arg base "$BASE" --arg fp "$fp" '
        {schema:"prdkit.review.v3",id:$id,repo:"owner/repo",pr:7,change:"001-reviewed",reviewer:"code",
         from:"start",to:$fp,head:$head,since:"",base:"refs/remotes/origin/main",base_at:$base,
         verdict:"PASS",critical:0,high:0,medium:0,low:0,report:"https://example.invalid/report"}')"
    fx_review 7 "$(printf '<!-- prdkit-review\n%s\n-->\n' "$body")"
    run bash "$CHECK" --json --pr "$PR" "$@" 001-reviewed
}

it 'native approval is captured from GraphQL with an ascending activity request'
fresh; approve; online --save-receipts .git/owner-snapshot
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq "$A" "$(printf '%s' "$OUTPUT" | jq -r .owner.commit)"
assert_eq "$A" "$(printf '%s' "$OUTPUT" | jq -r .owner.head_at_submission)"
assert_contains "$(cat "$GH_STUB_DIR/requests")" 'direction=asc'
assert_not_contains "$(cat "$GH_STUB_DIR/requests")" 'pulls/7/reviews' 'owner commit comes from GraphQL, not REST'
: > "$GH_STUB_DIR/requests"
run bash "$CHECK" --json --receipts .git/owner-snapshot 001-reviewed
assert_eq 3 "$STATUS" "$OUTPUT"
assert_eq '' "$(cat "$GH_STUB_DIR/requests")" 'snapshot owner validation makes no host call'

it 'latest decisive state includes dismissed barriers and ignores COMMENTED'
fresh; approve
fx_owner_review 7 CHANGES_REQUESTED "$A" '{"submittedAt":"2026-01-03T00:00:00Z"}'
online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'changes requested, not PASS'
fx_owner_review 7 DISMISSED "$A" '{"submittedAt":"2026-01-04T00:00:00Z"}'
online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'latest owner review was dismissed'
fx_owner_review 7 COMMENTED "$A" '{"submittedAt":"2026-01-05T00:00:00Z"}'
online; assert_eq 1 "$STATUS" 'a COMMENT cannot revive an approval'
approve "$A" '{"submittedAt":"2026-01-06T00:00:00Z"}'
online; assert_eq 0 "$STATUS" "$OUTPUT"

it 'code fixes keep owner approval, but L0 changes lapse it'
fresh; approve
printf '\nfixed\n' >> source.txt; git commit -qam code; B="$(git rev-parse HEAD)"
fx_activity "$A" "$B" '{"timestamp":"2026-01-03T00:00:00Z"}'
online; assert_eq 0 "$STATUS" "$OUTPUT"
printf '# Product\nChanged again.\n' > specs/product.md; git commit -qam spec
online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'L0/L1 spec changed'

it 'a drifted commit oid fails in ordinary, repeated-head and merge-push sequences'
for sequence in ordinary repeated merge; do
    fresh
    printf '\nfixed\n' >> source.txt; git commit -qam code; B="$(git rev-parse HEAD)"
    if [ "$sequence" = repeated ]; then
        printf '[]\n' > "$GH_STUB_DIR/activity.json"
        fx_activity 0000000000000000000000000000000000000000 "$B" '{"activity_type":"branch_creation","timestamp":"2026-01-01T00:00:00Z"}'
        fx_activity "$B" "$A" '{"activity_type":"force_push","timestamp":"2026-01-01T12:00:00Z"}'
    elif [ "$sequence" = merge ]; then
        jq '.[0].activity_type="pr_merge"' "$GH_STUB_DIR/activity.json" > .git/activity
        mv .git/activity "$GH_STUB_DIR/activity.json"
    fi
    approve "$B"
    fx_activity "$A" "$B" '{"timestamp":"2026-01-03T00:00:00Z"}'
    online; assert_eq 1 "$STATUS" "$sequence drift must fail"
    assert_contains "$OUTPUT" 'cannot be confirmed as the PR head'
done

it 'same-second, deletion, unknown type, retention and deciding-window gaps fail closed'
for problem in tie deletion unknown aged gap current-gap; do
    fresh; approve
    case "$problem" in
        tie) fx_activity "$A" "$A" '{"timestamp":"2026-01-02T00:00:00Z"}' ;;
        deletion) fx_activity "$A" 0000000000000000000000000000000000000000 '{"activity_type":"branch_deletion","timestamp":"2026-01-01T12:00:00Z"}' ;;
        unknown) fx_activity "$A" "$A" '{"activity_type":"future_type","timestamp":"2026-01-01T12:00:00Z"}' ;;
        aged) printf '[]\n' > "$GH_STUB_DIR/activity.json" ;;
        gap) fx_activity aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$A" '{"timestamp":"2026-01-03T00:00:00Z"}' ;;
        current-gap) printf '\nchanged\n' >> source.txt; git commit -qam code ;;
    esac
    online; assert_eq 1 "$STATUS" "$problem fails closed"
    assert_contains "$OUTPUT" 'push a commit (a record-only commit is enough) and approve again'
done

it 'old continuity gaps do not poison a fresh deciding window; a new push repairs retention'
fresh
fx_activity aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "$A" '{"activity_type":"force_push","timestamp":"2026-01-01T12:00:00Z"}'
approve; online; assert_eq 0 "$STATUS" 'an older gap is outside the deciding window'
printf '[]\n' > "$GH_STUB_DIR/activity.json"
approve "$A" '{"submittedAt":"2026-01-04T00:00:00Z"}'
online; assert_eq 1 "$STATUS" 'approval without a new push cannot repair an aged-out log'
printf '\nrecord-only note\n' >> specs/changes/001-reviewed.md; git commit -qam witness; B="$(git rev-parse HEAD)"
fx_activity "$A" "$B" '{"timestamp":"2026-01-05T00:00:00Z"}'
approve "$B" '{"submittedAt":"2026-01-06T00:00:00Z"}'
online; assert_eq 0 "$STATUS" "$OUTPUT"

it 'activity errors are unavailable; author spoofing and owner State text never approve'
fresh; approve
run env GH_STUB_FAIL=activity bash "$CHECK" --json --pr "$PR" 001-reviewed
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" '"authority":"unavailable"'
fresh
fx_owner_review 7 APPROVED "$A" '{"author":{"__typename":"Bot","databaseId":1003}}'
online; assert_eq 1 "$STATUS" 'owner author typename is checked'
printf '**Review**: round 1 · ignored · owner · PASS\n' >> specs/changes/001-reviewed.md; git commit -qam text
online; assert_eq 1 "$STATUS" 'a State line supplies no owner verdict'
fresh; approve; AUTHOR_OVERRIDE='{"user":{"id":1003},"author":{"databaseId":1003}}'
online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'owner authored this PR'

it 'owner and unnamed legacy blockers require a valid approval whose history includes them'
for reviewer in owner ''; do
    fresh; approve
    printf '**Review**: round 1 · ignored · %s · FAIL\n' "$reviewer" >> specs/changes/001-reviewed.md
    git commit -qam blocker; B="$(git rev-parse HEAD)"
    # Same L0/L1, but the old approval cannot have seen the new blocker.
    fx_activity "$A" "$B" '{"timestamp":"2026-01-03T00:00:00Z"}'
    online; assert_eq 1 "$STATUS"; assert_eq false "$(printf '%s' "$OUTPUT" | jq '.legacy_blockers[0].cleared')"
    approve "$B" '{"submittedAt":"2026-01-04T00:00:00Z"}'
    online; assert_eq 0 "$STATUS" "$OUTPUT"; assert_eq true "$(printf '%s' "$OUTPUT" | jq '.legacy_blockers[0].cleared')"
done

it 'approve-request-approve and dismissed approval variants follow the latest decisive state'
fresh; approve
fx_owner_review 7 CHANGES_REQUESTED "$A" '{"submittedAt":"2026-01-03T00:00:00Z"}'
approve "$A" '{"submittedAt":"2026-01-04T00:00:00Z"}'
online; assert_eq 0 "$STATUS" "$OUTPUT"
fresh; approve
fx_owner_review 7 DISMISSED "$A" '{"submittedAt":"2026-01-03T00:00:00Z"}'
online; assert_eq 1 "$STATUS" 'a dismissed later approval is a barrier to the earlier one'
assert_eq DISMISSED "$(printf '%s' "$OUTPUT" | jq -r .owner.state)"

it 'activity for another ref cannot cause a submission tie or witness this branch'
fresh; approve
fx_activity "$A" "$A" '{"ref":"refs/heads/other","timestamp":"2026-01-02T00:00:00Z"}'
online; assert_eq 0 "$STATUS" "$OUTPUT"
fresh; approve
jq 'map(.ref="refs/heads/other")' "$GH_STUB_DIR/activity.json" > .git/activity
mv .git/activity "$GH_STUB_DIR/activity.json"
online; assert_eq 1 "$STATUS" 'another refs push cannot confirm this approval'
assert_contains "$OUTPUT" 'cannot be confirmed as the PR head'

it 'owner submission times with fractions, offsets or malformed text fail closed'
for submitted in '2026-01-02T00:00:00.5Z' '2026-01-02T00:00:00+00:00' 'not-a-timestamp'; do
    fresh; approve "$A" "$(jq -cn --arg time "$submitted" '{submittedAt:$time}')"
    online; assert_eq 1 "$STATUS" "$submitted cannot order the owner review"
    assert_contains "$OUTPUT" '"authority":"unavailable"'
done

it 'activity pagination reads the deciding entry on page two and rejects a later page error'
fresh; approve
fx_activity "$A" "$A" '{"activity_type":"pr_merge","timestamp":"2026-01-01T12:00:00Z"}'
GH_STUB_ACTIVITY_PAGE_SIZE=1; export GH_STUB_ACTIVITY_PAGE_SIZE
online; assert_eq 0 "$STATUS" "$OUTPUT"
assert_contains "$(cat "$GH_STUB_DIR/requests")" 'page activity page=2'
run env GH_STUB_FAIL=activity-page-2 bash "$CHECK" --json --pr "$PR" 001-reviewed
assert_eq 1 "$STATUS" 'a successful first page cannot hide an unreadable second page'
assert_contains "$OUTPUT" '"authority":"unavailable"'
run env GH_STUB_PARTIAL=activity bash "$CHECK" --json --pr "$PR" 001-reviewed
assert_eq 1 "$STATUS" 'malformed activity is not an empty log'
assert_contains "$OUTPUT" 'complete owner activity log'
unset GH_STUB_ACTIVITY_PAGE_SIZE

it 'all supported deciding types confirm the head, independent of fixture order'
for kind in push force_push branch_creation pr_merge merge_queue_merge; do
    fresh; approve
    fx_activity "$A" "$A" "$(jq -cn --arg kind "$kind" '{activity_type:$kind,timestamp:"2026-01-01T12:00:00Z"}')"
    jq reverse "$GH_STUB_DIR/activity.json" > .git/activity
    mv .git/activity "$GH_STUB_DIR/activity.json"
    online; assert_eq 0 "$STATUS" "$kind: $OUTPUT"
done

it 'a confirmed but missing approved commit names the exact fetch instead of passing by tokens'
fresh; MISSING=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
approve "$MISSING"
printf '[]\n' > "$GH_STUB_DIR/activity.json"
fx_activity 0000000000000000000000000000000000000000 "$MISSING" '{"activity_type":"branch_creation","timestamp":"2026-01-01T00:00:00Z"}'
fx_activity "$MISSING" "$A" '{"timestamp":"2026-01-03T00:00:00Z"}'
online; assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "the owner approved $MISSING, which is not here; git fetch origin $MISSING"

it 'reparenting identical content keeps approval, while an L1 edit lapses it'
fresh; approve
# A different parent, as after a rebase/squash, with exactly the approved tree.
NEW_BASE="$(printf 'base advanced\n' | git commit-tree "$(git rev-parse "$BASE^{tree}")" -p "$BASE")"
git update-ref refs/remotes/origin/main "$NEW_BASE"
REBASED="$(printf 'rebased delivery\n' | git commit-tree "$(git rev-parse "$A^{tree}")" -p "$NEW_BASE")"
git reset -q --hard "$REBASED"
fx_activity "$A" "$REBASED" '{"activity_type":"force_push","timestamp":"2026-01-03T00:00:00Z"}'
online; assert_eq 0 "$STATUS" "$OUTPUT"
printf '# Architecture\nChanged contract.\n' > specs/architecture.md
git add specs/architecture.md; git commit -qm L1
online; assert_eq 1 "$STATUS" 'architecture specification edits need the owner again'
assert_contains "$OUTPUT" 'L0/L1 spec changed'

it 'native owner snapshots and structure previews never invoke gh or jq'
fresh; approve; online --save-receipts .git/owner-offline
assert_eq 0 "$STATUS" "$OUTPUT"
TOOLS="$(mktemp -d)"; track_tmp "$TOOLS"
sha_tool=sha256sum; command -v sha256sum >/dev/null 2>&1 || sha_tool=shasum
for cmd in bash dirname basename git sed awk tr head tail grep cat mktemp rm mv mkdir wc sort "$sha_tool"; do
    ln -s "$(command -v "$cmd")" "$TOOLS/$cmd"
done
: > "$GH_STUB_DIR/requests"
run env PATH="$TOOLS" bash "$CHECK" --json --receipts .git/owner-offline 001-reviewed
assert_eq 3 "$STATUS" "$OUTPUT"
assert_eq "$A" "$(printf '%s' "$OUTPUT" | jq -r .owner.head_at_submission)"
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
run env PATH="$TOOLS" bash "$CHECK" --json 001-reviewed
assert_eq 1 "$STATUS" 'no source cannot approve or supply independent coverage'
assert_contains "$OUTPUT" '"authority":"none"'
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

it 'owner snapshot submission times are validated offline too'
awk -F '\037' -v OFS='\037' '$1=="O" { $3="2026-01-02T00:00:00.5Z" } { print }' .git/owner-offline > .git/owner-bad-time
run env PATH="$TOOLS" bash "$CHECK" --json --receipts .git/owner-bad-time 001-reviewed
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'malformed receipt snapshot'
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

it 'inherited owner and unnamed blockers clear on T0, record-only closing and a new carrier'
for reviewer in owner ''; do
    for mode in docs closing carrier; do
        fresh; git reset -q --hard "$BASE"
        mkdir -p specs/changes docs
        printf '# Record\n**Tier**: T0\n## State\n**Review**: round 1 · ignored · %s · FAIL\n**Review**: round 2 · ignored · owner · PASS\n' "$reviewer" > specs/changes/001-reviewed.md
        if [ "$mode" = docs ]; then
            printf documentation > docs/guide.md; git add -A; git commit -qm docs
            CHANGE=001-reviewed
        else
            git add specs/changes; git commit -qm inherited
            git update-ref refs/remotes/origin/main HEAD
            git rm -q specs/changes/001-reviewed.md
            mkdir -p specs/log; printf -- '- 2026-01-01 001-reviewed: closed\n' > specs/log/001-reviewed.md
            CHANGE=001-reviewed
            if [ "$mode" = carrier ]; then
                CHANGE=002-carrier
                mkdir -p specs/changes
                printf '# Carrier\n**Tier**: T1\n## State\n' > specs/changes/002-carrier.md
                printf implementation > source.txt
            fi
            git add -A; git commit -qm "$mode"
        fi
        AT="$(git rev-parse HEAD)"; use_gh_stub; fx_pr 7 "$AT"
        if [ "$mode" = carrier ]; then
            run bash .prdkit/scripts/bash/publish-review.sh "$CHANGE" --pr "$PR" --reviewer code --verdict PASS --counts 0,0,0,0 --report https://example.invalid/report --head HEAD
            assert_eq 0 "$STATUS" "$OUTPUT"
        fi
        run bash "$CHECK" --json --pr "$PR" "$CHANGE"
        assert_eq 1 "$STATUS" "$mode waits for native approval"
        assert_eq false "$(printf '%s' "$OUTPUT" | jq '.legacy_blockers[0].cleared')"
        fx_activity 0000000000000000000000000000000000000000 "$AT" '{"activity_type":"branch_creation","timestamp":"2026-01-01T00:00:00Z"}'
        fx_owner_review 7 DISMISSED "$AT"
        run bash "$CHECK" --json --pr "$PR" "$CHANGE"
        assert_eq 1 "$STATUS" 'dismissed approval cannot clear an inherited owner blocker'
        fx_owner_review 7 APPROVED "$AT" '{"submittedAt":"2026-01-03T00:00:00Z"}'
        run bash "$CHECK" --json --pr "$PR" --save-receipts .git/owner-clearance "$CHANGE"
        assert_eq 0 "$STATUS" "$mode: $OUTPUT"
        assert_eq true "$(printf '%s' "$OUTPUT" | jq '.legacy_blockers[0].cleared')"
        : > "$GH_STUB_DIR/requests"
        run env PATH="$TOOLS" bash "$CHECK" --json --receipts .git/owner-clearance "$CHANGE"
        assert_eq 3 "$STATUS" "$mode snapshot: $OUTPUT"
        assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
    done
done

# These fixtures isolate PR-wide owner barriers from tier, scope and receipt errors.
# No real host or approval is used; every review below belongs to the local stub.
barrier_fixture() {
    fresh; git reset -q --hard "$BASE"
    CHANGE=001-reviewed; MODE="$1"
    mkdir -p specs/changes docs
    TIER="$MODE"
    case "$MODE" in
        record-only|closing|renamed|missing) TIER=T1 ;;
    esac
    if [ "$MODE" != missing ]; then
        printf '# Record\n**Tier**: %s\n## State\n' "$TIER" > "specs/changes/$CHANGE.md"
    fi
    case "$MODE" in
        T0|missing) printf documentation > docs/guide.md ;;
        record-only|closing) ;;
        *) printf implementation > source.txt ;;
    esac
    git add -A; git commit -qm delivery
    if [ "$MODE" = closing ]; then
        git rm -q "specs/changes/$CHANGE.md"
        mkdir -p specs/log
        printf -- '- 2026-01-01 %s: closed\n' "$CHANGE" > "specs/log/$CHANGE.md"
        git add -A; git commit -qm closure
    elif [ "$MODE" = renamed ]; then
        git mv "specs/changes/$CHANGE.md" specs/changes/002-carrier.md
        git commit -qm carrier; CHANGE=002-carrier
    fi
    AT="$(git rev-parse HEAD)"; use_gh_stub; fx_pr 7 "$AT"
    fx_activity 0000000000000000000000000000000000000000 "$AT" '{"activity_type":"branch_creation","timestamp":"2026-01-01T00:00:00Z"}'
    case "$MODE" in
        T1|T2|T3|renamed)
            FP="$(review_fingerprint "$PROJ" "$CHANGE" "$BASE" "$AT")"
            BODY="$(jq -cn --arg head "$AT" --arg base "$BASE" --arg fp "$FP" --arg change "$CHANGE" '
                {schema:"prdkit.review.v3",id:"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",repo:"owner/repo",pr:7,
                 change:$change,reviewer:"code",from:"start",to:$fp,head:$head,since:"",
                 base:"refs/remotes/origin/main",base_at:$base,verdict:"PASS",
                 critical:0,high:0,medium:0,low:0,report:"https://example.invalid/report"}')"
            fx_review 7 "$(printf '<!-- prdkit-review\n%s\n-->\n' "$BODY")" ;;
    esac
}
barrier_check() { run bash "$CHECK" --json --pr "$PR" "$@" "$CHANGE"; }
barrier_assert() {
    assert_eq 1 "$STATUS" "$OUTPUT"
    assert_eq host "$(printf '%s' "$OUTPUT" | jq -r .authority)"
    assert_eq "$1" "$(printf '%s' "$OUTPUT" | jq -r '.owner.barriers[0].state')"
    assert_eq user:1003 "$(printf '%s' "$OUTPUT" | jq -r '.owner.barriers[0].actor')"
    assert_contains "$OUTPUT" "$2"
    assert_not_contains "$OUTPUT" 'needs a recorded independent review' 'clean coverage cannot mask the owner barrier'
    assert_eq 0 "$(printf '%s' "$OUTPUT" | jq .invalid_receipts)"
}

it 'owner negatives block every tier, record-only closure, renamed and missing carriers'
for MODE in T0 T1 T2 T3 record-only closing renamed missing; do
    barrier_fixture "$MODE"
    barrier_check
    case "$MODE" in
        T3) assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" "T3 needs the owner's native approval too" ;;
        missing) assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'No change record' ;;
        *) assert_eq 0 "$STATUS" "$MODE event-free control: $OUTPUT"; assert_eq '[]' "$(printf '%s' "$OUTPUT" | jq -c .problems)" ;;
    esac
    fx_owner_review 7 CHANGES_REQUESTED "$AT"
    barrier_check --save-receipts .git/barrier-snapshot
    barrier_assert CHANGES_REQUESTED 'changes requested, not PASS'
    if [ "$MODE" = missing ]; then
        assert_eq '' "$(printf '%s' "$OUTPUT" | jq -r .tier)" 'missing carrier is diagnosed separately'
        assert_contains "$OUTPUT" 'No change record'
    else
        assert_eq "$TIER" "$(printf '%s' "$OUTPUT" | jq -r .tier)"
    fi
    assert_eq "$([ "$MODE" = record-only ] || [ "$MODE" = closing ] && echo true || echo false)" \
        "$(printf '%s' "$OUTPUT" | jq -r .record_only)"
    fx_owner_review 7 DISMISSED "$AT" '{"submittedAt":"2026-01-03T00:00:00Z"}'
    barrier_check
    barrier_assert DISMISSED 'latest owner review was dismissed'
    assert_not_contains "$OUTPUT" 'changes requested, not PASS' 'dismissal has its own revocation reason'
done

it 'COMMENTED, PENDING, maker text and a tier rewrite cannot clear an owner barrier'
barrier_fixture record-only
fx_owner_review 7 CHANGES_REQUESTED "$AT"
fx_owner_review 7 COMMENTED "$AT" '{"submittedAt":"2026-01-03T00:00:00Z"}'
fx_owner_review 7 PENDING "$AT" '{"submittedAt":null}'
printf '# Record\n**Tier**: T0\n## State\n**Review**: round 1 · ignored · owner · PASS\n' > specs/changes/001-reviewed.md
git commit -qam metadata; AT="$(git rev-parse HEAD)"; fx_pr 7 "$AT"
barrier_check
barrier_assert CHANGES_REQUESTED 'changes requested, not PASS'
assert_eq true "$(printf '%s' "$OUTPUT" | jq .record_only)"

it 'later approval clears only the issuing actor, with numeric decisive ordering'
barrier_fixture T1
sed 's/review-owner: user:1003/review-owner: user:1003, user:1004/' .prdkit/memory/config.md |
    trusted_edit refs/remotes/origin/main .prdkit/memory/config.md
fx_owner_review 7 CHANGES_REQUESTED "$AT" '{"fullDatabaseId":"9999"}'
fx_owner_review 7 APPROVED "$AT" '{"fullDatabaseId":"10000","author":{"databaseId":1004}}'
barrier_check
barrier_assert CHANGES_REQUESTED 'changes requested, not PASS'
assert_eq user:1004 "$(printf '%s' "$OUTPUT" | jq -r .owner.actor)"
fx_owner_review 7 APPROVED "$AT" '{"fullDatabaseId":"10001"}'
jq reverse "$GH_STUB_DIR/reviews/7.json" > .git/reversed
mv .git/reversed "$GH_STUB_DIR/reviews/7.json"
barrier_check --save-receipts .git/multi-owner
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq '[]' "$(printf '%s' "$OUTPUT" | jq -c .owner.barriers)"
fx_owner_review 7 DISMISSED "$AT" '{"fullDatabaseId":"10002","author":{"databaseId":1004}}'
barrier_check
assert_eq 1 "$STATUS"
assert_eq '[["user:1004","10002","DISMISSED"]]' \
    "$(printf '%s' "$OUTPUT" | jq -c '[.owner.barriers[]|[.actor,.review,.state]]')"
fx_owner_review 7 APPROVED "$AT" '{"fullDatabaseId":"10003"}'
barrier_check; assert_eq 1 "$STATUS" 'another actor still cannot clear the dismissal'
fx_owner_review 7 APPROVED "$AT" '{"fullDatabaseId":"10004","author":{"databaseId":1004}}'
barrier_check; assert_eq 0 "$STATUS" "$OUTPUT"

it 'timestamps precede numeric ids and every issuing actor keeps its barrier'
barrier_fixture T1
sed 's/review-owner: user:1003/review-owner: user:1003, user:1004/' .prdkit/memory/config.md |
    trusted_edit refs/remotes/origin/main .prdkit/memory/config.md
fx_owner_review 7 CHANGES_REQUESTED "$AT" '{"fullDatabaseId":"10000"}'
fx_owner_review 7 DISMISSED "$AT" '{"fullDatabaseId":"10001","author":{"databaseId":1004}}'
barrier_check
assert_eq 1 "$STATUS"
assert_eq '[["user:1003","CHANGES_REQUESTED"],["user:1004","DISMISSED"]]' \
    "$(printf '%s' "$OUTPUT" | jq -c '[.owner.barriers[]|[.actor,.state]]')"
fx_owner_review 7 APPROVED "$AT" '{"fullDatabaseId":"9999","submittedAt":"2026-01-03T00:00:00Z"}'
barrier_check
assert_eq 1 "$STATUS"
assert_eq '[["user:1004","DISMISSED"]]' "$(printf '%s' "$OUTPUT" | jq -c '[.owner.barriers[]|[.actor,.state]]')"
fx_owner_review 7 APPROVED "$AT" '{"fullDatabaseId":"9998","submittedAt":"2026-01-04T00:00:00Z","author":{"databaseId":1004}}'
barrier_check; assert_eq 0 "$STATUS" "$OUTPUT"

it 'an invalid later approval cannot erase the earlier negative at an exempt tier'
for INVALID in unwitnessed tie missing-object stale-slice self; do
    barrier_fixture record-only
    fx_owner_review 7 CHANGES_REQUESTED "$AT"
    APPROVED_AT="$AT"
    case "$INVALID" in
        unwitnessed) printf '[]\n' > "$GH_STUB_DIR/activity.json" ;;
        tie) fx_activity "$AT" "$AT" '{"timestamp":"2026-01-04T00:00:00Z"}' ;;
        missing-object)
            APPROVED_AT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
            printf '[]\n' > "$GH_STUB_DIR/activity.json"
            fx_activity 0000000000000000000000000000000000000000 "$APPROVED_AT" '{"activity_type":"branch_creation","timestamp":"2026-01-01T00:00:00Z"}'
            fx_activity "$APPROVED_AT" "$AT" '{"timestamp":"2026-01-05T00:00:00Z"}' ;;
        stale-slice)
            printf '# Product\nLater slice.\n' > specs/product.md
            git add specs/product.md; git commit -qm spec; LATER="$(git rev-parse HEAD)"
            fx_activity "$AT" "$LATER" '{"timestamp":"2026-01-05T00:00:00Z"}'
            fx_pr 7 "$LATER"
            # Keep code coverage clean despite the L0-induced T3 requirement.
            FP="$(review_fingerprint "$PROJ" "$CHANGE" "$BASE" "$LATER")"
            BODY="$(jq -cn --arg head "$LATER" --arg base "$BASE" --arg fp "$FP" '
                {schema:"prdkit.review.v3",id:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",repo:"owner/repo",pr:7,
                 change:"001-reviewed",reviewer:"code",from:"start",to:$fp,head:$head,since:"",
                 base:"refs/remotes/origin/main",base_at:$base,verdict:"PASS",
                 critical:0,high:0,medium:0,low:0,report:"https://example.invalid/report"}')"
            fx_review 7 "$(printf '<!-- prdkit-review\n%s\n-->\n' "$BODY")" ;;
        self) fx_pr 7 "$AT" '{"user":{"id":1003},"author":{"databaseId":1003}}' ;;
    esac
    fx_owner_review 7 APPROVED "$APPROVED_AT" '{"submittedAt":"2026-01-04T00:00:00Z"}'
    barrier_check
    barrier_assert CHANGES_REQUESTED 'changes requested, not PASS'
    assert_contains "$OUTPUT" 'later review' 'the invalid clearing attempt is diagnosed too'
    case "$INVALID" in
        unwitnessed|tie) assert_contains "$OUTPUT" 'cannot be confirmed as the PR head' ;;
        missing-object) assert_contains "$OUTPUT" "the owner approved $APPROVED_AT, which is not here" ;;
        stale-slice) assert_contains "$OUTPUT" 'L0/L1 spec changed' ;;
        self) assert_contains "$OUTPUT" 'owner authored this PR' ;;
    esac
done

it 'same-issuer valid approval clears the barrier without becoming independent coverage'
barrier_fixture T0
fx_owner_review 7 CHANGES_REQUESTED "$AT"
fx_owner_review 7 APPROVED "$AT" '{"submittedAt":"2026-01-03T00:00:00Z"}'
barrier_check --save-receipts .git/cleared-barrier
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq '[]' "$(printf '%s' "$OUTPUT" | jq -c .owner.barriers)"
assert_eq '[]' "$(printf '%s' "$OUTPUT" | jq -c .reviews)"
: > "$GH_STUB_DIR/requests"
run env PATH="$TOOLS" bash "$CHECK" --json --receipts .git/cleared-barrier "$CHANGE"
assert_eq 3 "$STATUS" "$OUTPUT"
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

it 'native barriers use personal configured identities on this PR, not closed-PR approval'
barrier_fixture T0
fx_owner_review 7 CHANGES_REQUESTED "$AT" '{"author":{"__typename":"Bot"}}'
fx_owner_review 7 CHANGES_REQUESTED "$AT" '{"author":{"databaseId":2003}}'
barrier_check; assert_eq 0 "$STATUS" "$OUTPUT"
fx_closed_pr 6 "$AT"
fx_owner_review 6 CHANGES_REQUESTED "$AT"
barrier_check; assert_eq 0 "$STATUS" 'no new cross-PR native barrier carry is invented'
fx_owner_review 7 CHANGES_REQUESTED "$AT"
fx_owner_review 6 APPROVED "$AT" '{"submittedAt":"2026-01-03T00:00:00Z"}'
barrier_check
barrier_assert CHANGES_REQUESTED 'changes requested, not PASS'

it 'actorless old snapshots and duplicate owner ids cannot prove clearance'
awk -F '\037' -v OFS='\037' 'NR==1 { $1="prdkit-receipts 1" } $1=="O" { NF=6 } { print }' \
    .git/multi-owner > .git/old-owner
: > "$GH_STUB_DIR/requests"
run env PATH="$TOOLS" bash "$CHECK" --json --receipts .git/old-owner 001-reviewed
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'malformed receipt snapshot'
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
barrier_fixture T0
fx_owner_review 7 CHANGES_REQUESTED "$AT" '{"fullDatabaseId":"9001"}'
fx_owner_review 7 APPROVED "$AT" '{"fullDatabaseId":"9001"}'
barrier_check
assert_eq 1 "$STATUS"
assert_eq unavailable "$(printf '%s' "$OUTPUT" | jq -r .authority)"
for TAMPER in actorless unlisted duplicate; do
    awk -F '\037' -v OFS='\037' -v tamper="$TAMPER" '
        $1=="O" {
            if (tamper=="actorless") NF=6
            if (tamper=="unlisted") $7="user:2003"
            if (tamper=="duplicate") print
        } { print }' .git/multi-owner > .git/tampered-owner
    : > "$GH_STUB_DIR/requests"
    run env PATH="$TOOLS" bash "$CHECK" --json --receipts .git/tampered-owner 001-reviewed
    assert_eq 1 "$STATUS" "$TAMPER"
    assert_not_contains "$OUTPUT" '"result":"pass"'
    if [ "$TAMPER" = unlisted ]; then
        assert_contains "$OUTPUT" 'has no configured actor identity'
        assert_eq unavailable "$(printf '%s' "$OUTPUT" | jq -r .authority)"
    else assert_contains "$OUTPUT" 'malformed receipt snapshot'; fi
    assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
done

it 'missing or ambiguous owner authority is unavailable rather than event-free'
for BROKEN in '.author=null' '.author.databaseId=null' '.state="FUTURE"' '.state=null'; do
    barrier_fixture T0
    fx_owner_review 7 CHANGES_REQUESTED "$AT"
    jq "map($BROKEN)" "$GH_STUB_DIR/reviews/7.json" > .git/broken-owner
    mv .git/broken-owner "$GH_STUB_DIR/reviews/7.json"
    barrier_check
    assert_eq 1 "$STATUS" "$BROKEN"
    assert_eq unavailable "$(printf '%s' "$OUTPUT" | jq -r .authority)"
done
finish
