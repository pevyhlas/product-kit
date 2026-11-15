#!/usr/bin/env bash
# Publish one immutable-content v3 verdict as a submitted COMMENT review. Never edit a record.
# A restatement reads the publisher's Git-directory log, never checkout files or the edited body:
#   publish-review.sh --pr URL --restates REVIEW_ID --receipt-id ID [--restates-pr ORIGIN_PR]
# Offline --dry-run needs jq to encode/validate JSON, but never invokes gh or writes the log.
set -euo pipefail
# shellcheck disable=SC2016 # Literal jq variables.
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/spec-lib.sh"
source "$SCRIPT_DIR/review-policy-lib.sh"
source "$SCRIPT_DIR/review-fingerprint-lib.sh"
source "$SCRIPT_DIR/review-receipts-lib.sh"
source "$SCRIPT_DIR/review-legacy-lib.sh"
usage='Usage: publish-review.sh <change-id> --pr <url> --reviewer <identity> --verdict PASS|FAIL --counts <c>,<h>,<m>,<l> --report <url> --head <rev> [--since <rev>] [--from-report <file>] [--clears-legacy] [--base <ref>] [--repo <dir>] [--dry-run]; or --pr <url> --restates <review-id> --receipt-id <32 hex> [--restates-pr <origin pr>] [--base <ref>] [--repo <dir>] [--dry-run]'
id=""; pr_url=""; reviewer=""; verdict=""; counts=""; report=""; head_ref=""; since_ref=""; from_report=""; base_ref=origin/HEAD; repo=.
dry_run=false; clears_legacy=false; restates=""; restates_pr=""; receipt_id=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --pr|--reviewer|--verdict|--counts|--report|--head|--since|--from-report|--base|--repo|--restates|--restates-pr|--receipt-id)
            [ "$#" -ge 2 ] || { echo "$usage" >&2; exit 2; }
            case "$1" in
                --pr) pr_url="$2" ;; --reviewer) reviewer="$2" ;; --verdict) verdict="$2" ;; --counts) counts="$2" ;;
                --report) report="$2" ;; --head) head_ref="$2" ;; --since) since_ref="$2" ;; --from-report) from_report="$2" ;;
                --base) base_ref="$2" ;; --repo) repo="$2" ;; --restates) restates="$2" ;; --restates-pr) restates_pr="$2" ;; --receipt-id) receipt_id="$2" ;;
            esac
            shift ;;
        --dry-run) dry_run=true ;; --clears-legacy) clears_legacy=true ;;
        --help|-h) echo "$usage"; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *) [ -z "$id" ] || { echo "$usage" >&2; exit 2; }; id="$1" ;;
    esac
    shift
done
refuse() { echo "publish-review.sh: $*" >&2; exit 1; }
[ -n "$pr_url" ] || { echo "$usage" >&2; exit 2; }
pr_re='^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)$'
[[ "$pr_url" =~ $pr_re ]] || refuse '--pr must be a github.com pull request URL'
host_repo="${BASH_REMATCH[1]}"; number="${BASH_REMATCH[2]}"
command -v jq >/dev/null 2>&1 || refuse 'publishing and dry-run JSON encoding need jq'
root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || refuse "not inside a Git checkout: $repo"
canonical="$(git -C "$root" rev-parse --symbolic-full-name "$base_ref" 2>/dev/null || true)"
# Drain every ref: grep -q can SIGPIPE the producer under pipefail when more refs follow.
if [ -z "$canonical" ] || ! spec_trusted_refs "$root" | grep -xF -- "$canonical" >/dev/null; then
    refuse "--base $base_ref is not a trusted integration branch (origin/HEAD's target, or one named by review-integration-branches in its committed config); pass the branch this change merges into"
