#!/usr/bin/env bash
# Receipt authority, validity, scope, repairs, complete reads and jq-free snapshot replay.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
source "$PK_ROOT/scripts/review-policy-lib.sh"
source "$PK_ROOT/scripts/review-fingerprint-lib.sh"
source "$PK_ROOT/scripts/review-receipts-lib.sh"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
cat >> .prdkit/memory/config.md <<'EOF'

## Configuration
- review-host: github
- review-publishers: bot:1001
- review-owner: user:1003
- review-publisher-isolation: required
EOF
git add -A; git commit -qm 'trusted receipt policy'
BASE="$(git rev-parse HEAD)"
printf 'implementation\n' > source.txt
git add source.txt; git commit -qm implementation
HEAD_SHA="$(git rev-parse HEAD)"
FP="$(review_fingerprint "$PROJ" 001-reviewed "$BASE" "$HEAD_SHA")"
REGISTRY=$'code\037reviewer\0371\nsecurity\037reviewer\0372'
PR_URL=https://github.com/owner/repo/pull/7
N=0
reset_host() {
    use_gh_stub
    fx_pr 7 "$HEAD_SHA"
    review_receipts_policy "$PROJ" "$BASE" || exit 1
    RC_RIGOR=light
    N=0
}
receipt() { # PR [payload jq transform] [GraphQL node overrides]
    local payload body
    N=$((N+1))
    payload="$(jq -cn --argjson pr "$1" --arg id "$(printf '%032x' "$N")" --arg head "$HEAD_SHA" --arg base "$BASE" --arg fp "$FP" '
        {schema:"prdkit.review.v3",id:$id,repo:"owner/repo",pr:$pr,change:"001-reviewed",reviewer:"code",
         from:"start",to:$fp,head:$head,since:"",base:"refs/remotes/origin/main",base_at:$base,
         verdict:"PASS",critical:0,high:0,medium:0,low:0,report:"https://example.invalid/report"}' | jq -c "${2:-.}")" || return 1
    body="$(printf '<!-- prdkit-review\n%s\n-->\nReport.\n' "$payload")"
    fx_review "$1" "$body" "${3:-}"
}
fetch() { # [failure]; policy/rigor are inputs, every fetch/scope output is reset
    WORK="$(mktemp -d)"; track_tmp "$WORK"
    RC_ERROR=""; RC_REPO=""; RC_PR=""; RC_PR_HEAD=""; RC_PR_CREATED=""; RC_BASE=""
    RC_FETCHED=""; RC_PR_AUTHOR=""; RC_IGNORED=0; RC_NOTES=(); RC_PROBLEMS=()
    RC_INVALID=0; RC_CARRIED=0; RC_RECEIPTS=0
    RC_FILE="$WORK/receipts"; RC_COVERAGE="$WORK/coverage"
    : > "$RC_FILE"; : > "$RC_COVERAGE" # A failed read must not open stdin in a later assertion.
    if review_receipts_fetch "$PR_URL" "$PROJ" "$WORK"; then STATUS=0; else STATUS=$?; fi
    if [ "$STATUS" -eq 0 ]; then review_receipts_scope 001-reviewed light "$REGISTRY" "$WORK" "$PROJ" || STATUS=$?; fi
    if [ "${1:-success}" = success ]; then
        assert_eq 0 "$STATUS" "host read/scope succeeds: $RC_ERROR"
        assert_eq '' "$RC_ERROR" 'successful read has no error'
    fi
}
problems() { printf '%s\n' ${RC_PROBLEMS[@]+"${RC_PROBLEMS[@]}"}; }
reset_host
it 'trusted receipt policy is read from the specified committed snapshot'
assert_eq bot:1001 "$RC_PUBLISHERS"
assert_eq user:1003 "$RC_OWNERS"
assert_eq required "$RC_ISOLATION"
printf '\n- review-publishers: user:1002\n' >> .prdkit/memory/config.md
review_receipts_policy "$PROJ" "$BASE"
assert_eq bot:1001 "$RC_PUBLISHERS" 'working-tree policy is not authority'
git restore .prdkit/memory/config.md
git update-ref refs/remotes/origin/policy "$BASE"
for edit in 's/review-host: github/review-host: other/' 's/bot:1001/bot:login/' \
    's/bot:1001/user:-1/' 's/user:1003/bot:1003/' 's/isolation: required/isolation: optional/'; do
    git show "$BASE:.prdkit/memory/config.md" | sed "$edit" | trusted_edit refs/remotes/origin/policy .prdkit/memory/config.md
    if review_receipts_policy "$PROJ" refs/remotes/origin/policy; then STATUS=0; else STATUS=$?; fi
    assert_eq 1 "$STATUS" "malformed trusted policy: $edit"
