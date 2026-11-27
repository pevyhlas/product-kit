#!/usr/bin/env bash
# Real gate modes. No recipe bridge: host evidence and record text vary independently here.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
STATUS=0
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
CHECK="${TEST_REVIEW_GATE:-$PROJ/.prdkit/scripts/bash/check-review.sh}"
cat > .prdkit/memory/config.md <<'EOF'

## Configuration
- review-host: github
- review-publishers: bot:1001, user:1002, user:1003, user:1004
- review-owner: user:1003, user:1005
- review-t0-paths: docs/
EOF
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n| second | reviewer |\n' >> .prdkit/memory/agents.md
mkdir -p .prdkit/history
printf -- '- 2026-01-02 002-earlier: completed\n' > .prdkit/history/log.md
git add -A; git commit -qm baseline
BASE="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git checkout -qb 001-reviewed
mkdir -p specs/changes
printf '# Change: reviewed\n**Tier**: T1\n## State\n' > specs/changes/001-reviewed.md
printf 'implementation\n' > source.txt
git add -A; git commit -qm implementation
HEAD_SHA="$(git rev-parse HEAD)"
PR=https://github.com/owner/repo/pull/7
use_gh_stub
fx_pr 7 "$HEAD_SHA"
online() { run bash "$CHECK" --json --pr "$PR" 001-reviewed; }

publisher_review() { # state commit [override object]
    fx_review 7 'Independent review.' "$(jq -cn --arg state "$1" --arg head "$2" --argjson extra "${3:-null}" '{state:$state,commit:{oid:$head}} * ($extra // {})')"
}
dismiss_review() { # GitHub updates the original review, not a separate timeline entry.
    local f="$GH_STUB_DIR/reviews/7.json"
    jq --arg id "$1" 'map(if (.fullDatabaseId|tostring)==$id then .state="DISMISSED" else . end)' "$f" > "$f.new" && mv "$f.new" "$f"
}
it 'only native approvals from an allowed non-author account count'
fx_review 7 'Verdict: PASS'
online; assert_eq 1 "$STATUS" 'review body is not approval'
fx_owner_review 7 APPROVED "$HEAD_SHA" '{"author":{"databaseId":1009}}'
fx_owner_review 7 APPROVED "$HEAD_SHA" '{"author":{"databaseId":1002}}'
online; assert_eq 1 "$STATUS" 'even an allowlisted PR author never counts'
fx_review 7 'reviewed' '{"state":"APPROVED"}'
online; assert_eq 0 "$STATUS" "eligible publisher: $OUTPUT"
git show "$BASE:.prdkit/memory/config.md" | { cat; echo '- review-publisher-isolation: shared'; } |
    trusted_edit refs/remotes/origin/main .prdkit/memory/config.md
online; assert_eq 1 "$STATUS" 'retired receipt policy fails closed'
assert_contains "$OUTPUT" 'review-publisher-isolation is unsupported'
git update-ref refs/remotes/origin/main "$BASE"; online
assert_contains "$OUTPUT" '"authority":"host"'
assert_contains "$OUTPUT" '"reviewer":1001'

it 'only the latest submitted review by that account on the exact head decides'
for state in CHANGES_REQUESTED DISMISSED COMMENTED; do
    printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
    publisher_review APPROVED "$HEAD_SHA"; online; assert_eq 0 "$STATUS" 'publisher qualifies at T1'
    publisher_review "$state" "$BASE"; online
    if [ "$state" = CHANGES_REQUESTED ]; then assert_eq 1 "$STATUS" 'later objection on another SHA blocks'
    else assert_eq 0 "$STATUS" 'other commits cannot revoke a positive approval'; fi
    publisher_review "$state" "$HEAD_SHA" '{"submittedAt":"2026-02-01T00:00:00Z"}'
    publisher_review APPROVED "$HEAD_SHA" # earlier submission time, despite appearing last
    online; assert_eq 1 "$STATUS" "$state overrides earlier approval"
done
publisher_review APPROVED "$HEAD_SHA" '{"submittedAt":"2026-02-02T00:00:00Z"}'; online; assert_eq 0 "$STATUS" 'independent approved publisher still counts'
fx_review 7 draft '{"state":"PENDING","submittedAt":null}'; online; assert_eq 0 "$STATUS" 'draft is not submitted'

