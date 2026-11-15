#!/usr/bin/env bash
# Fixture-only GitHub host. Never delegates to a real gh or makes a network request.
# See use_gh_stub and fx_* in lib.sh. Routes may be replaced by files under routes/.
set -euo pipefail
: "${GH_STUB_DIR:?use_gh_stub must select a fixture directory}"
printf '%s\n' "$*" >> "$GH_STUB_DIR/requests"
[ "${GH_STUB_OFFLINE:-false}" != true ] || exit 1
[ "${1:-}" = api ] || { echo 'gh stub: expected api' >&2; exit 2; }
shift
method=GET; endpoint=""; query=""; filter=""; paginate=false; input=""
owner=owner; name=repo; number=1; after=""; body=""; event=COMMENT
while [ "$#" -gt 0 ]; do
    case "$1" in
        graphql) endpoint=graphql ;;
        --method|-X) shift; method="$1" ;;
        --paginate) paginate=true ;;
        --jq|-q) shift; filter="$1" ;;
        --input) shift; input="$1" ;;
        --header|-H) shift ;;
        --hostname) shift; [ "$1" = github.com ] || exit 1 ;;
        --field|-F|--raw-field|-f)
            shift
            key="${1%%=*}"; value="${1#*=}"
            case "$key" in
                query) query="$value" ;;
                owner) owner="$value" ;; name) name="$value" ;;
                number|pr) number="$value" ;; endCursor|after) after="$value" ;;
                body) body="$value" ;; event) event="$value" ;;
                *) echo "gh stub: unknown field $key" >&2; exit 2 ;;
            esac ;;
        --*) echo "gh stub: unknown option $1" >&2; exit 2 ;;
        *) [ -z "$endpoint" ] || { echo 'gh stub: extra endpoint' >&2; exit 2; }; endpoint="${1#/}" ;;
    esac
    shift
done
emit() { if [ -n "$filter" ]; then jq -r "$filter"; else cat; fi; }
route="${endpoint#repos/*/*/}"
alias_route="${route%%\?*}"
operation=""
if [ "$endpoint" = graphql ]; then
    operation="$(printf '%s\n' "$query" | awk '
        /^[[:space:]]*(query|mutation)[[:space:]]+[A-Za-z_]/ {
            sub(/^[[:space:]]*(query|mutation)[[:space:]]+/, "")
            sub(/[^A-Za-z_0-9].*/, ""); print; exit
        }')"
    [ -n "$operation" ] || { echo 'gh stub: a named GraphQL operation is required' >&2; exit 2; }
    route="graphql:$operation"
fi
case "${GH_STUB_FAIL:-}" in
    "$route"|"$endpoint"|"$alias_route") echo "gh stub: injected failure: $route" >&2; exit 1 ;;
esac
override="$GH_STUB_DIR/routes/$(printf '%s' "$route" | tr '/?&=:' '_____').json"
if [ -f "$override" ]; then emit < "$override"; exit; fi
if [ "$endpoint" = graphql ]; then
    case "$operation" in
        PrdkitViewer) jq '{data:{viewer:(. + {__typename:"User"})}}' "$GH_STUB_DIR/publisher.json" | emit ;;
        PrdkitReviews)
            [ "$owner/$name" = owner/repo ] || exit 1
            pr="$GH_STUB_DIR/pulls/$number.json"
            reviews="$GH_STUB_DIR/reviews/$number.json"
            [ -f "$pr" ] && [ -f "$reviews" ] || exit 1
            page_size="${GH_STUB_PAGE_SIZE:-100}"; offset=0
            if [ -n "$after" ]; then
                case "$after" in cursor-*) offset="${after#cursor-}" ;; *) exit 1 ;; esac
                case "$offset" in ''|*[!0-9]*) exit 1 ;; esac
                [ "$offset" -gt 0 ] && [ $((offset % page_size)) -eq 0 ] || exit 1
            fi
            total="$(jq length "$reviews")"
            [ "$offset" -le "$total" ] || exit 1
            while :; do
                printf 'page %s pr=%s after=%s\n' "$operation" "$number" "$after" >> "$GH_STUB_DIR/requests"
                next=$((offset + page_size)); more=false
                [ "$next" -ge "$total" ] || more=true
                jq -n --slurpfile pr "$pr" --slurpfile reviews "$reviews" \
                    --argjson offset "$offset" --argjson size "$page_size" --argjson more "$more" --arg cursor "cursor-$next" '
                    $pr[0] as $p | {data:{repository:{pullRequest:{
                        number:$p.number, author:$p.author, state:($p.state | ascii_upcase),
                        headRefOid:$p.head.sha, headRefName:$p.head.ref, baseRefName:$p.base.ref,
                        createdAt:$p.created_at, merged:($p.merged_at != null),
                        reviews:{nodes:$reviews[0][$offset:($offset+$size)],
                            pageInfo:{hasNextPage:$more,endCursor:$cursor}}}}}}' | emit
                if [ "${GH_STUB_PARTIAL:-}" = "$route" ] || [ "${GH_STUB_PARTIAL:-}" = "$endpoint" ]; then break; fi
                if ! $paginate || ! $more; then break; fi
                after="cursor-$next"; offset="$next"
            done ;;
        *) echo "gh stub: unknown operation $operation" >&2; exit 1 ;;
    esac
    exit