done
{ git show "$BASE:.prdkit/memory/config.md"; printf '\n- review-publishers: bot:1001\n'; } |
    trusted_edit refs/remotes/origin/policy .prdkit/memory/config.md
if review_receipts_policy "$PROJ" refs/remotes/origin/policy; then STATUS=0; else STATUS=$?; fi
assert_eq 1 "$STATUS" 'duplicate policy key fails closed'
review_receipts_policy "$PROJ" "$BASE"

it 'NUL-bearing trusted receipt policy is rejected before awk can truncate it'
{ git show "$BASE:.prdkit/memory/config.md"; printf '\000hidden\n'; } |
    trusted_edit refs/remotes/origin/policy .prdkit/memory/config.md
if review_receipts_policy "$PROJ" refs/remotes/origin/policy; then STATUS=0; else STATUS=$?; fi
assert_eq 1 "$STATUS"
assert_contains "$RC_ERROR" 'contains NUL bytes'
review_receipts_policy "$PROJ" "$BASE"

it 'trusted policy read failures are not empty or valid policy, even after valid output'
POLICY_GIT="$(mktemp -d)"; track_tmp "$POLICY_GIT"
POLICY_REAL_GIT="$(command -v git)"; export POLICY_REAL_GIT
cat > "$POLICY_GIT/git" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$POLICY_GIT_LOG"
case "${3:-}" in
    ls-tree) [ "$POLICY_READ_FAILURE" != tree ] || exit 128 ;;
    show)
        case "${4:-}" in *:.prdkit/memory/config.md)
            case "$POLICY_READ_FAILURE" in
                empty-output) exit 128 ;;
                valid-output) "$POLICY_REAL_GIT" "$@"; exit 128 ;;
            esac ;;
        esac ;;
esac
exec "$POLICY_REAL_GIT" "$@"
EOF
chmod +x "$POLICY_GIT/git"
for failure in empty-output valid-output tree; do
    if PATH="$POLICY_GIT:$PATH" POLICY_READ_FAILURE="$failure" POLICY_GIT_LOG="$POLICY_GIT/calls" \
        review_receipts_policy "$PROJ" "$BASE"; then STATUS=0; else STATUS=$?; fi
    assert_eq 1 "$STATUS" "$failure fails closed"
    assert_contains "$RC_ERROR" 'cannot be read' "$failure is a read error, not a missing policy key"
done

it 'only a tree-proven absent policy file reads as empty, without invoking git show'
EMPTY_TREE="$(git mktree < /dev/null)"
ABSENT_POLICY="$(git commit-tree "$EMPTY_TREE" -p "$BASE" -m 'absent receipt policy')"
: > "$POLICY_GIT/calls"
if PATH="$POLICY_GIT:$PATH" POLICY_READ_FAILURE=empty-output POLICY_GIT_LOG="$POLICY_GIT/calls" \
    review_receipts_policy "$PROJ" "$ABSENT_POLICY"; then STATUS=0; else STATUS=$?; fi
assert_eq 1 "$STATUS" 'absence still fails required policy validation'
assert_contains "$RC_ERROR" 'review-publisher-isolation must be required or shared'
assert_not_contains "$RC_ERROR" 'cannot be read' 'absence is not an object read failure'
assert_not_contains "$(cat "$POLICY_GIT/calls")" ' show ' 'no failed show is used to infer absence'
review_receipts_policy "$PROJ" "$BASE"

it 'a listed numeric Bot author authenticates a valid v3 review'
receipt 7
fetch
assert_eq 0 "$STATUS" "$RC_ERROR"
assert_eq 1 "$RC_RECEIPTS"
assert_eq 0 "$RC_INVALID"
assert_eq '' "$(problems)"
assert_eq 1 "$(wc -l < "$RC_COVERAGE" | tr -d ' ')"
assert_contains "$(cat "$GH_STUB_DIR/requests")" 'graphql' 'reviews read through GraphQL'
assert_contains "$(cat "$GH_STUB_DIR/requests")" '-f owner=owner -f name=repo -F number=7' 'GraphQL names stay strings while the PR number is typed'

