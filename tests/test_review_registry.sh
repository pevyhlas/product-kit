#!/usr/bin/env bash
# Registry eligibility is distinct from host publisher authentication and reviewer independence.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TESTS_DIR/review-fixtures.sh"
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
receipt_policy "$PROJ"
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
LINK=https://example.invalid/report
PR=https://github.com/owner/repo/pull/7
record() { # identity [link] [head] [extra fixture review recipe]
    mkdir -p specs/changes
    printf '# Change: Fixture\n**Tier**: T1\n## State\n**Review**: round 1 · %s..%s · %s · PASS · %s · %s\n%s\n' \
        "$BASE" "${3:-$REVIEWED}" "$1" "$CLEAN" "${2:-$LINK}" "${4:-}" > "$RECORD"
    git add "$RECORD"; git commit -qm 'record review'
}
check() { run bash "$CHECK" --json 001-reviewed; }

it 'registered exact identities pass; makers, unknown and ambiguous identities do not'
for identity in code legacy; do
    record "$identity"; check
    assert_eq 0 "$STATUS" "$identity is eligible"
    assert_contains "$OUTPUT" '"authority":"host"' 'host authority is explicit'
    assert_contains "$OUTPUT" "\"registry_at\":\"$BASE\"" 'registry provenance pinned'
done
for identity in maker legacy-maker dual duplicate unclear unknown hidden fenced; do
    record "$identity"; check
    assert_eq 1 "$STATUS" "$identity cannot approve the change"
    assert_contains "$OUTPUT" "reviewer '$identity'" 'offending receipt identity identified'
done
record maker; check
assert_contains "$OUTPUT" 'is maker' 'maker is distinguished from unknown identity'

it 'a feature cannot register itself or turn its maker into an eligible reviewer'
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
assert_contains "$OUTPUT" 'No trusted integration base' 'self-registration still rejected'
git branch "$DEFAULT" "$BASE"
git update-ref "refs/remotes/origin/$DEFAULT" "$BASE"
git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$DEFAULT"
git reset -q --hard "$REVIEWED"

it 'ineligible superseded receipts cannot contribute coverage or erase standing failures'
record unknown "$LINK" "$REVIEWED" "**Review**: round 2 · $BASE..$REVIEWED · code · PASS · $CLEAN · $LINK"
check
assert_eq 1 "$STATUS" 'latest valid verdict cannot hide a fabricated earlier receipt'
assert_contains "$OUTPUT" "reviewer 'unknown' is unregistered" 'superseded offending receipt retained'
record code "$LINK" "$REVIEWED" "**Receipt fixture**: round 1 · $BASE..$REVIEWED · maker · FAIL · 0 critical, 1 high, 0 medium, 0 low · $LINK"
check
assert_eq 1 "$STATUS" 'maker failure is not silently dropped'
assert_contains "$OUTPUT" 'stands: no later clean PASS' 'standing failure remains visible'

it 'offline snapshots make no host request and work without gh or jq'
record code
run bash "$CHECK" --json --save-receipts .git/receipts 001-reviewed
assert_eq 0 "$STATUS" 'online gate saves a normalized snapshot'
: > "$GH_STUB_DIR/requests"
receipt_raw_run bash "$CHECK" --receipts .git/receipts 001-reviewed
assert_eq 3 "$STATUS" 'ordinary offline gate is a preview, never merge authority'
assert_eq '' "$(cat "$GH_STUB_DIR/requests")" 'no GitHub invocation'
assert_contains "$OUTPUT" PREVIEW 'human output has the same limitation'
mkdir .git/no-network-tools
sha_tool=sha256sum; command -v sha256sum >/dev/null 2>&1 || sha_tool=shasum
for cmd in bash dirname git sed awk tr head tail grep cat mktemp rm mv mkdir wc sort "$sha_tool"; do
    ln -s "$(command -v "$cmd")" ".git/no-network-tools/$cmd"
done
receipt_raw_run env PATH="$PROJ/.git/no-network-tools" bash "$CHECK" --json --receipts .git/receipts 001-reviewed
assert_eq 3 "$STATUS" 'offline gate works with neither gh nor jq installed'
assert_contains "$OUTPUT" '"authority":"snapshot"' 'snapshot provenance is not host authority'
receipt_raw_run env PATH="$PROJ/.git/no-network-tools" bash "$CHECK" --json --pr "$PR" 001-reviewed
assert_eq 1 "$STATUS" 'requested online check fails clearly without optional tools'
assert_contains "$OUTPUT" 'online receipts need gh and jq' 'missing tools explained'
assert_contains "$OUTPUT" '"authority":"unavailable"' 'no verified claim without tools'

it 'a missing registry is not a permissive legacy fallback'
git checkout -q "$DEFAULT"
git rm -q .prdkit/memory/agents.md; git commit -qm 'missing policy'
git update-ref "refs/remotes/origin/$DEFAULT" HEAD
git checkout -q 001-reviewed
git merge -q --no-edit "$DEFAULT"
check
assert_eq 1 "$STATUS" 'missing policy denies identities'
assert_contains "$OUTPUT" "reviewer 'code' is unregistered" 'migration gap explained'
finish
