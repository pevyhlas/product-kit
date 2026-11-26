#!/usr/bin/env bash
# shellcheck disable=SC2016 # Literal Markdown in assertions and sed patterns.
# Synthetic, NONAUTHORITATIVE host/input regressions. Never use a live host or key.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TESTS_DIR/review-package-fixtures.sh"
STATUS=0; OUTPUT=""; PKG=""

setup() {
    P="$(make_inited_project)" || exit 1
    track_tmp "$P"; cd "$P" || exit 1
    printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n| security | reviewer |\n| design | reviewer |\n' >> .prdkit/memory/agents.md
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
}
setup_small() {
    P="$(make_inited_project)" || exit 1
    track_tmp "$P"; cd "$P" || exit 1
    ID=001-small
    package_small_obligation_fixture "$ID" || exit 1
    BASE="$(git rev-parse HEAD^)"
}
advance() { printf '%s\n' "$1" >> src/app.txt; git add src/app.txt; git commit -qm "$1" || exit 1; }
build() {
    run bash "$BUILD" "$ID" "$BASE" "$@"
    if [ "$STATUS" != 0 ]; then _no 'package assembly' "$OUTPUT"; PKG=""; return 1; fi
    PKG="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
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

default_reads() { awk '/^## Open first/{ open=1; next } /^## /{ open=0 } open && /^[0-9]+\. /' "$PKG/index.md"; }
reject_reserved() {
    local path="$1"; shift
    run bash "$BUILD" "$ID" "$BASE" "$@" --evidence "$path"
    assert_eq 1 "$STATUS" "refuse ordinary reserved evidence: $path ($*)"
    assert_contains "$OUTPUT" "conflicting --evidence $path"
}

[ "$#" -gt 0 ] || set -- context paths facts obligations
for mode in "$@"; do
    if [ "$mode" = obligations ]; then setup_small; else setup; fi
    # The default exercises installed behavior; the override supports replay against a prior builder.
    BUILD="${PACKAGE_TEST_BUILDER:-$P/.prdkit/scripts/bash/build-review-package.sh}"
    case "$mode" in
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
        facts)
            it "Only copied facts get a spot in the default reading list"
            if build; then
                assert_eq 2 "$(default_reads | wc -l | tr -d ' ')" 'diff and obligations without facts'
                assert_contains "$(default_reads)" '2. `index.md`, [Review obligations]'
                assert_not_contains "$(default_reads)" 'evidence/facts/'
                assert_eq absent "$([ -e "$PKG/evidence/facts" ] || echo absent)"
                assert_contains "$(cat "$PKG/index.md")" '## Open only if a finding needs it'
            fi
            cache=".prdkit/cache/evidence/$ID/facts"
            mkdir -p "$cache" proof
            printf 'Example summary\n' > "$cache/summary.md"
            run bash "$BUILD" "$ID" "$BASE" --facts
            assert_eq 1 "$STATUS" 'a partial pair cannot be attached'
            assert_contains "$OUTPUT" "$cache/index.json"
            printf 'Example index\n' > "$cache/index.json"
            printf 'Other evidence\n' > proof/result.txt
            printf 'Conflicting leaf\n' > facts
            reject_reserved facts
            reject_reserved facts --facts
            rm facts; mkdir facts
            printf 'Conflicting evidence\n' > facts/summary.md
            reject_reserved facts/summary.md
            reject_reserved facts/summary.md --facts
            reject_reserved Facts/summary.md
            if build --facts --evidence proof/result.txt; then
                assert_eq 2 "$(jq .ROUND <<<"$OUTPUT")" 'validation failures do not allocate a round'
                assert_eq $'diff.patch\nevidence/facts/summary.md\nindex.md' \
                    "$(default_reads | sed -e 's/^[0-9][0-9]*\. \[\([^]]*\)\].*/\1/' -e 's/^[0-9][0-9]*\. `\([^`]*\)`.*/\1/')" \
                    'exact default read order'
                assert_contains "$(cat "$PKG/index.md")" 'no other file is a default read'
                assert_file "$PKG/evidence/proof/result.txt"
                assert_file "$PKG/bounds.txt"
                assert_file "$PKG/bounds-inputs.tsv"
                assert_contains "$(cat "$PKG/context-manifest.tsv")" 'trusted default-branch policy'
                for name in summary.md index.json; do
                    assert_file "$PKG/evidence/facts/$name"
                    assert_contains "$(cat "$PKG/manifest.tsv")" "caller-supplied:$cache/$name"
                done
                integrity
            fi ;;
        obligations)
            it "The one-line installed fixture exposes each unchanged requirement in a default read"
            assert_eq label.txt "$(git diff --name-only "$BASE" HEAD)"
            assert_eq $'1\t1\tlabel.txt' "$(git diff --numstat "$BASE" HEAD)"
            run env PRDKIT_TODAY=2026-01-02 bash .prdkit/scripts/bash/facts.sh "$ID" --base "$BASE"
            assert_eq 0 "$STATUS" "$OUTPUT"
            if build --facts; then
                assert_contains "$(default_reads)" '3. `index.md`, [Review obligations]' 'required default read'
                section="$(sed -n '/^## Review obligations$/,/^## Open only if/p' "$PKG/index.md")"
                assert_contains "$section" 'Acceptance: Preserve the exported public label.'
                assert_contains "$section" 'Release-label edits require the application smoke check.'
                assert_contains "$section" 'Keep the published label stable for automated clients.'
                assert_contains "$section" '**Rigor**: full'
                assert_contains "$section" "Source: specs/changes/$ID.md:"
                assert_contains "$section" 'Source: .prdkit/memory/constitution.md:'
                assert_contains "$section" 'Source: specs/product/constraints.md:'
                assert_contains "$section" '### Unresolved context and verification'
                assert_contains "$section" 'caller-supplied evidence requires revision/result/applicability verification'
                assert_not_contains "$section" '**Required full context:**'
                integrity
            fi

            it "Combined overflow retains all source artifacts and explicitly requires reading them"
            for file in first.md second.md; do
                awk -v label="$file" 'BEGIN {
                    print "EXPLICIT_START " label
                    for (i=0;i<240;i++) print "A selected obligation with a long body."
                    print "EXPLICIT_END " label
                }' > "$file"
            done
            git add first.md second.md; git commit -qm 'add two long explicit obligations'
            if build --context first.md; then
                assert_not_contains "$(cat "$PKG/index.md")" '**Required full context:**'
                assert_contains "$(cat "$PKG/index.md")" 'EXPLICIT_END first.md'
            fi
            if build --context first.md --context second.md; then
                section="$(sed -n '/^## Review obligations$/,/^## Open only if/p' "$PKG/index.md")"
                assert_contains "$section" 'captured obligations exceed the 16384-byte inline cap'
                assert_contains "$section" 'No partial obligation list is shown'
                assert_contains "$section" '[context-manifest.tsv](context-manifest.tsv)'
                assert_contains "$section" '[context-gaps.txt](context-gaps.txt)'
                assert_not_contains "$section" 'Preserve the exported public label'
                assert_not_contains "$section" EXPLICIT_START
                assert_not_contains "$section" EXPLICIT_END
                for file in first.md second.md; do
                    assert_contains "$(cat "$PKG/context-manifest.tsv")" "context/$file"
                    run cmp "$file" "$PKG/context/$file"
                    assert_eq 0 "$STATUS" 'full source is still present'
                done
            fi ;;
        *) echo "unknown fixture group: $mode" >&2; exit 2 ;;
    esac
done
finish
