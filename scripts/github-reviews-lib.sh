#!/usr/bin/env bash
# Read a single GitHub PR's reviews. No review bodies, commit authors or credentials are inputs.
# shellcheck disable=SC2034,SC2016 # Public outputs; jq/GraphQL variables are literal.

github_review_policy() {
    local root="$1" at="$2" config fields
    RC_ERROR="Cannot read trusted review policy at ${at:-origin/HEAD}"
    [ -n "$at" ] || return 1
    config="$(git -C "$root" show "$at:.prdkit/memory/config.md" | review_text_stream)" || return 1
    RC_ERROR='Trusted policy requires review-host: github, numeric review-publishers and numeric review-owner'
    fields="$(printf '%s\n' "$config" | awk "$SPEC_SKIP_AWK"'
        { if (spec_skip($0)) next }
        /^## / { active=($0=="## Configuration"); next }
        active && /^- review-(host|publishers|owner|publisher-isolation):/ {
            key=$0; sub(/:.*/, "", key); sub(/^- /,"",key)
            sub(/^[^:]*:[[:space:]]*/,""); sub(/[[:space:]]+$/,"")
            values[key]=$0; count[key]++
        }
        END {
            if (count["review-host"]!=1 || values["review-host"]!="github" ||
                count["review-publishers"]!=1 || values["review-publishers"]!~/^(bot|user):[1-9][0-9]*([[:space:]]*,[[:space:]]*(bot|user):[1-9][0-9]*)*$/ ||
                count["review-owner"]!=1 || values["review-owner"]!~/^user:[1-9][0-9]*([[:space:]]*,[[:space:]]*user:[1-9][0-9]*)*$/) exit 1
            if (count["review-publisher-isolation"]) print "Warning: review-publisher-isolation is retired; remove it after the 2.0 check is no longer required. The PR author never counts." > "/dev/stderr"
            print values["review-publishers"] "," values["review-owner"]
        }')" || return 1
    REVIEW_IDS="$(printf '%s' "$fields" | tr -d ' \t\r' | sed 's/bot://g;s/user://g')"
    RC_ERROR=""
}

github_review_fetch() { # URL private-work expected-head expected-base
    local url="$1" work="$2" expected="$3" base="$4" repo number query cursor="" next count=0 total="" page_total
    local re='^https://github\.com/([a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+)/pull/([1-9][0-9]*)$'
    RC_ERROR='--pr must be a github.com pull request URL'
    [[ "$url" =~ $re ]] || return 1
    repo="${BASH_REMATCH[1]}"; number="${BASH_REMATCH[2]}"
    RC_ERROR='online review checks require gh and jq'
    command -v gh >/dev/null && command -v jq >/dev/null || return 1
    query='query PrdkitReviews($owner:String!, $name:String!, $number:Int!, $endCursor:String) {
      repository(owner:$owner,name:$name) { pullRequest(number:$number) {
        number state headRefOid baseRefName author { ... on User { databaseId } ... on Bot { databaseId } }
        reviews(first:100,after:$endCursor) { totalCount nodes {
          fullDatabaseId state submittedAt commit { oid } author { ... on User { databaseId } ... on Bot { databaseId } }
        } pageInfo { hasNextPage endCursor } }
      } }
    }'
    RC_ERROR='Incomplete, malformed or non-advancing GitHub review pages'
    : > "$work/pages"; : > "$work/cursors"
    while :; do
        local args=()
        [ -z "$cursor" ] || args=(-f "endCursor=$cursor")
        gh api graphql --hostname github.com -f query="$query" -f owner="${repo%/*}" -f name="${repo#*/}" \
            -F number="$number" ${args[@]+"${args[@]}"} > "$work/page" || return 1
        jq -esc --argjson number "$number" '
          def id: type=="number" and .>0 and .==floor and .<9007199254740992;
          def sha: type=="string" and test("^[0-9a-f]{40}\\z");
          if length==1 and (.[0].errors // [])==[] then .[0].data.repository.pullRequest else null end |
          select(.number==$number and .state=="OPEN" and (.headRefOid|sha) and (.baseRefName|type=="string") and
            (.author.databaseId|id) and (.reviews as $r |
              ($r.totalCount|type=="number" and .>=0 and .==floor) and
              ($r.nodes|type=="array" and length<=100) and
              ($r.pageInfo.hasNextPage|type=="boolean") and
              ($r.pageInfo|has("endCursor")) and
              ($r.pageInfo.endCursor==null or ($r.pageInfo.endCursor|type=="string" and length>0 and (test("[[:cntrl:]]")|not))) and
              (if $r.pageInfo.hasNextPage then ($r.nodes|length)>0 and $r.pageInfo.endCursor!=null else true end) and
              all($r.nodes[]; (.fullDatabaseId|tostring|test("^[1-9][0-9]*\\z")) and
                ((.state=="PENDING" and .submittedAt==null) or ((.state|IN("APPROVED","COMMENTED","DISMISSED","CHANGES_REQUESTED")) and
                (.submittedAt|type=="string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\\z")) and
                (.author.databaseId|id) and (.commit.oid|sha))))))' "$work/page" > "$work/validated" || return 1
        cat "$work/validated" >> "$work/pages" || return 1
        next="$(jq -r '.reviews.pageInfo.endCursor // ""' "$work/validated")" || return 1
        if [ -n "$next" ]; then
            if grep -Fxq -- "$next" "$work/cursors"; then return 1; fi
            printf '%s\n' "$next" >> "$work/cursors" || return 1
        fi
        page_total="$(jq -r .reviews.totalCount "$work/validated")" || return 1
        [ -z "$total" ] || [ "$total" = "$page_total" ] || return 1
        total="$page_total"
        count=$((count + $(jq '.reviews.nodes|length' "$work/validated")))
        if jq -e '.reviews.pageInfo.hasNextPage' "$work/validated" >/dev/null; then
            [ "$count" -lt "$total" ] || return 1
            cursor="$next"
        else break; fi
    done
    jq -se '([.[] | del(.reviews.nodes,.reviews.pageInfo)] | unique | length)==1 and
        (.[0].reviews.totalCount as $n | [.[].reviews.nodes[].fullDatabaseId|tostring] |
         length==$n and (unique|length)==$n)' "$work/pages" >/dev/null || return 1
    pr_head="$(jq -r '.headRefOid' "$work/validated")" || return 1
    RC_ERROR='The PR head or target differs from the checked head and trusted base'
    [ "$pr_head" = "$expected" ] && [ "$(jq -r .baseRefName "$work/validated")" = "$base" ] || return 1
    # Latest submission per eligible numeric account, in host order for equal timestamps.
    approvals="$(jq -sc --arg ids "$REVIEW_IDS" --arg head "$expected" '
        .[0].author.databaseId as $maker | ($ids|split(",")) as $allowed |
        [.[].reviews.nodes[] | select(.state!="PENDING" and .commit.oid==$head and .author.databaseId!=$maker) |
         select((.author.databaseId|tostring) as $id | $allowed|index($id)!=null)] |
        sort_by(.submittedAt) | group_by(.author.databaseId) | map(last | select(.state=="APPROVED") |
        {reviewer:.author.databaseId,review:(.fullDatabaseId|tostring)})' "$work/pages")" || return 1
    RC_ERROR=""
}
