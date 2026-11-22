#!/usr/bin/env bash
# Synthetic, explicitly NONAUTHORITATIVE host fixtures. No live approvals or publisher key.
# Exercise the real native evaluator/publisher against gh-stub, never invented coverage edges.
set -euo pipefail
# shellcheck disable=SC2153 # STATUS/OUTPUT are assigned by the sourced fixture runner.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TESTS_DIR/review-fixtures.sh"
source "$TESTS_DIR/review-package-fixtures.sh"
STATUS=0; OUTPUT=""
P="$(make_inited_project)"; track_tmp "$P"; cd "$P"
BUILD="$PK_ROOT/scripts/build-review-package.sh"; CHECK="$PK_ROOT/scripts/check-review.sh"
PUBLISH="$PK_ROOT/scripts/publish-review.sh"
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n| security | reviewer |\n| maker | maker |\n' >> .prdkit/memory/agents.md
receipt_policy "$P"
mkdir -p src specs/parts specs/product specs/changes
printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\n' > src/app.txt
printf '# Product\n\nSynthetic product.\n' > specs/product.md
printf '# Architecture\n\n| Part | Purpose | Journeys |\n|---|---|---|\n| P1 | [Behavior](parts/p1.md) | J-01 |\n' > specs/architecture.md
printf '# P1\n\n## Behavior\n\n- **P1.B-01 Complete item** — Required behavior.\n  Continuation and sub-obligation.\n  - Nested obligation.\n\n## Unrelated\n\nOther canon.\n' > specs/parts/p1.md
printf '# Constraints\n\n- **C-01 Everywhere** — Scope: all parts.\n  Whole bound body.\n- **C-02 Later** (from: ga) — Scope: P1.\n  Owner direction required.\n' > specs/product/constraints.md
printf '# Lifecycle\n\n**Now**: Demo · **Next**: MVP\n' > specs/product/lifecycle.md
git add -A; git commit -qm 'synthetic baseline'
MAIN="$(git symbolic-ref --short HEAD)"; BASE="$(git rev-parse HEAD)"; REF="refs/remotes/origin/$MAIN"
git update-ref "$REF" "$BASE"; git symbolic-ref refs/remotes/origin/HEAD "$REF"
ID=001-targeted
git checkout -qb "$ID"
cat > "specs/changes/$ID.md" <<'EOF'
# Change: targeted

**Tier**: T2 · **Parts**: P1 · **Parent**: 900-programme · **Opened**: 2026-01-01

## Spec edits

P1.B-01.

## Acceptance

P1.B-01 and C-01 hold.

## State

**Step**: review
EOF
cat > specs/changes/900-programme.md <<'EOF'
# Programme

Original header.

## Outcome checkpoint

Original goal; architecture; progress: 1; budget: 2.

### Critical path

Required dependency outcome.

## Children

| Child | Outcome |
|---|---|
| 001-targeted | Required child obligation. |
| 002-sibling | SIBLING_BODY_NOT_NEEDED |

## Holds and lane limits

Owner hold remains; no stage promotion.

## Unrelated delivered narrative

