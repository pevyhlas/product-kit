#!/usr/bin/env bash
# Fixture-only GitHub host. Never delegates to a real gh or makes a network request.
# See use_gh_stub and fx_* in lib.sh. Routes may be replaced by files under routes/.
set -euo pipefail
: "${GH_STUB_DIR:?use_gh_stub must select a fixture directory}"
printf '%s\n' "$*" >> "$GH_STUB_DIR/requests"
[ "${GH_STUB_OFFLINE:-false}" != true ] || exit 1
if [ "$*" = 'repo view --json nameWithOwner,url' ]; then
    printf '%s\n' '{"nameWithOwner":"owner/repo","url":"https://github.com/owner/repo"}'
    exit
fi
[ "${1:-}" = api ] || { echo 'gh stub: expected api' >&2; exit 2; }
shift
endpoint=""; query=""; filter=""; paginate=false; method=GET; include=false; slurp=false; escapes=false
owner=owner; name=repo; number=1; after=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        graphql) endpoint=graphql ;;
        --paginate) paginate=true ;;
        --slurp) slurp=true ;;
        --include) include=true ;;
        --allow-escape-sequences) escapes=true ;;
        --method) shift; method="$1" ;;
        --jq|-q) shift; filter="$1" ;;
        --header|-H) shift ;;
        --hostname) shift; [ "$1" = github.com ] || exit 1 ;;
        --field|-F|--raw-field|-f)
            shift
            key="${1%%=*}"; value="${1#*=}"
            case "$key" in
                query) query="$value" ;;
                owner) owner="$value" ;; name) name="$value" ;;
                number|pr) number="$value" ;; endCursor|after) after="$value" ;;
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
        !found && /^[[:space:]]*(query|mutation)[[:space:]]+[A-Za-z_]/ {
            sub(/^[[:space:]]*(query|mutation)[[:space:]]+/, "")
            sub(/[^A-Za-z_0-9].*/, ""); operation=$0; found=1
        }
        END { if (found) print operation }')"
    [ -n "$operation" ] || { echo 'gh stub: a named GraphQL operation is required' >&2; exit 2; }
    route="graphql:$operation"
fi
case "${GH_STUB_FAIL:-}" in
    "$route"|"$endpoint"|"$alias_route") echo "gh stub: injected failure: $route" >&2; exit 1 ;;
esac
override="$GH_STUB_DIR/routes/$(printf '%s' "$route" | tr '/?&=:' '_____').json"
if [ "$operation" = PrdkitReviews ] && [ -f "$GH_STUB_DIR/routes/graphql_PrdkitReviews-$number.json" ]; then
    override="$GH_STUB_DIR/routes/graphql_PrdkitReviews-$number.json"
fi
if [ "$operation" = PrdkitCheckFacts ]; then
    if [ -f "$GH_STUB_DIR/rerun" ] && [ -f "$GH_STUB_DIR/routes/graphql_PrdkitCheckFacts-rerun.json" ]; then
        override="$GH_STUB_DIR/routes/graphql_PrdkitCheckFacts-rerun.json"
    elif [ -n "$after" ]; then
        case "$after" in cursor-[0-9]*) override="$GH_STUB_DIR/routes/graphql_PrdkitCheckFacts-$after.json" ;; *) exit 2 ;; esac
    elif [ -f "$GH_STUB_DIR/routes/graphql_PrdkitCheckFacts-later.json" ]; then
        if [ -f "$GH_STUB_DIR/read-check-facts" ]; then
            override="$GH_STUB_DIR/routes/graphql_PrdkitCheckFacts-later.json"
        fi
        : > "$GH_STUB_DIR/read-check-facts"
    fi
fi
if [ "$operation" = PrdkitPRFacts ] && [ -f "$GH_STUB_DIR/routes/graphql_PrdkitPRFacts-later.json" ]; then
    if [ -f "$GH_STUB_DIR/read-pr-facts" ]; then
        override="$GH_STUB_DIR/routes/graphql_PrdkitPRFacts-later.json"
    fi
    : > "$GH_STUB_DIR/read-pr-facts"
fi
case "$route" in
    actions/jobs/*/rerun)
        [ "$method" = POST ] && $include && [ -f "$override" ] || exit 2
        printf '%s\n' "$route" >> "$GH_STUB_DIR/rerun"
        cat "$override"; exit ;;
    actions/jobs/*/logs)
        [ "$method" = GET ] && $include && $escapes && [ -f "${override%.json}.txt" ] || exit 2
        cat "${override%.json}.txt"; exit ;;
    rules/branches/*\&page=*) ;;
    rules/branches/*)
        $paginate && $slurp || exit 2 ;;
esac
if [ -f "$override" ]; then emit < "$override"; exit; fi
if [ "$endpoint" = graphql ]; then
    case "$operation" in
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
                    $pr[0] as $p | {data:{repository:{nameWithOwner:"owner/repo",pullRequest:{
                        number:$p.number, author:$p.author,
                        state:(if $p.merged_at!=null then "MERGED" else ($p.state|ascii_upcase) end),
                        headRefOid:$p.head.sha, headRefName:$p.head.ref, baseRefName:$p.base.ref,
                        createdAt:$p.created_at, merged:($p.merged_at != null),
                        reviews:{totalCount:($reviews[0]|length),nodes:$reviews[0][$offset:($offset+$size)],
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
    pulls/[0-9]*) emit < "$GH_STUB_DIR/$route.json" ;;
    *) echo "gh stub: no fixture route $route" >&2; exit 1 ;;
esac
