#!/usr/bin/env bash
# Installed black-box collection, attachment and advisory verification.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project)" || exit 1
track_tmp "$PROJ"
cd "$PROJ" || exit 1
use_gh_stub
export PRDKIT_TODAY=2026-01-02
BIN=.prdkit/scripts/bash
ID=001-facts
CACHE=".prdkit/cache/evidence/$ID/facts"
INDEX="$CACHE/index.json"
SUMMARY="$CACHE/summary.md"
MAP=.prdkit/memory/review-checks.json
mkdir -p specs/changes specs/product src/nested
printf '# Example product\n' > specs/product.md
printf '# Example architecture\n' > specs/architecture.md
printf 'old\n' > src/deleted.txt
snapshot_upgrade_fixture "$PROJ" || exit 1
BASE="$(git rev-parse HEAD)"
git checkout -qb "$ID" || exit 1
cat > "specs/changes/$ID.md" <<'EOF'
# Change: example facts

**Opened**: 2026-01-02 · **Tier**: T1

## State

**Step**: review
**Waiting on**: none
**Next**: review
EOF
printf '# Constraints\n\n- **C-01 Example limit**: Scope: all.\n' > specs/product/constraints.md
printf 'up\n' > src/top.txt
printf 'down\n' > src/nested/deep.txt
git rm -q src/deleted.txt
git add -A && git commit -qm 'create change' || exit 1
HEAD_SHA="$(git rev-parse HEAD)"

it 'installed help names both evidence files and verification'
run bash "$BIN/facts.sh" --help
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '--verify'
assert_contains "$OUTPUT" "build-review-package.sh \"\$id\" \"\$base\" \"\$head\" --evidence"
assert_contains "$OUTPUT" '/facts/index.json'
run bash "$BIN/build-review-package.sh" --help
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '/facts/summary.md'
assert_contains "$OUTPUT" '/facts/index.json'

it 'verify reports an absent pack as drift without creating it'
run bash "$BIN/facts.sh" --verify "$ID"
assert_eq 1 "$STATUS" "$OUTPUT"
assert_contains "$OUTPUT" 'facts drift'
assert_eq absent "$([ ! -e "$CACHE" ] && echo absent)"

it 'one deterministic pack answers the collector questions and limits their scope'
run bash "$BIN/facts.sh" "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_file "$SUMMARY"
assert_file "$INDEX"
assert_contains "$(cat "$SUMMARY")" "Authoritative evidence for base \`$BASE\` and head \`$HEAD_SHA\` only"
assert_contains "$(cat "$SUMMARY")" 'do not rerun the collectors or reread the spec'
assert_contains "$(cat "$SUMMARY")" 'Does not answer design fit, correctness, or spec fit'
assert_contains "$(cat "$SUMMARY")" 'not a gate decision'
assert_contains "$(cat "$SUMMARY")" '[index.json](index.json)'
assert_eq true "$(jq --arg base "$BASE" --arg head "$HEAD_SHA" '
    .key == {base:$base, head:$head, version:3}
    and (.facts.doctor.details.advisories | type == "array")
    and .facts.doctor.command[-1] == "--json"
    and .facts.adoption.details.source_verification == "not-requested"
    and .facts.bounds.exit_status == 0 and (.facts.bounds.details | contains("C-01 Example limit"))
    and .facts.diff_check.exit_status == 0 and .facts.diff_check.result == "clean"
    and .inputs.config == {kind:"absent"} and .facts.path_checks.rules == null
    and .facts.path_checks.paths["src/deleted.txt"] == []
    and .facts.ci.result == "not collected: no --pr supplied" and .facts.ci.exit_status == null
' "$INDEX")"
assert_eq '' "$(cat "$GH_STUB_DIR/requests")" 'no host call without --pr'

saved="$(mktemp -d)"; track_tmp "$saved"
cp "$INDEX" "$SUMMARY" "$saved/"
run bash "$BIN/facts.sh" "$ID" --base "$BASE" --head "$HEAD_SHA"
assert_eq 0 "$STATUS" "$OUTPUT"
if cmp -s "$INDEX" "$saved/index.json" && cmp -s "$SUMMARY" "$saved/summary.md"; then
    _ok 'byte-identical recompute'
else
    _no 'byte-identical recompute'
fi
run bash "$BIN/facts.sh" --verify "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"