it 'one publisher cannot outvote another publisher on the same head'
second='{"author":{"databaseId":1004}}'
publisher_review CHANGES_REQUESTED "$HEAD_SHA" "$second"
GH_STUB_PAGE_SIZE=1 online; assert_eq 1 "$STATUS" 'T1 objection blocks despite an independent approval'
assert_contains "$OUTPUT" '"blocking":[{"reviewer":1004,'
run bash "$CHECK" --pr "$PR" 001-reviewed
block_id="$(jq -r 'last.fullDatabaseId' "$GH_STUB_DIR/reviews/7.json")"
assert_contains "$OUTPUT" "publisher 1004 (review $block_id on $HEAD_SHA)"
publisher_review APPROVED "$HEAD_SHA" "$second"; online; assert_eq 0 "$STATUS" 'objector later approves'
assert_contains "$OUTPUT" '"blocking":[]'

it 'pushing even a metadata-only commit requires fresh approval'
git commit -q --allow-empty -m 'new exact head'; online; assert_eq 1 "$STATUS" 'unpublished descendant cannot pass'
HEAD_SHA="$(git rev-parse HEAD)"; fx_pr 7 "$HEAD_SHA"; online; assert_eq 1 "$STATUS" 'old commit cannot approve new head'
fx_pr 7 ''; online; assert_eq 1 "$STATUS" 'empty PR head is an error'; assert_contains "$OUTPUT" '"authority":"unavailable"'
fx_pr 7 "$HEAD_SHA"

it 'every page must be complete and advance even after an eligible approval'
printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
publisher_review APPROVED "$HEAD_SHA"
publisher_review CHANGES_REQUESTED "$HEAD_SHA" '{"submittedAt":"2026-02-01T00:00:00Z"}'
GH_STUB_PAGE_SIZE=1 online; assert_eq 1 "$STATUS" 'second page revokes'
assert_contains "$(cat "$GH_STUB_DIR/requests")" 'after=cursor-1'
publisher_review APPROVED "$HEAD_SHA" '{"submittedAt":"2026-02-02T00:00:00Z"}'
GH_STUB_PAGE_SIZE=1 online; assert_eq 0 "$STATUS" 'last page restores approval'
GH_STUB_FAIL=graphql:PrdkitReviews online; assert_eq 1 "$STATUS" 'API failure'; assert_contains "$OUTPUT" '"authority":"unavailable"'
query='query PrdkitReviews { fixture }'
route="$GH_STUB_DIR/routes/graphql_PrdkitReviews-7.json"
GH_STUB_PAGE_SIZE=1 gh api graphql -f query="$query" -F number=7 > "$GH_STUB_DIR/first"
for edit in '.' '.data.repository.pullRequest.reviews.pageInfo.hasNextPage=false' \
    '.data.repository.pullRequest.reviews.pageInfo.endCursor=null' \
    '.data.repository.pullRequest.reviews.nodes[0].author.databaseId=null' \
    '.errors=[{"message":"partial"}]'; do
    jq "$edit" "$GH_STUB_DIR/first" > "$route"
    online; assert_eq 1 "$STATUS" 'non-advancing cursor, partial count or API errors fail closed'
    assert_contains "$OUTPUT" '"authority":"unavailable"'
done
rm "$route"
it 'change-local configuration cannot grant the PR reviewer permission'
git show "$BASE:.prdkit/memory/config.md" | sed 's/bot:1001, user:1002, user:1003/bot:1009/' |
    trusted_edit refs/remotes/origin/main .prdkit/memory/config.md
printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"; fx_review 7 'Reviewed.' '{"state":"APPROVED"}'
online; assert_eq 1 "$STATUS" 'publisher removed at the trusted tip'
assert_contains "$OUTPUT" 'requires an independent review-publishers'
git update-ref refs/remotes/origin/main "$BASE"

TOOLS="$(mktemp -d)"; track_tmp "$TOOLS"
sha_tool=sha256sum; command -v sha256sum >/dev/null 2>&1 || sha_tool=shasum
for cmd in bash dirname basename git sed awk tr head tail grep cat mktemp rm mv mkdir wc sort "$sha_tool"; do
    ln -s "$(command -v "$cmd")" "$TOOLS/$cmd"
