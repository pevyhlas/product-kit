#!/usr/bin/env bash
# Eligible names and optional remote report consistency are separate from actual independence.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
CHECK="$PROJ/.prdkit/scripts/bash/check-review.sh"
cat > .prdkit/memory/agents.md <<'EOF'
# Capabilities
| Role | Available agent or human | Notes |
|---|---|---|
| Independent review | legacy | eligible exact legacy identity |
| Implementation | legacy-maker | never a reviewer |
## Review registry
| Identity | Role |
|---|---|
| code | reviewer |
| maker | maker |
| dual | reviewer |
| dual | maker |
| duplicate | reviewer |
| duplicate | reviewer |
| unclear | undecided |
<!--
| hidden | reviewer |
-->
```
| fenced | reviewer |
```
EOF
git add -A; git commit -qm 'baseline registry'
BASE="$(git rev-parse HEAD)"
DEFAULT="$(git branch --show-current)"
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$DEFAULT"
git checkout -qb 001-reviewed
printf 'source\n' > source.txt
git add source.txt; git commit -qm implementation
REVIEWED="$(git rev-parse HEAD)"
RECORD=specs/changes/001-reviewed.md
CLEAN='0 critical, 0 high, 0 medium, 0 low'
LINK=https://github.com/fixture/project/pull/7#issuecomment-11
PR=https://github.com/fixture/project/pull/7
record() { # identity [link] [head] [extra review line]
    mkdir -p specs/changes
    printf '# Change: Fixture\n**Tier**: T1\n## State\n**Review**: round 1 · %s..%s · %s · PASS · %s · %s\n%s\n' \
        "$BASE" "${3:-$REVIEWED}" "$1" "$CLEAN" "${2:-$LINK}" "${4:-}" > "$RECORD"
    git add "$RECORD"; git commit -qm 'record review'
}
check() { run bash "$CHECK" --json 001-reviewed; }

it "registered exact identities pass; makers, unknown and ambiguous identities do not"
for identity in code legacy; do
    record "$identity"; check
    assert_eq 0 "$STATUS" "$identity is eligible"
    assert_contains "$OUTPUT" '"report_verification":"not-requested"' 'offline links explicitly unverified'
    assert_contains "$OUTPUT" "\"registry_at\":\"$BASE\"" 'registry provenance pinned'
done
for identity in maker legacy-maker dual duplicate unclear unknown hidden fenced; do
    record "$identity"; check
    assert_eq 1 "$STATUS" "$identity cannot approve the change"
    assert_contains "$OUTPUT" "$RECORD:4: reviewer '$identity'" 'offending line identified'
done
record maker; check
assert_contains "$OUTPUT" 'is maker' 'maker is distinguished from unknown identity'

it "a feature cannot register itself or turn its maker into an eligible reviewer"
printf '\n| invented | reviewer |\n' >> .prdkit/memory/agents.md
sed 's/| maker | maker |/| maker | reviewer |/' .prdkit/memory/agents.md > .git/agents-next
cp .git/agents-next .prdkit/memory/agents.md
git add .prdkit/memory/agents.md; git commit -qm 'self-authorizing policy'
POLICY_HEAD="$(git rev-parse HEAD)"
for identity in invented maker; do
    record "$identity" "$LINK" "$POLICY_HEAD"; check
    assert_eq 1 "$STATUS" 'change-local policy cannot authorize a verdict'
done
git symbolic-ref --delete refs/remotes/origin/HEAD
git update-ref -d "refs/remotes/origin/$DEFAULT"
git branch -f "$DEFAULT" "$POLICY_HEAD"
record invented "$LINK" "$POLICY_HEAD"
check
assert_eq 1 "$STATUS" 'local default cannot authorize its own invented reviewer'
assert_contains "$OUTPUT" 'No trusted integration-baseline registry' 'missing remote-default trust is explicit'
git branch -D "$DEFAULT" >/dev/null
run bash "$CHECK" --json --base "$POLICY_HEAD" 001-reviewed
assert_eq 1 "$STATUS" 'arbitrary --base cannot authorize a registry when no default exists'
assert_contains "$OUTPUT" "reviewer 'invented' is unregistered" 'self-registration still rejected'
git branch "$DEFAULT" "$BASE"
git update-ref "refs/remotes/origin/$DEFAULT" "$BASE"
git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$DEFAULT"
git reset -q --hard "$REVIEWED"

