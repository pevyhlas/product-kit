#!/usr/bin/env bash
# Real gate modes. No recipe bridge: host evidence and record text vary independently here.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
STATUS=0
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
CHECK="${TEST_REVIEW_GATE:-$PROJ/.prdkit/scripts/bash/check-review.sh}"
cat >> .prdkit/memory/config.md <<'EOF'

## Configuration
- review-host: github
- review-publishers: bot:1001, user:1002, user:1003, user:1004
- review-owner: user:1003, user:1005
- review-publisher-isolation: shared
- review-t0-paths: docs/
EOF
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n| second | reviewer |\n' >> .prdkit/memory/agents.md
mkdir -p specs
printf -- '- 2026-01-02 002-earlier: completed\n' > specs/log.md
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
it 'only native approvals from an allowed non-author account count'
fx_review 7 'Verdict: PASS'
online; assert_eq 1 "$STATUS" 'review body is not approval'
fx_owner_review 7 APPROVED "$HEAD_SHA" '{"author":{"databaseId":1009}}'
fx_owner_review 7 APPROVED "$HEAD_SHA" '{"author":{"databaseId":1002}}'
online; assert_eq 1 "$STATUS" 'even an allowlisted PR author never counts'
fx_review 7 'reviewed' '{"state":"APPROVED"}'
online; assert_eq 0 "$STATUS" "eligible publisher: $OUTPUT"
assert_contains "$OUTPUT" 'review-publisher-isolation is retired'
assert_contains "$OUTPUT" '"authority":"host"'
assert_contains "$OUTPUT" '"reviewer":1001'

it 'only the latest submitted review by that account on the exact head decides'
for state in CHANGES_REQUESTED DISMISSED COMMENTED; do
    printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
    publisher_review APPROVED "$HEAD_SHA"; online; assert_eq 0 "$STATUS" 'publisher qualifies at T1'
    publisher_review "$state" "$BASE"; online; assert_eq 0 "$STATUS" 'other commits never revoke'
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
assert_contains "$OUTPUT" "publisher 1004 (review $block_id)"
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
        publisher_review CHANGES_REQUESTED "$BASE"
        publisher_review CHANGES_REQUESTED "$h" '{"author":{"databaseId":1002}}'
        publisher_review CHANGES_REQUESTED "$h" '{"author":{"databaseId":1009}}'
        online; assert_eq 0 "$STATUS" 'stale, author and unlisted objections do not block T0'
        publisher_review CHANGES_REQUESTED "$h"; online; assert_eq 1 "$STATUS" 'eligible objection blocks T0'
        assert_contains "$OUTPUT" '"blocking":[{"reviewer":1001,'
        publisher_review DISMISSED "$h"; online; assert_eq 0 "$STATUS" 'dismissed objection no longer blocks T0'
        assert_contains "$OUTPUT" '"reviews":[]'
        assert_contains "$OUTPUT" '"blocking":[]'
        echo 'unrelated rewrite' > specs/log.md; git commit -qam 'shared log is not automatically exempt'
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
    fx_owner_review 7 DISMISSED "$h" '{"author":{"databaseId":1005}}'
    fx_pr 7 "$h" '{"author":{"databaseId":1003}}'; online; assert_eq 1 "$STATUS" 'PR author cannot approve as owner'
    fx_pr 7 "$h"
    fx_owner_review 7 DISMISSED "$h"; online; assert_eq 1 "$STATUS" 'dismissal removes the owner approval'
    fx_owner_review 7 APPROVED "$h"; publisher_review CHANGES_REQUESTED "$h"
    online; assert_eq 1 "$STATUS" 'owner cannot compensate for publisher revocation'
done
finish
