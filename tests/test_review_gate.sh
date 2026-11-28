#!/usr/bin/env bash
# Real gate modes. No recipe bridge: host evidence and record text vary independently here.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
STATUS=0
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
CHECK="${TEST_REVIEW_GATE:-$PROJ/.prdkit/scripts/bash/check-review.sh}"
cat > .prdkit/memory/config.md <<'EOF'

## Configuration
- review-host: github
- review-publishers: bot:1001, user:1002, user:1003, user:1004
- review-owner: user:1003, user:1005
- review-t0-paths: docs/
EOF
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n| second | reviewer |\n' >> .prdkit/memory/agents.md
mkdir -p .prdkit/history
printf -- '- 2026-01-02 002-earlier: completed\n' > .prdkit/history/log.md
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
dismiss_review() { # GitHub updates the original review, not a separate timeline entry.
    local f="$GH_STUB_DIR/reviews/7.json"
    jq --arg id "$1" 'map(if (.fullDatabaseId|tostring)==$id then .state="DISMISSED" else . end)' "$f" > "$f.new" && mv "$f.new" "$f"
}
it 'only native approvals from an allowed non-author account count'
fx_review 7 'Verdict: PASS'
online; assert_eq 1 "$STATUS" 'review body is not approval'
fx_owner_review 7 APPROVED "$HEAD_SHA" '{"author":{"databaseId":1009}}'
fx_owner_review 7 APPROVED "$HEAD_SHA" '{"author":{"databaseId":1002}}'
online; assert_eq 1 "$STATUS" 'even an allowlisted PR author never counts'
fx_review 7 'reviewed' '{"state":"APPROVED"}'
online; assert_eq 0 "$STATUS" "eligible publisher: $OUTPUT"
git show "$BASE:.prdkit/memory/config.md" | { cat; echo '- review-publisher-isolation: shared'; } |
    trusted_edit refs/remotes/origin/main .prdkit/memory/config.md
online; assert_eq 1 "$STATUS" 'retired receipt policy fails closed'
assert_contains "$OUTPUT" 'review-publisher-isolation is unsupported'
git update-ref refs/remotes/origin/main "$BASE"; online
assert_contains "$OUTPUT" '"authority":"host"'
assert_contains "$OUTPUT" '"reviewer":1001'

it 'only the latest submitted review by that account on the exact head decides'
for state in CHANGES_REQUESTED DISMISSED COMMENTED; do
    printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
    publisher_review APPROVED "$HEAD_SHA"; online; assert_eq 0 "$STATUS" 'publisher qualifies at T1'
    publisher_review "$state" "$BASE"; online
    if [ "$state" = CHANGES_REQUESTED ]; then assert_eq 1 "$STATUS" 'later objection on another SHA blocks'
    else assert_eq 0 "$STATUS" 'other commits cannot revoke a positive approval'; fi
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
assert_contains "$OUTPUT" "publisher 1004 (review $block_id on $HEAD_SHA)"
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
for retired in --receipts --save-receipts; do
    run bash "$CHECK" "$retired" snapshot 001-reviewed
    assert_eq 2 "$STATUS"
    assert_contains "$OUTPUT" "Unknown option: $retired"
done

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
        publisher_review CHANGES_REQUESTED "$h" '{"author":{"databaseId":1002}}'
        publisher_review CHANGES_REQUESTED "$h" '{"author":{"databaseId":1009}}'
        online; assert_eq 0 "$STATUS" 'author and unlisted objections do not block T0'
        publisher_review CHANGES_REQUESTED "$h"; online; assert_eq 1 "$STATUS" 'eligible objection blocks T0'
        assert_contains "$OUTPUT" '"blocking":[{"reviewer":1001,'
        dismiss_review "$(jq -r 'last.fullDatabaseId' "$GH_STUB_DIR/reviews/7.json")"
        online; assert_eq 0 "$STATUS" 'dismissed objection no longer blocks T0'
        assert_contains "$OUTPUT" '"reviews":[]'
        assert_contains "$OUTPUT" '"blocking":[]'
        echo 'unrelated rewrite' > .prdkit/history/log.md; git commit -qam 'shared log is not automatically exempt'
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
    dismiss_review "$(jq -r 'last.fullDatabaseId' "$GH_STUB_DIR/reviews/7.json")"
    fx_pr 7 "$h" '{"author":{"databaseId":1003}}'; online; assert_eq 1 "$STATUS" 'PR author cannot approve as owner'
    fx_pr 7 "$h"
    fx_owner_review 7 DISMISSED "$h"; online; assert_eq 1 "$STATUS" 'dismissal removes the owner approval'
    fx_owner_review 7 APPROVED "$h"; publisher_review CHANGES_REQUESTED "$h"
    online; assert_eq 1 "$STATUS" 'owner cannot compensate for publisher revocation'