it "ineligible superseded lines cannot contribute coverage or erase standing failures"
record unknown "$LINK" "$REVIEWED" "**Review**: round 2 · $BASE..$REVIEWED · code · PASS · $CLEAN · $LINK"
check
assert_eq 1 "$STATUS" 'latest valid verdict cannot hide a fabricated earlier line'
assert_contains "$OUTPUT" "reviewer 'unknown' is unregistered" 'superseded offending line retained'
record code "$LINK" "$REVIEWED" "**Review**: round 1 · $BASE..$REVIEWED · maker · FAIL · 0 critical, 1 high, 0 medium, 0 low · $LINK"
check
assert_eq 1 "$STATUS" 'maker failure is not silently dropped'
assert_contains "$OUTPUT" 'stands: no later clean PASS' 'standing failure remains visible'

it "offline checking does not invoke GitHub and marks report links unverified"
mkdir -p .git/bin
cat > .git/bin/gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RR_FIXTURE/requests"
[ "${RR_OFFLINE:-false}" != true ] || exit 1
case "$4" in
    repos/fixture/project/pulls/7) cat "$RR_FIXTURE/pr.json" ;;
    repos/fixture/project/issues/comments/11) cat "$RR_FIXTURE/comment.json" ;;
    repos/fixture/project/issues/comments/12) cat "$RR_FIXTURE/owner-comment.json" ;;
    *) exit 1 ;;
esac
EOF
chmod +x .git/bin/gh
export RR_FIXTURE="$PROJ/.git"
export PATH="$PROJ/.git/bin:$PATH"
record code
check
assert_eq 0 "$STATUS" 'ordinary review gate passes offline'
assert_eq no "$([ -f .git/requests ] && echo yes || echo no)" 'no GitHub invocation'
run bash "$CHECK" 001-reviewed
assert_contains "$OUTPUT" 'Report links unverified' 'human output has the same limitation'
mkdir .git/no-network-tools
# Standard utilities only; content fingerprints add mktemp, rm, wc, sort and one SHA-256 tool.
sha_tool=sha256sum; command -v sha256sum >/dev/null 2>&1 || sha_tool=shasum
for cmd in bash dirname git sed awk tr head grep cat mktemp rm wc sort "$sha_tool"; do
    ln -s "$(command -v "$cmd")" ".git/no-network-tools/$cmd"
done
run env PATH="$PROJ/.git/no-network-tools" bash "$CHECK" --json 001-reviewed
assert_eq 0 "$STATUS" 'offline gate works with neither gh nor jq installed'
run env PATH="$PROJ/.git/no-network-tools" bash "$CHECK" --json --verify-reports --pr "$PR" 001-reviewed
assert_eq 1 "$STATUS" 'requested online check fails clearly without optional tools'
assert_contains "$OUTPUT" 'report verification needs gh and jq' 'missing tools explained'
assert_contains "$OUTPUT" '"report_verification":"unavailable"' 'no verified claim without tools'

make_receipt() {
    jq -n --arg base "$BASE" --arg head "$REVIEWED" '{schema:"prdkit.review.v1",reviewer:"code",base:$base,head:$head,verdict:"PASS",critical:0,high:0,medium:0,low:0}'
}
publish_fixture() { # receipt on stdin
    local receipt body
    receipt="$(cat)"
    body="$(printf 'Review report.\n<!-- prdkit-review\n%s\n-->\n' "$receipt")"
    jq -n --arg body "$body" '{issue_url:"https://api.github.com/repos/fixture/project/issues/7",body:$body,user:{login:"shared-bot"}}' > .git/comment.json
    jq -n --arg head "$(git rev-parse HEAD)" '{head:{sha:$head}}' > .git/pr.json
}
online() { run bash "$CHECK" --json --verify-reports --pr "$PR" 001-reviewed; }
it "opt-in verification matches exact PR head, membership and report metadata"
make_receipt | publish_fixture
online
assert_eq 0 "$STATUS" "consistent report passes: $OUTPUT"
assert_contains "$OUTPUT" '"report_verification":"matched"' 'matching metadata status is explicit'
assert_contains "$(cat .git/requests)" 'issues/comments/11' 'linked report was actually queried'
for edit in '.reviewer="maker"' '.base="wrong"' '.head="wrong"' '.verdict="FAIL"' '.high=1'; do
    make_receipt | jq "$edit" | publish_fixture
    online
    assert_eq 1 "$STATUS" "mismatching report rejected: $edit"
    assert_contains "$OUTPUT" "$RECORD:4: report receipt" 'report mismatch names the source line'
