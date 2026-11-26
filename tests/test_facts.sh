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
assert_contains "$OUTPUT" "build-review-package.sh \"\$id\" \"\$base\" \"\$head\" --facts"
assert_contains "$OUTPUT" 'evidence/facts/{summary.md,index.json}'
run bash "$BIN/build-review-package.sh" --help
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" 'evidence/facts/{summary.md,index.json}'

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
    .key == {base:$base, head:$head, version:5}
    and (.facts.doctor.details.advisories | type == "array")
    and .facts.doctor.command[-1] == "--json"
    and .facts.adoption.details.source_verification == "not-requested"
    and .facts.bounds.exit_status == 0 and (.facts.bounds.details | contains("C-01 Example limit"))
    and .facts.bounds.state == "collected" and .facts.bounds.scope_revision == $head
    and (.inputs.installed_bounds_tools_sha256["review-bounds-lib.sh"] | length == 64)
    and .facts.diff_check.exit_status == 0 and .facts.diff_check.result == "clean"
    and .inputs.config == {kind:"absent"} and .facts.path_checks.rules == null
    and .facts.path_checks.paths["src/deleted.txt"] == []
    and .facts.ci.result == "not collected: no --pr supplied" and .facts.ci.exit_status == null
    and ([.facts[] | select(has("command"))] | length == 6 and all(.audience == "maintainer-rerun-only"))
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

it 'the round attaches the bound facts pair at shallow, relative paths'
run bash "$BIN/build-review-package.sh" "$ID" "$BASE" "$HEAD_SHA" --facts
assert_eq 0 "$STATUS" "$OUTPUT"
pkg="$(jq -r '.PACKAGE_DIR' <<< "$OUTPUT")"; paired="$pkg/evidence/facts"
for file in "$SUMMARY" "$INDEX"; do
    run cmp "$file" "$paired/${file##*/}"
    assert_eq 0 "$STATUS" "attached $file: $OUTPUT"
    assert_eq absent "$([ -e "$pkg/evidence/$file" ] || echo absent)" "no nested duplicate for $file"
done
if [ -f "$paired/index.json" ] && [ -f "$paired/summary.md" ]; then
    assert_eq true "$(jq --arg id "$ID" --arg base "$BASE" --arg head "$HEAD_SHA" '
        .change_id == $id and .key.base == $base and .key.head == $head
    ' "$paired/index.json")" "copied pair binds the exact change and range"
    copied_hash="$(python3 -I -B -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$paired/index.json")"
    assert_contains "$(cat "$paired/summary.md")" "SHA-256 \`$copied_hash\`" "summary binds raw copied index bytes"
fi

it 'invalid IDs and refs refuse; live worktree and index edits do not affect facts'
run bash "$BIN/facts.sh" '../001-facts'
assert_eq 2 "$STATUS"
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
mkdir
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
run bash "$BIN/build-review-package.sh" "$ID" "$BASE" "$NEXT_SHA" --facts
assert_eq 0 "$STATUS" "$OUTPUT"
pkg="$(jq -r .PACKAGE_DIR <<<"$OUTPUT")"
assert_contains "$(cat "$pkg/index.md")" 'Exact-head CI: see the facts summary'
assert_not_contains "$(cat "$pkg/index.md")" 'not collected'
assert_not_contains "$(cat "$pkg/context-gaps.txt")" 'CI'
assert_contains "$(cat "$pkg/evidence/facts/summary.md")" '1/4 required check(s) green'
assert_contains "$(cat "$pkg/evidence/facts/summary.md")" 'Verify: FAILURE'
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
assert_eq 1 "$(grep -Fc 'not collected' "$SUMMARY")" 'missing CI is stated once, not repeated per path or diagnostic'
assert_not_contains "$(cat "$SUMMARY")" 'check(s) green'

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

it 'the sealed pack uses deltas without importing any unrelated objects from the source pack'
run python3 -I -B - "$BIN/facts.py" <<'PY'
import importlib.util
from pathlib import Path
from random import Random
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory


def pack_bytes(objects):
    return sum(path.stat().st_size for path in (objects / "pack").glob("*.pack"))