it 'a decoded host receipt NUL is rejected before normalized rows reach awk'
reset_host; receipt 7 '.report="bad\u0000row"'; fetch
assert_eq 1 "$RC_INVALID"
assert_contains "$(problems)" 'missing or mistyped receipt field'

it 'receipt submission times must be canonical whole-second UTC values'
for submitted in '2026-01-02T00:00:00.5Z' '2026-01-02T00:00:00+00:00' 'not-a-timestamp'; do
    reset_host; receipt 7 . "$(jq -cn --arg time "$submitted" '{submittedAt:$time}')"; fetch failure
    assert_eq 1 "$STATUS" "$submitted is not safe for host ordering"
    assert_contains "$RC_ERROR" 'incomplete or non-advancing review pages'
done

it 'typename plus database id, not login or body, authenticates a publisher'
for override in '{"author":{"__typename":"User","databaseId":1001,"login":"publisher[bot]"}}' \
    '{"author":{"__typename":"Bot","databaseId":1004,"login":"publisher[bot]"}}'; do
    reset_host; receipt 7 . "$override"; fetch
    assert_eq 0 "$STATUS"
    assert_eq 1 "$RC_IGNORED"
    assert_eq 0 "$RC_RECEIPTS"
    assert_eq '' "$(problems)"
done
reset_host; RC_PUBLISHERS=user:1001; receipt 7; fetch
assert_eq 1 "$RC_IGNORED" 'a Bot cannot match a user entry'
reset_host; receipt 7 . '{"state":"PENDING"}'; fetch
assert_eq 0 "$RC_RECEIPTS" 'pending reviews are not receipts'
assert_eq 0 "$RC_INVALID"

it 'either edit marker invalidates a receipt, even with unchanged provenance'
for override in '{"lastEditedAt":"2026-01-03T00:00:00Z"}' '{"editor":{"__typename":"User","login":"admin"}}'; do
    reset_host; receipt 7 . "$override"; fetch
    assert_eq 1 "$RC_INVALID"
    assert_contains "$(problems)" 'edited receipt'
done

it 'zero, multiple, malformed and mistyped receipt blocks fail closed'
for body in 'no receipt' $'<!-- prdkit-review\n{bad}\n-->' $'<!-- prdkit-review\n{}\n-->\n<!-- prdkit-review\n{}\n-->'; do
    reset_host; fx_review 7 "$body"; fetch
    assert_eq 1 "$RC_INVALID" 'publisher body is not skipped'
done
for body in '[]' '"text"' false null; do
    reset_host; fx_review 7 "$(printf '<!-- prdkit-review\n%s\n-->\n' "$body")"; fetch
    assert_eq 0 "$STATUS" 'non-object payload is an invalid receipt, not an unavailable host'
    assert_eq 1 "$RC_INVALID"
done
for edit in '.repo="owner/elsewhere"' '.pr=8' '.pr="7"' '.schema="prdkit.review.v2"' 'del(.low)' '.critical="0"' \
    '.reviewer="owner"' '.to="none"' '.head="HEAD"' '.base_at="main"' '.from="start"|.since=.head' '.report="bad\u001frow"'; do
    reset_host; receipt 7 "$edit"; fetch
    assert_eq 1 "$RC_INVALID" "invalid: $edit"
done
reset_host; receipt 7 '.to="none"|.verdict="FAIL"'; fetch
assert_eq 0 "$RC_INVALID" 'none may name a blocking verdict with no content'
assert_contains "$(problems)" 'blocking verdict stands'

it 'identical retries are no-ops, but a conflicting id blocks'
reset_host; receipt 7; receipt 7 '.id="00000000000000000000000000000001"'; fetch
assert_eq 1 "$RC_RECEIPTS" 'first position retained'
assert_eq 0 "$RC_INVALID"
receipt 7 '.id="00000000000000000000000000000001"|.verdict="FAIL"'; fetch
assert_eq 3 "$RC_INVALID" 'all conflicting occurrences are invalid'
assert_contains "$(problems)" 'different content'