done
make_receipt | publish_fixture
jq '.issue_url="https://api.github.com/repos/fixture/project/issues/8"' .git/comment.json > .git/comment-next
mv .git/comment-next .git/comment.json
online
assert_eq 1 "$STATUS" 'a URL fragment cannot lie about actual PR membership'
assert_contains "$OUTPUT" 'does not belong to this PR' 'membership mismatch explained'
make_receipt | publish_fixture
jq '.head.sha="stale"' .git/pr.json > .git/pr-next
mv .git/pr-next .git/pr.json
online
assert_eq 1 "$STATUS" 'different PR head rejected'
assert_contains "$OUTPUT" 'PR head does not match' 'exact-head requirement explained'

it "unavailable reports or malformed/off-PR links never become a verified PASS"
make_receipt | publish_fixture
run env RR_OFFLINE=true bash "$CHECK" --json --verify-reports --pr "$PR" 001-reviewed
assert_eq 1 "$STATUS" 'opt-in verification fails when API access is unavailable'
assert_contains "$OUTPUT" '"report_verification":"unavailable"' 'offline access distinguished from a report mismatch'
for link in not-a-report-link https://github.com/fixture/other/pull/7#issuecomment-11 https://github.com/fixture/project/pull/8#issuecomment-11; do
    record code "$link"
    make_receipt | publish_fixture
    online
    assert_eq 1 "$STATUS" 'malformed or off-PR link rejected'
done
record code
make_receipt | publish_fixture
jq '.body="No receipt"' .git/comment.json > .git/comment-next
mv .git/comment-next .git/comment.json
online
assert_eq 1 "$STATUS" 'plain report without a receipt remains unverified'
{ make_receipt; make_receipt; } | publish_fixture
online
assert_eq 1 "$STATUS" 'multiple receipt objects cannot hide a conflicting assertion'

it "registered historical verdicts need matching reports too when verification is requested"
record code "$LINK" "$REVIEWED" "**Review**: round 2 · $BASE..$REVIEWED · code · PASS · $CLEAN · not-a-report-link"
make_receipt | publish_fixture
online
assert_eq 1 "$STATUS" 'later invalid report cannot reuse earlier matching report'
assert_contains "$OUTPUT" "$RECORD:5: report link" 'later offending line named'
record code not-a-report-link "$REVIEWED" "**Review**: round 2 · $BASE..$REVIEWED · code · PASS · $CLEAN · $LINK"
make_receipt | publish_fixture
online
assert_eq 1 "$STATUS" 'superseded invalid report still needs verification'
assert_contains "$OUTPUT" "$RECORD:4: report link" 'earlier offending line named'
record code

it "a fingerprint line verifies against the v2 receipt record-review.sh printed"
printf '# Change: Fixture\n**Tier**: T1\n## State\n' > "$RECORD"
git add "$RECORD"; git commit -qm 'record without verdicts'
run bash "$PROJ/.prdkit/scripts/bash/record-review.sh" 001-reviewed --reviewer code --verdict PASS --counts 0,0,0,0 --head HEAD --link "$LINK"
assert_eq 0 "$STATUS" "recorded: $OUTPUT"
v2="$(printf '%s\n' "$OUTPUT" | sed -n 3p)"
git commit -qam 'record review'
printf '%s\n' "$v2" | publish_fixture
online
assert_eq 0 "$STATUS" "the printed receipt matches: $OUTPUT"
assert_contains "$OUTPUT" '"report_verification":"matched"' 'matched'
printf '%s\n' "$v2" | jq '.head="provenance only"' | publish_fixture
online
assert_eq 0 "$STATUS" "head is provenance, not compared"
for edit in '.to="start"' '.from="fp1:0000000000000000000000000000000000000000000000000000000000000000"' '.schema="prdkit.review.v1"' '.low=1'; do
    printf '%s\n' "$v2" | jq -c "$edit" | publish_fixture
    online
    assert_eq 1 "$STATUS" "mismatching v2 receipt rejected: $edit"
    assert_contains "$OUTPUT" "$RECORD:5: report receipt" "names the line (after the blank line record-review.sh adds under an empty State): $edit"