fi
base_at="$(git -C "$root" rev-parse --verify "$canonical^{commit}")" || refuse "not a commit here: $base_ref"
policy_ref="$(spec_trusted_refs "$root" | sed -n 1p)"
policy_at="$(git -C "$root" rev-parse --verify "$policy_ref^{commit}")"
review_receipts_policy "$root" "$policy_at" || refuse "$RC_ERROR"
registry="$( { git -C "$root" show "$policy_at:.prdkit/memory/agents.md" 2>/dev/null || true; } | review_registry)"
rigor="$( { git -C "$root" show "$policy_at:.prdkit/memory/constitution.md" 2>/dev/null || true; } | tr -d '\r' | awk '
    { line=$0 } sub(/^[-*[:space:]]*[Rr]igor\**:\**[[:space:]]*/,"",line) { n++; value=tolower(line) }
    END { if (n==1 && value ~ /^(light|full)([[:space:]]|$)/) { sub(/[[:space:]].*/,"",value); print value } else print "unknown" }')"
[ "$rigor" != unknown ] || refuse 'the trusted constitution must name exactly one well-formed Rigor, light or full'
work="$(mktemp -d)" || refuse 'cannot allocate publication work directory'
trap 'rm -rf "$work"' EXIT
normalize_counts() {
    [[ "$1" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]] || return 1
    jq -ner --arg c "$1" '$c|split(",")|map(sub("^0+";"")|if .=="" then "0" else . end|tonumber) |
        if all(.[];type=="number" and .>=0 and floor==.) then map(tostring)|join(",") else error("counts") end'
}
git_dir="$(git -C "$root" rev-parse --git-common-dir)" || refuse 'cannot locate the shared Git directory'
case "$git_dir" in /*) ;; *) git_dir="$root/$git_dir" ;; esac
git_dir="$(CDPATH="" cd "$git_dir" && pwd -P)" || refuse 'cannot resolve the shared Git directory'
log_root="$git_dir/prdkit/receipts"
check_log_path() { # path below prdkit/receipts; every component must be publisher-owned, not a link
    local remaining="prdkit/receipts/$1" component path="$git_dir"
    while [ -n "$remaining" ]; do
        component="${remaining%%/*}"
        if [ "$component" = "$remaining" ]; then remaining=""; else remaining="${remaining#*/}"; fi
        path="$path/$component"
        [ ! -L "$path" ] || refuse "symlinked publisher log component: $path"
    done
}
if [ -n "$restates" ]; then
    [[ "$restates" =~ ^[1-9][0-9]*$ && "$receipt_id" =~ ^[0-9a-f]{32}$ ]] || refuse 'restatement needs a numeric --restates review id and --receipt-id (32 hex)'
    if [ -n "$reviewer$verdict$counts$report$head_ref$since_ref$from_report" ] || $clears_legacy; then
        refuse 'a restatement reads the full original verdict from the publish log; do not override its fields'
    fi
    origin="${restates_pr:-$number}"
    [[ "$origin" =~ ^[1-9][0-9]*$ ]] || refuse 'invalid --restates-pr'
    [ -z "$restates_pr" ] || [ "$origin" != "$number" ] || refuse '--restates-pr is present only when origin and posting PR differ'
    log="$log_root/$origin/$receipt_id.json"
    check_log_path "$origin/$receipt_id.json"
    [ -f "$log" ] && [ ! -L "$log" ] || refuse "no original publisher log: $log"
    if ! jq -se --arg repo "$host_repo" --argjson origin "$origin" --arg id "$receipt_id" '
        length==1 and (.[0] | .schema=="prdkit.review.v3" and .id==$id and (.repo|ascii_downcase)==($repo|ascii_downcase) and .pr==$origin and
        ([.change,.reviewer,.from,.to,.head,.since,.base,.base_at,.verdict,.report]|all(.[];type=="string" and (test("[\\x00-\\x1f\\x7f]")|not))) and
        ([.critical,.high,.medium,.low]|all(.[];type=="number" and .>=0 and floor==.)))' "$log" >/dev/null 2>&1; then refuse 'the original publish log is malformed or belongs to another PR/receipt'; fi
    original_change="$(jq -r .change "$log")"
    [ -z "$id" ] || [ "$id" = "$original_change" ] || refuse 'a restatement keeps the original change id'
    id="$original_change"
    jq --arg repo "$host_repo" --argjson pr "$number" --arg review "$restates" --argjson origin "$origin" '
        del(.restates,.restates_pr) | .repo=$repo | .pr=$pr | .restates=$review |
        if $origin!=$pr then .restates_pr=$origin else . end' "$log" > "$work/payload.json"