UNRELATED_PARENT_BODY_NOT_NEEDED
EOF
i=0; while [ "$i" -lt 800 ]; do echo "UNRELATED_PARENT_BODY_NOT_NEEDED $i"; i=$((i+1)); done >> specs/changes/900-programme.md
# The large parent already exists on the synthetic integration baseline, not in the full diff.
git add specs/changes/900-programme.md; git commit -qm 'baseline parent'
BASE="$(git rev-parse HEAD)"; git update-ref "$REF" "$BASE"
printf 'one\ntwo\nthree\nfour\nchanged\nsix\nseven\neight\nnine\n' > src/app.txt
git add -A; git commit -qm 'initial synthetic change'
F1="$(git rev-parse HEAD)"
use_gh_stub
host_head() { fx_pr 7 "$(git rev-parse HEAD)" "$(jq -cn --arg base "$MAIN" '{base:{ref:$base}}')"; }
post() {
    local who="$1" verdict="$2" at="$3" since="${4:-}" counts=0,0,0,0 args=()
    [ "$verdict" != FAIL ] || counts=0,1,0,0
    [ -z "$since" ] || args=(--since "$since")
    host_head
    receipt_raw_run bash "$PUBLISH" "$ID" --repo "$P" --pr https://github.com/owner/repo/pull/7 \
        --reviewer "$who" --verdict "$verdict" --counts "$counts" --head "$at" --report https://example.invalid/report \
        ${args[@]+"${args[@]}"}
    assert_eq 0 "$STATUS" "synthetic publisher invocation: $OUTPUT"
}
post security PASS "$F1"
post code FAIL "$F1"
cp "$GH_STUB_DIR/reviews/7.json" "$GH_STUB_DIR/original.json"
printf 'one\ntwo\nthree\nfour\nfixed\nsix\nseven\neight\nnine\n' > src/app.txt
git commit -qam 'bounded fix'
F2="$(git rev-parse HEAD)"; host_head
write_plan() {
    jq -n --arg head "$(git rev-parse HEAD)" --arg since "$F1" --arg at "$BASE" --arg base "$REF" \
        --slurpfile reviews "$GH_STUB_DIR/original.json" '
        {change:"001-targeted",pr:"https://github.com/owner/repo/pull/7",head:$head,since:$since,
         base_ref:$base,base_at:$at,policy_at:$at,
         reviewers:[
            {id:"code",action:"review",reason:"inspect the whole fix and cross-boundary effects",
             obligations:["P1.B-01"],references:[$reviews[0][1].url]},
            {id:"security",action:"unaffected",reason:"lead judgment, not approval",
             obligations:["P1.B-01"],references:[$reviews[0][0].url]}],
         fixes:[{path:"src/app.txt",reviewers:["code"],obligations:["P1.B-01"],
             receipt:$reviews[0][1].url,finding:"high-1"}],
         context:[{path:"specs/parts/p1.md",selector:"Behavior",reason:"affected behavior"}]}' > .git/plan.json
}
package() {
    write_plan
    [ "${1:-}" = "" ] || { jq "$1" .git/plan.json > .git/next.json; mv .git/next.json .git/plan.json; }
    receipt_raw_run bash "$BUILD" "$ID" "$BASE" --since "$F1" --pr https://github.com/owner/repo/pull/7 --review-plan .git/plan.json
    assert_eq 0 "$STATUS" "package built: $OUTPUT"
    PKG="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
}
advance() { printf '%s\n' "$1" >> src/app.txt; git add src/app.txt; git commit -qm "$1"; host_head; }
parity() {
    local plain status
    receipt_raw_run bash "$CHECK" --repo "$P" --json --pr https://github.com/owner/repo/pull/7 "$ID"
    plain="$OUTPUT"; status="$STATUS"
    receipt_raw_run bash "$CHECK" --repo "$P" --json --diagnostics --pr https://github.com/owner/repo/pull/7 "$ID"
    assert_eq "$status" "$STATUS" 'diagnostic exit parity'
    assert_eq "$(printf '%s' "$plain" | jq -Sc .)" "$(printf '%s' "$OUTPUT" | jq -Sc 'del(.diagnostics)')" 'existing JSON parity'
}

it "F1 PASS/FAIL plus F2 fix names code only, security prospective, gate still FAIL"
package
j="$(cat "$PKG/dispatch.json")"
assert_eq '["code"]' "$(printf '%s' "$j" | jq -c .review_now)" 'only failing affected reviewer now'
assert_eq '["security"]' "$(printf '%s' "$j" | jq -c '[.prospective_carry[].reviewer]')" 'security is conditional, not retained'
assert_eq '[]' "$(printf '%s' "$j" | jq -c .retained)" 'no pre-receipt retained approval'
assert_eq fail "$(printf '%s' "$j" | jq -r .gate_result)" 'original native FAIL kept'
assert_eq 1 "$(cat "$PKG/gate.status")" 'failing gate exit kept'
assert_eq true "$(printf '%s' "$j" | jq -r .scope_valid)" 'complete advisory map accepted'
assert_contains "$(printf '%s' "$j" | jq -r '.prospective_carry[0].condition')" 'actual clean native' 'forecast condition explicit'

