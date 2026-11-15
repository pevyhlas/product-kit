#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_gh_stub
HEAD_SHA=1111111111111111111111111111111111111111
fx_pr 7 "$HEAD_SHA"
fx_closed_pr 6 "$HEAD_SHA"
fx_closed_pr 5 "$HEAD_SHA" '{"merged_at":"2026-01-01T01:00:00Z"}'
fx_pr 4 "$HEAD_SHA" '{"head":{"label":"owner:other"}}'
# shellcheck disable=SC2016 # GraphQL variables, not shell interpolation.
QUERY='query PrdkitReviews($owner:String!, $name:String!, $number:Int!, $endCursor:String) { repository(owner:$owner,name:$name) { pullRequest(number:$number) { author { __typename login databaseId } state headRefOid baseRefName reviews(first:100,after:$endCursor) { nodes { fullDatabaseId url body state submittedAt lastEditedAt editor { login } author { __typename login } commit { oid } } pageInfo { hasNextPage endCursor } } } } }'
reviews() { gh api graphql --paginate -f query="$QUERY" -F owner=owner -F name=repo -F number=7 "$@"; }

it 'PR fixtures expose the head, base, author and state'
run gh api repos/owner/repo/pulls/7 --jq '.head.sha'
assert_eq 0 "$STATUS"
assert_eq "$HEAD_SHA" "$OUTPUT"
run gh api 'repos/owner/repo/pulls?state=closed&head=owner:feature'
assert_eq '5,6' "$(printf '%s' "$OUTPUT" | jq -r 'sort_by(.number) | map(.number|tostring) | join(",")')"
assert_contains "$OUTPUT" 'merged_at' 'merged predecessors remain available for restatements'

it 'GraphQL pages preserve reviews and cursor order'
fx_review 7 first
fx_review 7 FAIL '{"fullDatabaseId":"1009","submittedAt":"2026-01-02T01:00:00Z"}'
run env GH_STUB_PAGE_SIZE=1 gh api graphql --paginate -f query="$QUERY" -F number=7
assert_eq 0 "$STATUS"
assert_eq 'first,FAIL' "$(printf '%s' "$OUTPUT" | jq -sr '[.[].data.repository.pullRequest.reviews.nodes[].body] | join(",")')"
assert_contains "$(cat "$GH_STUB_DIR/requests")" 'after=cursor-1' 'second page requested with advancing cursor'
run reviews -F endCursor=bogus
assert_eq 1 "$STATUS" 'bad cursor refused'
run env GH_STUB_PAGE_SIZE=1 GH_STUB_PARTIAL=graphql:PrdkitReviews gh api graphql --paginate -f query="$QUERY" -F number=7
assert_eq true "$(printf '%s' "$OUTPUT" | jq '.data.repository.pullRequest.reviews.pageInfo.hasNextPage')" 'partial stream retains evidence of a missing page'
run env GH_STUB_FAIL=graphql:PrdkitReviews gh api graphql -f query="$QUERY" -F number=7
assert_eq 1 "$STATUS" 'route failure injected'
run env GH_STUB_OFFLINE=true gh api repos/owner/repo/pulls/7
assert_eq 1 "$STATUS" 'offline host fails without falling through'
run env GH_STUB_FAIL=pulls/7 gh api repos/owner/repo/pulls/7
assert_eq 1 "$STATUS" 'REST route failure injected'
run env GH_STUB_PARTIAL=pulls/7 gh api repos/owner/repo/pulls/7
assert_eq 0 "$STATUS" 'partial REST output simulates a truncated successful response'
run jq -e . <<< "$OUTPUT"
assert_eq no "$([ "$STATUS" -eq 0 ] && echo yes || echo no)" 'partial REST response is not a complete JSON document'

it 'edits keep provenance and only GraphQL exposes the edit markers'
jq '.[0].body="edited" | .[0].lastEditedAt="2026-01-03T00:00:00Z" | .[0].editor={__typename:"User",login:"admin",databaseId:1004}' \
    "$GH_STUB_DIR/reviews/7.json" > "$GH_STUB_DIR/edited.json"