done
it 'objections survive a push until their own dismissal or the objector approves the new head'
for level in T0 T1; do
    git checkout -q --detach "$BASE"
    mkdir -p specs/changes
    printf '# Change\n**Tier**: %s\n## State\n' "$level" > specs/changes/001-reviewed.md
    git add -A; git commit -qm "$level record"
    old="$(git rev-parse HEAD)"; fx_pr 7 "$old"
    f="$GH_STUB_DIR/reviews/7.json"; printf '[]\n' > "$f"
    publisher_review CHANGES_REQUESTED "$old"; objection="$(jq -r 'last.fullDatabaseId' "$f")"
    git commit -q --allow-empty -m 'new PR head'; h="$(git rev-parse HEAD)"; fx_pr 7 "$h"
    online; assert_eq 1 "$STATUS" "$level push alone cannot clear an objection"
    assert_contains "$OUTPUT" "\"blocking\":[{\"reviewer\":1001,\"review\":\"$objection\",\"role\":\"publisher\",\"commit\":\"$old\"}]"
    publisher_review APPROVED "$h" "$second"; online; assert_eq 1 "$STATUS" "$level another publisher cannot clear it"
    publisher_review APPROVED "$old"; publisher_review COMMENTED "$h"; online
    assert_eq 1 "$STATUS" "$level old-head approval and new-head comment cannot clear it"
    publisher_review DISMISSED "$h"; online; assert_eq 1 "$STATUS" "$level unrelated dismissal cannot clear it"
    publisher_review CHANGES_REQUESTED "$h"; newer="$(jq -r 'last.fullDatabaseId' "$f")"
    dismiss_review "$newer"; online; assert_eq 1 "$STATUS" "$level dismissing only the newer objection leaves the original"
    cp "$f" "$f.before"
    dismiss_review "$objection"; online; assert_eq 0 "$STATUS" "$level dismissal of the objection itself clears it"
    mv "$f.before" "$f"
    publisher_review APPROVED "$h"; GH_STUB_PAGE_SIZE=1 online
    assert_eq 0 "$STATUS" "$level later exact-head approval by the objector clears it across pages"
    assert_contains "$OUTPUT" '"blocking":[]'
done

owner_policy() {
    { git show "$BASE:.prdkit/memory/config.md"; printf '%s\n' "$@"; } |
        trusted_edit refs/remotes/origin/main .prdkit/memory/config.md
}

it 'only trusted per-PR policy lets a T3 owner approval carry to a descendant'
git checkout -q --detach "$BASE"
mkdir -p specs/changes
printf '# Change\n**Tier**: T3\n## State\n' > specs/changes/001-reviewed.md
echo '- owner-approval: per-pr' >> .prdkit/memory/config.md
git add -A; git commit -qm 'T3 implementation'
approved="$(git rev-parse HEAD)"
printf 'ordinary follow-up\n' > source.txt
git add source.txt; git commit -qm 'fix "quoted" output'
git commit -q --allow-empty -m 'close review round'
h="$(git rev-parse HEAD)"; fx_pr 7 "$h"
f="$GH_STUB_DIR/reviews/7.json"; printf '[]\n' > "$f"
publisher_review APPROVED "$h"; fx_owner_review 7 APPROVED "$approved"
rid="$(jq -r 'last.fullDatabaseId' "$f")"
online; assert_eq 1 "$STATUS" 'missing key defaults to exact-head despite the candidate edit'
assert_contains "$OUTPUT" "requires a review-owner APPROVED review on the exact PR head $h"
assert_not_contains "$OUTPUT" '"owner_approval'
implicit="$(jq -c 'del(.policy_at)' <<< "$OUTPUT")"
owner_policy '- owner-approval: exact-head'
online; assert_eq 1 "$STATUS" 'explicit exact-head also refuses'
assert_eq "$implicit" "$(jq -c 'del(.policy_at)' <<< "$OUTPUT")" 'explicit and implicit exact-head have the same verdict'
owner_policy '- owner-approval: per-pr'
GH_STUB_PAGE_SIZE=1 online; assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq "per-pr 1003 $rid $approved 0" \
    "$(jq -r '.owner_approval | [.mode,.reviewer,.review,.commit,.more] | join(" ")' <<< "$OUTPUT")"
assert_eq false "$(jq '.owner_approval | has("base")' <<< "$OUTPUT")"
assert_eq "publisher owner" "$(jq -r '[.reviews[].role]|join(" ")' <<< "$OUTPUT")"
commits="$(git log --format='%h %s' "$approved..$h")"
assert_eq "$commits" "$(jq -r '.owner_approval.commits_since[]' <<< "$OUTPUT")"
run bash "$CHECK" --pr "$PR" 001-reviewed
assert_eq 0 "$STATUS"; assert_contains "$OUTPUT" "owner approval is per-PR, given on $approved"
while IFS= read -r line; do assert_contains "$OUTPUT" "  $line"; done <<< "$commits"

it 'the latest deciding owner review is replayed across commits and pages'
fx_owner_review 7 COMMENTED "$h"; online; assert_eq 0 "$STATUS" 'comment is not a deciding review'
fx_review 7 draft '{"state":"PENDING","submittedAt":null}'; online; assert_eq 0 "$STATUS" 'pending is ignored'
fx_owner_review 7 CHANGES_REQUESTED "$approved" '{"submittedAt":"2026-02-01T00:00:00Z"}'
fx_owner_review 7 APPROVED "$h" # appears last, but submitted before the objection
GH_STUB_PAGE_SIZE=1 online; assert_eq 1 "$STATUS" 'later objection on an earlier SHA voids approval'
assert_contains "$OUTPUT" '"blocking":[{"reviewer":1003,'
fx_owner_review 7 APPROVED "$approved" '{"submittedAt":"2026-02-02T00:00:00Z"}'
rid="$(jq -r 'last.fullDatabaseId' "$f")"
online; assert_eq 0 "$STATUS" 'later qualifying approval from the objector restores it'
assert_contains "$OUTPUT" '"blocking":[]'
dismiss_review "$rid"; online; assert_eq 1 "$STATUS" 'the latest dismissed approval does not count or restore an older approval'
assert_not_contains "$OUTPUT" '"owner_approval"'
fx_owner_review 7 APPROVED "$h" '{"submittedAt":"2026-02-03T00:00:00Z"}'
run bash "$CHECK" --pr "$PR" 001-reviewed
assert_eq 0 "$STATUS"; exact_text="$OUTPUT"
assert_not_contains "$OUTPUT" 'per-PR'
online; assert_eq 0 "$STATUS"; exact_json="$(jq -c 'del(.policy_at)' <<< "$OUTPUT")"
assert_not_contains "$OUTPUT" '"owner_approval"'
owner_policy '- owner-approval: exact-head'
run bash "$CHECK" --pr "$PR" 001-reviewed
assert_eq "$exact_text" "$OUTPUT" 'clean exact-head approval prints the same in both modes'
online; assert_eq "$exact_json" "$(jq -c 'del(.policy_at)' <<< "$OUTPUT")"
owner_policy '- owner-approval: per-pr'