it "Child context has immutable provenance, complete bounds/items/checkpoint/row, not whole parent"
assert_contains "$(cat "$PKG/context-manifest.tsv")" "$F2" 'head binding'
assert_contains "$(cat "$PKG/context-manifest.tsv")" "$(git rev-parse "$F2:specs/changes/$ID.md")" 'actual child blob'
combined="$(cat "$PKG"/context-sections/*.txt)"
assert_contains "$combined" 'Whole bound body.' 'complete bound body'
assert_contains "$combined" 'Nested obligation.' 'complete referenced item includes nested body'
assert_contains "$combined" 'Original goal; architecture' 'checkpoint'
assert_contains "$combined" 'Owner hold remains' 'parent hold/limit'
assert_contains "$combined" 'Required child obligation' 'actual child row'
assert_not_contains "$combined" UNRELATED_PARENT_BODY_NOT_NEEDED 'unrelated large parent text absent'
assert_not_contains "$combined" SIBLING_BODY_NOT_NEEDED 'sibling body absent'
assert_contains "$(cat "$PKG/bounds.txt")" C-02 'all bounds, including later stage'
assert_contains "$(cat "$PKG/bounds.txt")" 'built only on owner direction' 'later owner limit preserved'
assert_contains "$(cat "$PKG/bounds-inputs.tsv")" "$(git rev-parse "$F2:specs/product/constraints.md")" 'bounds input object'
while IFS=$'\t' read -r file bytes oid source; do
    [ "$file" != file ] || continue
    assert_eq "$bytes" "$(wc -c < "$PKG/$file" | tr -d ' ')" "inventory bytes: $source"
    assert_eq "$oid" "$(git hash-object --no-filters "$PKG/$file")" "inventory exact: $file"
done < "$PKG/manifest.tsv"

it "Gate diagnostics do not change any existing JSON field, coverage or exits"
parity

it "An actual clean native narrow receipt, not a forecast, establishes carry"
post code PASS "$F2" "$F1"
receipt_raw_run bash "$CHECK" --repo "$P" --json --diagnostics --pr https://github.com/owner/repo/pull/7 "$ID"
assert_eq 0 "$STATUS" "real evaluator accepts synthetic narrow receipt: $OUTPUT"
assert_eq true "$(printf '%s' "$OUTPUT" | jq '.diagnostics.latest[] | select(.reviewer=="security") | .end_covered')" 'actual security retention'
parity
# A full request cannot reuse a package assembled with an earlier native evaluation and plan.
receipt_raw_run bash "$BUILD" "$ID" "$BASE"
assert_eq 0 "$STATUS" 'the same source can get a fresh package for different inputs'
fresh="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
assert_contains "$(cat "$fresh/index.md")" 'package context or bindings differ'
assert_eq false "$([ -e "$fresh/gate.json" ] && echo true || echo false)" 'does not inherit the previous native evaluation'

it "Full replacement PASS clears own FAIL but does not bridge another approval"
cp "$GH_STUB_DIR/original.json" "$GH_STUB_DIR/reviews/7.json"
post code PASS "$F2"
receipt_raw_run bash "$CHECK" --repo "$P" --json --diagnostics --pr https://github.com/owner/repo/pull/7 "$ID"
assert_eq 1 "$STATUS" 'security still uncovered'
assert_eq false "$(printf '%s' "$OUTPUT" | jq '.diagnostics.latest[] | select(.reviewer=="security") | .end_covered')" 'no fictional narrow edge'
post security PASS "$F2" "$F1"
receipt_raw_run bash "$CHECK" --repo "$P" --json --diagnostics --pr https://github.com/owner/repo/pull/7 "$ID"
assert_eq 0 "$STATUS" 'both actually covered now'
cp "$GH_STUB_DIR/original.json" "$GH_STUB_DIR/reviews/7.json"
post security PASS "$F2" "$F1"
receipt_raw_run bash "$CHECK" --repo "$P" --json --diagnostics --pr https://github.com/owner/repo/pull/7 "$ID"
assert_eq 1 "$STATUS" 'another reviewer cannot clear code FAIL'
assert_eq '["code"]' "$(printf '%s' "$OUTPUT" | jq -c '[.diagnostics.standing[].reviewer]')" 'own FAIL retained'