else
    [ -z "$restates_pr$receipt_id" ] || refuse '--restates-pr and --receipt-id require --restates'
    [ -n "$id" ] && [ -n "$reviewer" ] && [ -n "$head_ref" ] || { echo "$usage" >&2; exit 2; }
    is_change_id "$id" || refuse "expected a change id such as 004-export-csv (got: $id)"
    [[ "$reviewer" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || refuse "reviewer '$reviewer' is not a registry identity (lowercase letters, digits, _ . -)"
    [ "$reviewer" != owner ] || refuse 'the owner approves natively on the PR'
    [ "$(review_eligibility "$registry" "$reviewer")" = reviewer ] || refuse "reviewer '$reviewer' is not an eligible identity in the trusted registry"
    [ -n "$report" ] || refuse '--report names the report URL'
    case "$report" in *" · "*|*$'\n'*|*$'\r'*|*$'\037'*) refuse 'the report URL must be one field, with no line break or separator' ;; esac
    if [ -n "$from_report" ]; then
        [ -f "$from_report" ] || refuse "cannot read --from-report $from_report"
        report_verdict="$(awk '{ sub(/\r$/,""); previous=last; last=$0 } END { print previous }' "$from_report")"
        report_counts="$(awk '{ sub(/\r$/,""); last=$0 } END { print last }' "$from_report")"
        [[ "$report_verdict" =~ ^Verdict:[[:space:]]+(PASS|FAIL)$ ]] || refuse 'the report must end with Verdict: PASS|FAIL and Counts: <n> critical, <n> high, <n> medium, <n> low'
        report_verdict="${BASH_REMATCH[1]}"
        count_re='^Counts: ([0-9]+) critical, ([0-9]+) high, ([0-9]+) medium, ([0-9]+) low$'
        [[ "$report_counts" =~ $count_re ]] || refuse 'the report has no readable final Counts line'
        report_counts="${BASH_REMATCH[1]},${BASH_REMATCH[2]},${BASH_REMATCH[3]},${BASH_REMATCH[4]}"
        report_counts="$(normalize_counts "$report_counts")" || refuse 'unreadable report counts'
        [ -z "$verdict" ] || [ "$(printf '%s' "$verdict" | tr '[:lower:]' '[:upper:]')" = "$report_verdict" ] || refuse '--verdict disagrees with --from-report'
        if [ -n "$counts" ]; then normalized="$(normalize_counts "$counts")" || refuse 'invalid --counts'; [ "$normalized" = "$report_counts" ] || refuse '--counts disagrees with --from-report'; fi
        verdict="$report_verdict"; counts="$report_counts"
    fi
    verdict="$(printf '%s' "$verdict" | tr '[:lower:]' '[:upper:]')"
    case "$verdict" in PASS|FAIL) ;; *) refuse 'the verdict is PASS or FAIL' ;; esac
    counts="$(normalize_counts "$counts")" || refuse '--counts is required: four non-negative integers, <critical>,<high>,<medium>,<low>'
    IFS=, read -r c h m l <<< "$counts"
    head="$(git -C "$root" rev-parse --verify --quiet "$head_ref^{commit}")" || refuse "not a commit here: $head_ref"
    since=""; from=start
    review_fingerprint "$root" "$id" "$base_at" "$head" >/dev/null || refuse "$REVIEW_FP_ERROR"; to="$REVIEW_FP"
    if [ -n "$since_ref" ]; then
        since="$(git -C "$root" rev-parse --verify --quiet "$since_ref^{commit}")" || refuse "not a commit here: $since_ref"
        review_fingerprint "$root" "$id" "$base_at" "$since" >/dev/null || refuse "$REVIEW_FP_ERROR"
        from="$REVIEW_FP"
        # A --since at the start still names the full change, with canonical empty provenance.
        if [ "$from" = "$REVIEW_FP_EMPTY" ]; then from=start; since=""; fi
    fi
    from_fp="$from"; [ "$from" != start ] || from_fp="$REVIEW_FP_EMPTY"
    if $clears_legacy; then
        if [ "$to" != "$REVIEW_FP_EMPTY" ] || [ -n "$since_ref" ] || [ "$verdict" != PASS ] || _receipts_blocking "$verdict" "$c" "$h" "$m" "$rigor"; then
            refuse '--clears-legacy requires empty content, no --since, and a clean full PASS'
        fi
        review_legacy_collect "$root" "$id" "$canonical" "$head" "$rigor" "$work/legacy" "$work/blockers" || refuse 'cannot scan the complete legacy history'
        awk -F '\037' -v reviewer="$reviewer" '$3==reviewer { found=1 } END { exit !found }' "$work/blockers" || refuse '--clears-legacy requires a legacy blocker for this reviewer at --head'
    elif [ "$from_fp" = "$to" ]; then
        [ -z "$since_ref" ] || refuse "nothing changed since --since $since_ref; no round needed"
        refuse "the change has no content at $head_ref against $base_ref; nothing to review (use --clears-legacy only for a matching legacy blocker)"
    fi
    receipt_id="$(od -An -tx1 -N16 /dev/urandom | tr -d ' \n')"
    [[ "$receipt_id" =~ ^[0-9a-f]{32}$ ]] || refuse 'could not generate a receipt id'
    jq -n --arg id "$receipt_id" --arg repo "$host_repo" --argjson pr "$number" --arg change "$id" --arg reviewer "$reviewer" \
        --arg from "$from" --arg to "$to" --arg head "$head" --arg since "$since" --arg base "$canonical" --arg base_at "$base_at" \
        --arg verdict "$verdict" --arg report "$report" --argjson c "$c" --argjson h "$h" --argjson m "$m" --argjson l "$l" '
        {schema:"prdkit.review.v3",id:$id,repo:$repo,pr:$pr,change:$change,reviewer:$reviewer,from:$from,to:$to,head:$head,since:$since,
         base:$base,base_at:$base_at,verdict:$verdict,critical:$c,high:$h,medium:$m,low:$l,report:$report}' > "$work/payload.json"