done
: > "$GH_STUB_DIR/requests"
for missing in gh jq; do
    if [ "$missing" = gh ]; then ln -s "$(command -v jq)" "$TOOLS/jq"
    else rm -f "$TOOLS/jq"; ln -s "$GH_STUB_DIR/bin/gh" "$TOOLS/gh"; fi
    run env PATH="$TOOLS" bash "$CHECK" --json --pr "$PR" 001-reviewed
    assert_eq 1 "$STATUS" "missing $missing cannot pass"
    assert_contains "$OUTPUT" '"authority":"unavailable"'
    assert_contains "$OUTPUT" '"result":"preview"' 'unavailable is never a JSON pass or fail verdict'
    assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
done

it 'offline structure is a preview and cannot approve'
run bash "$CHECK" --json 001-reviewed
assert_eq 3 "$STATUS" "$OUTPUT"
assert_contains "$OUTPUT" '"result":"preview"'
for retired in --receipts --save-receipts; do
    run bash "$CHECK" "$retired" snapshot 001-reviewed
    assert_eq 2 "$STATUS"
    assert_contains "$OUTPUT" "Unknown option: $retired"
done

it 'the direct gate refuses two best merge bases even with an eligible approval'
other="$(git commit-tree "$BASE^{tree}" -p "$BASE" -m 'independent target commit')"
target_tip="$(git commit-tree "$HEAD_SHA^{tree}" -p "$other" -p "$HEAD_SHA" -m 'target merges feature')"
feature_tip="$(git commit-tree "$HEAD_SHA^{tree}" -p "$HEAD_SHA" -p "$other" -m 'feature merges target')"
git update-ref refs/remotes/origin/main "$target_tip"
git checkout -q --detach "$feature_tip"
assert_eq 2 "$(git merge-base --all origin/main HEAD | wc -l | tr -d ' ')" 'fixture has two best ancestors'
fx_pr 7 "$feature_tip"; publisher_review APPROVED "$feature_tip"
online; assert_eq 1 "$STATUS" 'approval does not resolve an ambiguous review range'
assert_contains "$OUTPUT" 'multiple merge bases'
run bash "$CHECK" --json 001-reviewed
assert_eq 1 "$STATUS" 'ambiguous structure cannot pass preview either'
assert_contains "$OUTPUT" 'multiple merge bases'
it 'each effective tier enforces its own minimum; an overlapping account is owner only'
git update-ref refs/remotes/origin/main "$BASE"
for level in T0 T1 T2 T3; do
    git checkout -q --detach "$BASE"
    mkdir -p specs/changes docs
    printf '# Change\n**Tier**: %s\n## State\n' "$level" > specs/changes/001-reviewed.md
    echo doc > docs/page.md
    git add -A; git commit -qm "$level"
    h="$(git rev-parse HEAD)"; fx_pr 7 "$h"
    printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
    online
    if [ "$level" = T0 ]; then
        assert_eq 0 "$STATUS" 'T0 needs no positive approval'
        assert_contains "$OUTPUT" '"reviews":[]'
        GH_STUB_FAIL=graphql:PrdkitReviews online; assert_eq 1 "$STATUS" 'T0 still requires a complete host read'
        publisher_review CHANGES_REQUESTED "$h" '{"author":{"databaseId":1002}}'
        publisher_review CHANGES_REQUESTED "$h" '{"author":{"databaseId":1009}}'
        online; assert_eq 0 "$STATUS" 'author and unlisted objections do not block T0'
        publisher_review CHANGES_REQUESTED "$h"; online; assert_eq 1 "$STATUS" 'eligible objection blocks T0'
        assert_contains "$OUTPUT" '"blocking":[{"reviewer":1001,'
        dismiss_review "$(jq -r 'last.fullDatabaseId' "$GH_STUB_DIR/reviews/7.json")"
        online; assert_eq 0 "$STATUS" 'dismissed objection no longer blocks T0'
        assert_contains "$OUTPUT" '"reviews":[]'
        assert_contains "$OUTPUT" '"blocking":[]'
        echo 'unrelated rewrite' > .prdkit/history/log.md; git commit -qam 'shared log is not automatically exempt'
        fx_pr 7 "$(git rev-parse HEAD)"; online; assert_eq 1 "$STATUS" 'T0 must qualify structurally'
        assert_contains "$OUTPUT" 'T0 is docs only'
        continue
    fi
    assert_eq 1 "$STATUS" "$level without approval fails"
    fx_owner_review 7 APPROVED "$h"; online
    assert_eq 1 "$STATUS" "$level owner-only approval is not independent"
    assert_contains "$OUTPUT" 'requires an independent review-publishers'
    printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
    publisher_review APPROVED "$h"; online
    if [ "$level" != T3 ]; then assert_eq 0 "$STATUS" "$level independent approval suffices"; continue; fi
    assert_eq 1 "$STATUS" 'publisher alone cannot approve T3'
    assert_contains "$OUTPUT" 'also requires a review-owner'
    fx_owner_review 7 APPROVED "$BASE"; online; assert_eq 1 "$STATUS" 'older owner approval cannot qualify'
    fx_owner_review 7 APPROVED "$h"; online; assert_eq 0 "$STATUS" 'distinct publisher and owner approve T3'
    fx_owner_review 7 CHANGES_REQUESTED "$h" '{"author":{"databaseId":1005}}'
    online; assert_eq 1 "$STATUS" 'another owner objects despite both T3 approvals'
    assert_contains "$OUTPUT" '"blocking":[{"reviewer":1005,'
    dismiss_review "$(jq -r 'last.fullDatabaseId' "$GH_STUB_DIR/reviews/7.json")"
    fx_pr 7 "$h" '{"author":{"databaseId":1003}}'; online; assert_eq 1 "$STATUS" 'PR author cannot approve as owner'
    fx_pr 7 "$h"
    fx_owner_review 7 DISMISSED "$h"; online; assert_eq 1 "$STATUS" 'dismissal removes the owner approval'
    fx_owner_review 7 APPROVED "$h"; publisher_review CHANGES_REQUESTED "$h"
    online; assert_eq 1 "$STATUS" 'owner cannot compensate for publisher revocation'