done
make_receipt | publish_fixture
online
assert_eq 1 "$STATUS" "a v1 receipt does not verify a fingerprint line"
record code

it "an owner line passes report verification with or without counts; its comment needs an owner receipt"
OWNER_LINK=https://github.com/fixture/project/pull/7#issuecomment-12
owner_record() { # the owner line's fields after its verdict
    mkdir -p specs/changes
    printf '# Change: Fixture\n**Tier**: T3\n## State\n**Review**: round 1 · %s..%s · code · PASS · %s · %s\n**Review**: round 1 · %s..%s · owner · PASS · %s\n' \
        "$BASE" "$REVIEWED" "$CLEAN" "$LINK" "$BASE" "$REVIEWED" "$1" > "$RECORD"
    git add "$RECORD"; git commit -qm 'record owner verdict'
}
owner_receipt() {
    jq -n --arg base "$BASE" --arg head "$REVIEWED" '{schema:"prdkit.review.v1",reviewer:"owner",base:$base,head:$head,verdict:"PASS"}'
}
publish_owner() { # receipt on stdin; empty publishes the owner's words without one
    local receipt body='Approved.'
    receipt="$(cat)"
    [ -z "$receipt" ] || body="$(printf 'Approved.\n<!-- prdkit-review\n%s\n-->\n' "$receipt")"
    jq -n --arg body "$body" '{issue_url:"https://api.github.com/repos/fixture/project/issues/7",body:$body}' > .git/owner-comment.json
}
for fields in "$OWNER_LINK" "$CLEAN · $OWNER_LINK" "0 critical, 1 high · $OWNER_LINK"; do
    owner_record "$fields"
    make_receipt | publish_fixture
    owner_receipt | publish_owner
    : > .git/requests
    check
    assert_eq 0 "$STATUS" "offline gate passes the owner line: $fields"
    online
    assert_eq 0 "$STATUS" "owner line verifies: $fields: $OUTPUT"
    assert_contains "$OUTPUT" '"report_verification":"matched"' "owner report matched: $fields"
    assert_contains "$(cat .git/requests)" 'issues/comments/12' "owner link read from the last field: $fields"
done
owner_record "$CLEAN · $OWNER_LINK"
make_receipt | publish_fixture
printf '' | publish_owner
online
assert_eq 1 "$STATUS" "owner words without a receipt stay unverified"
assert_contains "$OUTPUT" "$RECORD:5: report receipt is absent" "missing owner receipt names the owner line"
for edit in '.reviewer="code"' '.head="wrong"' '.verdict="FAIL"' '.schema="other"'; do
    owner_receipt | jq "$edit" | publish_owner
    online
    assert_eq 1 "$STATUS" "mismatching owner receipt rejected: $edit"
    assert_contains "$OUTPUT" "$RECORD:5: report receipt" "owner receipt mismatch names the owner line: $edit"
done
owner_record "$CLEAN"
make_receipt | publish_fixture
owner_receipt | publish_owner
online
assert_eq 1 "$STATUS" "an owner line without a link fails verification"
assert_contains "$OUTPUT" "$RECORD:5: report link must name an issuecomment" "counts in the link's place are rejected as a link"
record code

it "a missing registry is not a permissive legacy fallback"
git checkout -q "$DEFAULT"
git rm -q .prdkit/memory/agents.md; git commit -qm 'missing policy'
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
git checkout -q 001-reviewed
git merge -q --no-edit "$DEFAULT"
check
assert_eq 1 "$STATUS" 'missing policy denies identities'
assert_contains "$OUTPUT" "reviewer 'code' is unregistered" 'migration gap explained'

finish