it 'restatement restores the original position and never removes its verdict'
reset_host
receipt 7 '.verdict="FAIL"' '{"lastEditedAt":"2026-01-03T00:00:00Z"}'
receipt 7 '.id="00000000000000000000000000000001"|.verdict="FAIL"|.restates="1001"'
fetch
assert_eq 0 "$RC_INVALID"
assert_eq 1 "$RC_RECEIPTS"
assert_contains "$(problems)" 'blocking verdict stands' 'restated FAIL still blocks'
assert_eq 1 "$(awk -F '\037' '$1=="R" { print $2 }' "$RC_FILE")" 'repair inherits first position'
receipt 7; fetch
assert_eq '' "$(problems)" 'later full PASS clears the restated FAIL'
reset_host; receipt 7 . '{"editor":{"login":"admin"}}'; receipt 7 '.restates="1001"'; fetch
assert_eq 0 "$RC_INVALID" 'a receipt id in an edited body cannot veto the original publisher repair'
reset_host; receipt 7; receipt 7 '.restates="1001"'; fetch
assert_eq 1 "$RC_INVALID" 'restatement cannot remove a valid receipt'

it 'even a same-id restatement cannot replace a valid FAIL with PASS'
reset_host; receipt 7 '.verdict="FAIL"'
receipt 7 '.id="00000000000000000000000000000001"|.restates="1001"'
fetch
assert_eq 1 "$RC_INVALID" 'same id reaches the invalid-original guard, not the id-mismatch guard'
assert_contains "$(problems)" 'blocking verdict stands' 'the valid original FAIL remains'

it 'a different listed publisher cannot restate another publishers invalid receipt'
for author in '{"__typename":"Bot","databaseId":1004,"login":"other[bot]"}' '{"__typename":"User","databaseId":1001,"login":"other"}'; do
    reset_host; RC_PUBLISHERS=$'bot:1001\nbot:1004\nuser:1001'
    receipt 7 '.verdict="FAIL"' '{"editor":{"login":"admin"}}'
    receipt 7 '.id="00000000000000000000000000000001"|.restates="1001"' "$(jq -cn --argjson author "$author" '{author:$author}')"
    fetch
    assert_eq 2 "$RC_INVALID" 'original invalid receipt and unauthorized restatement both block'
    assert_contains "$(problems)" 'same publisher'
    assert_contains "$(problems)" 'edited receipt'
done

it 'foreign changes block without granting checked-change coverage'
reset_host; receipt 7 '.change="002-sibling"|.verdict="FAIL"'; receipt 7 '.reviewer="security"'; fetch
assert_contains "$(problems)" 'code 002-sibling blocking verdict stands'
assert_eq 1 "$(wc -l < "$RC_COVERAGE" | tr -d ' ')"
receipt 7; fetch
assert_eq '' "$(problems)" 'same reviewer full PASS for the checked carrier clears the sibling'
reset_host; receipt 7 '.change="002-sibling"'; fetch
assert_eq '' "$(cat "$RC_COVERAGE")" 'a foreign PASS grants no coverage'

it 'other-change blockers require full PASS; a non-empty narrow PASS cannot clear them'
reset_host; receipt 7 '.change="002-sibling"|.verdict="FAIL"'
receipt 7 '.from="fp1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"|.since="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
fetch
assert_eq 0 "$RC_INVALID" 'the narrow receipt itself is valid'
assert_contains "$(problems)" 'code 002-sibling blocking verdict stands'
receipt 7; fetch
assert_eq '' "$(problems)" 'a later full PASS from start clears the foreign blocker'

it 'host order is submittedAt then numeric review id, not fixture order'
reset_host; receipt 7 . '{"fullDatabaseId":"1010","submittedAt":"2026-01-03T00:00:00Z"}'
receipt 7 '.verdict="FAIL"' '{"fullDatabaseId":"1009","submittedAt":"2026-01-02T00:00:00Z"}'
fetch
assert_eq '' "$(problems)" 'later PASS clears despite reverse fixture order'
assert_eq $'1009\n1010' "$(awk -F '\037' '{ print $4 }' "$RC_COVERAGE")"

it 'same-second receipt order compares review ids numerically across digit lengths'
reset_host; receipt 7 . '{"fullDatabaseId":"10000"}'
receipt 7 '.verdict="FAIL"' '{"fullDatabaseId":"9999"}'
fetch
assert_eq '' "$(problems)" '10000 is later than 9999, not lexically earlier'
assert_eq $'9999\n10000' "$(awk -F '\037' '{ print $4 }' "$RC_COVERAGE")"

