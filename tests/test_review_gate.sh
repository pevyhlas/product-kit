#!/usr/bin/env bash
# Real gate modes. No recipe bridge: host evidence and record text vary independently here.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
source "$PK_ROOT/scripts/review-fingerprint-lib.sh"
STATUS=0
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
CHECK="$PROJ/.prdkit/scripts/bash/check-review.sh"
CLOSE="$PROJ/.prdkit/scripts/bash/close-change.sh"
cat >> .prdkit/memory/config.md <<'EOF'

## Configuration
- review-host: github
- review-publishers: bot:1001
- review-owner: user:1003
- review-publisher-isolation: required
- review-t0-paths: docs/
EOF
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n| second | reviewer |\n' >> .prdkit/memory/agents.md
mkdir -p specs
printf -- '- 2026-01-02 002-earlier: completed\n' > specs/log.md
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
FP="$(review_fingerprint "$PROJ" 001-reviewed "$BASE" "$HEAD_SHA")"
PR=https://github.com/owner/repo/pull/7
use_gh_stub
fx_pr 7 "$HEAD_SHA"
payload() { # PR [jq edit]
    jq -cn --argjson pr "$1" --arg head "$HEAD_SHA" --arg base "$BASE" --arg fp "$FP" '
        {schema:"prdkit.review.v3",id:"00000000000000000000000000000001",repo:"owner/repo",pr:$pr,
         change:"001-reviewed",reviewer:"code",from:"start",to:$fp,head:$head,since:"",base:"refs/remotes/origin/main",base_at:$base,
         verdict:"PASS",critical:0,high:0,medium:0,low:0,report:"https://example.invalid/report"}' | jq -c "${2:-.}"
}
publish() { local body; body="$(payload "$1" "${2:-.}")"; fx_review "$1" "$(printf '<!-- prdkit-review\n%s\n-->\n' "$body")" "${3:-}"; }
online() { run bash "$CHECK" --json --pr "$PR" "$@" 001-reviewed; }

it 'record PASS text supplies no independent verdict, even online'
printf '**Review**: round 1 · start..%s · code · PASS · 0 critical, 0 high, 0 medium, 0 low · text-only\n' "$FP" >> specs/changes/001-reviewed.md
git commit -qam 'untrusted verdict text'
fx_pr 7 "$(git rev-parse HEAD)"
online
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'needs a recorded independent review'
assert_contains "$OUTPUT" '"receipts":0'
publish 7
online --save-receipts .git/receipts
assert_eq 0 "$STATUS" "$OUTPUT"
assert_contains "$OUTPUT" '"authority":"host"'
assert_contains "$OUTPUT" '"result":"pass"' 'only host authority reports a JSON pass'
assert_contains "$OUTPUT" '"receipt":"https://github.com/owner/repo/pull/7#pullrequestreview-1001"'
assert_not_contains "$OUTPUT" report_verification

it 'a merged predecessor on the same head branch does not make the gate unavailable'
fx_closed_pr 6 "$HEAD_SHA" '{"merged_at":"2026-01-03T00:00:00Z"}'
publish 6 '.verdict="FAIL"'
online
assert_eq 0 "$STATUS" "$OUTPUT"
assert_contains "$OUTPUT" '"authority":"host"'
assert_contains "$OUTPUT" '"carried_blockers":0'
rm "$GH_STUB_DIR/pulls/6.json" "$GH_STUB_DIR/reviews/6.json"

it 'an invalid authenticated receipt remains host evidence and blocks'
publish 7 '.id="00000000000000000000000000000002"|.to="fp1:0000000000000000000000000000000000000000000000000000000000000000"'
online
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" '"authority":"host"'
assert_contains "$OUTPUT" '"invalid_receipts":1'
jq '.[0:1]' "$GH_STUB_DIR/reviews/7.json" > "$GH_STUB_DIR/keep.json"
mv "$GH_STUB_DIR/keep.json" "$GH_STUB_DIR/reviews/7.json"

it 'snapshots are jq-free preview passes, never host authority'
: > "$GH_STUB_DIR/requests"
run bash "$CHECK" --json --receipts .git/receipts 001-reviewed
assert_eq 3 "$STATUS" "$OUTPUT"
assert_contains "$OUTPUT" '"authority":"snapshot"'
assert_contains "$OUTPUT" '"result":"preview"' 'a successful snapshot is not a JSON pass'
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