done
it 'objections survive a push until their own dismissal or the objector approves the new head'
for level in T0 T1; do
    git checkout -q --detach "$BASE"
    mkdir -p specs/changes
    printf '# Change\n**Tier**: %s\n## State\n' "$level" > specs/changes/001-reviewed.md
    git add -A; git commit -qm "$level record"
    old="$(git rev-parse HEAD)"; fx_pr 7 "$old"
    f="$GH_STUB_DIR/reviews/7.json"; printf '[]\n' > "$f"
    publisher_review CHANGES_REQUESTED "$old"; objection="$(jq -r 'last.fullDatabaseId' "$f")"
    git commit -q --allow-empty -m 'new PR head'; h="$(git rev-parse HEAD)"; fx_pr 7 "$h"
    online; assert_eq 1 "$STATUS" "$level push alone cannot clear an objection"
    assert_contains "$OUTPUT" "\"blocking\":[{\"reviewer\":1001,\"review\":\"$objection\",\"role\":\"publisher\",\"commit\":\"$old\"}]"
    publisher_review APPROVED "$h" "$second"; online; assert_eq 1 "$STATUS" "$level another publisher cannot clear it"
    publisher_review APPROVED "$old"; publisher_review COMMENTED "$h"; online
    assert_eq 1 "$STATUS" "$level old-head approval and new-head comment cannot clear it"
    publisher_review DISMISSED "$h"; online; assert_eq 1 "$STATUS" "$level unrelated dismissal cannot clear it"
    publisher_review CHANGES_REQUESTED "$h"; newer="$(jq -r 'last.fullDatabaseId' "$f")"
    dismiss_review "$newer"; online; assert_eq 1 "$STATUS" "$level dismissing only the newer objection leaves the original"
    cp "$f" "$f.before"
    dismiss_review "$objection"; online; assert_eq 0 "$STATUS" "$level dismissal of the objection itself clears it"
    mv "$f.before" "$f"
    publisher_review APPROVED "$h"; GH_STUB_PAGE_SIZE=1 online
    assert_eq 0 "$STATUS" "$level later exact-head approval by the objector clears it across pages"
    assert_contains "$OUTPUT" '"blocking":[]'
done

owner_policy() {
    { git show "$BASE:.prdkit/memory/config.md"; printf '%s\n' "$@"; } |
        trusted_edit refs/remotes/origin/main .prdkit/memory/config.md
}

