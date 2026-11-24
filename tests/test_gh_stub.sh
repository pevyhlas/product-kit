#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
use_gh_stub
HEAD_SHA=1111111111111111111111111111111111111111
fx_pr 7 "$HEAD_SHA"
# shellcheck disable=SC2016 # GraphQL variables, not shell interpolation.
QUERY='query PrdkitReviews($owner:String!, $name:String!, $number:Int!, $endCursor:String) { repository(owner:$owner,name:$name) { pullRequest(number:$number) { author { ... on User { databaseId } ... on Bot { databaseId } } state headRefOid baseRefName reviews(first:100,after:$endCursor) { totalCount nodes { fullDatabaseId body state submittedAt commit { oid } } pageInfo { hasNextPage endCursor } } } } }'
reviews() { gh api graphql --paginate -f query="$QUERY" -F owner=owner -F name=repo -F number=7 "$@"; }

it 'operation discovery consumes the whole query even under pipefail'
# A long valid trailing GraphQL comment makes an early-exit awk reader SIGPIPE the writer
# deterministically; normal short multi-line queries can hit the same race intermittently.
long_query="$QUERY"$'\n'"$(awk 'BEGIN { for (i=0;i<4000;i++) print "# trailing comment" }')"
run gh api graphql --paginate -f query="$long_query" -F number=7
assert_eq 0 "$STATUS" 'named query parsing must not turn SIGPIPE into host unavailability'
assert_eq 0 "$(printf '%s' "$OUTPUT" | jq '.data.repository.pullRequest.reviews.nodes|length')"

it 'PR fixtures expose the head, base, author and state'
run gh api repos/owner/repo/pulls/7 --jq '.head.sha'
assert_eq 0 "$STATUS"
assert_eq "$HEAD_SHA" "$OUTPUT"
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