run bash "$CHECK" --receipts .git/receipts 001-reviewed
assert_contains "$OUTPUT" PREVIEW
assert_contains "$OUTPUT" fetched=
run bash "$CHECK" --json 001-reviewed
assert_eq 1 "$STATUS" 'no source grants no coverage'
assert_contains "$OUTPUT" '"authority":"none"'
assert_contains "$OUTPUT" '"result":"preview"' 'even a failing structure-only check is a preview'
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"

it 'offline gate modes use only standard tools; either missing online tool fails unavailable'
TOOLS="$(mktemp -d)"; track_tmp "$TOOLS"
sha_tool=sha256sum; command -v sha256sum >/dev/null 2>&1 || sha_tool=shasum
for cmd in bash dirname basename git sed awk tr head tail grep cat mktemp rm mv mkdir wc sort "$sha_tool"; do
    ln -s "$(command -v "$cmd")" "$TOOLS/$cmd"
done
: > "$GH_STUB_DIR/requests"
run env PATH="$TOOLS" bash "$CHECK" --json --receipts .git/receipts 001-reviewed
assert_eq 3 "$STATUS" "$OUTPUT"
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
run env PATH="$TOOLS" bash "$CHECK" --json 001-reviewed
assert_eq 1 "$STATUS" 'structure-only mode cannot invent missing coverage'
assert_contains "$OUTPUT" '"authority":"none"'
assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
for missing in gh jq; do
    if [ "$missing" = gh ]; then ln -s "$(command -v jq)" "$TOOLS/jq"
    else rm -f "$TOOLS/jq"; ln -s "$GH_STUB_DIR/bin/gh" "$TOOLS/gh"; fi
    run env PATH="$TOOLS" bash "$CHECK" --json --pr "$PR" 001-reviewed
    assert_eq 1 "$STATUS" "missing $missing cannot pass"
    assert_contains "$OUTPUT" '"authority":"unavailable"'
    assert_contains "$OUTPUT" '"result":"preview"' 'unavailable is never a JSON pass or fail verdict'
    assert_eq '' "$(cat "$GH_STUB_DIR/requests")"
done

it 'contradictory source modes are usage errors'
run bash "$CHECK" --pr "$PR" --receipts .git/receipts 001-reviewed
assert_eq 2 "$STATUS"
run bash "$CHECK" --save-receipts .git/receipts 001-reviewed
assert_eq 2 "$STATUS"

it 'missing tools, offline and partial API responses are unavailable, not empty lists'
for setting in GH_STUB_OFFLINE=true GH_STUB_PARTIAL=pulls/7; do
    run env "$setting" bash "$CHECK" --json --pr "$PR" 001-reviewed
    assert_eq 1 "$STATUS"
    assert_contains "$OUTPUT" '"authority":"unavailable"'
done
run env 'GH_STUB_FAIL=pulls?state=closed&head=owner%3Afeature' bash "$CHECK" --json --pr "$PR" 001-reviewed
assert_eq 1 "$STATUS" 'a failed closed-source listing is not an empty successful list'
assert_contains "$OUTPUT" '"authority":"unavailable"'
assert_contains "$OUTPUT" 'could not enumerate closed source PRs completely'
printf 'previous snapshot\n' > .git/unavailable-snapshot
run env GH_STUB_OFFLINE=true bash "$CHECK" --json --pr "$PR" --save-receipts .git/unavailable-snapshot 001-reviewed
assert_eq 1 "$STATUS"
assert_eq 'previous snapshot' "$(cat .git/unavailable-snapshot)" 'an unavailable read never replaces a snapshot with less evidence'

it 'shared policy is surfaced in JSON and warns in human output'
git show "$BASE:.prdkit/memory/config.md" | sed 's/isolation: required/isolation: shared/' |
    trusted_edit refs/remotes/origin/main .prdkit/memory/config.md