it 'per-PR does not credit old publisher, non-owner or rewritten approvals'
printf '[]\n' > "$f"
publisher_review APPROVED "$approved"; fx_owner_review 7 APPROVED "$approved"
online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'requires an independent review-publishers APPROVED review'
printf '[]\n' > "$f"
publisher_review APPROVED "$h"; fx_owner_review 7 APPROVED "$approved" '{"author":{"databaseId":1009}}'
online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'requires a review-owner APPROVED review under per-PR policy'
rewritten="$(git commit-tree "$approved^{tree}" -p "$BASE" -m 'old version of this PR')"
fx_owner_review 7 APPROVED "$approved"; fx_owner_review 7 APPROVED "$rewritten"
online; assert_eq 1 "$STATUS" 'latest approval on rewritten history cannot carry or restore the prior one'
assert_eq "$rewritten" "$(jq -r '.owner_approval_not_ancestors[]' <<< "$OUTPUT")"
run bash "$CHECK" --pr "$PR" 001-reviewed
assert_contains "$OUTPUT" "approval on $rewritten does not carry over: not a verified ancestor of $h"
fx_owner_review 7 APPROVED "$approved" '{"author":{"databaseId":1005}}'
online; assert_eq 0 "$STATUS" 'a different eligible owner can still satisfy the minimum'
assert_eq 1005 "$(jq '.owner_approval.reviewer' <<< "$OUTPUT")"
fx_owner_review 7 CHANGES_REQUESTED "$approved"
online; assert_eq 1 "$STATUS" 'another owner approval cannot clear the objector'
assert_eq 1003 "$(jq '.blocking[].reviewer' <<< "$OUTPUT")"

it 'invalid or duplicate owner policy fails closed'
for value in '' sticky 'per-pr exact-head' Exact-head; do
    owner_policy "- owner-approval: $value"
    online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'Expected one owner-approval value'
    assert_contains "$OUTPUT" '"authority":"unavailable"'
done
owner_policy '- owner-approval: per-pr' '- owner-approval: per-pr'
online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'Expected one owner-approval value'
owner_policy '- owner-approval: per-pr' '- Owner-Approval: exact-head'
online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'Invalid owner-approval key'
owner_policy '- **owner-approval**: per-pr'
online; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'Invalid owner-approval key'
for unrelated in '- owner-approval-note: keep approvals current' '- owner-approval_x: per-pr' \
    'Set owner-approval: per-pr only before production.' '- review-notes: owner-approval=per-pr is pre-production only'; do
    owner_policy "$unrelated"
    online; assert_not_contains "$OUTPUT" '"authority":"unavailable"'
    assert_not_contains "$OUTPUT" 'owner-approval key'
done
owner_policy '- owner-approval: per-pr'

it 'per-PR commit evidence lists the first 20 lines in git log order'
for i in {1..22}; do git commit -q --allow-empty -m "follow-up $i"; done
h="$(git rev-parse HEAD)"; fx_pr 7 "$h"
printf '[]\n' > "$f"
publisher_review APPROVED "$h"; fx_owner_review 7 APPROVED "$approved"
online; assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 20 "$(jq '.owner_approval.commits_since|length' <<< "$OUTPUT")"
assert_eq 4 "$(jq '.owner_approval.more' <<< "$OUTPUT")"
assert_eq "$(git log --format='%h %s' -20 "$approved..$h")" \
    "$(jq -r '.owner_approval.commits_since[]' <<< "$OUTPUT")"
run bash "$CHECK" --pr "$PR" 001-reviewed
assert_eq 0 "$STATUS"; assert_contains "$OUTPUT" '  +4 more'
assert_not_contains "$OUTPUT" 'fix "quoted" output'

carry_reviews() { # approval commit; publish the current fixture head and reset reviews
    h="$(git rev-parse HEAD)"; fx_pr 7 "$h"
    printf '[]\n' > "$f"
    publisher_review APPROVED "$h"; fx_owner_review 7 APPROVED "$1"
}
assert_policy_carry_refused() { # first policy commit and Git's displayed path
    online
    assert_eq 1 "$STATUS" "$_CURRENT"
    assert_eq "fail host publisher" \
        "$(jq -r '[.result,.authority,.reviews[].role] | join(" ")' <<< "$OUTPUT")"
    assert_eq "$1 $2" "$(jq -r '.owner_approval_policy_change | [.commit,.path] | join(" ")' <<< "$OUTPUT")"
    assert_not_contains "$OUTPUT" '"owner_approval":'
    run bash "$CHECK" --pr "$PR" 001-reviewed
    assert_eq 1 "$STATUS"
    assert_contains "$OUTPUT" "$1 ($2)"
    assert_contains "$OUTPUT" "fresh owner approval on the exact head $h"
}

