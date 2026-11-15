#!/usr/bin/env bash
# Real publisher against the shared host stub, including read-back, log repair and legacy close.
# shellcheck disable=SC2016 # jq variables and Markdown markers are literal.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
source "$PK_ROOT/scripts/review-fingerprint-lib.sh"
STATUS=0
PROJ="$(make_inited_project)"; track_tmp "$PROJ"; cd "$PROJ" || exit 1
PUB="$PROJ/.prdkit/scripts/bash/publish-review.sh"; CHECK="$PROJ/.prdkit/scripts/bash/check-review.sh"
cat >> .prdkit/memory/config.md <<'EOF'

## Configuration
- review-host: github
- review-publishers: bot:1001
- review-owner: user:1003
- review-publisher-isolation: required
EOF
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n| security | reviewer |\n| maker | maker |\n' >> .prdkit/memory/agents.md
git add -A; git commit -qm baseline; BASE="$(git rev-parse HEAD)"
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git update-ref refs/remotes/origin/main "$BASE"
git checkout -qb 001-reviewed
mkdir -p specs/changes
printf '# Change\n**Tier**: T1\n## State\n' > specs/changes/001-reviewed.md
printf implementation > source.txt
git add -A; git commit -qm implementation; A="$(git rev-parse HEAD)"
PR=https://github.com/owner/repo/pull/7
LOG_ROOT="$PROJ/.git/prdkit/receipts"
fresh() {
    git reset -q --hard "$A"; git update-ref refs/remotes/origin/main "$BASE"
    use_gh_stub; fx_pr 7 "$A"
}
post() { run bash "$PUB" 001-reviewed --pr "$PR" --reviewer code --verdict PASS --counts 0,0,0,0 --report https://example.invalid/report --head HEAD "$@"; }
payload() { printf '%s\n' "$OUTPUT" | awk '/^<!-- prdkit-review$/ { inside=1; next } inside && /^-->$/ { exit } inside { print }'; }
gate() { fx_pr 7 "$(git rev-parse HEAD)"; run bash "$CHECK" --json --pr "$PR" 001-reviewed; }

it 'dry-run prints exact v3 fields, preserves source and never calls the host'
fresh; before="$(git status --porcelain; git rev-parse HEAD; git hash-object specs/changes/001-reviewed.md)"
post --dry-run --counts 00,0,01,2
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
assert_eq "$before" "$(git status --porcelain; git rev-parse HEAD; git hash-object specs/changes/001-reviewed.md)"
assert_eq 'base,base_at,change,critical,from,head,high,id,low,medium,pr,repo,report,reviewer,schema,since,to,verdict' "$(payload | jq -r 'keys|join(",")')"
assert_eq 'prdkit.review.v3/owner/repo/7/code/PASS/0/0/1/2' "$(payload | jq -r '[.schema,.repo,.pr,.reviewer,.verdict,.critical,.high,.medium,.low]|join("/")')"
assert_eq "$A/$BASE" "$(payload | jq -r '[.head,.base_at]|join("/")')"
assert_eq 32 "$(payload | jq '.id|length')"

it 'posting sends COMMENT without commit_id and verifies GraphQL before reporting success'
post
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq COMMENT "$(jq -r .event "$GH_STUB_DIR/post-request.json")"
assert_eq false "$(jq 'has("commit_id")' "$GH_STUB_DIR/post-request.json")"
assert_contains "$(cat "$GH_STUB_DIR/requests")" 'query PrdkitReviews'
assert_not_contains "$(cat "$GH_STUB_DIR/requests")" 'pulls/7/reviews/1001' 'REST is never used to validate a review'
RECEIPT_ID="$(payload | jq -r .id)"
assert_file "$LOG_ROOT/7/$RECEIPT_ID.json"
assert_eq "$RECEIPT_ID" "$(jq -r .id "$LOG_ROOT/7/$RECEIPT_ID.json")"
assert_eq "$RECEIPT_ID" "$(jq -r .id "$LOG_ROOT/7/reviews/1001.json")" 'review-id log points to the posted verdict'
gate; assert_eq 0 "$STATUS" "$OUTPUT"

it 'a second trusted integration ref cannot SIGPIPE a dry-run default-base match'
fresh
git show "$BASE:.prdkit/memory/config.md" | sed '/^## Configuration$/a\
- review-integration-branches: origin/develop' | trusted_edit refs/remotes/origin/main .prdkit/memory/config.md
post --dry-run
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

it 'a failed POST keeps the write-ahead payload and never reports publication'
fresh
run env GH_STUB_FAIL=pulls/7/reviews bash "$PUB" 001-reviewed --pr "$PR" --reviewer code --verdict FAIL --counts 0,0,0,0 --report https://example.invalid/report --head HEAD
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'POST failed or its result is unknown'
saved_log="$(printf '%s\n' "$OUTPUT" | sed 's/.*payload is retained at //;s/; inspect the PR before retrying$//')"
assert_file "$saved_log"
assert_eq FAIL "$(jq -r .verdict "$saved_log")"
assert_not_contains "$OUTPUT" 'Published '

it 'all b refusals occur without posting'
fresh; git branch -f wip HEAD
for flags in base since owner identity maker unknown fingerprint since-fingerprint counts report-field; do
    case "$flags" in
        base) post --dry-run --base wip ;;
        since) post --dry-run --since HEAD ;;
        owner) post --dry-run --reviewer owner --since HEAD~1 ;;
        identity) post --dry-run --reviewer Code ;;
        maker) post --dry-run --reviewer maker ;;
        unknown) post --dry-run --reviewer absent ;;
        fingerprint) post --dry-run --head fp1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
        since-fingerprint) post --dry-run --since fp1:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
        counts) post --dry-run --counts 0,0,-1,0 ;;
        report-field) post --dry-run --report 'https://example.invalid/a · b' ;;
    esac
    assert_eq 1 "$STATUS" "$flags: $OUTPUT"
    assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