fx_pr 7 "$(git rev-parse HEAD)" '{"user":{"id":1001},"author":{"databaseId":1001,"__typename":"Bot","login":"publisher[bot]"}}'
online
assert_eq 0 "$STATUS" "$OUTPUT"
assert_contains "$OUTPUT" '"publisher_isolation":"shared"'
run bash "$CHECK" --pr "$PR" 001-reviewed
assert_contains "$OUTPUT" "not the reviewer's independence"
run bash "$CHECK" --receipts .git/receipts 001-reviewed
assert_eq 3 "$STATUS"
assert_contains "$OUTPUT" 'Publisher isolation is shared'
git update-ref refs/remotes/origin/main "$BASE"

it 'PR base and head are checked; an unpushed record-only closing commit is permitted'
fx_pr 7 "$(git rev-parse HEAD)" '{"base":{"ref":"other"}}'
online
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'the PR merges into other, not --base main'
fx_pr 7 "$(git rev-parse HEAD)"
PR_HEAD="$(git rev-parse HEAD)"

it 'online --head must descend from the PR head, not merely carry equal content'
TWIN="$(printf 'equal-content sibling\n' | git commit-tree "$(git rev-parse "$PR_HEAD^{tree}")" -p "$BASE")"
for unrelated in "$TWIN" "$HEAD_SHA"; do
    assert_eq "$FP" "$(review_fingerprint "$PROJ" 001-reviewed "$BASE" "$unrelated")" 'fixture has identical reviewed content'
    online --head "$unrelated"
    assert_eq 1 "$STATUS" 'equal content cannot replace PR history'
    assert_contains "$OUTPUT" '"authority":"unavailable"'
    assert_contains "$OUTPUT" '"result":"preview"'
    assert_contains "$OUTPUT" 'is not a local ancestor of --head'
done

it 'an unavailable PR-head object produces clean preview JSON and a fetch remedy'
fx_pr 7 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
online
assert_eq 1 "$STATUS"
assert_eq preview "$(printf '%s' "$OUTPUT" | jq -r .result)" 'Git diagnostics do not corrupt the JSON channel'
assert_contains "$OUTPUT" '"authority":"unavailable"'
assert_contains "$OUTPUT" 'fetch the PR head'
fx_pr 7 "$PR_HEAD"

it 'a descendant with unpublished code still fails content binding'
printf 'unreviewed\n' >> source.txt; git commit -qam 'unpublished code'
online
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'PR head does not match the content'
git reset -q --hard "$PR_HEAD"
run bash "$CLOSE" 001-reviewed 'done'
assert_eq 2 "$STATUS" 'closing without --pr is a usage error'
before="$(git rev-parse HEAD)"
run bash "$CLOSE" --pr "$PR" 001-reviewed 'done'
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq "$before" "$(git rev-parse HEAD^)" 'one local closing commit'
online
assert_eq 0 "$STATUS" "$OUTPUT"
assert_contains "$OUTPUT" '"head_is_pr_head":false'
assert_contains "$OUTPUT" "\"pr_head\":\"$PR_HEAD\""