it 'an otherwise identical checkout at another path verifies the restored pack'
relocated="$(mktemp -d)"; track_tmp "$relocated"
cp -R "$PROJ/." "$relocated/" || exit 1
run bash "$relocated/$BIN/facts.sh" --verify "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"

it 'both pack files attach byte-for-byte through ordinary package evidence'
run bash "$BIN/build-review-package.sh" "$ID" "$BASE" "$HEAD_SHA" --evidence "$SUMMARY" --evidence "$INDEX"
assert_eq 0 "$STATUS" "$OUTPUT"
pkg="$(jq -r '.PACKAGE_DIR' <<< "$OUTPUT")"
for file in "$SUMMARY" "$INDEX"; do
    run cmp "$file" "$pkg/evidence/$file"
    assert_eq 0 "$STATUS" "attached $file: $OUTPUT"
done

it 'invalid IDs and refs refuse; live worktree and index edits do not affect facts'
for bad in '../001-facts' '111-absent'; do
    run bash "$BIN/facts.sh" "$bad"
    assert_eq 2 "$STATUS"
done
for ref in --base --head; do
    run bash "$BIN/facts.sh" --verify "$ID" "$ref" does-not-exist
    assert_eq 2 "$STATUS"
done
run bash "$BIN/facts.sh" "$ID" --verify --head "$BASE"
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'does not match --head'
printf 'untracked\n' > outside.txt
git add outside.txt
git update-index --assume-unchanged src/top.txt
printf 'dirty\n' >> src/top.txt
run bash "$BIN/facts.sh" --verify "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"
git rm -fq outside.txt
git update-index --no-assume-unchanged src/top.txt
git checkout -- src/top.txt
run bash "$BIN/facts.sh" "$ID" --verify --pr '0'
assert_eq 2 "$STATUS"
run cmp "$INDEX" "$saved/index.json"
assert_eq 0 "$STATUS" 'refusals leave prior index intact'

it 'the head and config inputs change their stamps; overlong bounds spill into the index'
cat > "$MAP" <<'EOF'
{
  "src/*.txt": ["Build", "Surface"],
  "src/**/*.txt": ["Verify", "Queue"],
  "src/nested/d?ep.[t]xt": ["Verify", "Optional"]
}
EOF
awk 'BEGIN { for (n = 2; n <= 85; n++) printf "- **C-%02d Test limit %d**: Scope: all.\n", n, n }' \
    >> specs/product/constraints.md
printf 'trailing \n' >> src/top.txt
git add -A && git commit -qm 'add path map and bounds' || exit 1
NEXT_SHA="$(git rev-parse HEAD)"
run bash "$BIN/facts.sh" --verify "$ID" --base "$BASE"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" '- key:'
assert_contains "$OUTPUT" '+ key:'
assert_contains "$OUTPUT" 'diff_check:'
run bash "$BIN/facts.sh" "$ID" --head "$NEXT_SHA"
assert_eq 0 "$STATUS" "$OUTPUT"
map_hash="$(python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$MAP")"
assert_eq true "$(jq --arg head "$NEXT_SHA" --arg hash "$map_hash" '
    .key.head == $head and .inputs.config.sha256 == $hash
    and .facts.diff_check.exit_status != 0 and (.facts.diff_check.details | contains("trailing whitespace"))
    and (.facts.bounds.details | contains("C-85 Test limit 85"))
    and (.facts.path_checks.paths["src/deleted.txt"] | map(.name)) == ["Build","Queue","Surface","Verify"]
    and (.facts.path_checks.paths["src/top.txt"] | map(.name)) == ["Build","Queue","Surface","Verify"]
    and (.facts.path_checks.paths["src/nested/deep.txt"] | map(.name)) == ["Optional","Queue","Verify"]
    and (.facts.path_checks.paths["src/top.txt"] | all(.state == "not collected" and .status == null))
' "$INDEX")"
assert_eq 60 "$(awk 'END {print NR}' "$SUMMARY")"
assert_contains "$(cat "$SUMMARY")" 'more detail line(s): see [index.json](index.json).'
assert_not_contains "$(cat "$SUMMARY")" 'C-85 Test limit 85'