with TemporaryDirectory(prefix="facts-pack-") as scratch:
    work = Path(scratch)
    repo = work / "repo"
    scripts = repo / ".prdkit/scripts/bash"
    scripts.mkdir(parents=True)
    script = scripts / "facts.py"
    shutil.copyfile(sys.argv[1], script)

    def git(*args, **kwargs):
        return subprocess.check_output(["git", "-C", str(repo), *args], **kwargs)

    git("init", "--quiet")
    git("config", "user.name", "Fixture")
    git("config", "user.email", "fixture@example.invalid")
    asset = repo / "asset.bin"
    asset.write_bytes(Random(5).randbytes(1024 * 1024))
    git("add", ".")
    git("commit", "--quiet", "-m", "add binary")
    base = git("rev-parse", "HEAD").decode().strip()
    for n in range(1, 16):
        with asset.open("r+b") as stream:
            stream.seek(n)
            changed_byte = stream.read(1)[0] ^ 1
            stream.seek(n)
            stream.write(bytes([changed_byte]))
        git("commit", "--quiet", "-am", f"revise binary {n}")
    head = git("rev-parse", "HEAD").decode().strip()
    unrelated = git("hash-object", "-w", "--stdin", input=b"reachable only through an unrelated tag\n").strip()
    git("tag", "unrelated", unrelated.decode())
    git("repack", "-ad", "--quiet")
    source_objects = repo / ".git/objects"
    assert not (source_objects / unrelated[:2].decode() / unrelated[2:].decode()).exists()
    assert git("cat-file", "-t", unrelated.decode()).strip() == b"blob"

    spec = importlib.util.spec_from_file_location("facts", script)
    facts = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(facts)
    directory = work / "snapshot"
    directory.mkdir()
    snapshot = facts.Snapshot(facts.Collector(), directory, base, head)
    objects = snapshot.root / ".git/objects"
    assert not (objects / "info/alternates").exists(), "snapshot still has a live alternate"
    expected = set(git("rev-list", "--objects", "--no-object-names", head).splitlines())
    actual = set(snapshot.git("cat-file", "--batch-all-objects", "--batch-check=%(objectname)").splitlines())
    assert actual == expected and unrelated not in actual, (actual - expected, expected - actual)

    source_size, sealed_size = pack_bytes(source_objects), pack_bytes(objects)
    print(f"Source pack: {source_size} bytes; sealed pack: {sealed_size} bytes; {len(actual)} exact objects")
    assert 0 < sealed_size <= 3 * source_size, "sealed history lost binary delta compression"
PY
assert_eq 0 "$STATUS" "$OUTPUT"
assert_contains "$OUTPUT" 'exact objects'

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
it 'A record-only specs tree has no spec bounds in either the snapshot or the package'
P="$(make_inited_project)" || exit 1
track_tmp "$P"; cd "$P" || exit 1
ID=001-record-only
CACHE=".prdkit/cache/evidence/$ID/facts"
mkdir -p specs/changes
printf '# Change\n\n**Tier**: T1\n' > "specs/changes/$ID.md"
printf 'before\n' > label.txt
snapshot_upgrade_fixture "$P" || exit 1
BASE="$(git rev-parse HEAD)"
printf 'after\n' > label.txt
git commit -qam 'edit label without spec inputs' || exit 1
run bash "$BIN/facts.sh" "$ID" --base "$BASE"
assert_eq 0 "$STATUS" "$OUTPUT"
empty_bounds='No spec bounds apply at this revision.'
assert_eq true "$(jq --arg notice "$empty_bounds" '
    .facts.bounds | .state == "absent" and .exit_status == 0 and .result == $notice and .details == $notice
' "$CACHE/index.json")"
run bash "$BIN/build-review-package.sh" "$ID" "$BASE" --facts
assert_eq 0 "$STATUS" "$OUTPUT"
pkg="$(jq -r .PACKAGE_DIR <<<"$OUTPUT")"
assert_eq "$empty_bounds" "$(cat "$pkg/bounds.txt")"
assert_eq 1 "$(grep -Fc "$empty_bounds" "$pkg/evidence/facts/summary.md")"
assert_not_contains "$(cat "$pkg/evidence/facts/summary.md")" 'bounds not collected'
assert_not_contains "$(cat "$pkg/context-gaps.txt")" 'bounds unavailable'

