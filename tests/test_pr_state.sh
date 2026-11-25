#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
use_gh_stub
PR_STATE="$PROJ/.prdkit/scripts/bash/pr-state.sh"
CI_WAIT="$PROJ/.prdkit/scripts/bash/ci-wait.sh"
ROUTES="$GH_STUB_DIR/routes"
HEAD_SHA=1111111111111111111111111111111111111111
OTHER=2222222222222222222222222222222222222222
CHECK='suite "quotes" / café'
JOB_LINK='https://github.com/owner/repo/actions/runs/91/job/71'
fx_pr 7 "$HEAD_SHA"

pr_metadata() {
    jq -n --arg head "$1" --arg base "$OTHER" '{
      data: {repository:{nameWithOwner:"owner/repo",pullRequest:{
        number:7, state:"OPEN", isDraft:true, headRefOid:$head, baseRefOid:$base, baseRefName:"main",
        mergeable:"UNKNOWN", mergeStateStatus:"BLOCKED", baseRef:{name:"main",branchProtectionRule:null}
      }}}}'
}
pr_metadata "$HEAD_SHA" > "$ROUTES/graphql_PrdkitPRFacts.json"
rule_file="$ROUTES/rules_branches_main_per_page_100.json"
required_rules() {
    jq -n --arg name "$CHECK" '[[{type:"required_status_checks",parameters:{
        required_status_checks:[{context:$name,integration_id:15368}]}}]]'
}
required_rules > "$rule_file"

check_run() { # status conclusion [opaque id] [url]
    jq -n --arg name "$CHECK" --arg status "$1" --arg conclusion "$2" --arg id "${3:-job-71}" \
        --arg url "${4:-$JOB_LINK}" '{
          __typename:"CheckRun", id:$id,name:$name,status:$status,
          conclusion:(if $conclusion=="" then null else $conclusion end),
          detailsUrl:$url, permalink:$url, checkSuite:{app:{databaseId:15368}}, isRequired:true}'
}
check_page() { # total more cursor [commit]; reads check objects from stdin
    jq -s --arg head "$HEAD_SHA" --arg commit "${4:-$HEAD_SHA}" --arg cursor "$3" \
        --argjson total "$1" --argjson more "$2" '{
          data:{repository:{nameWithOwner:"owner/repo",pullRequest:{
            number:7, headRefOid:$head, baseRefName:"main", commits:{nodes:[{commit:{
              oid:$commit,statusCheckRollup:{contexts:{totalCount:$total,nodes:.,pageInfo:{
                hasNextPage:$more,endCursor:(if $cursor=="" then null else $cursor end)
              }}}}}]}
          }}}}'
}
check_file="$ROUTES/graphql_PrdkitCheckFacts.json"
check_run COMPLETED SUCCESS | check_page 1 false '' > "$check_file"

it 'both installed helpers expose help without reading GitHub'
for helper in "$PR_STATE" "$CI_WAIT"; do
    run bash "$helper" --help
    assert_eq 0 "$STATUS"
    assert_contains "$OUTPUT" 'never a merge verdict'
done
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

it 'PR snapshot round-trips JSON and retains only the latest submitted review per account'
fx_review 7 old-request '{"state":"CHANGES_REQUESTED","submittedAt":"2026-01-02T00:01:00Z"}'
fx_review 7 approval '{"state":"APPROVED","submittedAt":"2026-01-02T00:02:00Z"}'
fx_review 7 newer-pending '{"state":"PENDING","submittedAt":null,"author":null}'
fx_owner_review 7 APPROVED "$HEAD_SHA"
fx_owner_review 7 CHANGES_REQUESTED "$OTHER" # same timestamp; GitHub page order breaks the tie
fx_review 7 old-timestamp '{"state":"COMMENTED","submittedAt":"2026-01-01T23:59:00Z"}'
run env GH_STUB_PAGE_SIZE=2 bash "$PR_STATE" 7
assert_eq 0 "$STATUS"
assert_eq true "$(jq -s --arg name "$CHECK" --arg url "$JOB_LINK" --arg head "$HEAD_SHA" --arg base "$OTHER" '
    length == 1 and (.[0] |
      .repo == "owner/repo" and .number == 7 and .state == "OPEN" and .draft == true and
      .head_sha == $head and .base_ref == "main" and .base_sha == $base and
      .mergeable == "UNKNOWN" and .merge_state == "BLOCKED" and
      .required_checks == [{name:$name,status:"COMPLETED",conclusion:"SUCCESS",link:$url}] and
      .reviews.latest_by_account == [
        {account_id:1001,review_id:"1002",state:"APPROVED",submitted_at:"2026-01-02T00:02:00Z",commit_sha:$head},
        {account_id:1003,review_id:"1005",state:"CHANGES_REQUESTED",submitted_at:"2026-01-02T00:00:00Z",commit_sha:$base}
      ] and .reviews.blocking == [.reviews.latest_by_account[1]] and
      (.fetched_at | type == "string" and endswith("Z")))' <<< "$OUTPUT")"