it 'a legacy shared-log close preserves only its own new line as metadata'
git checkout -qb shared-log-close "$PR_HEAD"
printf -- '- 2026-01-03 001-reviewed: closed\n' >> specs/log.md
git commit -qam 'write the shared log while the record is still open'
run bash "$CHECK" --json --pr "$PR" 001-reviewed
assert_eq 1 "$STATUS" 'an open record cannot exempt even its own log line'
assert_contains "$OUTPUT" 'PR head does not match the content'
git rm -q specs/changes/001-reviewed.md; git commit -qm 'close the selected change'
SHARED_CLOSE="$(git rev-parse HEAD)"
online
assert_eq 0 "$STATUS" "a valid shared-log close keeps the old receipt: $OUTPUT"
assert_eq "$FP" "$(printf '%s' "$OUTPUT" | jq -r .fingerprint)" 'the close alone leaves the fingerprint unchanged'
git update-ref refs/remotes/origin/main "$PR_HEAD"
online
assert_eq 0 "$STATUS" 'a clean bridge close after the implementation merged needs no new receipt'
assert_contains "$OUTPUT" '"record_only":true'
git update-ref refs/remotes/origin/main "$BASE"
sed 's/: closed$/: deferred/' specs/log.md > .git/revised-log
cp .git/revised-log specs/log.md; git commit -qam 'revise the closing disposition'
assert_changed_fingerprint() {
    run review_fingerprint "$PROJ" 001-reviewed "$BASE" HEAD
    assert_eq 0 "$STATUS" "$1: fingerprint computation succeeded"
    if review_is_fp "$OUTPUT"; then _ok "$1: valid fingerprint"; else _no "$1: expected a fingerprint"; fi
    assert_not_contains "$OUTPUT" "$FP" "$1"
}
assert_changed_fingerprint 'H2: a revised disposition is reviewed content'
git checkout -q "$PR_HEAD"
git rm -q specs/changes/001-reviewed.md
printf -- '- 2026-01-03 001-reviewed: closed\rannotation\n' >> specs/log.md
git commit -qam 'close with a multiline description'
assert_changed_fingerprint 'M1: embedded CR is not one-line closing metadata'
git checkout -q "$PR_HEAD"
git rm -q specs/changes/001-reviewed.md
printf -- '- 2026-01-03 001-reviewed: closed\r\n' >> specs/log.md
git commit -qam 'close with CRLF'
assert_eq "$FP" "$(review_fingerprint "$PROJ" 001-reviewed "$BASE" HEAD)" 'a CRLF-terminated close is still one line'
git checkout -q "$SHARED_CLOSE"
printf -- '- 2026-01-03 001-reviewed: closed\n' > specs/log.md
git commit -qam 'drop another change from the shared log'
online
assert_eq 1 "$STATUS" 'dropping another close breaks the unpushed close bridge'
assert_contains "$OUTPUT" 'PR head does not match the content'
assert_not_contains "$OUTPUT" "\"fingerprint\":\"$FP\"" 'the shared-log loss changes the fingerprint'
fx_pr 7 "$(git rev-parse HEAD)"
online
assert_eq 1 "$STATUS" 'publishing the bad merge resolution does not restore receipt coverage'
assert_contains "$OUTPUT" 'reviewed content differs at: specs/log.md'
BAD_HEAD="$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/main "$PR_HEAD"
online
assert_eq 1 "$STATUS" 'a bridge after the implementation merged still needs review for the shared-log loss'
assert_contains "$OUTPUT" '"record_only":false'
git update-ref refs/remotes/origin/main "$BASE"

it 'old receipts keep their posted fingerprints but do not grandfather shared-log edits'
OLD_FP="$(review_legacy_log_fingerprint "$PROJ" 001-reviewed "$BASE" "$BAD_HEAD")"
NEW_FP="$(review_fingerprint "$PROJ" 001-reviewed "$BASE" "$BAD_HEAD")"
assert_eq "$FP" "$(review_legacy_log_fingerprint "$PROJ" 001-reviewed "$BASE" "$PR_HEAD")" 'unchanged log is compatible at the reviewed head'
assert_not_contains "$OLD_FP" "$NEW_FP" 'legacy and corrected provenance differ at the edited head'
cp "$GH_STUB_DIR/reviews/7.json" "$GH_STUB_DIR/reviews-original.json"
printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
publish 7 ".head=\"$BAD_HEAD\"|.to=\"$OLD_FP\""
git checkout "$SHARED_CLOSE" -- specs/log.md; git commit -qm 'restore earlier log state'
fx_pr 7 "$(git rev-parse HEAD)"
online
assert_eq 1 "$STATUS" 'H1: legacy-only provenance supplies no positive coverage'
git checkout -q "$BAD_HEAD"; fx_pr 7 "$BAD_HEAD"
publish 7 ".id=\"00000000000000000000000000000003\"|.head=\"$BAD_HEAD\"|.to=\"$OLD_FP\"|.verdict=\"FAIL\""
online
assert_eq 1 "$STATUS" 'a pre-upgrade FAIL still blocks'
assert_contains "$OUTPUT" '"invalid_receipts":0' 'old matching provenance is recognized'
assert_contains "$OUTPUT" 'blocking verdict stands'
publish 7 ".id=\"00000000000000000000000000000005\"|.head=\"$BAD_HEAD\"|.to=\"$OLD_FP\""
online
assert_contains "$OUTPUT" 'blocking verdict stands' 'H1: a legacy-only PASS does not clear a blocker'
publish 7 ".id=\"00000000000000000000000000000004\"|.head=\"$BAD_HEAD\"|.to=\"$NEW_FP\""
online
assert_eq 0 "$STATUS" "a new full PASS reviews the log and clears the old blocker: $OUTPUT"
mv "$GH_STUB_DIR/reviews-original.json" "$GH_STUB_DIR/reviews/7.json"