it "Actual retained clean coverage remains visible while another reviewer FAIL stands"
advance retained-control
post security PASS HEAD
package
assert_eq '["security"]' "$(jq -c '[.retained[].reviewer]' "$PKG/dispatch.json")" 'actual clean security retained beside code FAIL'
assert_eq fail "$(jq -r .gate_result "$PKG/dispatch.json")" 'not whole-gate approval'
cp "$GH_STUB_DIR/original.json" "$GH_STUB_DIR/reviews/7.json"

it "Affected security must be reviewed; incomplete/forged/omitted mappings cannot reduce"
advance security-affected
package '.reviewers[1].action="review" | .fixes[0].reviewers=["code","security"]'
assert_eq '["code","security"]' "$(jq -c .review_now "$PKG/dispatch.json")" 'security affected selected'
assert_eq '[]' "$(jq -c .prospective_carry "$PKG/dispatch.json")" 'affected never prospective'
advance omitted-blocker
package '.reviewers |= map(select(.id!="code"))'
assert_eq false "$(jq -r .scope_valid "$PKG/dispatch.json")" 'omitted code not valid'
assert_eq '["code"]' "$(jq -c .review_now "$PKG/dispatch.json")" 'map cannot hide standing blocker'
advance unmapped-delta
package '.fixes[0].path="src/missing.txt"'
assert_eq false "$(jq -r .scope_valid "$PKG/dispatch.json")" 'unmapped delta pending'
advance forged-text
package '.reviewers[1].references=["PASS security"]'
assert_eq false "$(jq -r .scope_valid "$PKG/dispatch.json")" 'typed PASS is no native reference'
advance missing-concern
package '.reviewers += [{id:"maker",action:"unaffected",reason:"not eligible",obligations:["P1.B-01"],references:["new-change"]}]'
assert_eq false "$(jq -r .scope_valid "$PKG/dispatch.json")" 'maker cannot fill concern'

it "Stale plan refuses before allocation"
advance stale-binding
write_plan
jq '.head="0000000000000000000000000000000000000000"' .git/plan.json > .git/next.json; mv .git/next.json .git/plan.json
before="$(package_snapshot .prdkit/cache/evidence/001-targeted/reviews)"
receipt_raw_run bash "$BUILD" "$ID" "$BASE" --since "$F1" --pr https://github.com/owner/repo/pull/7 --review-plan .git/plan.json
assert_eq 1 "$STATUS" 'stale binding refused'
assert_eq "$before" "$(package_snapshot .prdkit/cache/evidence/001-targeted/reviews)" 'no artifact mutation (path/mode/size/hash/directories)'

it "Unpublished code, unavailable/partial host and snapshots cannot certify retention"
advance unpublished
# Deliberately leave the synthetic host at an older code head.
fx_pr 7 "$F2" "$(jq -cn --arg base "$MAIN" '{base:{ref:$base}}')"
package
assert_eq unknown "$(jq -r .coverage "$PKG/dispatch.json")" 'unpublished changed code unbound'
assert_eq 'null' "$(jq -c .retained "$PKG/dispatch.json")" 'unknown is not an authenticated empty list'
advance partial-host
export GH_STUB_FAIL=graphql:PrdkitReviews
package
assert_eq unknown "$(jq -r .coverage "$PKG/dispatch.json")" 'incomplete host unknown'
unset GH_STUB_FAIL
receipt_raw_run bash "$CHECK" --repo "$P" --json --diagnostics --pr https://github.com/owner/repo/pull/7 --save-receipts .git/snapshot "$ID"
receipt_raw_run bash "$CHECK" --repo "$P" --json --diagnostics --receipts .git/snapshot "$ID"
assert_eq snapshot "$(printf '%s' "$OUTPUT" | jq -r .authority)" 'snapshot remains nonauthoritative'
assert_eq false "$(printf '%s' "$OUTPUT" | jq -r .diagnostics.host_content_bound)" 'snapshot never claims host binding'