it 'a carried owner approval stops at the oldest policy edit, not the latest edit'
git checkout -q --detach "$approved"
git commit -q --allow-empty -m 'ordinary follow-up before policy'
printf '\nPolicy update.\n' >> .prdkit/memory/config.md
git add .prdkit/memory/config.md; git commit -qm 'first policy edit'
first_policy="$(git rev-parse HEAD)"
printf '\nSecond update.\n' >> .prdkit/memory/config.md
git add .prdkit/memory/config.md; git commit -qm 'second policy edit'
carry_reviews "$approved"
assert_policy_carry_refused "$first_policy" .prdkit/memory/config.md

it 'an exact-head owner approval still counts with policy edits'
fx_owner_review 7 APPROVED "$h" '{"author":{"databaseId":1005}}'
online; assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 'publisher owner' "$(jq -r '[.reviews[].role] | join(" ")' <<< "$OUTPUT")"
assert_not_contains "$OUTPUT" '"owner_approval'

it 'a carried approval does not cover a kit gitlink update'
git checkout -q --detach "$approved"
git rm -qr .product-kit
git update-index --add --cacheinfo "160000,$BASE,.product-kit"
git commit -qm 'pin kit'
link_approved="$(git rev-parse HEAD)"
git update-index --cacheinfo "160000,$approved,.product-kit"
git commit -qm 'update kit pin'
carry_reviews "$link_approved"
git config diff.ignoreSubmodules all
assert_policy_carry_refused "$h" .product-kit
git config --unset diff.ignoreSubmodules

it 'a carried approval does not cover a workflow file, including spaces in its path'
git checkout -q --detach "$approved"
mkdir -p .github/workflows
printf 'name: example\n' > '.github/workflows/check changes.yml'
git add .github/workflows; git commit -qm 'add review workflow'
carry_reviews "$approved"
assert_policy_carry_refused "$h" '.github/workflows/check changes.yml'

it 'a carried approval treats a quoted raw path as policy'
git checkout -q --detach "$approved"
odd_path="$(printf 'odd-\303\251.txt')"
printf 'follow-up\n' > "$odd_path"
git add "$odd_path"; git commit -qm 'add file with an odd path'
carry_reviews "$approved"
git config core.quotePath false
assert_policy_carry_refused "$h" '"odd-\303\251.txt"'
git config --unset core.quotePath

it 'a carried approval accepts policy changes that match the merged trusted base, not its tip'
per_pr_base="$(git rev-parse origin/main)"
git checkout -q --detach "$per_pr_base"
mkdir -p .github/workflows
printf 'name: old check\n' > .github/workflows/old.yml
git add .github/workflows; git commit -qm 'baseline workflow'
merge_fork="$(git rev-parse HEAD)"
git checkout "$approved" -- specs/changes/001-reviewed.md
git commit -qm 'implement change'
merge_approved="$(git rev-parse HEAD)"

git checkout -q --detach "$merge_fork"
mkdir -p .prdkit/history/log
history_path='.prdkit/history/log/002-[closed].md'
printf -- '- 2026-01-02 002-earlier: completed\n' > "$history_path"
git add -- "$history_path"; git commit -qm 'record a completed change'
printf '\nBase policy update.\n' >> .prdkit/memory/config.md
git rm -q .github/workflows/old.yml
git add .prdkit/memory/config.md; git commit -qm 'update base policy'
merged_base="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main "$merged_base"
{ git show "$merged_base:.prdkit/memory/config.md"; printf '\nNot merged yet.\n'; } |
    trusted_edit refs/remotes/origin/main .prdkit/memory/config.md

git checkout -q --detach "$merge_approved"
git merge -q --no-ff -m 'update from trusted base' "$merged_base"
printf 'ordinary follow-up after updating\n' > source.txt
git add source.txt; git commit -qm 'follow up after update'
merged_head="$(git rev-parse HEAD)"
assert_eq "$merged_base" "$(git merge-base origin/main "$merged_head")"
carry_reviews "$merge_approved"
online; assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq "$merge_approved $merged_base" \
    "$(jq -r '.owner_approval | [.commit,.base] | join(" ")' <<< "$OUTPUT")"
assert_not_contains "$OUTPUT" '"owner_approval_policy_change"'

it 'a PR policy change introduced by merging the base is attributed to the merge commit'
git checkout -q --detach "$merge_approved"
git merge -q --no-ff --no-commit "$merged_base"
mkdir -p .github/workflows
printf 'name: new check\n' > .github/workflows/new.yml
git add .github/workflows; git commit -qm 'merge with a PR workflow edit'
carry_reviews "$merge_approved"
assert_policy_carry_refused "$h" .github/workflows/new.yml

it 'a merge resolution that differs from the trusted base voids carry'
git checkout -q --detach "$merge_approved"
git merge -q --no-ff --no-commit "$merged_base"
printf '\nDifferent resolution.\n' >> .prdkit/memory/config.md
git add .prdkit/memory/config.md; git commit -qm 'merge with a different policy resolution'
carry_reviews "$merge_approved"
assert_policy_carry_refused "$merged_base" .prdkit/memory/config.md

it 'a clean merge of approved PR and base edits to the same path still needs fresh approval'
git checkout -q --detach "$merge_approved"
{ printf '# PR policy notes\n'; git show HEAD:.prdkit/memory/config.md; } > .prdkit/memory/config.md
git add .prdkit/memory/config.md; git commit -qm 'document PR policy changes'
same_path_approved="$(git rev-parse HEAD)"
git merge -q --no-ff -m 'combine two policy edits' "$merged_base"
carry_reviews "$same_path_approved"
assert_policy_carry_refused "$merged_base" .prdkit/memory/config.md