it 'neither retired receipt schema nor an owner relay can authenticate a verdict'
for edit in '.schema="prdkit.review.v1"' '.reviewer="owner"'; do
    reset_host; receipt 7 "$edit"; fetch
    assert_eq 1 "$RC_INVALID"
    assert_eq '' "$(cat "$RC_COVERAGE")"
done

it 'tokens are checked against base_at, and missing provenance is not a coverage edge'
reset_host; receipt 7 '.to="fp1:0000000000000000000000000000000000000000000000000000000000000000"'; fetch
assert_eq 1 "$RC_INVALID"
assert_contains "$(problems)" 'its to is not the content of its head'
printf 'follow-up\n' >> source.txt
git commit -qam 'follow-up implementation'
NARROW_HEAD="$(git rev-parse HEAD)"
NARROW_TO="$(review_fingerprint "$PROJ" 001-reviewed "$BASE" "$NARROW_HEAD")"
assert_not_contains "$NARROW_TO" "$FP" 'the narrow PASS has a non-empty range'
NARROW_PASS=".from=\"$FP\"|.to=\"$NARROW_TO\"|.head=\"$NARROW_HEAD\""
for endpoint in head since base_at; do
    reset_host; receipt 7 '.verdict="FAIL"'
    edit=".$endpoint=\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\""
    if [ "$endpoint" = since ]; then
        fx_pr 7 "$NARROW_HEAD"
        edit="$NARROW_PASS|$edit"
    fi
    receipt 7 "$edit"; fetch
    assert_eq 0 "$RC_INVALID" 'absent objects do not erase authenticated history'
    assert_contains "$(problems)" 'blocking verdict stands' "missing $endpoint cannot clear the blocker"
    assert_eq unverified "$(awk -F '\037' 'END { print $NF }' "$RC_COVERAGE")" "missing $endpoint is not verified coverage"
done
reset_host; fx_pr 7 "$NARROW_HEAD"; receipt 7 '.verdict="FAIL"'
receipt 7 "$NARROW_PASS|.since=\"$HEAD_SHA\""; fetch
assert_eq verified "$(awk -F '\037' 'END { print $NF }' "$RC_COVERAGE")" 'local since verifies the same narrow range'
assert_eq '' "$(problems)" 'the same PASS with local since clears the blocker'
assert_eq 0 "$RC_INVALID" 'available since recomputes to from for a non-empty range'
reset_host; receipt 7 '.from=.to|.since=.head'; fetch
assert_eq 1 "$RC_INVALID" 'matching provenance cannot make an empty range valid'
assert_contains "$(problems)" 'prdkit.review.v3 requires a non-empty fingerprint delta'
reset_host; receipt 7 '.from="fp1:0000000000000000000000000000000000000000000000000000000000000000"|.since=.head'; fetch
assert_eq 1 "$RC_INVALID"
assert_contains "$(problems)" 'its from is not the content of since'
reset_host; git update-ref refs/remotes/origin/main "$HEAD_SHA"; receipt 7; fetch
assert_eq 0 "$RC_INVALID" 'the base ref advanced to the reviewed head, but base_at remains authoritative'

it 'required isolation rejects self-publication; shared accepts it with the standing note'
reset_host
fx_pr 7 "$HEAD_SHA" '{"user":{"id":1001},"author":{"databaseId":1001,"login":"publisher[bot]","__typename":"Bot"}}'
receipt 7; fetch
assert_eq 1 "$RC_INVALID"
assert_contains "$(problems)" 'isolation required'
RC_ISOLATION=shared; fetch
assert_eq 0 "$RC_INVALID"
assert_contains "${RC_NOTES[*]}" "not the reviewer's independence"

it 'required isolation is immutable on the source PR, including edited reviews'
reset_host
malformed='.restates="123"|.restates_chain=["invalid"]'
receipt 7 "$malformed" '{"author":{"databaseId":1005}}'
receipt 7 "$malformed"
fetch
assert_eq 1 "$RC_IGNORED" 'unlisted authors do not enter schema validation'
assert_eq 1 "$RC_INVALID" 'malformed trusted chain is one invalid receipt'
assert_contains "$(problems)" 'invalid repair chain'
reset_host
fx_closed_pr 6 "$HEAD_SHA" '{"author":{"databaseId":1001}}'
receipt 6 . '{"editor":{"login":"admin"}}'
receipt 7 '.id="00000000000000000000000000000001"|.restates="1001"|.restates_pr=6'
fetch
assert_contains "$(problems)" 'isolation required'
assert_eq 2 "$RC_INVALID" 'source policy failure and unusable repair remain'