compare_bounds() { # expected state, package gap or expected output fragment, optional env command/prefix
    local expected="$1" marker="$2" pkg details facts_state
    shift 2
    run "$@" bash "$BIN/facts.sh" "$ID" --base "$BASE"
    assert_eq 0 "$STATUS" "$OUTPUT" || return
    run "$@" bash "$BIN/build-review-package.sh" "$ID" "$BASE" --facts
    assert_eq 0 "$STATUS" "$OUTPUT" || return
    pkg="$(jq -er .PACKAGE_DIR <<< "$OUTPUT")"
    facts_state="$(jq -r '.facts.bounds.state' "$pkg/evidence/facts/index.json")"
    details="$(jq -r '.facts.bounds.details // ""' "$pkg/evidence/facts/index.json")"
    assert_eq "$expected" "$facts_state" 'expected facts state'
    assert_eq "$facts_state" "$(cat "$pkg/bounds-status.txt")" 'HEAD state agrees'
    assert_eq "$details" "$(cat "$pkg/bounds.txt")" 'HEAD bounds bytes agree (ignoring final LF)'
    if [ "$expected" = unavailable ]; then
        assert_eq '' "$details"
        assert_contains "$(cat "$pkg/context-gaps.txt")" "$marker"
        assert_contains "$(cat "$pkg/context-gaps.txt")" 'bounds bounds unavailable'
        assert_not_contains "$(cat "$pkg/evidence/facts/summary.md")" "$empty_bounds"
        assert_not_contains "$(cat "$pkg/index.md")" 'No spec files at BASE or HEAD; no spec bounds apply.'
    else
        assert_contains "$details" "$marker"
        assert_not_contains "$(cat "$pkg/context-gaps.txt")" 'bounds bounds unavailable'
        assert_eq "$(awk -F '\t' '$1 ~ /^specs\/changes\// {print $2}' "$pkg/bounds-inputs.tsv")" \
            "$(jq -r '.facts.bounds.scope_revision' "$pkg/evidence/facts/index.json")" 'scope is bound to the same revision'
    fi
    parity_pkg="$pkg"
}

it 'A malformed scope still fails collection even without spec inputs for bounds'
printf '# Change\n\n**Tier**: T1 · **Parts**: P1 · **Parts**: P2\n' > "specs/changes/$ID.md"
git commit -qam 'make record scope ambiguous' || exit 1
run bash "$BIN/facts.sh" "$ID" --base "$BASE"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_contains "$(cat "$CACHE/summary.md")" 'bounds not collected (exit 1)'
assert_not_contains "$(cat "$CACHE/summary.md")" "$empty_bounds"
compare_bounds unavailable 'bounds bounds unavailable'

it 'An unsafe canon entry cannot be mistaken for absent spec bounds'
git show "$BASE:specs/changes/$ID.md" > "specs/changes/$ID.md"
ln -s missing.md specs/product.md
git add specs && git commit -qm 'add an unresolved spec link' || exit 1
run bash "$BIN/facts.sh" "$ID" --base "$BASE"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_contains "$(cat "$CACHE/summary.md")" 'bounds not collected (exit 2)'
assert_not_contains "$(cat "$CACHE/summary.md")" "$empty_bounds"
compare_bounds unavailable 'unsafe spec input specs/product.md'