done
run bash "$PUB" 001-reviewed --pr "$PR" --reviewer code --verdict PASS --report https://example.invalid/report --head HEAD --dry-run
assert_eq 1 "$STATUS" 'counts are required without --from-report'
assert_contains "$OUTPUT" '--counts is required'
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

it 'a posted review with unavailable GraphQL read-back retains its repair payload'
fresh
run env GH_STUB_FAIL=graphql:PrdkitReviews bash "$PUB" 001-reviewed --pr "$PR" --reviewer code --verdict FAIL --counts 0,0,0,0 --report https://example.invalid/report --head HEAD
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'was posted but GraphQL read-back failed'
saved="$(jq -r '.body|split("\n")[1]|fromjson|.id' "$GH_STUB_DIR/post-request.json")"
assert_file "$LOG_ROOT/7/$saved.json"

it 'from-report reads the final two lines and refuses disagreeing CLI verdict/counts'
fresh
printf 'Findings and evidence.\nVerdict: PASS\nCounts: 0 critical, 0 high, 0 medium, 2 low\n' > .git/report
post --dry-run --from-report .git/report --counts 0,0,0,2
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 2 "$(payload | jq .low)"
post --dry-run --from-report .git/report --verdict FAIL --counts 0,0,0,2
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'disagrees with --from-report'
post --dry-run --from-report .git/report
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" '--counts disagrees'
run bash "$PUB" 001-reviewed --pr "$PR" --reviewer code --report https://example.invalid/report --head HEAD --from-report .git/report --dry-run
assert_eq 0 "$STATUS" 'report may supply verdict and counts'
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

it 'malformed or trailing report text cannot supply a verdict'
for trailer in 'Counts: unreadable' 'Counts: 0 critical, 0 high, 0 medium, -1 low' 'trailing explanation'; do
    printf 'Verdict: PASS\n%s\n' "$trailer" > .git/report
    post --dry-run --from-report .git/report
    assert_eq 1 "$STATUS" "$trailer"
    assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
done

it 'dry-run is JSON-only and leaves no publisher log even without gh on PATH'
fresh; TOOLS="$(mktemp -d)"; track_tmp "$TOOLS"
sha_tool=sha256sum; command -v sha256sum >/dev/null 2>&1 || sha_tool=shasum
for cmd in bash dirname git sed awk tr head tail grep cat mktemp rm mv mkdir wc sort jq od "$sha_tool"; do
    ln -s "$(command -v "$cmd")" "$TOOLS/$cmd"
done
logs_before="$(find "$LOG_ROOT" -type f | sort)"
run env PATH="$TOOLS" bash "$PUB" 001-reviewed --pr "$PR" --reviewer code --verdict PASS --counts 0,0,0,0 --report https://example.invalid/report --head HEAD --dry-run
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq "$logs_before" "$(find "$LOG_ROOT" -type f | sort)"
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

