#!/usr/bin/env bash
# A multi-PR change retains earlier PASS records after a squash, without letting those
# records approve later source or treating their earlier-PR reports as current evidence.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
CHECK="$PROJ/.prdkit/scripts/bash/check-review.sh"
RECORD=specs/changes/001-greet.md
CLEAN='0 critical, 0 high, 0 medium, 0 low'
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n| security | reviewer |\n' >> .prdkit/memory/agents.md
sed 's/^- \*\*Rigor\*\*: light/- **Rigor**: full/' .prdkit/memory/constitution.md > .git/constitution-next
cp .git/constitution-next .prdkit/memory/constitution.md
git add -A; git commit -qm installed
DEFAULT="$(git symbolic-ref --short HEAD)"
BASE="$(git rev-parse HEAD)"
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$DEFAULT"
verdict() { # reviewer range [verdict] [counts] [link]
    printf '**Review**: round 1 · %s · %s · %s · %s · %s\n' "$2" "$1" "${3:-PASS}" "${4:-$CLEAN}" \
        "${5:-https://github.com/fixture/project/pull/1#issuecomment-10}"
}
record() { # tier, then review lines
    local tier="$1"; shift
    mkdir -p specs/changes
    { printf '# Change: Greeting\n\n**Tier**: %s\n\n## State\n' "$tier"; printf '%s\n' "$@"; } > "$RECORD"
    git add "$RECORD"; git commit -qm record
}
check() { run bash "$CHECK" --json 001-greet; }

git checkout -qb first-pr
mkdir -p src; echo hello > src/app.txt
git add src; git commit -qm implementation
FIRST="$(git rev-parse HEAD)"
OLD_CODE="$(verdict code "$BASE..$FIRST")"
OLD_SECURITY="$(verdict security "$BASE..$FIRST")"
record T1 "$OLD_CODE" "$OLD_SECURITY"
git checkout -q "$DEFAULT"
git merge --squash first-pr >/dev/null; git commit -qm 'first PR squash'
SQUASH="$(git rev-parse HEAD)"
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
git checkout -qb next-pr
echo warmer > src/app.txt; git commit -qam 'next implementation'
SECOND="$(git rev-parse HEAD)"
LINK=https://github.com/fixture/project/pull/2#issuecomment-20
CURRENT="$(verdict code "$SQUASH..$SECOND" PASS "$CLEAN" "$LINK")"

it "earlier squashed PASS lines can remain alongside a current PR review"
record T1 "$OLD_CODE" "$OLD_SECURITY" "$CURRENT"
check
assert_eq 0 "$STATUS" "new review covers the second PR despite an earlier reviewer with no new round: $OUTPUT"
assert_contains "$OUTPUT" '"historical_reviews":2' 'historical verdicts explicitly distinguished'
assert_not_contains "$OUTPUT" '"reviewer":"security"' 'historical reviewer does not count as current'
run bash "$CHECK" 001-greet
assert_contains "$OUTPUT" '2 inherited non-blocking PASS verdict(s)' 'human output discloses ignored history'
assert_contains "$(cat "$RECORD")" "$OLD_SECURITY" 'original record remains unchanged'

it "current review coverage still invalidates after a source edit"
BEFORE_EDIT="$(git rev-parse HEAD)"
echo unreviewed >> src/app.txt; git commit -qam 'after current review'
check
assert_eq 1 "$STATUS" 'historical records cannot cover a post-review edit'
assert_contains "$OUTPUT" 'changed since the reviewed head' 'current coverage is enforced'
git reset -q --hard "$BEFORE_EDIT"

it "historical PASS records alone cannot cover new work or satisfy the independent-review requirement"
record T1 "$OLD_CODE" "$OLD_SECURITY"
check
assert_eq 1 "$STATUS" 'new code still requires a current independent review'
assert_contains "$OUTPUT" 'needs a recorded independent review' 'historical reviews grant no authority'
record T1 "$OLD_CODE" "$OLD_SECURITY" "$(verdict code "$SECOND..$SECOND" PASS "$CLEAN" "$LINK")"
check
assert_eq 1 "$STATUS" 'an empty new review cannot borrow old coverage'
assert_contains "$OUTPUT" 'is empty' 'empty current range still rejected'

it "editing an inherited line makes it current, not a trusted historical exemption"
record T1 "$OLD_CODE" "${OLD_SECURITY/issuecomment-10/issuecomment-99}" "$CURRENT"
check
assert_eq 1 "$STATUS" 'new or edited off-history verdict must be resolved'
assert_contains "$OUTPUT" "commit $FIRST is not in the history" 'foreign-head diagnostic preserved'

it "an untrusted comparison base cannot authorize historical review exemptions"
record T1 "$OLD_CODE" "$OLD_SECURITY" "$CURRENT"
git symbolic-ref --delete refs/remotes/origin/HEAD
run bash "$CHECK" --json --base "$SQUASH" 001-greet
assert_eq 1 "$STATUS" 'arbitrary base does not replace origin/HEAD trust'
assert_contains "$OUTPUT" 'No trusted integration-baseline registry' 'missing trust remains explicit'
assert_contains "$OUTPUT" '"historical_reviews":0' 'no history exemption without trusted provenance'
git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$DEFAULT"