record="specs/changes/$ID.md"
for fixture in symlink-canon binary-canon binary-design control-path noncanonical-control-path \
    plain-record empty-record binary-record unterminated-record executable-record duplicate-tier review-field \
    collected modified-bound removed-last-bound partial-canon partial-base undefined-reference \
    recovered-record recovered-with-bound; do
    it "Reviewed bounds fixture: $fixture"
    git checkout -q --detach "$BASE" || exit 1
    expected=unavailable; marker='bounds bounds unavailable'
    case "$fixture" in
        symlink-canon)
            ln -s ../label.txt specs/product.md; marker='unsafe spec input specs/product.md' ;;
        binary-canon|binary-design)
            spec=product; [ "$fixture" != binary-design ] || spec=design
            printf 'bad\000bytes\n' > "specs/$spec.md"; marker="unreadable/non-text input specs/$spec.md" ;;
        partial-canon|partial-base)
            printf '# Product\n\n- **C-01 Known**: Scope: all.\n' > specs/product.md
            printf 'bad\000bytes\n' > specs/design.md; marker='unreadable/non-text input specs/design.md' ;;
        control-path|noncanonical-control-path)
            dir=specs
            if [ "$fixture" = control-path ]; then dir=specs/product; mkdir -p "$dir"; fi
            printf '# Odd name\n' > "$dir/"$'odd\tname.md'; marker='unsafe spec input' ;;
        plain-record) printf 'Plain text without a tier.\n' > "$record" ;;
        empty-record) : > "$record" ;;
        binary-record) printf '# Change\n\n**Tier**: T1\n\nbad\000bytes\n' > "$record"; marker='unreadable child record' ;;
        unterminated-record) printf '**Tier**: T1' > "$record" ;;
        executable-record) chmod +x "$record"; marker='actual child record is unsafe/unreadable' ;;
        duplicate-tier) printf '\n<!-- **Tier**: T2 -->\n' >> "$record" ;;
        review-field) printf '\n## State\n\n**Review**: obsolete\n' >> "$record" ;;
        collected|modified-bound|removed-last-bound)
            printf '# Product\n\n- **C-01 Original**: Scope: all.\n' > specs/product.md
            expected=collected; marker='C-01 Original' ;;
        undefined-reference)
            printf '\n## Acceptance\n\nSee [window][missing].\n' >> "$record"
            expected=absent; marker="$empty_bounds" ;;
        recovered-record) git rm -q "$record"; expected=absent; marker="$empty_bounds" ;;
        recovered-with-bound)
            printf '# Product\n\n- **C-01 Survives**: Scope: all.\n' > specs/product.md
            git rm -q "$record"; expected=collected; marker='C-01 Survives' ;;
    esac
    git add -A && git commit -qm "$fixture" || exit 1
    parity_base="$BASE"
    case "$fixture" in
        modified-bound|removed-last-bound)
            BASE="$(git rev-parse HEAD)"
            if [ "$fixture" = removed-last-bound ]; then
                git rm -q specs/product.md || exit 1
                expected=absent; marker="$empty_bounds"
            else
                printf '# Product\n\n- **C-01 Revised**: Scope: all.\n' > specs/product.md
                marker='C-01 Revised'
            fi
            git commit -qam "$fixture transition" || exit 1 ;;
        partial-base)
            BASE="$(git rev-parse HEAD)"
            git rm -q specs/design.md specs/product.md && git commit -qm 'remove the BASE spec inputs' || exit 1
            expected=absent; marker="$empty_bounds" ;;
    esac
    compare_bounds "$expected" "$marker"
    case "$fixture" in
        removed-last-bound)
            assert_contains "$(cat "$parity_pkg/bounds-base.txt")" 'C-01 Original'
            assert_contains "$(cat "$parity_pkg/context-manifest.tsv")" $'\tbound-removed\tC-01' ;;
        partial-base)
            assert_eq '' "$(cat "$parity_pkg/bounds-base.txt")" 'incomplete BASE inventory is not a bounds result'
            assert_contains "$(cat "$parity_pkg/context-gaps.txt")" 'unresolved BASE obligation: BASE bounds unavailable'
            assert_contains "$(cat "$parity_pkg/context-manifest.tsv")" $'\tbound-removed\tC-01' ;;
        undefined-reference) assert_contains "$(cat "$parity_pkg/context-gaps.txt")" 'undefined reference' ;;
        recovered-*)
            assert_eq "$parity_base" "$(jq -r '.facts.bounds.scope_revision' "$parity_pkg/evidence/facts/index.json")" ;;
    esac
    BASE="$parity_base"
done

it 'An unknown change does not fall back to --all with or without HEAD specs'
ID=111-absent
compare_bounds unavailable 'actual child record missing or unrecoverable'
git checkout -q --detach "$BASE" || exit 1
printf 'after\n' > label.txt
git commit -qam 'unknown change with no spec inputs' || exit 1
compare_bounds unavailable 'actual child record missing or unrecoverable'
ID=001-record-only

it 'A failing, truncated, or malformed HEAD inventory is unavailable and does not erase BASE bounds'
git checkout -q --detach "$BASE" || exit 1
printf '# Product\n\n- **C-01 Base promise**: Scope: all.\n' > specs/product.md
git add specs/product.md && git commit -qm 'record a BASE bound' || exit 1
record_only_base="$BASE"
BASE="$(git rev-parse HEAD)"
printf 'after\n' > label.txt
git commit -qam 'enumeration failure control' || exit 1
fault_bin="$(mktemp -d)"; track_tmp "$fault_bin"
real_git="$(command -v git)"
fault_head="$(git rev-parse HEAD)"
for fault in fail truncated malformed; do
    {
        printf '#!/usr/bin/env bash\nreal=%q\nhead=%q\nfault=%q\n' "$real_git" "$fault_head" "$fault"
        cat <<'EOF'
case " $* " in
    *" ls-tree -r -t -z $head -- specs ")
        case "$fault" in
            fail) exit 65 ;;
            truncated) printf '040000 tree 0123456789abcdef\tspecs'; exit 0 ;;
            malformed) printf 'bad record\000'; exit 0 ;;
        esac ;;