fi
# Validate cached-restatement token/identity fields too, without ever recomputing/replacing them.
IFS=$'\037' read -r receipt_id change reviewer from to rhead since base base_at verdict c h m l < <(
    jq -r '[.id,.change,.reviewer,.from,.to,.head,.since,.base,.base_at,.verdict,.critical,.high,.medium,.low]|map(tostring)|join("\u001f")' "$work/payload.json")
# shellcheck disable=SC2034 # Dynamic input to _receipts_row_valid.
scope_rigor="$rigor"
_receipts_row_valid || refuse 'the publish payload has invalid v3 token/identity fields'
[ "$(review_eligibility "$registry" "$reviewer")" = reviewer ] || refuse 'the original reviewer is no longer eligible in trusted policy'
_receipts_consistency "$root" "$change" "$from" "$to" "$rhead" "$since" "$base" "$base_at" || refuse "$RC_ERROR"
payload="$(jq -c . "$work/payload.json")"
body="$(printf '<!-- prdkit-review\n%s\n-->\n\n%s %s: %s\nReport: %s\n' "$payload" "$reviewer" "$(jq -r .change "$work/payload.json")" "$verdict" "$(jq -r .report "$work/payload.json")")"
check_log_path "$number/$receipt_id.json"
check_log_path "$number/reviews"
# The host review id is not known until POST. Reject existing symlink targets before posting.
for entry in "$log_root/$number/reviews/"*; do
    [ ! -L "$entry" ] || refuse "symlinked publisher log component: $entry"