assert_contains "$(cat "$GH_STUB_DIR/requests")" 'after=cursor-4'

it 'only completed SUCCESS passes, including when the exact head has multiple pages'
check_run COMPLETED SUCCESS | check_page 2 true cursor-1 > "$check_file"
check_run QUEUED '' | jq '.id="optional" | .name="optional" | .isRequired=false' |
    check_page 2 false '' > "$ROUTES/graphql_PrdkitCheckFacts-cursor-1.json"
wait_for_ci() { run bash "$CI_WAIT" --repo owner/repo --timeout "${1:-30}" --interval 1 7 --head "$HEAD_SHA" "${@:2}"; }
wait_for_ci
assert_eq 0 "$STATUS"
assert_eq '' "$OUTPUT"
assert_contains "$(cat "$GH_STUB_DIR/requests")" 'endCursor=cursor-1'

it 'a partial or duplicate check inventory cannot pass and never produces a snapshot'
printf '%s\n' '' | check_page 2 false '' > "$ROUTES/graphql_PrdkitCheckFacts-cursor-1.json"
wait_for_ci
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'incomplete GitHub pagination'
check_run COMPLETED SUCCESS | check_page 2 false '' > "$ROUTES/graphql_PrdkitCheckFacts-cursor-1.json"
wait_for_ci
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'duplicated check page entry'
run env GH_STUB_PAGE_SIZE=2 GH_STUB_PARTIAL=graphql:PrdkitReviews bash "$PR_STATE" --repo owner/repo 7
assert_eq 2 "$STATUS"
assert_not_contains "$OUTPUT" '"fetched_at"'

it 'a failure prints a bounded excerpt from a verified exact-head job'
signature='runner lost [temporary].'
job_fixture() { # id, URL
    jq -n --argjson id "$1" --arg head "$HEAD_SHA" --arg name "$CHECK" --arg url "$2" '{
        id:$id,run_id:91,head_sha:$head,name:$name,html_url:$url,status:"completed",conclusion:"failure"
    }' > "$ROUTES/actions_jobs_$1.json"
    {
        printf 'HTTP/1.1 200 OK\nContent-Type: text/plain\r\n\r\n'
        printf '%s\n' "$signature"
        awk 'BEGIN { for (i=1; i<=100; i++) print "background line " i }'
        printf '\033[31m##[error]example failure\033[0m\n'
        awk 'BEGIN { for (i=1; i<=15; i++) print "cleanup line " i }'
    } > "$ROUTES/actions_jobs_${1}_logs.txt"
}
job_fixture 71 "$JOB_LINK"
printf 'HTTP/2.0 201 Created\r\n\r\n' > "$ROUTES/actions_jobs_71_rerun.json"
check_run COMPLETED FAILURE | check_page 1 false '' > "$check_file"
wait_for_ci
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "$CHECK"$'\tFAILURE\t'"$JOB_LINK"
assert_contains "$OUTPUT" '##[error]example failure'
assert_not_contains "$OUTPUT" 'cleanup line 15'
assert_not_contains "$OUTPUT" $'\033'
assert_eq true "$([ "$(grep -c '^  |' <<< "$OUTPUT")" -le 12 ] && echo true)"
assert_not_contains "$(cat "$GH_STUB_DIR/requests")" '--method POST'
printf 'HTTP/1.1 200 OK\nContent-Type: text/html\r\n\r\n%s\n' "$signature" > "$ROUTES/actions_jobs_71_logs.txt"
wait_for_ci
assert_eq 2 "$STATUS" 'an unexpected log response is not a valid failure excerpt or retry signal'
assert_contains "$OUTPUT" 'expected a nonempty plain-text Actions job log'
job_fixture 71 "$JOB_LINK"

it 'reruns require a literal match on an explicitly supplied file, and are attempted only once'
printf '%s\n' 'runner lost .*[temporary].' > "$GH_STUB_DIR/signatures"
wait_for_ci 30 --rerun-on "$GH_STUB_DIR/signatures"
assert_eq 1 "$STATUS"
assert_not_contains "$(cat "$GH_STUB_DIR/requests")" '--method POST'
printf '%s\n' "$signature" > "$GH_STUB_DIR/signatures"
job2='https://github.com/owner/repo/actions/runs/91/job/72'
job_fixture 72 "$job2"
check_run COMPLETED FAILURE job-72 "$job2" | check_page 1 false '' > "$ROUTES/graphql_PrdkitCheckFacts-rerun.json"
wait_for_ci 30 --rerun-on "$GH_STUB_DIR/signatures"
assert_eq 1 "$STATUS" 'a rerun failure is still a failure'
assert_contains "$OUTPUT" "Rerun requested: $CHECK [$HEAD_SHA] $JOB_LINK"
assert_contains "$OUTPUT" "$CHECK"$'\tFAILURE\t'"$job2"
assert_eq 'actions/jobs/71/rerun' "$(cat "$GH_STUB_DIR/rerun")"
rm "$GH_STUB_DIR/rerun"