it 'an ignored root .gitattributes cannot hide committed trailing whitespace'
printf '\n/.gitattributes\n' >> .git/info/exclude
printf 'src/*.txt whitespace=-blank-at-eol\n' > .gitattributes
run git diff --check "$BASE..$NEXT_SHA" --
assert_eq 0 "$STATUS" 'the live attribute rule suppresses the finding'
run bash "$BIN/facts.sh" --verify "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"
rm .gitattributes
printf 'src/*.txt whitespace=-blank-at-eol\n' > .git/info/attributes
run bash "$BIN/facts.sh" --verify "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"
rm .git/info/attributes

it 'a committed root .gitattributes does control the whitespace check'
printf 'src/*.txt whitespace=-blank-at-eol\n' > .gitattributes
git add -f .gitattributes && git commit -qm 'commit whitespace rule' || exit 1
run bash "$BIN/facts.sh" "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq clean "$(jq -r '.facts.diff_check.result' "$INDEX")"
git revert --no-edit HEAD >/dev/null || exit 1

it 'the committed snapshot leaves ignored installation and generated files out'
printf '\n/.product-kit/local-source/\n/.generated/\n' >> .git/info/exclude
mkdir -p .product-kit/local-source
printf 'one\n' > .product-kit/local-source/VERSION
# Put the setting in the config section, not an example or later section.
sed '/^## Configuration/a\
- adoption-source: .product-kit/local-source
' .prdkit/memory/config.md > "$saved/config"
cp "$saved/config" .prdkit/memory/config.md
mkdir -p .generated tests
printf '#!/usr/bin/env bash\n' > .generated/example.sh
ln -s ../.generated/example.sh tests/test-example.sh
printf '\n[Generated](../.generated/example.html)\n' >> specs/product.md
git add .prdkit/memory/config.md specs/product.md tests/test-example.sh &&
    git commit -qm 'add links to generated artifacts' || exit 1
NEXT_SHA="$(git rev-parse HEAD)"
worktrees="$(git worktree list --porcelain)"
run bash "$BIN/facts.sh" "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq "$worktrees" "$(git worktree list --porcelain)"
assert_eq 0 "$(jq -r '.facts.adoption.exit_status' "$INDEX")" 'ignored kit source is absent from the snapshot'
assert_contains "$(jq -r '.facts.doctor.details.advisories[]' "$INDEX")" '.generated/example.html, which does not exist'
assert_contains "$(jq -r '.facts.doctor.details.advisories[]' "$INDEX")" 'test symlink target is absent; citations not checked'

it 'editing the ignored target of a tracked test symlink cannot supply doctor citations'
printf '# Verifies R-99\n' >> .generated/example.sh
run bash "$BIN/doctor.sh" --json
assert_contains "$OUTPUT" 'ID R-99 is cited at tests/test-example.sh'
run bash "$BIN/facts.sh" --verify "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"

it 'an ignored generated link target cannot suppress a committed missing-link advisory'
printf 'generated\n' > .generated/example.html
run bash "$BIN/doctor.sh" --json
assert_not_contains "$OUTPUT" '.generated/example.html, which does not exist'
run bash "$BIN/facts.sh" --verify "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"

it 'doctor date changes are still explicit inputs; ignored adoption source edits are not'
printf 'two\n' > .product-kit/local-source/VERSION
run bash "$BIN/facts.sh" --verify "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"
run env PRDKIT_TODAY=2026-01-03 bash "$BIN/facts.sh" --verify "$ID"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'inputs changed'

it 'no gh records no CI; local collectors do not invoke jq'
local_bin="$saved/no-gh"
mkdir "$local_bin"
while IFS= read -r prog; do
    case "$prog" in gh|jq) continue ;; esac
    path="$(type -P "$prog")" && { [ -e "$local_bin/$prog" ] || ln -s "$path" "$local_bin/$prog"; }
done <<'EOF'
awk
basename
bash
cat
cksum
cmp
cut
date
dirname
find
git
grep
head
mktemp
od
python3
readlink
rm
sed
sha256sum
shasum
sort
tail
tr
uniq
wc
EOF
run env PATH="$local_bin" bash "$BIN/facts.sh" "$ID" --pr 7
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 'not collected: gh not available on PATH' "$(jq -r '.facts.ci.result' "$INDEX")"
assert_eq true "$(jq '.facts.bounds.exit_status == 0 and (.facts.doctor.details | type == "object")
    and (.facts.adoption.details | type == "object")' "$INDEX")" \
    "$(jq -c '.facts | [.bounds,.doctor,.adoption] | map({result,stderr})' "$INDEX")"