done
if $dry_run; then printf '%s\n' "$body"; exit 0; fi
command -v gh >/dev/null 2>&1 || refuse 'posting a review needs gh'
gh api --hostname github.com "repos/$host_repo/pulls/$number" > "$work/pr.json" 2>/dev/null || refuse 'could not read the destination PR'
jq -e --arg base "${canonical#refs/remotes/origin/}" --argjson number "$number" '.number==$number and .base.ref==$base and (.user.id|type)=="number"' "$work/pr.json" >/dev/null || refuse 'the destination PR does not match the trusted base or has incomplete metadata'
gh api graphql --hostname github.com -f 'query=query PrdkitViewer { viewer { __typename login ... on User { databaseId } } }' > "$work/viewer.json" 2>/dev/null || refuse 'could not read the publisher viewer id'
viewer="$(jq -er '.data.viewer.databaseId|numbers|tostring' "$work/viewer.json")" || refuse 'the publisher viewer has no numeric id'
printf '%s\n' "$RC_PUBLISHERS" | awk -F : -v id="$viewer" '$2==id { found=1 } END { exit !found }' || refuse 'the publishing credential is not a listed publisher'
if [ "$RC_ISOLATION" = required ] && [ "$(jq -r .user.id "$work/pr.json")" = "$viewer" ]; then refuse 'publisher also authored this PR (isolation required)'; fi
# Write ahead: even a POST timeout or an edited/unreadable read-back must not lose the repair log.
mkdir -p "$log_root/$number" || refuse 'cannot create the publisher log'
check_log_path "$number/$receipt_id.json"
log="$log_root/$number/$receipt_id.json"
if [ ! -e "$log" ]; then cp "$work/payload.json" "$log" || refuse 'cannot retain the publish payload'
elif [ -z "$restates" ]; then refuse 'receipt id already exists in the publish log'; fi
jq -n --arg body "$body" '{event:"COMMENT",body:$body}' > "$work/post.json"
if ! gh api --hostname github.com --method POST "repos/$host_repo/pulls/$number/reviews" --input "$work/post.json" > "$work/posted.json" 2>/dev/null; then
    refuse "POST failed or its result is unknown; the payload is retained at $log; inspect the PR before retrying"
fi
review="$(jq -er '.id|tostring|select(test("^[1-9][0-9]*$"))' "$work/posted.json")" || refuse "POST returned no review id; payload retained at $log"
check_log_path "$number/reviews/$review.json"
if ! mkdir -p "$log_root/$number/reviews" || ! cp "$work/payload.json" "$log_root/$number/reviews/$review.json"; then refuse 'review posted but could not retain its review-id log'; fi
url="https://github.com/$host_repo/pull/$number#pullrequestreview-$review"
_receipts_reviews "$host_repo" "$number" "$work" || refuse "review $url was posted but GraphQL read-back failed: $RC_ERROR; payload retained at $log"
if ! jq -e --arg id "$review" --arg body "$body" --arg viewer "$viewer" --arg publishers "$RC_PUBLISHERS" '
    [.reviews[]|select((.fullDatabaseId|tostring)==$id)] as $rows | ($rows|length)==1 and ($rows[0] as $r |
       $r.body==$body and $r.state=="COMMENTED" and $r.lastEditedAt==null and $r.editor==null and
       ($r.author.databaseId|tostring)==$viewer and
       (($r.author.__typename as $t | (if $t=="Bot" then "bot:" elif $t=="User" then "user:" else "?:" end)+($r.author.databaseId|tostring)) as $actor |
        ($publishers|split("\n")|index($actor))!=null))' "$work/source-$number.json" >/dev/null; then
    refuse "review $url was posted but its GraphQL author, id, edit state or body did not verify; it cannot be deleted; payload retained at $log"
fi
printf 'Published %s\n%s\n' "$url" "$body"