it 'absent required and queued checks time out; non-success conclusions fail'
check_page 0 false '' </dev/null > "$check_file"
run bash "$PR_STATE" --repo owner/repo 7
assert_eq 0 "$STATUS"
assert_eq NOT_STARTED "$(jq -r '.required_checks[0].status' <<< "$OUTPUT")"
wait_for_ci 1
assert_eq 3 "$STATUS"
assert_contains "$OUTPUT" 'timed out'
check_run QUEUED '' | check_page 1 false '' > "$check_file"
wait_for_ci 1
assert_eq 3 "$STATUS"
for conclusion in SKIPPED CANCELLED STALE NEUTRAL TIMED_OUT; do
    # Third-party check links must not be dereferenced or treated as Actions jobs.
    check_run COMPLETED "$conclusion" job-71 https://example.com/check |
        check_page 1 false '' > "$check_file"
    wait_for_ci
    assert_eq 1 "$STATUS" "$conclusion is never success"
    assert_contains "$OUTPUT" "$CHECK"$'\t'"$conclusion"$'\thttps://example.com/check'
done

it 'stale head and differently bound check payloads are refused without reporting results'
: > "$GH_STUB_DIR/requests"
pr_metadata "$OTHER" > "$ROUTES/graphql_PrdkitPRFacts.json"
wait_for_ci
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'stale head'
assert_not_contains "$(cat "$GH_STUB_DIR/requests")" 'PrdkitCheckFacts'
pr_metadata "$HEAD_SHA" > "$ROUTES/graphql_PrdkitPRFacts.json"
check_run COMPLETED SUCCESS | check_page 1 false '' "$OTHER" > "$check_file"
wait_for_ci
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'refusing alternate commit checks'
check_run COMPLETED FAILURE | check_page 1 false '' > "$check_file"
pr_metadata "$OTHER" > "$ROUTES/graphql_PrdkitPRFacts-later.json"
wait_for_ci
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'stale head'
assert_not_contains "$OUTPUT" "$JOB_LINK"
rm "$ROUTES/graphql_PrdkitPRFacts-later.json"

it 'classic protection and legacy statuses work without an installed jq binary'
pr_metadata "$HEAD_SHA" | jq --arg name "$CHECK" '.data.repository.pullRequest.baseRef.branchProtectionRule={
    requiresStatusChecks:true,requiredStatusCheckContexts:[$name],requiredStatusChecks:[{context:$name,app:null}]
}' > "$ROUTES/graphql_PrdkitPRFacts.json"
printf '[[]]\n' > "$rule_file"
jq -n --arg name "$CHECK" '{__typename:"StatusContext",id:"status-1",context:$name,state:"SUCCESS",
    targetUrl:null,isRequired:true}' | check_page 1 false '' > "$check_file"
gh api graphql -f 'query=query PrdkitReviews { repository }' -F number=7 > "$GH_STUB_DIR/reviews-response.json" || exit 1
mv "$GH_STUB_DIR/reviews-response.json" "$ROUTES/graphql_PrdkitReviews.json"
cat > "$GH_STUB_DIR/bin/jq" <<'NO_JQ'
#!/usr/bin/env bash
echo "jq must not be invoked" >&2
exit 99
NO_JQ
chmod +x "$GH_STUB_DIR/bin/jq"
wait_for_ci
assert_eq 0 "$STATUS"
run bash "$PR_STATE" --repo owner/repo 7
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '"status": "COMPLETED", "conclusion": "SUCCESS", "link": null'
rm "$GH_STUB_DIR/bin/jq" "$ROUTES/graphql_PrdkitReviews.json"
pr_metadata "$HEAD_SHA" > "$ROUTES/graphql_PrdkitPRFacts.json"

it 'an empty requirement inventory and corrupt gh output never pass'
printf '[[]]\n' > "$rule_file"
wait_for_ci
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'no required status checks'
required_rules > "$rule_file"
printf '{"data":' > "$check_file"
wait_for_ci
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'expected complete JSON from gh'
printf '[{"type":"required_status_checks"}]\n' > "$rule_file"
wait_for_ci
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'expected a complete paginated rule list'
run bash "$CI_WAIT" --repo owner/repo --timeout 0 7 --head "$HEAD_SHA"
assert_eq 2 "$STATUS"
finish