it "Invalid receipts require repair; new clean verdicts cannot suppress them"
advance invalid-receipt
fx_review 7 "$(jq -r '.[1].body' "$GH_STUB_DIR/original.json")" '{"lastEditedAt":"2026-01-03T00:00:00Z"}'
post code PASS HEAD
package
assert_eq 1 "$(jq .blockers.invalid_receipts "$PKG/dispatch.json")" 'invalid receipt not repaired by new PASS'
assert_eq fail "$(jq -r .gate_result "$PKG/dispatch.json")" 'invalid still blocks native gate'
assert_eq pending "$(jq -r .dispatch "$PKG/dispatch.json")" 'no ready replacement panel'
parity
cp "$GH_STUB_DIR/original.json" "$GH_STUB_DIR/reviews/7.json"

it "Foreign and carried FAILs remain explicit and grant no approval transfer"
advance foreign-blocker
payload="$(jq -r '.[1].body|split("\n")[1]|fromjson|
    .id="cccccccccccccccccccccccccccccccc"|.change="002-foreign"|.to="none"|tojson' "$GH_STUB_DIR/original.json")"
fx_review 7 "$(printf '<!-- prdkit-review\n%s\n-->' "$payload")"
package
assert_eq '["002-foreign"]' "$(jq -c '[.blockers.scope[]|select(.change=="002-foreign")|.change]' "$PKG/dispatch.json")" 'foreign FAIL survives map'
assert_eq fail "$(jq -r .gate_result "$PKG/dispatch.json")" 'foreign FAIL blocks'
parity
cp "$GH_STUB_DIR/original.json" "$GH_STUB_DIR/reviews/7.json"
advance carried-blocker
fx_closed_pr 6 "$(git rev-parse HEAD)" "$(jq -cn --arg base "$MAIN" '{base:{ref:$base}}')"
payload="$(printf '%s' "$payload" | jq -c '.pr=6|.change="001-targeted"')"
fx_review 6 "$(printf '<!-- prdkit-review\n%s\n-->' "$payload")"
package
assert_eq 1 "$(jq .blockers.carried "$PKG/dispatch.json")" 'closed source blocker preserved'
assert_eq '[]' "$(jq -c .retained "$PKG/dispatch.json")" 'no cross-PR PASS transfer'
parity
rm "$GH_STUB_DIR/pulls/6.json" "$GH_STUB_DIR/reviews/6.json"

it "PR-wide owner barriers survive advisory planning beside actually retained coverage"
for native_state in CHANGES_REQUESTED DISMISSED; do
    advance "native-owner-$native_state"
    post code PASS HEAD
    post security PASS HEAD
    fx_owner_review 7 "$native_state" "$(git rev-parse HEAD)"
    package
    assert_eq "$native_state" "$(jq -r '.blockers.owner.barriers[0].state' "$PKG/dispatch.json")" \
        'advisory output retains the actual owner barrier'
    assert_eq '["owner"]' "$(jq -c .blockers.problem_classes "$PKG/dispatch.json")" \
        'the only failure is classified as owner, not an unrelated coverage or legacy failure'
    assert_eq 1 "$(jq '.problems|length' "$PKG/gate.json")" 'one native owner barrier, no duplicate T3 error'
    assert_eq '["code","security"]' "$(jq -c '[.retained[].reviewer]|sort' "$PKG/dispatch.json")" \
        'actual independent coverage stays distinct from overall eligibility'
    assert_eq fail "$(jq -r .gate_result "$PKG/dispatch.json")" 'owner barrier still blocks the native gate'
    assert_eq pending "$(jq -r .dispatch "$PKG/dispatch.json")" 'an advisory map cannot waive the owner barrier'
    parity