it 'closed-unmerged standing FAILs carry, but closed PASSes never cover'
reset_host; fx_closed_pr 6 "$HEAD_SHA"
receipt 6 '.verdict="FAIL"'; fetch
assert_eq 1 "$RC_CARRIED"
assert_contains "$(problems)" '/pull/6#pullrequestreview-1001'
receipt 7 '.reviewer="security"'; fetch
assert_eq 1 "$RC_CARRIED" 'another reviewer cannot clear carry'
receipt 7; fetch
assert_eq 0 "$RC_CARRIED" 'full PASS on this PR clears carry'

it 'a carried FAIL is not cleared by the same reviewers non-empty narrow PASS'
reset_host; fx_closed_pr 6 "$HEAD_SHA"; receipt 6 '.verdict="FAIL"'
receipt 7 '.from="fp1:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"|.since="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
fetch
assert_eq 0 "$RC_INVALID"
assert_eq 1 "$RC_CARRIED" 'narrow PASS cannot clear carry'
assert_contains "$(problems)" 'blocking verdict stands'
receipt 7; fetch
assert_eq 0 "$RC_CARRIED" 'full PASS from start clears it'

it 'invalid receipts on closed-unmerged PRs carry even after a fresh full PASS'
reset_host; fx_closed_pr 6 "$HEAD_SHA"
receipt 6 '.verdict="FAIL"' '{"lastEditedAt":"2026-01-03T00:00:00Z"}'
receipt 7; fetch
assert_eq 1 "$RC_INVALID" 'the edited predecessor cannot be dropped'
assert_eq 1 "$RC_CARRIED" 'only a same-author restatement can clear invalid carry'
assert_contains "$(problems)" '/pull/6#pullrequestreview-1001: edited receipt'

reset_host; fx_closed_pr 6 "$HEAD_SHA"; receipt 6; fetch
assert_eq '' "$(cat "$RC_COVERAGE")" 'earlier delivery PASS never covers this PR'
reset_host; fx_closed_pr 6 "$HEAD_SHA"; receipt 6 '.verdict="FAIL"'; receipt 6; fetch
assert_eq 0 "$RC_CARRIED" 'origin resolves its own FAIL before carry'
reset_host; fx_closed_pr 6 "$HEAD_SHA" '{"merged_at":"2026-01-03T00:00:00Z"}'; receipt 6 '.verdict="FAIL"'; fetch
assert_eq '' "$(problems)" 'ordinary merged receipts are ignored'

it 'REST and GraphQL closed-source merge status must agree'
for mismatch in state merged rest; do
    reset_host; fx_closed_pr 6 "$HEAD_SHA" '{"merged_at":"2026-01-03T00:00:00Z"}'; fetch
    case "$mismatch" in
        state) edit='.data.repository.pullRequest.state="CLOSED"' ;;
        merged) edit='.data.repository.pullRequest.merged=false' ;;
        rest) edit='.'; fx_closed_pr 6 "$HEAD_SHA" ;;
    esac
    jq "$edit" "$WORK/pages-6" > "$GH_STUB_DIR/routes/graphql_PrdkitReviews-6.json"
    fetch failure
    assert_eq 1 "$STATUS" "$mismatch disagreement fails closed"
    assert_contains "$RC_ERROR" 'changed while enumerating'
done
reset_host
fx_pr 7 "$HEAD_SHA" '{"head":{"ref":"feature&other=#fragment","label":"owner:feature&other=#fragment"}}'
fx_closed_pr 6 "$HEAD_SHA" '{"head":{"ref":"feature&other=#fragment","label":"owner:feature&other=#fragment"}}'
receipt 6 '.verdict="FAIL"'; fetch
assert_eq 1 "$RC_CARRIED" 'query metacharacters in a ref cannot hide its closed source'
assert_contains "$(cat "$GH_STUB_DIR/requests")" 'head=owner%3Afeature%26other%3D%23fragment' 'the head filter is URL encoded'