it 'a fresh checkout without the superseded reviewed head cannot use its legacy token'
fresh="$(mktemp -d)"; track_tmp "$fresh"; git -C "$fresh" init -q
git -C "$fresh" fetch -q --no-tags "$PROJ" "$PR_HEAD"
git -C "$fresh" checkout -q --detach FETCH_HEAD
git -C "$fresh" update-ref refs/remotes/origin/main "$BASE"
git -C "$fresh" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
run git -C "$fresh" cat-file -e "$BAD_HEAD^{commit}"
if [ "$STATUS" != 0 ]; then _ok 'superseded object is absent'; else _no 'superseded object unexpectedly present'; fi
cp "$GH_STUB_DIR/reviews/7.json" "$GH_STUB_DIR/saved-reviews.json"
printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
fx_pr 7 "$PR_HEAD"
publish 7 ".head=\"$BAD_HEAD\"|.to=\"$OLD_FP\""
online --repo "$fresh"
assert_eq 1 "$STATUS" 'unverified receipt cannot cover the current head in a fresh checkout'
publish 7 '.id="00000000000000000000000000000006"'
online --repo "$fresh"
assert_eq 0 "$STATUS" 'corrected full PASS restores coverage without the superseded object'

it 'every reviewer needs usable latest provenance'
git checkout -q "$PR_HEAD"
for prior in absent present; do
    printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
    publish 7 '.reviewer="second"'
    if [ "$prior" = present ]; then publish 7 '.id="00000000000000000000000000000006"'; fi
    publish 7 ".id=\"00000000000000000000000000000007\"|.head=\"$BAD_HEAD\"|.to=\"$OLD_FP\""
    online --diagnostics
    assert_eq 1 "$STATUS" "another reviewer cannot cover a legacy-only latest PASS (earlier PASS $prior)"
    assert_eq false "$(printf '%s' "$OUTPUT" | jq -r '.diagnostics.latest[]|select(.reviewer=="code")|.end_covered')" 'latest unusable review stays visible'
    assert_contains "$OUTPUT" 'corrected full PASS'
done
publish 7 ".id=\"00000000000000000000000000000008\"|.since=\"$BAD_HEAD\"|.from=\"$NEW_FP\""
online
assert_eq 1 "$STATUS" 'a corrected narrow PASS cannot repair an unusable latest range'
publish 7 '.id="00000000000000000000000000000009"'
online
assert_eq 0 "$STATUS" 'both reviewers now have usable latest verdicts'
mv "$GH_STUB_DIR/saved-reviews.json" "$GH_STUB_DIR/reviews/7.json"

it 'compaction is not closing metadata'
git checkout -q "$SHARED_CLOSE"
printf -- '- 2026-01-04 compaction: retain current entries\n' >> specs/log.md
git commit -qam 'compact the shared log'
fx_pr 7 "$PR_HEAD"
online
assert_eq 1 "$STATUS" 'compaction also changes the reviewed fingerprint'
assert_contains "$OUTPUT" 'PR head does not match the content'
git checkout -q 001-reviewed