it "a fresh clone need not retain squashed-away commit objects"
CLONE="$(mktemp -d)"; track_tmp "$CLONE"
git clone -q --no-local --single-branch --branch next-pr "$PROJ" "$CLONE"
git -C "$CLONE" update-ref "refs/remotes/origin/$DEFAULT" "$SQUASH"
git -C "$CLONE" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$DEFAULT"
run git -C "$CLONE" cat-file -e "$FIRST^{commit}"
assert_eq 128 "$STATUS" 'old head is genuinely absent in this clone'
run bash "$CHECK" --repo "$CLONE" --json 001-greet
assert_eq 0 "$STATUS" "squashed record works without the old PR's objects: $OUTPUT"

it "shallow history cannot classify missing heads as squashed away"
SHALLOW="$(mktemp -d)"; track_tmp "$SHALLOW"
depth="$(git rev-list --count "$SQUASH..HEAD")"
git clone -q --depth="$((depth + 1))" --single-branch --branch next-pr "file://$PROJ" "$SHALLOW"
git -C "$SHALLOW" update-ref "refs/remotes/origin/$DEFAULT" "$SQUASH"
git -C "$SHALLOW" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$DEFAULT"
run bash "$CHECK" --repo "$SHALLOW" --json 001-greet
assert_eq 1 "$STATUS" 'shallow history requires a full fetch before using the exemption'
assert_contains "$OUTPUT" '"historical_reviews":0' 'shallow clone does not infer historical status'

it "online verification checks current reports and explicitly excludes historical ones"
mkdir -p .git/bin
: > .git/requests
cat > .git/bin/gh <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$RR_FIXTURE/requests"
case "$4" in
    repos/fixture/project/pulls/2) cat "$RR_FIXTURE/pr.json" ;;
    repos/fixture/project/issues/comments/20) cat "$RR_FIXTURE/comment.json" ;;
    *) exit 1 ;;
esac
EOF
chmod +x .git/bin/gh
export RR_FIXTURE="$PROJ/.git"
export PATH="$PROJ/.git/bin:$PATH"
receipt="$(jq -n --arg base "$SQUASH" --arg head "$SECOND" '{schema:"prdkit.review.v1",reviewer:"code",base:$base,head:$head,verdict:"PASS",critical:0,high:0,medium:0,low:0}')"
body="$(printf 'Review report.\n<!-- prdkit-review\n%s\n-->\n' "$receipt")"
jq -n --arg body "$body" '{issue_url:"https://api.github.com/repos/fixture/project/issues/2",body:$body}' > .git/comment.json
jq -n --arg head "$(git rev-parse HEAD)" '{head:{sha:$head}}' > .git/pr.json
run bash "$CHECK" --json --verify-reports --pr https://github.com/fixture/project/pull/2 001-greet
assert_eq 0 "$STATUS" "only current PR reports need current PR membership: $OUTPUT"
assert_contains "$OUTPUT" '"report_verification":"matched"' 'current report matched'
assert_contains "$OUTPUT" '"historical_reviews":2' 'historical reports not represented as verified'
assert_contains "$(cat .git/requests)" 'issues/comments/20' 'current report fetched'
assert_not_contains "$(cat .git/requests)" 'issues/comments/10' 'earlier PR report not fetched as current evidence'
jq '.body="No receipt"' .git/comment.json > .git/comment-next
mv .git/comment-next .git/comment.json
run bash "$CHECK" --json --verify-reports --pr https://github.com/fixture/project/pull/2 001-greet
assert_eq 1 "$STATUS" 'historical PASS cannot rescue a missing current receipt'
assert_contains "$OUTPUT" 'report receipt is absent' 'current report is still enforced'

it "blocking, malformed and owner verdicts inherited from the baseline are not exempted"
for old in "$(verdict security FAIL..HEAD)" \
    "$(verdict security "$BASE..$FIRST" FAIL '0 critical, 1 high, 0 medium, 0 low')" \
    "$(verdict security "$BASE..$FIRST" PASS '0 critical, 0 high, 1 medium, 0 low')" \
    "$(verdict security "$BASE..$FIRST" PASS 'looks fine')" \
    "**Review**: round 1 · $BASE..$FIRST · owner · PASS · https://github.com/fixture/project/pull/1#issuecomment-10"; do
    git checkout -q "$DEFAULT"
    record T3 "$old"
    git update-ref "refs/remotes/origin/$DEFAULT" HEAD
    start="$(git rev-parse HEAD)"
    git checkout -q -B guarded-pr
    echo guarded >> src/app.txt; git commit -qam 'new code'
    current_head="$(git rev-parse HEAD)"
    record T3 "$old" "$(verdict code "$start..$current_head" PASS "$CLEAN" "$LINK")"
    check
    assert_eq 1 "$STATUS" 'existing blocking/owner/hash checks are not waived'
    assert_contains "$OUTPUT" '"historical_reviews":0' 'only independent non-blocking PASS is historical'
done

finish