it 'R3 is the source of exact-head CI states, including failures, pending and missing checks'
fx_pr 7 "$NEXT_SHA"
routes="$GH_STUB_DIR/routes"
metadata() {
    jq -n --arg head "$1" --arg base "$BASE" '{data:{repository:{nameWithOwner:"owner/repo",
      pullRequest:{number:7,state:"OPEN",isDraft:true,headRefOid:$head,baseRefOid:$base,
                   baseRefName:"main",mergeable:"UNKNOWN",mergeStateStatus:"BLOCKED",
                   baseRef:{name:"main",branchProtectionRule:null}}}}}'
}
metadata "$NEXT_SHA" > "$routes/graphql_PrdkitPRFacts.json"
cat > "$routes/rules_branches_main_per_page_100_page_1.json" <<'EOF'
[{"type":"required_status_checks","parameters":{"required_status_checks":[
 {"context":"Queue"},{"context":"Verify"},{"context":"Unseen"},{"context":"Green"}
]}}]
EOF
jq -n --arg head "$NEXT_SHA" '
    def check($name;$status;$conclusion): {__typename:"CheckRun",id:$name,name:$name,status:$status,
      conclusion:$conclusion,detailsUrl:null,permalink:null,checkSuite:{app:null},isRequired:true};
    {data:{repository:{nameWithOwner:"owner/repo",pullRequest:{number:7,headRefOid:$head,
      baseRefName:"main",commits:{nodes:[{commit:{oid:$head,statusCheckRollup:{contexts:{
        totalCount:3,nodes:[check("Queue";"QUEUED";null),check("Verify";"COMPLETED";"FAILURE"),
                            check("Green";"COMPLETED";"SUCCESS")],
        pageInfo:{hasNextPage:false,endCursor:null}
      }}}}]}}}}}
' > "$routes/graphql_PrdkitCheckFacts.json"
run bash "$BIN/facts.sh" "$ID" --pr 7
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq true "$(jq --arg head "$NEXT_SHA" '
    .facts.ci.exit_status == 0 and .facts.ci.details.head_sha == $head
    and .facts.ci.result == "1/4 required check(s) green"
    and (.facts.ci.details | has("fetched_at") | not)
    and (.facts.ci.details.required_checks[] | select(.name=="Unseen") | .status) == "NOT_STARTED"
    and .facts.path_checks.paths["src/nested/deep.txt"] == [
       {name:"Optional",state:"not reported as required",status:null,conclusion:null},
       {name:"Queue",state:"reported",status:"QUEUED",conclusion:null},
       {name:"Verify",state:"reported",status:"COMPLETED",conclusion:"FAILURE"}]
' "$INDEX")"
assert_contains "$(cat "$SUMMARY")" '1/4 required check(s) green'
cp "$INDEX" "$saved/online.json"
sleep 1
run bash "$BIN/facts.sh" --verify "$ID" --pr 7
assert_eq 0 "$STATUS" "$OUTPUT"

it 'only a byte-exact check name matches the path map and the CI link stays verbatim'
check_name="$(pwd -P)/Build"
check_link="https://ci.example.invalid$(pwd -P)/Build"
rules="$routes/rules_branches_main_per_page_100_page_1.json"
checks="$routes/graphql_PrdkitCheckFacts.json"
cp "$rules" "$saved/rules.json"
cp "$checks" "$saved/pr-checks.json"
jq --arg name "$check_name" '.[0].parameters.required_status_checks = [{context:$name}]' \
    "$saved/rules.json" > "$rules"
jq --arg name "$check_name" --arg link "$check_link" '
    .data.repository.pullRequest.commits.nodes[0].commit.statusCheckRollup.contexts |=
      (.totalCount = 1 | .nodes = [.nodes[2] | .name = $name | .detailsUrl = $link])
' "$saved/pr-checks.json" > "$checks"
run bash "$BIN/facts.sh" "$ID" --pr 7
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq true "$(jq --arg name "$check_name" --arg link "$check_link" '
    .facts.ci.details.required_checks == [{name:$name,status:"COMPLETED",conclusion:"SUCCESS",link:$link}]
    and (.facts.path_checks.paths["src/top.txt"][] | select(.name=="Build")) ==
      {name:"Build",state:"not reported as required",status:null,conclusion:null}