it 'record-only and T0 exempt coverage, never blocker enumeration'
git update-ref refs/remotes/origin/main "$before"
printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
online
assert_eq 0 "$STATUS" "$OUTPUT"
assert_contains "$OUTPUT" '"record_only":true'
run bash "$CHECK" --json 001-reviewed
assert_eq 3 "$STATUS"
fx_closed_pr 6 "$HEAD_SHA"
publish 6 '.verdict="FAIL"'
online
assert_eq 1 "$STATUS" 'record-only carried FAIL still blocks'
assert_contains "$OUTPUT" '"carried_blockers":1'
git update-ref refs/remotes/origin/main "$BASE"
git checkout -qb 002-docs "$BASE"
mkdir -p specs/changes docs
printf '# Docs\n**Tier**: T0\n## State\n' > specs/changes/002-docs.md
printf 'documentation\n' > docs/guide.md
git add -A; git commit -qm docs
use_gh_stub; fx_pr 7 "$(git rev-parse HEAD)"
run bash "$CHECK" --json 002-docs
assert_eq 3 "$STATUS" 'T0 without a source is only a preview'
run bash "$CHECK" --json --pr "$PR" 002-docs
assert_eq 0 "$STATUS" "$OUTPUT"
publish 7 '.change="002-docs"|.verdict="FAIL"|.to="none"|.head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
run bash "$CHECK" --json --pr "$PR" 002-docs
assert_eq 1 "$STATUS" 'T0 FAIL blocks online'
assert_contains "$OUTPUT" 'blocking verdict stands'

it "a renamed carrier cannot drop another identity's FAIL, and foreign PASS never covers"
git checkout -qb 003-original "$BASE"
mkdir -p specs/changes
printf '# Original\n**Tier**: T1\n## State\n' > specs/changes/003-original.md
printf implementation > source.txt; git add -A; git commit -qm original
use_gh_stub; fx_pr 7 "$(git rev-parse HEAD)"
PUB="$PROJ/.prdkit/scripts/bash/publish-review.sh"
run bash "$PUB" 003-original --pr "$PR" --reviewer code --verdict FAIL --counts 0,0,0,0 --report https://example.invalid/report --head HEAD
assert_eq 0 "$STATUS" "$OUTPUT"
git rm -q specs/changes/003-original.md
mkdir -p specs/changes
printf '# Carrier\n**Tier**: T1\n## State\n' > specs/changes/004-carrier.md
mkdir -p specs/log; printf -- '- 2026-01-01 003-original: moved to carrier\n' > specs/log/003-original.md
git add -A; git commit -qm carrier
fx_pr 7 "$(git rev-parse HEAD)"
printf '| security | reviewer |\n' >> .git/registry-fragment
{ git show "$BASE:.prdkit/memory/agents.md"; cat .git/registry-fragment; } |
    trusted_edit refs/remotes/origin/main .prdkit/memory/agents.md
run bash "$PUB" 004-carrier --pr "$PR" --reviewer security --verdict PASS --counts 0,0,0,0 --report https://example.invalid/report --head HEAD
assert_eq 0 "$STATUS" "$OUTPUT"
run bash "$CHECK" --json --pr "$PR" 004-carrier
assert_eq 1 "$STATUS" 'another reviewer covers the carrier but cannot clear the original FAIL'
assert_contains "$OUTPUT" 'code 003-original blocking verdict stands'
run bash "$PUB" 004-carrier --pr "$PR" --reviewer code --verdict PASS --counts 0,0,0,0 --report https://example.invalid/report --head HEAD
assert_eq 0 "$STATUS" "$OUTPUT"
run bash "$CHECK" --json --pr "$PR" 004-carrier
assert_eq 0 "$STATUS" "$OUTPUT"
printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
run bash "$PUB" 003-original --pr "$PR" --reviewer code --verdict PASS --counts 0,0,0,0 --report https://example.invalid/report --head HEAD
assert_eq 0 "$STATUS" "$OUTPUT"
run bash "$CHECK" --json --pr "$PR" 004-carrier
assert_eq 1 "$STATUS" 'foreign PASS supplies no carrier coverage'
assert_contains "$OUTPUT" 'needs a recorded independent review'

# Restore the T0 closing fixture for its independent preview-exit test.
git checkout -q 002-docs
use_gh_stub; fx_pr 7 "$(git rev-parse HEAD)"

it 'close-change refuses a preview from its gate without changing source'
# Deliberately replace the gate only in this disposable project to inject its exit contract.
printf '#!/usr/bin/env bash\nprintf "PREVIEW\\n"\nexit 3\n' > "$CHECK"
before="$(git rev-parse HEAD)"
run bash "$CLOSE" --pr "$PR" 002-docs 'done'
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'publish the remaining verdicts first'
assert_eq "$before" "$(git rev-parse HEAD)"
assert_file specs/changes/002-docs.md
finish