it 'only trusted per-PR policy lets a T3 owner approval carry to a descendant'
git checkout -q --detach "$BASE"
mkdir -p specs/changes
printf '# Change\n**Tier**: T3\n## State\n' > specs/changes/001-reviewed.md
echo '- owner-approval: per-pr' >> .prdkit/memory/config.md
git add -A; git commit -qm 'T3 implementation'
approved="$(git rev-parse HEAD)"
git commit -q --allow-empty -m 'fix "quoted" output'
git commit -q --allow-empty -m 'close review round'
h="$(git rev-parse HEAD)"; fx_pr 7 "$h"
f="$GH_STUB_DIR/reviews/7.json"; printf '[]\n' > "$f"
publisher_review APPROVED "$h"; fx_owner_review 7 APPROVED "$approved"
rid="$(jq -r 'last.fullDatabaseId' "$f")"
online; assert_eq 1 "$STATUS" 'missing key defaults to exact-head despite the candidate edit'
assert_contains "$OUTPUT" "requires a review-owner APPROVED review on the exact PR head $h"
assert_not_contains "$OUTPUT" '"owner_approval'
implicit="$(jq -c 'del(.policy_at)' <<< "$OUTPUT")"
owner_policy '- owner-approval: exact-head'
online; assert_eq 1 "$STATUS" 'explicit exact-head also refuses'
assert_eq "$implicit" "$(jq -c 'del(.policy_at)' <<< "$OUTPUT")" 'explicit and implicit exact-head have the same verdict'
owner_policy '- owner-approval: per-pr'
GH_STUB_PAGE_SIZE=1 online; assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq "per-pr 1003 $rid $approved 0" \
    "$(jq -r '.owner_approval | [.mode,.reviewer,.review,.commit,.more] | join(" ")' <<< "$OUTPUT")"
assert_eq "publisher owner" "$(jq -r '[.reviews[].role]|join(" ")' <<< "$OUTPUT")"
commits="$(git log --format='%h %s' "$approved..$h")"
assert_eq "$commits" "$(jq -r '.owner_approval.commits_since[]' <<< "$OUTPUT")"
run bash "$CHECK" --pr "$PR" 001-reviewed
assert_eq 0 "$STATUS"; assert_contains "$OUTPUT" "owner approval is per-PR, given on $approved"
while IFS= read -r line; do assert_contains "$OUTPUT" "  $line"; done <<< "$commits"

it 'the latest deciding owner review is replayed across commits and pages'
fx_owner_review 7 COMMENTED "$h"; online; assert_eq 0 "$STATUS" 'comment is not a deciding review'
fx_review 7 draft '{"state":"PENDING","submittedAt":null}'; online; assert_eq 0 "$STATUS" 'pending is ignored'
fx_owner_review 7 CHANGES_REQUESTED "$approved" '{"submittedAt":"2026-02-01T00:00:00Z"}'
fx_owner_review 7 APPROVED "$h" # appears last, but submitted before the objection
GH_STUB_PAGE_SIZE=1 online; assert_eq 1 "$STATUS" 'later objection on an earlier SHA voids approval'
assert_contains "$OUTPUT" '"blocking":[{"reviewer":1003,'
fx_owner_review 7 APPROVED "$approved" '{"submittedAt":"2026-02-02T00:00:00Z"}'
rid="$(jq -r 'last.fullDatabaseId' "$f")"
online; assert_eq 0 "$STATUS" 'later qualifying approval from the objector restores it'
assert_contains "$OUTPUT" '"blocking":[]'
dismiss_review "$rid"; online; assert_eq 1 "$STATUS" 'the latest dismissed approval does not count or restore an older approval'
assert_not_contains "$OUTPUT" '"owner_approval"'
fx_owner_review 7 APPROVED "$h" '{"submittedAt":"2026-02-03T00:00:00Z"}'
run bash "$CHECK" --pr "$PR" 001-reviewed
assert_eq 0 "$STATUS"; exact_text="$OUTPUT"
assert_not_contains "$OUTPUT" 'per-PR'
online; assert_eq 0 "$STATUS"; exact_json="$(jq -c 'del(.policy_at)' <<< "$OUTPUT")"
assert_not_contains "$OUTPUT" '"owner_approval"'
owner_policy '- owner-approval: exact-head'
run bash "$CHECK" --pr "$PR" 001-reviewed
assert_eq "$exact_text" "$OUTPUT" 'clean exact-head approval prints the same in both modes'
online; assert_eq "$exact_json" "$(jq -c 'del(.policy_at)' <<< "$OUTPUT")"
owner_policy '- owner-approval: per-pr'