it 'a mode difference from the trusted base voids carry even with identical blob content'
git checkout -q --detach "$merged_head"
chmod +x "$history_path"
git update-index --chmod=+x -- "$history_path"
git commit -qm 'change mode only'
carry_reviews "$merge_approved"
assert_policy_carry_refused "$(git rev-parse "$merged_base^")" "$history_path"

it 'a carried owner approval needs one trusted merge base even without a net policy change'
feature_tip="$(git commit-tree "$merge_approved^{tree}" -p "$merge_approved" -p "$merged_base" -m 'feature integrates target')"
target_tip="$(git commit-tree "$merged_base^{tree}" -p "$merged_base" -p "$merge_approved" -m 'target integrates feature')"
git update-ref refs/remotes/origin/main "$target_tip"
git checkout -q --detach "$feature_tip"
carry_reviews "$merge_approved"
online; assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'multiple merge bases'
assert_contains "$OUTPUT" "fresh owner approval on the exact head $h"
assert_not_contains "$OUTPUT" '"owner_approval"'
assert_not_contains "$OUTPUT" '"owner_approval_policy_change"'
assert_not_contains "$OUTPUT" 'touches the policy surface'
mkdir -p .github/workflows
printf 'on: push\n' > .github/workflows/ambiguous.yml
git add .github/workflows/ambiguous.yml; git commit -qm 'add workflow after integration'
ambiguous_policy="$(git rev-parse HEAD)"
carry_reviews "$merge_approved"
online; assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'multiple merge bases'
assert_eq "$ambiguous_policy .github/workflows/ambiguous.yml" \
    "$(jq -r '.owner_approval_policy_change | [.commit,.path] | join(" ")' <<< "$OUTPUT")"
assert_not_contains "$OUTPUT" '"owner_approval":'
run bash "$CHECK" --pr "$PR" 001-reviewed
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "single trusted merge base for the carried T3 owner approval on $merge_approved, and $ambiguous_policy (.github/workflows/ambiguous.yml) touches the policy surface"
git update-ref refs/remotes/origin/main "$per_pr_base"

it 'only net policy changes under the exact prefixes stop a carry'
git checkout -q --detach "$first_policy"
git revert --no-edit "$first_policy" >/dev/null
mkdir -p .github/workflows-notes
printf 'Notes\n' > .github/workflows-notes/review.md
git add .github/workflows-notes; git commit -qm 'add workflow notes outside the policy surface'
carry_reviews "$approved"
online; assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq "$approved" "$(jq -r '.owner_approval.commit' <<< "$OUTPUT")"
assert_not_contains "$OUTPUT" '"owner_approval_policy_change"'

it 'an unreadable carry diff fails closed, even when Git produced output'
real_git="$(command -v git)"
mkdir "$_SCRATCH_CWD/git-fault"
cat > "$_SCRATCH_CWD/git-fault/git" <<'SH'
#!/usr/bin/env bash
case "$REVIEW_DIFF_FAULT:$*" in
    'diff:'*' diff --raw '*|'diff-tree:'*' diff-tree --raw '*)
        "$REAL_GIT" "$@"
        exit 5 ;;
esac
case "$*" in
    *" ls-tree "*" $REVIEW_TREE_FAULT -- .github/workflows/old.yml"|*" ls-tree $REVIEW_TREE_FAULT")
        if [ -n "$REVIEW_TREE_FAULT" ]; then
            "$REAL_GIT" "$@"
            exit 5
        fi ;;
esac
exec "$REAL_GIT" "$@"
SH
chmod +x "$_SCRATCH_CWD/git-fault/git"
for fault in diff diff-tree; do
    if [ "$fault" = diff ]; then target="$first_policy^"; else target="$first_policy"; fi
    git checkout -q --detach "$target"
    carry_reviews "$approved"
    REAL_GIT="$real_git" REVIEW_DIFF_FAULT="$fault" PATH="$_SCRATCH_CWD/git-fault:$PATH" online
    assert_eq 1 "$STATUS" "$fault read failure must prevent carry"
    assert_eq "fail host publisher" \
        "$(jq -r '[.result,.authority,.reviews[].role] | join(" ")' <<< "$OUTPUT")"
    assert_contains "$OUTPUT" 'Cannot read the policy diff for the carried T3 owner approval'
    assert_contains "$OUTPUT" "fresh owner approval on the exact head $h"
    assert_not_contains "$OUTPUT" '"owner_approval'
done

it 'an unreadable tree entry is not evidence of a matching policy deletion'
git update-ref refs/remotes/origin/main "$merged_base"
git checkout -q --detach "$merged_head"
carry_reviews "$merge_approved"
for unreadable in "$h" "$merged_base"; do
    REAL_GIT="$real_git" REVIEW_TREE_FAULT="$unreadable" PATH="$_SCRATCH_CWD/git-fault:$PATH" \
        assert_policy_carry_refused "$merged_base" .github/workflows/old.yml
done
git update-ref refs/remotes/origin/main "$per_pr_base"

it 'an unreadable merge base tree voids carry even without policy changes'
git checkout -q --detach "$first_policy^"
carry_reviews "$approved"
REAL_GIT="$real_git" REVIEW_TREE_FAULT="$(git merge-base origin/main "$h")" \
    PATH="$_SCRATCH_CWD/git-fault:$PATH" online
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "fresh owner approval on the exact head $h"
assert_not_contains "$OUTPUT" '"owner_approval"'