mv "$GH_STUB_DIR/edited.json" "$GH_STUB_DIR/reviews/7.json"
run reviews
assert_eq "$HEAD_SHA" "$(printf '%s' "$OUTPUT" | jq -r '.data.repository.pullRequest.reviews.nodes[0].commit.oid')"
assert_eq '1001/COMMENTED/2026-01-02T00:00:00Z' "$(printf '%s' "$OUTPUT" | jq -r '.data.repository.pullRequest.reviews.nodes[0] | [.author.databaseId,.state,.submittedAt] | join("/")')"
assert_contains "$OUTPUT" 'lastEditedAt' 'GraphQL edit timestamp present'
assert_contains "$OUTPUT" 'admin' 'GraphQL editor present'
run gh api repos/owner/repo/pulls/7/reviews/1001
assert_eq edited "$(printf '%s' "$OUTPUT" | jq -r .body)"
assert_eq false "$(printf '%s' "$OUTPUT" | jq 'has("lastEditedAt") or has("editor") or has("updated_at")')" 'REST has no edit marker'

it 'installation viewer reports User with the publishing bot id'
run gh api graphql -f 'query=query PrdkitViewer { viewer { __typename login databaseId } }'
assert_eq 'User/1001' "$(printf '%s' "$OUTPUT" | jq -r '.data.viewer | [.__typename,.databaseId] | join("/")')"

it 'COMMENT posting appends on closed PRs with configurable author and read-back'
printf '%s\n' '{"__typename":"User","databaseId":1005,"login":"reviewer"}' > "$GH_STUB_DIR/publisher.json"
run gh api --method POST repos/owner/repo/pulls/6/reviews -f event=COMMENT -f body=restatement
assert_eq 0 "$STATUS"
assert_eq '1005/COMMENTED/restatement' "$(printf '%s' "$OUTPUT" | jq -r '[.user.id,.state,.body] | join("/")')"
review_id="$(printf '%s' "$OUTPUT" | jq -r .id)"
run gh api "repos/owner/repo/pulls/6/reviews/$review_id" --jq .body
assert_eq restatement "$OUTPUT"
assert_eq 1 "$(jq length "$GH_STUB_DIR/reviews/6.json")" 'POST persisted in the review connection'
assert_contains "$(cat "$GH_STUB_DIR/requests")" '--method POST' 'POST logged'
printf '%s\n' '{"event":"COMMENT","body":"summary\nreceipt"}' > "$GH_STUB_DIR/post-input.json"
run gh api --hostname github.com -X POST repos/owner/repo/pulls/6/reviews --input "$GH_STUB_DIR/post-input.json"
assert_eq 0 "$STATUS" 'JSON input posting supported'
assert_eq $'summary\nreceipt' "$(printf '%s' "$OUTPUT" | jq -r .body)" 'body preserved byte-for-byte'

it 'owner, activity, user and existing issue-comment fixture routes are available'
fx_owner_review 7 APPROVED "$HEAD_SHA"
assert_eq 'User/1003/APPROVED' "$(jq -r '.[-1] | [.author.__typename,.author.databaseId,.state] | join("/")' "$GH_STUB_DIR/reviews/7.json")"
fx_activity 0000000000000000000000000000000000000000 "$HEAD_SHA" '{"activity_type":"pr_merge"}'
run gh api 'repos/owner/repo/activity?ref=refs/heads/feature'
assert_contains "$OUTPUT" 'pr_merge'
printf '%s\n' '{"id":1001,"login":"publisher[bot]"}' > "$GH_STUB_DIR/users/publisher[bot].json"
run gh api 'users/publisher[bot]' --jq .id
assert_eq 1001 "$OUTPUT"
printf '%s\n' '{"body":"report"}' > "$GH_STUB_DIR/issues/comments/1001.json"
run gh api repos/owner/repo/issues/comments/1001 --jq .body
assert_eq report "$OUTPUT"

it 'operation fixtures can inject malformed pages without changing the stub'
printf '%s\n' '{"data":{"repository":{"pullRequest":null}}}' > "$GH_STUB_DIR/routes/graphql_PrdkitReviews.json"
run reviews
assert_eq null "$(printf '%s' "$OUTPUT" | jq '.data.repository.pullRequest')"
run gh api graphql -f 'query={ viewer { login } }'
assert_eq 2 "$STATUS" 'unnamed operations refused'

it 'an empty log witnesses a test that made no host requests'
: > "$GH_STUB_DIR/requests"
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
finish