it 'restatements keep origin scope and survive a merged carrier'
for merge in null '"2026-01-04T00:00:00Z"'; do
    reset_host; fx_closed_pr 6 "$HEAD_SHA"; fx_closed_pr 5 "$HEAD_SHA" "{\"merged_at\":$merge}"
    receipt 6 . '{"editor":{"login":"admin"}}'
    receipt 5 '.id="00000000000000000000000000000001"|.restates="1001"|.restates_pr=6'
    fetch
    assert_eq 0 "$RC_INVALID" 'repair read from closed or merged carrier'
    assert_eq '' "$(problems)"
    assert_eq '' "$(cat "$RC_COVERAGE")" 'restated old PASS gives no new coverage'
done
reset_host; fx_closed_pr 6 "$HEAD_SHA"; receipt 6 '.verdict="FAIL"' '{"lastEditedAt":"2026-01-03T00:00:00Z"}'
receipt 7 '.id="00000000000000000000000000000001"|.restates="1001"|.restates_pr=6|.verdict="FAIL"'; fetch
assert_eq 0 "$RC_INVALID"
assert_eq 1 "$RC_CARRIED" 'restated closed FAIL remains a carried blocker'
receipt 7; fetch
assert_eq 0 "$RC_CARRIED" 'later native full PASS clears it'

it 'paging cannot silently omit a second-page FAIL or an unreadable origin'
reset_host; receipt 7; receipt 7 '.verdict="FAIL"'
GH_STUB_PAGE_SIZE=1; export GH_STUB_PAGE_SIZE
fetch
assert_eq 2 "$RC_RECEIPTS"
assert_contains "$(problems)" 'blocking verdict stands'
GH_STUB_PARTIAL=graphql:PrdkitReviews; export GH_STUB_PARTIAL
fetch failure
assert_eq 1 "$STATUS"
assert_contains "$RC_ERROR" 'incomplete'
unset GH_STUB_PARTIAL GH_STUB_PAGE_SIZE
reset_host; receipt 7; fetch
jq '.data.repository.pullRequest.reviews.pageInfo={hasNextPage:true,endCursor:"same"}' "$WORK/pages-7" > "$GH_STUB_DIR/routes/graphql_PrdkitReviews.json"
jq '.data.repository.pullRequest.reviews.pageInfo={hasNextPage:false,endCursor:"same"}' "$WORK/pages-7" >> "$GH_STUB_DIR/routes/graphql_PrdkitReviews.json"
fetch failure
assert_eq 1 "$STATUS" 'even a terminating stream must advance its cursor'
assert_contains "$RC_ERROR" 'non-advancing'
reset_host; fx_closed_pr 6 "$HEAD_SHA"; rm "$GH_STUB_DIR/reviews/6.json"; fetch failure
assert_eq 1 "$STATUS"
assert_contains "$RC_ERROR" 'PR 6'
reset_host; GH_STUB_OFFLINE=true; export GH_STUB_OFFLINE; fetch failure
assert_eq 1 "$STATUS"
unset GH_STUB_OFFLINE

it 'snapshot round trip needs neither gh nor jq and retains invalid blockers'
reset_host; receipt 7; fx_review 7 'invalid publisher body'; fetch
SNAPSHOT="$WORK/snapshot"
review_receipts_write "$SNAPSHOT"
ORIGINAL="$(cat "$RC_FILE")"
TOOLS="$(mktemp -d)"; track_tmp "$TOOLS"
sha_tool=sha256sum; command -v sha256sum >/dev/null 2>&1 || sha_tool=shasum
for cmd in bash dirname git sed awk tr head tail grep cat mktemp rm mv wc sort mkdir "$sha_tool"; do ln -s "$(command -v "$cmd")" "$TOOLS/$cmd"; done
OFFLINE_WORK="$(mktemp -d)"; track_tmp "$OFFLINE_WORK"
: > "$GH_STUB_DIR/requests"
if PATH="$TOOLS" review_receipts_read "$SNAPSHOT" "$OFFLINE_WORK"; then STATUS=0; else STATUS=$?; fi
assert_eq 0 "$STATUS" "$RC_ERROR"
assert_eq "$ORIGINAL" "$(cat "$RC_FILE")"
if PATH="$TOOLS" review_receipts_scope 001-reviewed light "$REGISTRY" "$OFFLINE_WORK" "$PROJ"; then STATUS=0; else STATUS=$?; fi
assert_eq 0 "$STATUS" "$RC_ERROR"
assert_eq 1 "$RC_INVALID"
assert_eq '' "$(cat "$GH_STUB_DIR/requests")" 'offline reader made no host requests'
if PATH="$TOOLS" review_receipts_fetch "$PR_URL" "$PROJ" "$OFFLINE_WORK"; then STATUS=0; else STATUS=$?; fi
assert_eq 1 "$STATUS" 'online mode fails when gh or jq is absent'
assert_contains "$RC_ERROR" 'need gh and jq'
assert_eq '' "$(cat "$GH_STUB_DIR/requests")" 'missing optional tools never call a real host'
printf 'bad snapshot\n' > "$SNAPSHOT"
if PATH="$TOOLS" review_receipts_read "$SNAPSHOT" "$OFFLINE_WORK"; then STATUS=0; else STATUS=$?; fi
assert_eq 1 "$STATUS" 'malformed offline source is rejected without optional tools'

