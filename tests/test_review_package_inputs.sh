#!/usr/bin/env bash
# Synthetic, NONAUTHORITATIVE host/input regressions. Never use a live host or key.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TESTS_DIR/review-fixtures.sh"
STATUS=0; OUTPUT=""; PKG=""
# Override only this test driver to retain pre-fix reproductions against a frozen kit snapshot.
BUILD="${PACKAGE_TEST_BUILDER:-$PK_ROOT/scripts/build-review-package.sh}"
PUBLISH="$PK_ROOT/scripts/publish-review.sh"

setup() {
    P="$(make_inited_project)" || exit 1
    track_tmp "$P"; cd "$P" || exit 1
    printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n| security | reviewer |\n| design | reviewer |\n' >> .prdkit/memory/agents.md
    receipt_policy "$P"
    mkdir -p src specs/parts specs/product/constraints specs/changes
    printf 'one\ntwo\nthree\nfour\nfive\nsix\nseven\neight\nnine\n' > src/app.txt
    printf '# Product\n\nSynthetic product.\n' > specs/product.md
    printf '# Architecture\n\n| Part | Purpose | Journeys |\n|---|---|---|\n| P1 | Behavior | J-01 |\n' > specs/architecture.md
    printf '# P1\n\n- **P1.B-01 Behavior** — Complete behavior.\n' > specs/parts/p1.md
    printf '# Constraints\n\n- **C-77 Literal filename** — Scope: all parts.\n  REQUIRED_LITERAL_BODY\n' > specs/product/constraints/é.md
    cat > specs/changes/900-parent.md <<'EOF'
# Programme

Header.

## Outcome checkpoint

Goal and progress.

## Children

| Child | Obligation |
|---|---|
| 001-inputs | Required child row. |

## Interface contract

REQUIRED_PARENT_BODY

### Nested behavior

REQUIRED_PARENT_NESTED_BODY

## Unrelated

UNRELATED_PARENT_BODY
EOF
    git add -A; git commit -qm 'synthetic input baseline' || exit 1
    BASE="$(git rev-parse HEAD)"; MAIN="$(git symbolic-ref --short HEAD)"
    REF="refs/remotes/origin/$MAIN"
    git update-ref "$REF" "$BASE"; git symbolic-ref refs/remotes/origin/HEAD "$REF"
    git checkout -qb 001-inputs || exit 1
    ID=001-inputs
    cat > "specs/changes/$ID.md" <<'EOF'
# Change

**Tier**: T2 · **Parts**: P1 · **Parent**: 900-parent

## Acceptance

P1.B-01; [required design](900-parent.md#interface-contract).

## State

**Step**: review
EOF
    printf 'initial\n' >> src/app.txt
    git add -A; git commit -qm 'initial synthetic input change' || exit 1
    F1="$(git rev-parse HEAD)"
    use_gh_stub
    host_head
    post security PASS
    post code FAIL
    cp "$GH_STUB_DIR/reviews/7.json" "$GH_STUB_DIR/original.json"
    advance fix
    ROOT="$P/.prdkit/cache/evidence/$ID/reviews"
}
host_head() { fx_pr 7 "$(git rev-parse HEAD)" "$(jq -cn --arg base "$MAIN" '{base:{ref:$base}}')"; }
post() {
    local counts=0,0,0,0
    [ "$2" != FAIL ] || counts=0,1,0,0
    host_head
    receipt_raw_run bash "$PUBLISH" "$ID" --repo "$P" --pr https://github.com/owner/repo/pull/7 \
        --reviewer "$1" --verdict "$2" --counts "$counts" --head HEAD --report https://example.invalid/report
    [ "$STATUS" = 0 ] || { _no "synthetic publication failed" "$OUTPUT"; exit 1; }
}
advance() { printf '%s\n' "$1" >> src/app.txt; git add src/app.txt; git commit -qm "$1" || exit 1; host_head; }
plan() {
    jq -n --arg head "$(git rev-parse HEAD)" --arg since "$F1" --arg at "$BASE" --arg base "$REF" \
        --slurpfile rs "$GH_STUB_DIR/original.json" '
        {change:"001-inputs",pr:"https://github.com/owner/repo/pull/7",head:$head,since:$since,
         base_ref:$base,base_at:$at,policy_at:$at,
         reviewers:[
           {id:"code",action:"review",reason:"whole delta",obligations:["P1.B-01"],references:[$rs[0][1].url]},
           {id:"security",action:"unaffected",reason:"advisory judgment",obligations:["P1.B-01"],references:[$rs[0][0].url]}],
         fixes:[{path:"src/app.txt",reviewers:["code"],obligations:["P1.B-01"],receipt:$rs[0][1].url,finding:"high-1"}]}' > .git/plan.json
}
build() {
    receipt_raw_run bash "$BUILD" "$ID" "$BASE" "$@"
    if [ "$STATUS" != 0 ]; then _no 'package assembly' "$OUTPUT"; PKG=""; return 1; fi
    PKG="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
}
mapped() { plan; build --since "$F1" --pr https://github.com/owner/repo/pull/7 --review-plan .git/plan.json; }
foreign() { # reviewer verdict origin; explicit synthetic native input, not live evidence
    local who="$1" verdict="$2" origin="$3" fp=none payload serial
    serial="$(jq -s '[.[][]]|length' "$GH_STUB_DIR"/reviews/*.json)"
    [ "$verdict" != PASS ] || fp="$(review_fingerprint "$P" 002-foreign "$BASE" HEAD)"
    payload="$(jq -cn --arg who "$who" --arg verdict "$verdict" --arg fp "$fp" --argjson origin "$origin" \
        --arg id "$(printf '%s' "$who-$origin-$serial" | review_sha256 | cut -c1-32)" --arg head "$(git rev-parse HEAD)" \
        --slurpfile rs "$GH_STUB_DIR/original.json" '
        $rs[0][0].body|split("\n")[1]|fromjson|
        .id=$id|.reviewer=$who|.verdict=$verdict|.pr=$origin|.change="002-foreign"|.to=$fp|.head=$head')"
    fx_review "$origin" "$(printf '<!-- prdkit-review\n%s\n-->' "$payload")" '{"submittedAt":"2026-01-02T13:00:00Z"}'
}
integrity() {
    local file bytes oid source
    while IFS=$'\t' read -r file bytes oid source; do
        [ "$file" != file ] || continue
        assert_eq "$bytes" "$(wc -c < "$PKG/$file" | tr -d ' ')" "bytes $source"
        assert_eq "$oid" "$(git hash-object --no-filters "$PKG/$file")" "hash $file"
    done < "$PKG/manifest.tsv"
    assert_eq 0 "$(cut -f1 "$PKG/manifest.tsv" | LC_ALL=C sort | uniq -d | wc -l | tr -d ' ')" 'no conflicting artifact names'
}

[ "$#" -gt 0 ] || set -- blockers prior plan context paths
for mode in "$@"; do
    setup
    case "$mode" in
        blockers)
            it "Same-identity foreign and carried blockers exclude retained and prospective facts"
            post security PASS; foreign security FAIL 7
            if mapped; then
                assert_eq 0 "$(jq .blockers.invalid_receipts "$PKG/dispatch.json")" 'foreign FAIL is valid native fixture evidence'
                assert_eq true "$(jq 'any(.blockers.scope[]; .reviewer=="security" and .change=="002-foreign")' "$PKG/dispatch.json")" 'foreign FAIL actually stands after checked PASS'
                assert_eq '[]' "$(jq -c '[.retained[].reviewer]' "$PKG/dispatch.json")" 'foreign blocker excludes retained identity'
                assert_eq fail "$(jq -r .gate_result "$PKG/dispatch.json")" 'native FAIL unchanged'
            fi
            cp "$GH_STUB_DIR/original.json" "$GH_STUB_DIR/reviews/7.json"
            advance prospective
            foreign security FAIL 7
            if mapped; then
                assert_eq 0 "$(jq .blockers.invalid_receipts "$PKG/dispatch.json")" 'foreign prospective blocker is valid'
                assert_eq true "$(jq 'any(.blockers.scope[]; .reviewer=="security")' "$PKG/dispatch.json")" 'prospective scope blocker actually stands'
                assert_eq '[]' "$(jq -c '[.prospective_carry[].reviewer]' "$PKG/dispatch.json")" 'foreign blocker excludes prospective identity'
            fi
            cp "$GH_STUB_DIR/original.json" "$GH_STUB_DIR/reviews/7.json"
            advance carried
            post security PASS
            fx_closed_pr 6 "$(git rev-parse HEAD)" "$(jq -cn --arg base "$MAIN" '{base:{ref:$base}}')"
            foreign security FAIL 6
            if mapped; then
                assert_eq 1 "$(jq .blockers.carried "$PKG/dispatch.json")" 'carried fixture actually stands'
                assert_eq '[]' "$(jq -c '[.retained[].reviewer]' "$PKG/dispatch.json")" 'carried blocker excludes retained identity'
            fi
            rm "$GH_STUB_DIR/pulls/6.json" "$GH_STUB_DIR/reviews/6.json"
            cp "$GH_STUB_DIR/original.json" "$GH_STUB_DIR/reviews/7.json"
            ;;
        prior)
            it "Every valid current-PR identity is accounted without foreign approval transfer"
            foreign design PASS 7
            if mapped; then
                assert_eq 0 "$(jq .blockers.invalid_receipts "$PKG/dispatch.json")" 'foreign prior PASS is valid native input'
                assert_eq false "$(jq .scope_valid "$PKG/dispatch.json")" 'omitted clean foreign reviewer disables reduced scope'
                assert_eq '["design"]' "$(jq -c .scope_pending.missing_reviewers "$PKG/dispatch.json")" 'omitted prior identity named'
                assert_eq false "$(jq 'any(.retained[],.prospective_carry[]; .reviewer=="design")' "$PKG/dispatch.json")" 'foreign PASS grants no coverage'
            fi
            advance mapped-prior; plan
            jq '.reviewers += [{id:"design",action:"review",reason:"new concern",obligations:["P1.B-01"],references:["new-change"]}] |
                .fixes[0].reviewers += ["design"]' .git/plan.json > .git/next.json; mv .git/next.json .git/plan.json
            if build --since "$F1" --pr https://github.com/owner/repo/pull/7 --review-plan .git/plan.json; then
                assert_eq true "$(jq .scope_valid "$PKG/dispatch.json")" 'explicit complete map control'
                assert_eq '["code","design"]' "$(jq -c .review_now "$PKG/dispatch.json")" 'foreign identity needs its selected review, not inherited approval'
            fi ;;
        plan)
            it "Exactly one JSON object is validated and consumed before any allocation"
            plan; cp .git/plan.json .git/valid.json
            jq '.head="0000000000000000000000000000000000000000"' .git/valid.json > .git/plan.json
            cat .git/valid.json >> .git/plan.json
            receipt_raw_run bash "$BUILD" "$ID" "$BASE" --since "$F1" --pr https://github.com/owner/repo/pull/7 --review-plan .git/plan.json
            assert_eq 1 "$STATUS" 'concatenated stale/current maps refused'
            assert_contains "$OUTPUT" 'invalid/stale advisory plan' 'invalid input diagnostic'
            assert_eq absent "$([ -e "$ROOT" ] && echo present || echo absent)" 'no round or completion allocated'
            advance single-map
            if mapped; then
                assert_eq 1 "$(jq -s length "$PKG/review-plan.json")" 'single consumed document'
                assert_eq "$(git rev-parse HEAD)" "$(jq -r .head "$PKG/review-plan.json")" 'same validated head consumed'
                integrity
            fi ;;
        context)
            it "Generated context cannot overwrite explicit whole-file context"
            mkdir -p sections; printf 'EXPLICIT_SOURCE_BYTES\n' > sections/1.txt
            git add sections; git commit -qm 'explicit context fixture' || exit 1
            if build --context sections/1.txt --context sections/1.txt; then
                assert_eq "$(git show HEAD:sections/1.txt)" "$(cat "$PKG/context/sections/1.txt")" 'explicit bytes preserved'
                integrity
                assert_contains "$(cat "$PKG/context-manifest.tsv")" "$(git rev-parse HEAD:sections/1.txt)" 'whole-file blob binding'
                assert_eq 1 "$(awk -F '\t' '$1=="context/sections/1.txt" { n++ } END { print n+0 }' "$PKG/context-manifest.tsv")" 'repeated explicit request remains one snapshot'
                content="$(find "$PKG" -type f -name '*.txt' -exec cat {} \;)"
                assert_contains "$content" REQUIRED_PARENT_BODY 'anchored unchanged parent block included'
                assert_contains "$content" REQUIRED_PARENT_NESTED_BODY 'anchored parent subsections included'
                assert_not_contains "$content" UNRELATED_PARENT_BODY 'no whole-parent default'
            fi
            git rm -q sections/1.txt; rmdir sections 2>/dev/null || true
            printf 'EXPLICIT_REGULAR_FILE\n' > sections
            git add sections; git commit -qm 'regular context name fixture' || exit 1
            if build --context sections; then assert_eq EXPLICIT_REGULAR_FILE "$(cat "$PKG/context/sections")" 'regular file cannot collide with generated directory'; integrity; fi
            printf '\n[missing](900-parent.md#missing-heading)\n' >> "specs/changes/$ID.md"
            git add "specs/changes/$ID.md"; git commit -qm 'missing anchored parent reference' || exit 1
            advance missing-anchor
            if build; then assert_contains "$(cat "$PKG/context-gaps.txt")" '900-parent.md#missing-heading' 'missing parent anchor named'; fi
            printf '\n## Interface contract\n\nAMBIGUOUS_SIBLING_BODY\n' >> specs/changes/900-parent.md
            git add specs/changes/900-parent.md; git commit -qm 'ambiguous parent anchor' || exit 1
            if build; then
                assert_contains "$(cat "$PKG/context-gaps.txt")" '900-parent.md#interface-contract' 'duplicate parent anchor is unresolved, not guessed'
                assert_not_contains "$(find "$PKG/context-sections" -type f -exec cat {} \;)" AMBIGUOUS_SIBLING_BODY 'no ambiguous sibling selected'
            fi
            printf '\n[programme](900-parent.md)\n' >> "specs/changes/$ID.md"
            git add "specs/changes/$ID.md"; git commit -qm 'parent navigation link' || exit 1
            advance unanchored-parent
            if build; then assert_contains "$(cat "$PKG/context-gaps.txt")" 'explicit section needed for specs/changes/900-parent.md' 'unanchored parent link is accounted as a gap'; fi ;;
        paths)
            it "Literal spec paths participate in actual bounds and changed canon, or have a named gap"
            printf '  CHANGED_LITERAL_BODY\n' >> specs/product/constraints/é.md
            unsafe=$'specs/product/constraints/line\nbreak.md'
            printf '# Constraint\n\n- **C-78 Rejected path** — Scope: all parts.\n' > "$unsafe"
            git add specs/product; git commit -qm 'literal path controls' || exit 1
            if build; then
                assert_contains "$(cat "$PKG/bounds.txt")" C-77 'Unicode file included in actual bounds'
                assert_contains "$(cat "$PKG/bounds-inputs.tsv")" "$(git rev-parse HEAD:specs/product/constraints/é.md)" 'literal bounds input blob'
                assert_contains "$(cat "$PKG/context-manifest.tsv")" 'specs/product/constraints/é.md' 'literal source path provenance'
                assert_contains "$(find "$PKG" -type f -name '*.txt' -exec cat {} \;)" CHANGED_LITERAL_BODY 'changed literal canon supplied'
                assert_contains "$(cat "$PKG/context-gaps.txt")" 'unsafe spec input' 'unsupported control path has explicit rejection gap'
                integrity
            fi ;;
        *) echo "unknown fixture group: $mode" >&2; exit 2 ;;
    esac
done
finish