it 'per-PR does not credit old publisher, non-owner or rewritten approvals'
printf '[]\n' > "$f"
publisher_review APPROVED "$approved"; fx_owner_review 7 APPROVED "$approved"
online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'requires an independent review-publishers APPROVED review'
printf '[]\n' > "$f"
publisher_review APPROVED "$h"; fx_owner_review 7 APPROVED "$approved" '{"author":{"databaseId":1009}}'
online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'requires a review-owner APPROVED review under per-PR policy'
rewritten="$(git commit-tree "$approved^{tree}" -p "$BASE" -m 'old version of this PR')"
fx_owner_review 7 APPROVED "$approved"; fx_owner_review 7 APPROVED "$rewritten"
online; assert_eq 1 "$STATUS" 'latest approval on rewritten history cannot carry or restore the prior one'
assert_eq "$rewritten" "$(jq -r '.owner_approval_not_ancestors[]' <<< "$OUTPUT")"
run bash "$CHECK" --pr "$PR" 001-reviewed
assert_contains "$OUTPUT" "approval on $rewritten does not carry over: not a verified ancestor of $h"
fx_owner_review 7 APPROVED "$approved" '{"author":{"databaseId":1005}}'
online; assert_eq 0 "$STATUS" 'a different eligible owner can still satisfy the minimum'
assert_eq 1005 "$(jq '.owner_approval.reviewer' <<< "$OUTPUT")"
fx_owner_review 7 CHANGES_REQUESTED "$approved"
online; assert_eq 1 "$STATUS" 'another owner approval cannot clear the objector'
assert_eq 1003 "$(jq '.blocking[].reviewer' <<< "$OUTPUT")"

it 'invalid or duplicate owner policy fails closed'
for value in '' sticky 'per-pr exact-head' Exact-head; do
    owner_policy "- owner-approval: $value"
    online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'Expected one owner-approval value'
    assert_contains "$OUTPUT" '"authority":"unavailable"'
done
owner_policy '- owner-approval: per-pr' '- owner-approval: per-pr'
online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'Expected one owner-approval value'
owner_policy '- owner-approval: per-pr' '- Owner-Approval: exact-head'
online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'Invalid owner-approval key'
owner_policy '- owner-approval: per-pr'

it 'per-PR commit evidence lists the first 20 lines in git log order'
for i in {1..22}; do git commit -q --allow-empty -m "follow-up $i"; done
h="$(git rev-parse HEAD)"; fx_pr 7 "$h"
printf '[]\n' > "$f"
publisher_review APPROVED "$h"; fx_owner_review 7 APPROVED "$approved"
online; assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 20 "$(jq '.owner_approval.commits_since|length' <<< "$OUTPUT")"
assert_eq 4 "$(jq '.owner_approval.more' <<< "$OUTPUT")"
assert_eq "$(git log --format='%h %s' -20 "$approved..$h")" \
    "$(jq -r '.owner_approval.commits_since[]' <<< "$OUTPUT")"
run bash "$CHECK" --pr "$PR" 001-reviewed
assert_eq 0 "$STATUS"; assert_contains "$OUTPUT" '  +4 more'
assert_not_contains "$OUTPUT" 'fix "quoted" output'

it 'per-PR policy does not change owner objections at T1 or T2'
for level in T1 T2; do
    git checkout -q --detach "$BASE"
    mkdir -p specs/changes
    printf '# Change\n**Tier**: %s\n## State\n' "$level" > specs/changes/001-reviewed.md
    git add -A; git commit -qm "$level record"
    approved="$(git rev-parse HEAD)"
    git commit -q --allow-empty -m 'new exact head'
    h="$(git rev-parse HEAD)"; fx_pr 7 "$h"; printf '[]\n' > "$f"
    publisher_review APPROVED "$h"
    fx_owner_review 7 CHANGES_REQUESTED "$approved"; fx_owner_review 7 APPROVED "$approved"
    online; assert_eq 1 "$STATUS" "$level requires an exact-head approval to clear the owner's objection"
    assert_contains "$OUTPUT" '"blocking":[{"reviewer":1003,'
    fx_owner_review 7 APPROVED "$h"; online; assert_eq 0 "$STATUS" "$OUTPUT"
done
finish