it 'read-back rejects wrong typename/id, edits and changed body, retaining the log'
for overrides in '{"author":{"__typename":"User","databaseId":1001}}' \
    '{"author":{"databaseId":1005}}' '{"lastEditedAt":"2026-01-03T00:00:00Z"}' \
    '{"editor":{"login":"admin"}}' '{"body":"corrupted"}' '{"state":"APPROVED"}'; do
    fresh
    run env GH_STUB_POST_OVERRIDES="$overrides" bash "$PUB" 001-reviewed --pr "$PR" --reviewer code --verdict PASS --counts 0,0,0,0 --report https://example.invalid/report --head HEAD
    assert_eq 1 "$STATUS" "$OUTPUT"
    assert_contains "$OUTPUT" 'was posted but'
    assert_contains "$(cat "$GH_STUB_DIR/requests")" '--method POST'
    saved="$(jq -r '.body|split("\n")[1]|fromjson|.id' "$GH_STUB_DIR/post-request.json")"
    assert_file "$LOG_ROOT/7/$saved.json" 'write-ahead log survives failed verification'
done

it 'GraphQL must return the exact POST review database id'
fresh; post
assert_eq 0 "$STATUS" "$OUTPUT"
gh api graphql --hostname github.com -f 'query=query PrdkitReviews { fixture }' -F owner=owner -F name=repo -F number=7 > .git/read-back
jq '.data.repository.pullRequest.reviews.nodes[0].fullDatabaseId="9999"' .git/read-back > "$GH_STUB_DIR/routes/graphql_PrdkitReviews.json"
post
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'GraphQL author, id, edit state or body did not verify'
saved="$(jq -r '.body|split("\n")[1]|fromjson|.id' "$GH_STUB_DIR/post-request.json")"
assert_file "$LOG_ROOT/7/$saved.json"

it 'required isolation refuses before POST, while viewer User still matches the bot numeric id'
fresh; fx_pr 7 "$A" '{"user":{"id":1001},"author":{"databaseId":1001,"__typename":"Bot"}}'
post
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'isolation required'
assert_not_contains "$(cat "$GH_STUB_DIR/requests")" '--method POST'

it 'restatement reads the original full verdict from the log on the same or a later PR'
fresh; post --verdict FAIL
assert_eq 0 "$STATUS" "$OUTPUT"; original="$(payload)"; saved="$(payload | jq -r .id)"
jq '.[0].body="corrupted"|.[0].lastEditedAt="2026-01-03T00:00:00Z"' "$GH_STUB_DIR/reviews/7.json" > .git/edited
mv .git/edited "$GH_STUB_DIR/reviews/7.json"
run bash "$PUB" --pr "$PR" --restates 1001 --receipt-id "$saved"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq "$original" "$(payload | jq -c 'del(.restates)')"
assert_eq false "$(payload | jq 'has("restates_pr")')"
gate; assert_eq 1 "$STATUS" 'restatement restores FAIL, never deletes its verdict'
assert_contains "$OUTPUT" '"invalid_receipts":0'
fx_closed_pr 7 "$A"
fx_pr 8 "$A"
run bash "$PUB" --pr https://github.com/owner/repo/pull/8 --restates 1001 --restates-pr 7 --receipt-id "$saved"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq '8/7' "$(payload | jq -r '[.pr,.restates_pr]|join("/")')"
assert_eq "$original" "$(payload | jq -c 'del(.restates,.restates_pr)|.pr=7')"
run bash "$CHECK" --json --pr https://github.com/owner/repo/pull/8 001-reviewed
assert_eq 1 "$STATUS" 'identical restatement retries keep the original FAIL'
assert_contains "$OUTPUT" '"invalid_receipts":0' 'a repeated faithful repair is a no-op, not a new invalid receipt'

it 'tracked and planted old in-tree logs are never used for restatement'
for kind in planted tracked; do
    fresh; missing=00000000000000000000000000009999
    mkdir -p .prdkit/cache/receipts/7
    printf '{"id":"%s","verdict":"PASS"}\n' "$missing" > ".prdkit/cache/receipts/7/$missing.json"
    if [ "$kind" = tracked ]; then git add -f ".prdkit/cache/receipts/7/$missing.json"; git commit -qm forged; fi
    run bash "$PUB" --pr "$PR" --restates 1001 --receipt-id "$missing"
    assert_eq 1 "$STATUS" "$kind old log is not publisher state"
    assert_contains "$OUTPUT" 'no original publisher log'
    assert_not_contains "$(cat "$GH_STUB_DIR/requests")" '--method POST'
    rm -f ".prdkit/cache/receipts/7/$missing.json"
done