' "$INDEX")"
cp "$saved/rules.json" "$rules"
cp "$saved/pr-checks.json" "$checks"
run bash "$BIN/facts.sh" "$ID" --pr 7
assert_eq 0 "$STATUS" "$OUTPUT"

it 'a PR for another head and a failed pr-state read never report green'
fx_pr 7 "$HEAD_SHA"
metadata "$HEAD_SHA" > "$routes/graphql_PrdkitPRFacts.json"
sed "s/$NEXT_SHA/$HEAD_SHA/g" "$routes/graphql_PrdkitCheckFacts.json" > "$saved/checks.json"
cp "$saved/checks.json" "$routes/graphql_PrdkitCheckFacts.json"
run bash "$BIN/facts.sh" "$ID" --pr 7 --verify
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" '+ ci: not collected:'
assert_contains "$OUTPUT" 'does not match the checkout head'
run cmp "$INDEX" "$saved/online.json"
assert_eq 0 "$STATUS" 'verify did not replace facts'
run env GH_STUB_OFFLINE=true bash "$BIN/facts.sh" "$ID" --pr 7
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq true "$(jq '.facts.ci.exit_status == 2 and .facts.ci.details == null
    and (.facts.ci.result | startswith("not collected: "))' "$INDEX")"

it 'hydrating an unreachable archive proof cannot change facts without changing HEAD history'
proof_repo="$(mktemp -d)"; track_tmp "$proof_repo"
git clone -q --local "$PROJ" "$proof_repo" && git -C "$proof_repo" checkout -q --detach "$BASE" || exit 1
mkdir -p "$proof_repo/.prdkit/history" .prdkit/history
printf '%s\n' '- 2026-01-01 005-closed: Completed.' > "$proof_repo/.prdkit/history/log.md"
git -C "$proof_repo" add .prdkit/history/log.md &&
    git -C "$proof_repo" -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm proof || exit 1
proof="$(git -C "$proof_repo" rev-parse HEAD)"
# shellcheck disable=SC2016 # Markdown code span
printf '**Log condensed through**: none; also 005; those entries: `git show %s:.prdkit/history/log.md`.\nAllocated through: 005\n' \
    "$proof" > .prdkit/history/archive.md
git add .prdkit/history/archive.md && git commit -qm 'declare a sparse archive proof' || exit 1
run git cat-file -t "$proof"
assert_eq 128 "$STATUS" 'proof starts absent'
run bash "$BIN/facts.sh" "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_contains "$(jq -r '.facts.doctor.details.findings[]' "$INDEX")" "cannot resolve sparse snapshot $proof"
cp "$INDEX" "$saved/proof-missing.json"
refs="$(git show-ref)"
local_head="$(git rev-parse HEAD)"
git fetch -q --no-tags --no-write-fetch-head --no-auto-gc "$proof_repo" "$proof" || exit 1
assert_eq "$refs" "$(git show-ref)" 'hydration did not update any refs'
assert_eq "$local_head" "$(git rev-parse HEAD)"
assert_eq commit "$(git cat-file -t "$proof")"
run bash "$BIN/doctor.sh" --json
assert_eq 0 "$STATUS" 'standalone doctor can use the hydrated proof'
run bash "$BIN/facts.sh" --verify "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"
run bash "$BIN/facts.sh" "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"
run cmp "$INDEX" "$saved/proof-missing.json"
assert_eq 0 "$STATUS" 'hydration left facts and stamps unchanged'

it 'an archive proof reachable from HEAD is usable by the facts snapshot'
git merge -q --no-edit --no-ff -s ours "$proof" || exit 1
run bash "$BIN/facts.sh" "$ID"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq pass "$(jq -r '.facts.doctor.details.result' "$INDEX")"

it 'malformed committed maps and nonregular cached artifacts refuse'
printf '{"src/*":["Verify"],"src/*":["Queue"]}\n' > "$MAP"
git add "$MAP" && git commit -qm 'invalid map' || exit 1
run bash "$BIN/facts.sh" "$ID" --verify
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'duplicate JSON key'
git revert --no-edit HEAD >/dev/null || exit 1
mv "$SUMMARY" "$saved/final-summary.md"
ln -s "$saved/final-summary.md" "$SUMMARY"
run bash "$BIN/facts.sh" "$ID"
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'unsafe facts file: summary.md'
assert_symlink "$SUMMARY"
finish