it 'per-PR policy does not change owner objections at T1 or T2'
for level in T1 T2; do
    git checkout -q --detach "$BASE"
    mkdir -p specs/changes
    printf '# Change\n**Tier**: %s\n## State\n' "$level" > specs/changes/001-reviewed.md
    git add -A; git commit -qm "$level record"
    approved="$(git rev-parse HEAD)"
    git commit -q --allow-empty -m 'new exact head'
    h="$(git rev-parse HEAD)"; fx_pr 7 "$h"; printf '[]\n' > "$f"
    publisher_review APPROVED "$h"
    fx_owner_review 7 CHANGES_REQUESTED "$approved"; fx_owner_review 7 APPROVED "$approved"
    online; assert_eq 1 "$STATUS" "$level requires an exact-head approval to clear the owner's objection"
    assert_contains "$OUTPUT" '"blocking":[{"reviewer":1003,'
    fx_owner_review 7 APPROVED "$h"; online; assert_eq 0 "$STATUS" "$OUTPUT"
done

owner_comment() { # body timestamp [author ID] [extra host fields]
    local extra="${4:-}"
    jq --arg body "$1" --arg at "$2" --argjson author "${3:-1003}" --argjson extra "${extra:-null}" '
        ((last.fullDatabaseId // "2000" | tonumber) + 1 | tostring) as $id |
        . + [({fullDatabaseId:$id,body:$body,createdAt:$at,updatedAt:$at,lastEditedAt:null,
            author:{__typename:"User",databaseId:$author},url:("https://github.com/owner/repo/pull/7#issuecomment-"+$id)} * ($extra // {}))]
    ' "$comments" > "$comments.next" && mv "$comments.next" "$comments"
}
reset_opt_in() {
    printf '[]\n' > "$comments"
    carry_reviews "$1"
}
assert_opt_in_exact_required() {
    online
    assert_eq 1 "$STATUS" "$_CURRENT"
    assert_contains "$OUTPUT" '"authority":"host"'
    assert_contains "$OUTPUT" "requires a review-owner APPROVED review on the exact PR head $h"
    assert_not_contains "$OUTPUT" '"owner_approval":'
}

it 'only the trusted config enables exact-head-opt-in; all three values parse'
mkdir "$GH_STUB_DIR/comments"; comments="$GH_STUB_DIR/comments/7.json"
carry='owner-approval: carry'; exact_line='owner-approval: exact-head'
hint='This repository allows owner-approval: carry'
t1='2026-01-03T00:00:00Z'; t2='2026-01-04T00:00:00Z'; t3='2026-01-05T00:00:00Z'
owner_policy '- owner-approval: exact-head-opt-in'
git checkout -q --detach origin/main
git checkout "$merge_approved" -- specs/changes/001-reviewed.md
git commit -qm 'implement T3 change'; opt_approved="$(git rev-parse HEAD)"
git commit -q --allow-empty -m "$carry"
opt_head="$(git rev-parse HEAD)"
reset_opt_in "$opt_approved"
for mode in exact-head exact-head-opt-in per-pr; do
    owner_policy "- owner-approval: $mode"
    online
    assert_contains "$OUTPUT" '"authority":"host"' "$mode parses"
done
owner_policy '- owner-approval: sticky'
online; assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'exact-head, exact-head-opt-in or per-pr'
git update-ref refs/remotes/origin/main "$BASE"
: > "$GH_STUB_DIR/requests"
owner_comment "$carry" "$t1"
assert_opt_in_exact_required
assert_not_contains "$OUTPUT" "$hint"
assert_not_contains "$(cat "$GH_STUB_DIR/requests")" PrdkitOwnerComments
owner_policy '- owner-approval: exact-head-opt-in'

it 'an owner comment on a later page enables carry with its provenance'
reset_opt_in "$opt_approved"
owner_comment 'Earlier discussion.' "$t1"
owner_comment $'I expect follow-ups.\r\nowner-approval: carry  \r\nThanks.' "$t2"
: > "$GH_STUB_DIR/requests"
GH_STUB_PAGE_SIZE=1 online; assert_eq 0 "$STATUS" "$_CURRENT"
assert_contains "$(cat "$GH_STUB_DIR/requests")" 'page PrdkitOwnerComments pr=7 after=cursor-1'
assert_contains "$(cat "$GH_STUB_DIR/requests")" 'body createdAt updatedAt lastEditedAt url'
assert_contains "$(cat "$GH_STUB_DIR/requests")" 'state submittedAt commit { oid } author { __typename'
assert_eq "exact-head-opt-in $opt_approved 0 comment 2002 https://github.com/owner/repo/pull/7#issuecomment-2002 1003 $t2" \
    "$(jq -r '.owner_approval | [.mode,.commit,.more, (.opt_in | .kind,.id,.url,.author,.at)] | join(" ")' <<< "$OUTPUT")"
assert_eq 'at author id kind url' "$(jq -r '.owner_approval.opt_in | keys | join(" ")' <<< "$OUTPUT")"
assert_eq "$(git log --format='%h %s' "$opt_approved..$h")" "$(jq -r '.owner_approval.commits_since[]' <<< "$OUTPUT")"
assert_eq 'review reviewer role' "$(jq -r '.reviews[]|select(.role=="owner") | keys | join(" ")' <<< "$OUTPUT")"

it 'owner review bodies do not opt in, whether submitted or pending'
reset_opt_in "$opt_approved"
fx_owner_review 7 COMMENTED "$h" "{\"body\":\"$carry\",\"submittedAt\":\"$t1\"}"
assert_opt_in_exact_required
fx_owner_review 7 PENDING "$h" "{\"body\":\"$carry\",\"submittedAt\":null,\"createdAt\":\"$t2\"}"
assert_opt_in_exact_required
jq 'map(del(.body,.url,.createdAt))' "$f" > "$f.next" && mv "$f.next" "$f"
owner_comment "$carry" "$t1"
online; assert_eq 0 "$STATUS" 'the pending review does not interfere with the valid comment'
assert_eq "$t1" "$(jq -r '.owner_approval.opt_in.at' <<< "$OUTPUT")"

it 'untrusted authors, PR text and decorated lines do not opt in'
reset_opt_in "$opt_approved"
fx_pr 7 "$h" "{\"body\":\"$carry\"}"
owner_comment "$carry" "$t1" 1009 '{"author":{"login":"owner"}}'
fx_review 7 "$carry" '{"author":{"__typename":"Bot","databaseId":1003}}'
owner_comment "Please use $carry" "$t1"
owner_comment "$carry today" "$t1"
owner_comment $'> owner-approval: carry\n`owner-approval: carry`\n    owner-approval: carry\nowner-approval: carry\t' "$t1"
assert_opt_in_exact_required
assert_contains "$OUTPUT" "$hint"
assert_eq 2 "$(jq -r '.problems|length' <<< "$OUTPUT")" 'one problem and one hint'

it 'a marker only permits carry for its author'
reset_opt_in "$opt_approved"
printf '[]\n' > "$f"; publisher_review APPROVED "$h"
fx_owner_review 7 APPROVED "$opt_approved" '{"author":{"__typename":"User","databaseId":1005}}'
owner_comment "$carry" "$t1"
assert_opt_in_exact_required
owner_comment "$carry" "$t2" 1005
online; assert_eq 0 "$STATUS" "$_CURRENT"
assert_eq '1005 1005' "$(jq -r '.owner_approval | [.reviewer,.opt_in.author] | join(" ")' <<< "$OUTPUT")"

it 'an edited owner comment cannot opt in, even if it is newest or edited in the same second'
reset_opt_in "$opt_approved"
owner_comment 'Earlier discussion.' "$t1"
owner_comment "$carry" "$t2" 1003 "{\"updatedAt\":\"$t3\"}"
assert_opt_in_exact_required
owner_comment "$carry" "$t3" 1003 "{\"lastEditedAt\":\"$t3\"}"
assert_opt_in_exact_required

it 'edited comments neither replace nor revoke an earlier unedited carry'
reset_opt_in "$opt_approved"
owner_comment "$carry" "$t1"
owner_comment "$carry" "$t2" 1003 "{\"updatedAt\":\"$t3\"}"
online; assert_eq 0 "$STATUS" "$_CURRENT"
assert_eq 2001 "$(jq -r '.owner_approval.opt_in.id' <<< "$OUTPUT")"
owner_comment "$exact_line" "$t2" 1003 "{\"updatedAt\":\"$t3\"}"
online; assert_eq 0 "$STATUS" "$_CURRENT"
assert_eq 2001 "$(jq -r '.owner_approval.opt_in.id' <<< "$OUTPUT")"

it 'missing or invalid comment timestamps cannot opt in and do not invalidate other comments'
for edit in 'del(.[0].createdAt)' 'del(.[0].updatedAt)' \
    '.[0].createdAt="invalid"' '.[0].updatedAt="invalid"' \
    '.[0] |= (.createdAt="2026-02-30T00:00:00Z" | .updatedAt=.createdAt)'; do
    reset_opt_in "$opt_approved"
    owner_comment "$carry" "$t2"
    jq "$edit" "$comments" > "$comments.next" && mv "$comments.next" "$comments"
    assert_opt_in_exact_required
    assert_contains "$OUTPUT" "$hint"
    owner_comment "$carry" "$t1"
    online; assert_eq 0 "$STATUS" "$edit does not invalidate a separate qualifying comment"
    assert_eq 2002 "$(jq -r '.owner_approval.opt_in.id' <<< "$OUTPUT")"
done

it 'exact-head in a comment has no special effect and a deleted carry no longer counts'
reset_opt_in "$opt_approved"
owner_comment "$exact_line" "$t1"
assert_opt_in_exact_required
owner_comment "$carry"$'\n'"$exact_line" "$t2"
owner_comment "$exact_line" "$t3"
online; assert_eq 0 "$STATUS" "$_CURRENT"
assert_eq 2002 "$(jq -r '.owner_approval.opt_in.id' <<< "$OUTPUT")"
jq 'del(.[1])' "$comments" > "$comments.next" && mv "$comments.next" "$comments"
assert_opt_in_exact_required

it 'a later or tied objection or dismissal revokes carry until a newer eligible comment'
after='2026-01-06T00:00:00Z'
for state in CHANGES_REQUESTED DISMISSED; do
    reset_opt_in "$opt_approved"
    owner_comment "$carry" "$t1"
    fx_owner_review 7 "$state" "$opt_approved" "{\"body\":\"$carry\",\"submittedAt\":\"$t2\"}"
    assert_opt_in_exact_required
    if [ "$state" = CHANGES_REQUESTED ]; then
        assert_eq 1003 "$(jq '.blocking[].reviewer' <<< "$OUTPUT")"
    fi
    fx_owner_review 7 APPROVED "$opt_approved" "{\"submittedAt\":\"$t3\"}"
    assert_opt_in_exact_required
    assert_contains "$OUTPUT" "$hint"
    owner_comment "$carry" "$t2"
    assert_opt_in_exact_required
    owner_comment "$carry" "$after" 1003 '{"updatedAt":"2026-01-07T00:00:00Z"}'
    assert_opt_in_exact_required
    owner_comment "$carry" "$after"
    owner_comment "$carry" "$t1"
    online; assert_eq 0 "$STATUS" 'a new marker and qualifying approval restore carry'
    assert_eq "2004 $after" "$(jq -r '.owner_approval.opt_in | [.id,.at] | join(" ")' <<< "$OUTPUT")"
done

it 'unavailable or incomplete comment pages discard even a valid marker'
reset_opt_in "$opt_approved"
owner_comment "$carry" "$t1"
owner_comment 'A second page.' "$t2"
for fault in graphql:PrdkitOwnerComments graphql:PrdkitOwnerComments:cursor-1; do
    : > "$GH_STUB_DIR/requests"
    GH_STUB_FAIL="$fault" GH_STUB_PAGE_SIZE=1 assert_opt_in_exact_required
    assert_contains "$OUTPUT" 'owner approval opt-in could not be read'
    assert_not_contains "$OUTPUT" "$hint"
    if [[ "$fault" == *cursor-1 ]]; then
        assert_contains "$(cat "$GH_STUB_DIR/requests")" 'endCursor=cursor-1'
    fi
done
query='query PrdkitOwnerComments { fixture }'
route="$GH_STUB_DIR/routes/graphql_PrdkitOwnerComments.json"
GH_STUB_PAGE_SIZE=1 gh api graphql -f query="$query" -F number=7 > "$GH_STUB_DIR/first-comment"
for edit in '.data.repository.pullRequest.comments.pageInfo.hasNextPage=false' \
    '.data.repository.pullRequest.headRefOid="1111111111111111111111111111111111111111"' '.errors=[{"message":"partial"}]'; do
    jq "$edit" "$GH_STUB_DIR/first-comment" > "$route"
    assert_opt_in_exact_required
    assert_contains "$OUTPUT" 'owner approval opt-in could not be read'
done
rm "$route"
fx_owner_review 7 APPROVED "$h"
GH_STUB_FAIL=graphql:PrdkitOwnerComments online
assert_eq 0 "$STATUS" 'comment failure cannot invalidate an exact-head approval'
assert_not_contains "$OUTPUT" '"owner_approval"'
assert_not_contains "$OUTPUT" 'could not be read'

it 'opt-in reuses the merge-aware policy-surface guard'
git update-ref refs/remotes/origin/main "$merged_base"
{ git show "$merged_base:.prdkit/memory/config.md" | sed 's/^- owner-approval: per-pr$/- owner-approval: exact-head-opt-in/'; } |
    trusted_edit refs/remotes/origin/main .prdkit/memory/config.md
git checkout -q --detach "$merged_head"
reset_opt_in "$merge_approved"; owner_comment "$carry" "$t1"
online; assert_eq 0 "$STATUS" "$_CURRENT"
assert_eq "exact-head-opt-in $merge_approved $merged_base" \
    "$(jq -r '.owner_approval|[.mode,.commit,.base]|join(" ")' <<< "$OUTPUT")"
mkdir -p .github/workflows
printf 'name: PR workflow change\n' > .github/workflows/new.yml
git add .github/workflows/new.yml; git commit -qm 'edit review policy'
carry_reviews "$merge_approved"
assert_policy_carry_refused "$h" .github/workflows/new.yml

it 'opt-in does not let an older owner approval clear an objection at T2'
owner_policy '- owner-approval: exact-head-opt-in'
git checkout -q --detach origin/main
mkdir -p specs/changes
printf '# Change\n**Tier**: T2\n## State\n' > specs/changes/001-reviewed.md
git add specs; git commit -qm 'implement T2 change'; t2_old="$(git rev-parse HEAD)"
git commit -q --allow-empty -m 'new exact head'
reset_opt_in "$t2_old"
owner_comment "$carry" "$t1"
fx_owner_review 7 CHANGES_REQUESTED "$t2_old" "{\"submittedAt\":\"$t2\"}"
fx_owner_review 7 APPROVED "$t2_old" "{\"body\":\"$carry\",\"submittedAt\":\"$t3\"}"
: > "$GH_STUB_DIR/requests"
online; assert_eq 1 "$STATUS" "$_CURRENT"
assert_eq 1003 "$(jq '.blocking[].reviewer' <<< "$OUTPUT")"
assert_not_contains "$(cat "$GH_STUB_DIR/requests")" PrdkitOwnerComments
fx_owner_review 7 APPROVED "$h" '{"submittedAt":"2026-01-06T00:00:00Z"}'
online; assert_eq 0 "$STATUS" "exact-head approval still clears the objection: $OUTPUT"

it 'legacy modes ignore comment and review-body markers without a comments request'
git checkout -q --detach "$opt_head"
for mode in exact-head per-pr; do
    owner_policy "- owner-approval: $mode"
    reset_opt_in "$opt_approved"
    : > "$GH_STUB_DIR/requests"
    online; before="$OUTPUT"; before_status="$STATUS"
    requests_before="$(cat "$GH_STUB_DIR/requests")"
    : > "$GH_STUB_DIR/requests"
    if [ "$mode" = per-pr ]; then marker="$exact_line"; else marker="$carry"; fi
    owner_comment "$marker" "$t1"
    body_changed="$(jq --arg body "$marker" 'last.body=$body' "$f")"
    printf '%s\n' "$body_changed" > "$f"
    online
    assert_eq "$before_status" "$STATUS" "$mode exit code is unchanged"
    assert_eq "$before" "$OUTPUT" "$mode JSON is unchanged"
    assert_eq "$requests_before" "$(cat "$GH_STUB_DIR/requests")" "$mode requests are unchanged"
    assert_not_contains "$requests_before" PrdkitOwnerComments
    assert_not_contains "$requests_before" 'body createdAt url'
done
finish