done
cp "$GH_STUB_DIR/original.json" "$GH_STUB_DIR/reviews/7.json"

it "Legacy blockers, owner requirements and tier floors are not waived by the map"
printf '**Review**: round 1 · %s..%s · code · FAIL · 0 critical, 1 high, 0 medium, 0 low · https://example.invalid/legacy\n' \
    "$BASE" "$F1" >> "specs/changes/$ID.md"
git add "specs/changes/$ID.md"; git commit -qm 'synthetic standing legacy FAIL'
advance legacy-blocker
package
assert_eq true "$(jq '(.blockers.legacy|length)>0' "$PKG/dispatch.json")" 'standing legacy FAIL explicit'
assert_eq fail "$(jq -r .gate_result "$PKG/dispatch.json")" 'legacy blocks'
parity
sed 's/\*\*Tier\*\*: T2/**Tier**: T3/' "specs/changes/$ID.md" > .git/record
cp .git/record "specs/changes/$ID.md"; git add "specs/changes/$ID.md"; git commit -qm 'synthetic T3 requirement'
advance owner-required
package
assert_eq T3 "$(jq -r .tier "$PKG/gate.json")" 'T3 preserved'
assert_eq true "$(jq '.blockers.problem_classes|index("owner")!=null' "$PKG/dispatch.json")" 'owner obligation explicit'
parity
sed 's/\*\*Tier\*\*: T3/**Tier**: T2/' "specs/changes/$ID.md" > .git/record
cp .git/record "specs/changes/$ID.md"; git add "specs/changes/$ID.md"; git commit -qm 'synthetic lower tier claim'
advance tier-floor
package
assert_eq T3 "$(jq -r .tier "$PKG/gate.json")" 'historical floor cannot be lowered'
assert_eq fail "$(jq -r .gate_result "$PKG/dispatch.json")" 'floor/owner/legacy still blocking'
parity

it "Ambiguous selectors, symlink context and deleted child provenance stay explicit"
sed 's/Parent\*\*: 900-programme/Parent**: —/' "specs/changes/$ID.md" > .git/record
cp .git/record "specs/changes/$ID.md"; git add "specs/changes/$ID.md"; git commit -qm 'standalone change'
advance context-gaps
package '.context=[{path:"specs/parts/p1.md",selector:"Missing heading",reason:"required"}]'
assert_not_contains "$(cat "$PKG/context-gaps.txt")" 'parent' 'standalone change does not request a parent for the Opened date'
assert_contains "$(cat "$PKG/context-gaps.txt")" 'ambiguous/missing/unsupported section' 'unresolved selector gap'
ln -s app.txt src/link.txt; git add src/link.txt
git commit -qm 'synthetic link'; host_head
receipt_raw_run bash "$BUILD" "$ID" "$BASE" --context src/link.txt
assert_eq 1 "$STATUS" 'symlink cannot masquerade as whole context'
printf 'dirty worktree\n' > specs/parts/p1.md
advance dirty-control
package
assert_not_contains "$(cat "$PKG"/context-sections/*.txt)" 'dirty worktree' 'committed canon only'
git rm -q "specs/changes/$ID.md"
mkdir -p specs/log; printf -- '- 2026-01-03 %s: closed\n' "$ID" > "specs/log/$ID.md"
git add specs/log; git commit -qm 'synthetic close'
# Closing metadata is equal: compare refuses, even though the historical record is recoverable.
receipt_raw_run bash "$BUILD" "$ID" "$BASE"
assert_eq 1 "$STATUS" 'closing record metadata alone needs no new round'
# New source at the closing head permits a structural package with historical record binding.
advance closing-new-source
receipt_raw_run bash "$BUILD" "$ID" "$BASE"
assert_eq 0 "$STATUS" "closing package: $OUTPUT"
PKG="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
assert_contains "$(cat "$PKG/context-manifest.tsv")" "$(git rev-parse HEAD~2)" 'historical child revision bound'
assert_contains "$(cat "$PKG/context-manifest.tsv")" 'historical when source_rev differs' 'not represented as an H blob'
finish