fi
case "${GH_STUB_PARTIAL:-}" in
    "$route"|"$endpoint"|"$alias_route") printf '%s\n' '{"incomplete":'; exit ;;
esac
case "$route" in
    pulls\?state=closed\&head=*)
        jq -s --arg head "${route#*head=}" '[.[] | (.head.label // "owner:feature") as $label |
            select(.state == "closed" and ($label == $head or (($label | @uri) == $head)))]' \
            "$GH_STUB_DIR"/pulls/*.json | emit ;;
    pulls/[0-9]*/reviews/[0-9]*)
        number="${route#pulls/}"; number="${number%%/*}"; review_id="${route##*/}"
        # REST intentionally exposes no lastEditedAt/editor/edit marker (probe §9.2).
        jq -e --arg id "$review_id" '.[] | select((.fullDatabaseId | tostring) == $id) |
            {id:.fullDatabaseId,html_url:.url,body,state,submitted_at:.submittedAt,commit_id:.commit.oid,
             user:{id:.author.databaseId,login:.author.login,type:.author.__typename}}' \
            "$GH_STUB_DIR/reviews/$number.json" | emit ;;
    pulls/[0-9]*/reviews)
        number="${route#pulls/}"; number="${number%%/*}"
        if [ "$method" = POST ]; then
            if [ -n "$input" ]; then
                if [ "$input" = - ]; then payload="$(cat)"; else payload="$(cat "$input")"; fi
                body="$(printf '%s' "$payload" | jq -er .body)"
                event="$(printf '%s' "$payload" | jq -er .event)"
            fi
            [ "$event" = COMMENT ] || exit 1
            # COMMENT reviews are accepted on closed PRs too (probe §9.6).
            [ -f "$GH_STUB_DIR/pulls/$number.json" ] || exit 1
            next_id="$(jq -s '[.[][] | .fullDatabaseId | tonumber] | (max // 1000) + 1' "$GH_STUB_DIR"/reviews/*.json)"
            jq -n --slurpfile reviews "$GH_STUB_DIR/reviews/$number.json" \
                --slurpfile pr "$GH_STUB_DIR/pulls/$number.json" --slurpfile author "$GH_STUB_DIR/publisher.json" \
                --argjson id "$next_id" \
                --arg body "$body" --argjson number "$number" --arg time "${GH_STUB_NOW:-2026-01-02T12:00:00Z}" '
                {fullDatabaseId:($id|tostring),url:("https://github.com/owner/repo/pull/"+($number|tostring)+"#pullrequestreview-"+($id|tostring)),
                 body:$body,state:"COMMENTED",submittedAt:$time,lastEditedAt:null,editor:null,
                 author:$author[0],commit:{oid:$pr[0].head.sha}}' > "$GH_STUB_DIR/posted.json"
            jq --slurpfile review "$GH_STUB_DIR/posted.json" '. + $review' "$GH_STUB_DIR/reviews/$number.json" > "$GH_STUB_DIR/next.json"
            mv "$GH_STUB_DIR/next.json" "$GH_STUB_DIR/reviews/$number.json"
            jq '{id:.fullDatabaseId,body,state,submitted_at:.submittedAt,commit_id:.commit.oid,
                 user:{id:.author.databaseId,login:.author.login,type:.author.__typename}}' "$GH_STUB_DIR/posted.json" | emit
        else
            jq '[.[] | {id:.fullDatabaseId,body,state,submitted_at:.submittedAt,commit_id:.commit.oid,
                user:{id:.author.databaseId,login:.author.login,type:.author.__typename}}]' "$GH_STUB_DIR/reviews/$number.json" | emit
        fi ;;
    pulls/[0-9]*) emit < "$GH_STUB_DIR/$route.json" ;;
    activity\?*|activity)
        # The real endpoint defaults to newest first; direction=asc is explicit.
        if [[ "$endpoint" = *direction=asc* ]]; then jq 'sort_by(.timestamp,.id)' "$GH_STUB_DIR/activity.json" | emit
        else jq 'sort_by(.timestamp,.id)|reverse' "$GH_STUB_DIR/activity.json" | emit; fi ;;
    users/*) emit < "$GH_STUB_DIR/users/${route#users/}.json" ;;
    issues/comments/[0-9]*) emit < "$GH_STUB_DIR/$route.json" ;;
    *) echo "gh stub: no fixture route $route" >&2; exit 1 ;;
esac