it 'editing FAIL and planting a tracked PASS log cannot produce host-authority PASS'
fresh; post --verdict FAIL --counts 0,1,0,0
assert_eq 0 "$STATUS" "$OUTPUT"; saved="$(payload | jq -r .id)"
jq '.[0].body=(.[0].body|split("\n")|.[1]|fromjson|.verdict="PASS"|.high=0|"<!-- prdkit-review\n"+tojson+"\n-->") |
    .[0].lastEditedAt="2026-01-03T00:00:00Z"' "$GH_STUB_DIR/reviews/7.json" > .git/edited
mv .git/edited "$GH_STUB_DIR/reviews/7.json"
gate; assert_eq 1 "$STATUS" 'an edited FAIL remains invalid'
mkdir -p .prdkit/cache/receipts/7
jq '.verdict="PASS"|.high=0' "$LOG_ROOT/7/$saved.json" > ".prdkit/cache/receipts/7/$saved.json"
git add -f ".prdkit/cache/receipts/7/$saved.json"; git commit -qm 'planted old publisher log'
run bash "$PUB" --pr "$PR" --restates 1001 --receipt-id "$saved"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 'FAIL/1' "$(payload | jq -r '[.verdict,.high]|join("/")')" 'repair uses the publisher-owned original, not the planted PASS'
git rm -q -f ".prdkit/cache/receipts/7/$saved.json"; git commit -qm 'remove planted log'
gate; assert_eq 1 "$STATUS" 'restatement cannot launder FAIL into host PASS'
assert_contains "$OUTPUT" '"authority":"host"'
assert_contains "$OUTPUT" '"invalid_receipts":0'
assert_contains "$OUTPUT" 'verdict FAIL, not PASS'

it 'every symlinked publisher-log component is refused before posting'
fresh; post --verdict FAIL
assert_eq 0 "$STATUS" "$OUTPUT"; saved="$(payload | jq -r .id)"
for component in "$PROJ/.git/prdkit" "$LOG_ROOT" "$LOG_ROOT/7" "$LOG_ROOT/7/$saved.json" "$LOG_ROOT/7/reviews" "$LOG_ROOT/7/reviews/1001.json"; do
    mv "$component" "$component.saved"
    ln -s "$component.saved" "$component"
    : > "$GH_STUB_DIR/requests"
    run bash "$PUB" --pr "$PR" --restates 1001 --receipt-id "$saved"
    assert_eq 1 "$STATUS" "$component is not a trusted log path"
    assert_contains "$OUTPUT" 'symlinked publisher log component'
    assert_not_contains "$(cat "$GH_STUB_DIR/requests")" '--method POST'
    rm "$component"; mv "$component.saved" "$component"
done

it 'linked worktrees share the absolute Git-common-dir publisher log'
fresh; LINKED="$(mktemp -d)"; track_tmp "$LINKED"
git worktree add -q --detach "$LINKED" "$A"
post --repo "$LINKED"
assert_eq 0 "$STATUS" "$OUTPUT"; saved="$(payload | jq -r .id)"
assert_file "$LOG_ROOT/7/$saved.json"
assert_eq file "$([ -f "$LINKED/.git" ] && printf file)" 'linked checkout uses a gitfile, not a separate publisher log'

it 'real empty-content publishing clears a merged-open legacy FAIL with no artificial delta'
git reset -q --hard "$BASE"; git update-ref refs/remotes/origin/main "$BASE"
mkdir -p specs/changes
printf '# Change\n**Tier**: T1\n## State\n**Review**: round 1 · ignored · code · FAIL · 0 critical, 0 high, 0 medium, 0 low · legacy\n' > specs/changes/001-reviewed.md
git add -A; git commit -qm inherited; INHERITED="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main "$INHERITED"
git rm -q specs/changes/001-reviewed.md; mkdir -p specs/log
printf -- '- 2026-01-01 001-reviewed: closed\n' > specs/log/001-reviewed.md
git add specs/log; git commit -qm close
use_gh_stub; fx_pr 7 "$(git rev-parse HEAD)"
gate; assert_eq 1 "$STATUS" 'closing waits for the reviewer full PASS'
post
assert_eq 1 "$STATUS" 'empty content is refused without the explicit exception'
post --clears-legacy --reviewer security
assert_eq 1 "$STATUS" 'another reviewer has no matching legacy blocker'
post --clears-legacy --since HEAD
assert_eq 1 "$STATUS" 'empty --since remains refused'
post --clears-legacy
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq "$REVIEW_FP_EMPTY" "$(payload | jq -r .to)"
gate; assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq true "$(printf '%s' "$OUTPUT" | jq '.legacy_blockers[0].cleared')"
finish