it 'tampered snapshots revalidate fields, content consistency and increasing sequence offline'
reset_host; receipt 7; receipt 7 '.reviewer="security"'; fetch
SNAPSHOT="$WORK/original-snapshot"; review_receipts_write "$SNAPSHOT"
: > "$GH_STUB_DIR/requests"
for tamper in owner token fingerprint sequence; do
    awk -F '\037' -v OFS='\037' -v tamper="$tamper" '
        NR==2 && tamper=="owner" { $8="owner" }
        NR==2 && tamper=="token" { $9="not-a-token"; $12="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" }
        NR==2 && tamper=="fingerprint" { $10="fp1:0000000000000000000000000000000000000000000000000000000000000000" }
        NR==3 && tamper=="sequence" { $2=1 }
        { print }' "$SNAPSHOT" > "$WORK/tampered-snapshot"
    OFFLINE_WORK="$(mktemp -d)"; track_tmp "$OFFLINE_WORK"
    if PATH="$TOOLS" review_receipts_read "$WORK/tampered-snapshot" "$OFFLINE_WORK"; then STATUS=0; else STATUS=$?; fi
    if [ "$tamper" = sequence ]; then
        assert_eq 1 "$STATUS" 'non-increasing sequence rejects the snapshot before scope'
        assert_contains "$RC_ERROR" 'malformed receipt snapshot'
    else
        assert_eq 0 "$STATUS" "$RC_ERROR"
        if PATH="$TOOLS" review_receipts_scope 001-reviewed light "$REGISTRY" "$OFFLINE_WORK" "$PROJ"; then STATUS=0; else STATUS=$?; fi
        assert_eq 0 "$STATUS" "$RC_ERROR"
        assert_eq 1 "$RC_INVALID" "$tamper becomes an invalid blocking row"
        if [ "$tamper" = fingerprint ]; then assert_contains "$(problems)" 'its to is not the content of its head'
        else assert_contains "$(problems)" 'invalid receipt tokens or fields'; fi
    fi
    assert_eq '' "$(cat "$GH_STUB_DIR/requests")" 'tampered replay still makes no host call'
done

it 'snapshot receipt submission times also fail closed without gh or jq'
awk -F '\037' -v OFS='\037' 'NR==2 { $5="2026-01-02T00:00:00.5Z" } { print }' "$SNAPSHOT" > "$WORK/bad-time"
OFFLINE_WORK="$(mktemp -d)"; track_tmp "$OFFLINE_WORK"
if PATH="$TOOLS" review_receipts_read "$WORK/bad-time" "$OFFLINE_WORK"; then STATUS=0; else STATUS=$?; fi
assert_eq 1 "$STATUS"
assert_contains "$RC_ERROR" 'malformed receipt snapshot'
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

it 'raw NUL in a snapshot is rejected before awk or shell row decoding'
# Embed it in an otherwise valid header, not an extra invalid row: a truncating awk
# and Bash read would otherwise accept the original numeric author id unchanged.
{ IFS= read -r header; printf '%s\000\n' "$header"; cat; } < "$SNAPSHOT" > "$WORK/nul-snapshot"
OFFLINE_WORK="$(mktemp -d)"; track_tmp "$OFFLINE_WORK"
if PATH="$TOOLS" review_receipts_read "$WORK/nul-snapshot" "$OFFLINE_WORK"; then STATUS=0; else STATUS=$?; fi
assert_eq 1 "$STATUS"
assert_contains "$RC_ERROR" 'malformed receipt snapshot'
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
finish