esac
exec "$real" "$@"
EOF
    } > "$fault_bin/git"
    chmod +x "$fault_bin/git"
    compare_bounds unavailable 'cannot completely enumerate spec entries' env PATH="$fault_bin:$PATH"
    assert_contains "$(cat "$parity_pkg/bounds-base.txt")" 'C-01 Base promise'
    assert_not_contains "$(cat "$parity_pkg/context-gaps.txt")" 'unresolved BASE obligation: cannot completely enumerate'
done

it 'Unavailable scope history is not confirmed absence'
git rm -q "$record" && git commit -qm 'remove the record before testing a history read failure' || exit 1
{
    printf '#!/usr/bin/env bash\nreal=%q\n' "$real_git"
    cat <<'EOF'
case " $* " in
    *" log -1 --format=%H "*) exit 65 ;;
esac
exec "$real" "$@"
EOF
} > "$fault_bin/git"
compare_bounds unavailable 'actual child record missing or unrecoverable' env PATH="$fault_bin:$PATH"

it 'ASCII case aliases are rejected before copying either HEAD path, preserving BASE'
git checkout -q --detach "$BASE" || exit 1
upper=specs/product/Guides.md
lower=specs/product/guides.md
# Create both names in the Git tree without relying on a case-sensitive checkout.
upper_blob="$(printf '# Upper\n\n- **C-11 Upper**: Scope: all.\n  Keep the original upper body.\n' | git hash-object -w --stdin)" || exit 1
git update-index --add --cacheinfo "100644,$upper_blob,$upper" &&
    git commit -qm 'add binding upper path' || exit 1
BASE="$(git rev-parse HEAD)"
lower_blob="$(printf '# Lower\n\n- **C-12 Lower**: Scope: all.\n' | git hash-object -w --stdin)" || exit 1
git -c core.ignoreCase=false update-index --add --cacheinfo "100644,$lower_blob,$lower" &&
    git commit -qm 'add case-alias path' || exit 1
compare_bounds unavailable 'ASCII case-fold collision'
assert_contains "$(jq -r '.facts.bounds.stderr' "$CACHE/index.json")" 'ASCII case-fold collision'
assert_not_contains "$(cat "$parity_pkg/bounds-inputs.tsv")" "$upper"
assert_not_contains "$(cat "$parity_pkg/bounds-inputs.tsv")" "$lower"
assert_contains "$(cat "$parity_pkg/bounds-base.txt")" 'C-11 Upper'
assert_contains "$(cat "$parity_pkg/bounds-base-inputs.tsv")" "$upper"
assert_contains "$(cat "$parity_pkg"/context-sections/*.txt)" 'Keep the original upper body.'
run bash "$BIN/build-review-package.sh" "$ID" "$BASE" --context "$upper" --context "$lower"
assert_eq 0 "$STATUS" "$OUTPUT"
pkg="$(jq -er .PACKAGE_DIR <<< "$OUTPUT")"
assert_eq unavailable "$(cat "$pkg/bounds-status.txt")"
assert_eq '' "$([ ! -e "$pkg/context/specs" ] || printf present)" 'explicit context must not materialize either alias'

for path in specs/product/group specs/parts/group vendor/group; do
    it "An opaque gitlink is a bounds gap only under the spec root: $path"
    git checkout -q --detach "$record_only_base" || exit 1
    # A gitlink to an unavailable object, with no submodule worktree to read.
    git update-index --add --cacheinfo "160000,$(printf '%0*d' "${#record_only_base}" 1),$path" &&
        git commit -qm "add gitlink at $path" || exit 1
    BASE="$(git rev-parse HEAD)"
    printf 'gitlink control\n' > label.txt
    git add label.txt && git commit -qm 'keep gitlink unchanged' || exit 1
    if [ "$path" = vendor/group ]; then
        compare_bounds absent "$empty_bounds"
        assert_not_contains "$(cat "$parity_pkg/context-gaps.txt")" 'unsafe spec input'
    else
        compare_bounds unavailable "unsafe spec input $path"
        assert_contains "$(jq -r '.facts.bounds.stderr' "$CACHE/index.json")" "unsafe spec input $path"
        assert_contains "$(cat "$parity_pkg/context-gaps.txt")" "unresolved BASE obligation: unsafe spec input $path"
    fi
done

finish
