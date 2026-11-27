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
    package_small_obligation_fixture "$ID" "${1:-}" || exit 1
    BASE="$(git rev-parse HEAD^)"
}
setup_no_specs() {
    P="$(make_inited_project)" || exit 1
    track_tmp "$P"; cd "$P" || exit 1
    ID=001-no-specs
    rm -f .prdkit/memory/config.md .prdkit/memory/agents.md
    mkdir src
    printf 'before\n' > src/app.txt
    snapshot_upgrade_fixture "$P" || exit 1
    BASE="$(git rev-parse HEAD)"
    git checkout -qb "$ID" || exit 1
    advance after
}
advance() { printf '%s\n' "$1" >> src/app.txt; git add src/app.txt; git commit -qm "$1" || exit 1; }
build() {
    run bash "$BUILD" "$ID" "$BASE" "$@"
    if [ "$STATUS" != 0 ]; then _no 'package assembly' "$OUTPUT"; PKG=""; return 1; fi
    if ! PKG="$(printf '%s' "$OUTPUT" | jq -er .PACKAGE_DIR)"; then
        _no 'package JSON' "$OUTPUT"; return 1
    fi
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
default_read_paths() { default_reads | sed -e 's/^[0-9][0-9]*\. \[\([^]]*\)\].*/\1/' -e 's/^[0-9][0-9]*\. `\([^`]*\)`.*/\1/'; }
obligations_section() {
    sed -n '/^## Review obligations$/,/^## Evidence status/p' "$PKG/index.md"
    if [ -f "$PKG/obligations.md" ]; then cat "$PKG/obligations.md"; fi
}
non_verification_gaps() { sed '/^verification /d' "$PKG/context-gaps.txt"; }
released_context_retained() { # opt-in with a local v3.2.0 builder; named exceptions follow
    [ -n "${PACKAGE_TEST_REFERENCE_BUILDER:-}" ] || return 0
    local old artifact row found tab=$'\t' gap source
    run bash "$PACKAGE_TEST_REFERENCE_BUILDER" "$ID" "$BASE" "$@"
    assert_eq 0 "$STATUS" "released builder: $OUTPUT" || return 1
    old="$(printf '%s' "$OUTPUT" | jq -er .PACKAGE_DIR)" || return 1
    while IFS="$tab" read -r artifact row; do
        case "$artifact" in artifact|-) continue ;; esac
        found="$(ROW="$row" awk 'substr($0,index($0,"\t")+1)==ENVIRON["ROW"] { print $1; exit }' "$PKG/context-manifest.tsv")"
        if [ -n "$found" ] && cmp -s "$old/$artifact" "$PKG/$found"; then
            _ok 'released excerpt retained with exact provenance and bytes'
        else
            _no 'released excerpt retained with exact provenance and bytes' "$row"
        fi
    done < "$old/context-manifest.tsv"
    while IFS= read -r gap; do
        case "$gap" in
            'bounds unresolved BASE obligation: BASE bounds unavailable; inspect bounds-base.stderr')
                if [ "$(cat "$old/bounds-base.stderr")" = 'No spec files under specs/' ]; then continue; fi ;;
            'bounds bounds unavailable; inspect bounds.stderr')
                if [ "$(cat "$PKG/bounds.txt" 2>/dev/null)" = 'No spec bounds apply at this revision.' ] &&
                    { [ ! -e "$old/bounds.stderr" ] || [ "$(cat "$old/bounds.stderr")" = 'No spec files under specs/' ]; }; then continue; fi ;;
            'canon missing/unsafe/unreadable context '*| 'policy missing/unsafe/unreadable context '*)
                case "${gap#* context }" in
                    *:specs/product.md|*:specs/architecture.md|*:.prdkit/memory/agents.md|*:.prdkit/memory/config.md)
                        source="${gap#* context }"
                        found="$(git ls-tree "${source%%:*}" -- ":(literal)${source#*:}")" || found=unreadable
                        [ -n "$found" ] || continue ;;
                esac ;;
        esac
        if grep -Fxq -- "$gap" "$PKG/context-gaps.txt"; then _ok 'released gap retained'
        else _no 'released gap retained' "$gap"; fi
    done < "$old/context-gaps.txt"
}
reject_reserved() {
    local path="$1"; shift
    run bash "$BUILD" "$ID" "$BASE" "$@" --evidence "$path"
    assert_eq 1 "$STATUS" "refuse ordinary reserved evidence: $path ($*)"
    assert_contains "$OUTPUT" "conflicting --evidence $path"
}

[ "$#" -gt 0 ] || set -- context paths facts lean obligations no-specs empty-endpoints merged-history reconcile references reference-style plain-brackets edge-blanks nontext
for mode in "$@"; do
    case "$mode" in
        obligations|reconcile|references|reference-style|plain-brackets|edge-blanks|nontext) setup_small ;;
        lean) setup_small installed-policy ;;
        no-specs|empty-endpoints|merged-history) setup_no_specs ;;
        *) setup ;;
    esac
    # The default exercises installed behavior; the override supports replay against a prior builder.
    BUILD="${PACKAGE_TEST_BUILDER:-$P/.prdkit/scripts/bash/build-review-package.sh}"
    case "$mode" in
        no-specs)
            no_specs='No spec files at BASE or HEAD; no spec bounds apply.'
            it "A small committed change without specs or scope stays lean but does not claim absent bounds"
            assert_eq absent "$([ -e specs ] && echo present || echo absent)" 'no specs directory in fixture'
            # Untracked specs are not an input on either revision.
            mkdir -p specs
            printf '# Untracked\n' > specs/product.md
            if build; then
                section="$(obligations_section)"
                assert_not_contains "$section" "$no_specs"
                assert_contains "$section" 'HEAD bounds are unavailable'
                assert_not_contains "$section" '**Required full context:**'
                assert_not_contains "$section" 'mark the review pending'
                assert_eq $'diff.patch\nindex.md' "$(default_read_paths)" 'missing scope and unavailable bounds stay inline'
                assert_contains "$(non_verification_gaps)" "child actual child record missing or unrecoverable: specs/changes/$ID.md"
                assert_eq unavailable "$(cat "$PKG/bounds-status.txt")"
                assert_eq '' "$(cat "$PKG/bounds.txt")"
                assert_eq '' "$(awk -F '\t' '$3 ~ /^specs\// {print}' "$PKG/context-manifest.tsv")" 'no spec obligations'
                assert_contains "$(cat "$PKG/context-manifest.tsv")" '.prdkit/memory/constitution.md' 'required trusted policy remains'
                integrity
                released_context_retained
            fi

            it "Adding the first spec includes its canon as proposed and retains the missing scope warning"
            printf '# Product\n\n- **C-01 New bound**: Scope: all.\n  Keep the public label.\n' > specs/product.md
            git add specs/product.md && git commit -qm 'add first spec' || exit 1
            if build; then
                section="$(obligations_section)"
                assert_not_contains "$section" "$no_specs"
                assert_not_contains "$section" '**Required full context:**'
                assert_contains "$section" 'Canon (specs/product.md) — Proposed by this change'
                assert_contains "$section" 'Keep the public label.'
                assert_not_contains "$section" 'C-01 — BASE'
                assert_contains "$(cat "$PKG/bounds-base.txt")" 'No spec bounds apply at this revision.'
                assert_contains "$(non_verification_gaps)" 'child actual child record missing or unrecoverable:'
                assert_contains "$(non_verification_gaps)" 'bounds bounds unavailable; inspect bounds.stderr'
                assert_not_contains "$(non_verification_gaps)" 'unresolved BASE obligation'
                released_context_retained
            fi

            it "Deleting the last spec keeps its BASE canon and bounds for review"
            BASE="$(git rev-parse HEAD)"
            git rm -q specs/product.md && git commit -qm 'remove last spec' || exit 1
            if build; then
                section="$(obligations_section)"
                assert_not_contains "$section" "$no_specs"
                assert_not_contains "$section" '**Required full context:**'
                assert_contains "$section" 'C-01 — BASE, removed by this change'
                assert_contains "$section" 'Canon (specs/product.md) — BASE, removed by this change'
                assert_contains "$section" 'Keep the public label.'
                assert_eq unavailable "$(cat "$PKG/bounds-status.txt")"
                assert_contains "$(non_verification_gaps)" 'child actual child record missing or unrecoverable:'
                assert_contains "$(non_verification_gaps)" 'bounds unavailable'
                assert_not_contains "$(non_verification_gaps)" 'canon missing/unsafe/unreadable context'
                released_context_retained
            fi

            it "An unreadable committed BASE spec does not count as absent"
            shim="$(mktemp -d)"; track_tmp "$shim"
            export FIXTURE_GIT FIXTURE_UNREADABLE
            FIXTURE_GIT="$(command -v git)"
            FIXTURE_UNREADABLE="$(git rev-parse "$BASE:specs/product.md")"
            cat > "$shim/git" <<'EOF'
#!/usr/bin/env bash
if [ "${3:-}" = cat-file ] && [ "${4:-}" = blob ] && [ "${5:-}" = "$FIXTURE_UNREADABLE" ]; then
    exit 1
fi
exec "$FIXTURE_GIT" "$@"
EOF
            chmod +x "$shim/git"
            if PATH="$shim:$PATH" build --evidence src/app.txt; then
                section="$(obligations_section)"
                assert_not_contains "$section" "$no_specs"
                assert_contains "$section" '**Required full context:** A BASE obligation could not be resolved.'
                assert_contains "$(cat "$PKG/context-gaps.txt")" 'canon unresolved BASE obligation: unreadable/non-text input specs/product.md'
                assert_not_contains "$(cat "$PKG/bounds-base.txt")" 'No spec bounds apply'
            fi

            it "A committed non-text HEAD spec is a gap, not a no-specs package"
            mkdir -p specs
            printf 'not\000text\n' > specs/product.md
            git add specs/product.md && git commit -qm 'unreadable spec at HEAD' || exit 1
            if build; then
                section="$(obligations_section)"
                assert_not_contains "$section" "$no_specs"
                assert_contains "$section" 'C-01 — BASE, binding for this review'
                assert_contains "$section" 'Canon (specs/product.md) — BASE, binding for this review'
                assert_contains "$(non_verification_gaps)" 'canon unreadable/non-text input specs/product.md'
                assert_not_contains "$(cat "$PKG"/bounds*.txt)" 'No spec bounds apply'
            fi

            it "Failure to enumerate the BASE tree is not proof of no specs"
            BASE="$(git rev-parse HEAD^)"
            cat > "$shim/git" <<'EOF'
#!/usr/bin/env bash
if [ "${3:-}" = ls-tree ] && [ "${4:-}" = -r ] && [ "${7:-}" = "$FIXTURE_BASE" ]; then
    exit 1
fi
exec "$FIXTURE_GIT" "$@"
EOF
            if FIXTURE_BASE="$BASE" PATH="$shim:$PATH" build --evidence src/app.txt; then
                assert_not_contains "$(obligations_section)" "$no_specs"
                assert_contains "$(obligations_section)" '**Required full context:** A BASE obligation could not be resolved.'
                assert_contains "$(non_verification_gaps)" 'canon unresolved BASE obligation: cannot completely enumerate spec entries'
            fi ;;
        empty-endpoints)
            record="specs/changes/$ID.md"
            it "Closing with two spec-free endpoints keeps historical scope and references, not endpoint bounds"
            mkdir -p specs/changes
            printf '# Product\n\n## Contract\n\nHistorical contract body.\n' > specs/product.md
            printf '# Change\n\n**Tier**: T1\n\n## Acceptance\n\nHistorical acceptance. See [contract](../product.md#contract).\n' > "$record"
            git add specs && git commit -qm 'open selected record' || exit 1
            historical="$(git rev-parse HEAD)"
            git rm -q "$record" specs/product.md || exit 1
            advance 'close selected record'
            assert_eq '' "$(git ls-tree -r --name-only "$BASE" -- specs)" 'BASE has no specs'
            assert_eq '' "$(git ls-tree -r --name-only HEAD -- specs)" 'HEAD has no specs'
            if build; then
                section="$(obligations_section)"
                assert_contains "$section" 'No spec files at BASE or HEAD; no spec bounds apply.'
                assert_contains "$section" 'Historical child record — scope evidence only, not a substitute for BASE'
                assert_contains "$section" 'Historical acceptance.'
                assert_contains "$section" 'Historical contract body.'
                assert_contains "$(cat "$PKG/context-manifest.tsv")" "$historical"$'\t'"$record"
                assert_eq '' "$(non_verification_gaps)" 'clean history requires no extra reads'
                assert_not_contains "$section" '**Required full context:**'
                assert_contains "$(cat "$PKG/bounds.txt")" 'No spec bounds apply at this revision.'
                assert_contains "$(cat "$PKG/bounds-base.txt")" 'No spec bounds apply at this revision.'
                assert_contains "$(cat "$PKG/bounds-inputs.tsv")" "$record"$'\t'"$historical"
                released_context_retained
            fi

            it "A same-ID follow-up preserves the pre-deletion record and citations when BASE is the closure"
            mkdir -p specs/changes
            printf '# Product\n\n## Contract\n\nPre-BASE contract body.\n' > specs/product.md
            printf '# Change\n\n**Tier**: T1\n\n## Acceptance\n\nFollow-up scope. See [contract](../product.md#contract) and [missing](../missing.md#rule).\n' > "$record"
            git add specs && git commit -qm 'open record with resolved and unresolved links' || exit 1
            historical="$(git rev-parse HEAD)"
            git rm -q "$record" specs/product.md && git commit -qm 'close scope before follow-up' || exit 1
            BASE="$(git rev-parse HEAD)"
            git update-ref refs/remotes/origin/main "$BASE" || exit 1
            advance 'follow-up to the same ID'
            for style in full delta; do
                args=()
                [ "$style" != delta ] || args=(--since "$BASE")
                if build ${args[@]+"${args[@]}"}; then
                    assert_contains "$(obligations_section)" 'Historical child record — scope evidence only, not a substitute for BASE'
                    assert_contains "$(obligations_section)" 'Follow-up scope.'
                    assert_contains "$(obligations_section)" 'Pre-BASE contract body.'
                    assert_contains "$(non_verification_gaps)" "link missing/unsafe context $historical:specs/missing.md"
                    assert_not_contains "$(non_verification_gaps)" 'child actual child record missing or unrecoverable'
                    released_context_retained ${args[@]+"${args[@]}"}
                fi
            done

            it "A shallow clone keeps legacy recovery or the missing-child warning at the cutoff"
            for depth in 3 2; do
                shallow="$(mktemp -d)" || exit 1; track_tmp "$shallow"
                git clone -q --depth "$depth" --branch "$ID" "file://$P" "$shallow" || exit 1
                cd "$shallow" || exit 1
                git update-ref refs/remotes/origin/main "$BASE" &&
                    git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main || exit 1
                BUILD="${PACKAGE_TEST_BUILDER:-$shallow/.prdkit/scripts/bash/build-review-package.sh}"
                assert_eq true "$(git rev-parse --is-shallow-repository)"
                if build; then
                    if [ "$depth" = 3 ]; then
                        assert_contains "$(obligations_section)" 'Pre-BASE contract body.'
                        assert_contains "$(non_verification_gaps)" "link missing/unsafe context $historical:specs/missing.md"
                    else
                        assert_contains "$(non_verification_gaps)" "actual child record missing or unrecoverable: $record"
                        assert_not_contains "$(cat "$PKG/context-manifest.tsv")" 'child-historical'
                    fi
                    assert_not_contains "$(non_verification_gaps)" 'cannot inspect child record history'
                    released_context_retained
                fi
                cd "$P" || exit 1
            done
            BUILD="${PACKAGE_TEST_BUILDER:-$P/.prdkit/scripts/bash/build-review-package.sh}"

            it "A non-text historical child remains a gap with two spec-free endpoints"
            mkdir -p specs/changes
            printf '# Change\n\nUnreadable\000record.\n' > "$record"
            git add "$record" && git commit -qm 'record unreadable scope' || exit 1
            historical="$(git rev-parse HEAD)"
            git rm -q "$record" || exit 1
            advance 'close unreadable record'
            if build; then
                assert_not_contains "$(obligations_section)" 'No spec files at BASE or HEAD; no spec bounds apply.'
                assert_contains "$(non_verification_gaps)" "unreadable child record $historical:$record"
                assert_contains "$(non_verification_gaps)" 'bounds unavailable'
                released_context_retained
            fi

            it "A failed history lookup with empty endpoints remains a gap"
            shim="$(mktemp -d)"; track_tmp "$shim"
            export FIXTURE_GIT
            FIXTURE_GIT="$(command -v git)"
            cat > "$shim/git" <<'EOF'
#!/usr/bin/env bash
if [ "${3:-}" = log ] && [ "${4:-}" = -1 ] && [ "${5:-}" = --format=%H ]; then
    exit 1
fi
exec "$FIXTURE_GIT" "$@"
EOF
            chmod +x "$shim/git"
            if PATH="$shim:$PATH" build --evidence src/app.txt; then
                assert_contains "$(non_verification_gaps)" "child actual child record missing or unrecoverable: $record"
                assert_eq unavailable "$(cat "$PKG/bounds-status.txt")"
                PATH="$shim:$PATH" released_context_retained --evidence src/app.txt
            fi

            it "An empty bounds inventory does not bypass validation of a record header"
            mkdir -p specs/changes
            printf '# Change\n\n**Tier**: T1\n**Parts**: P1\n**Parts**: P2\n\n## Acceptance\n\nKeep the public label.\n' > "$record"
            git add "$record" && git commit -qm 'record ambiguous scope' || exit 1
            if build; then
                assert_contains "$(obligations_section)" 'Child record — Proposed by this change'
                assert_contains "$(non_verification_gaps)" 'bounds bounds unavailable; inspect bounds.stderr'
                assert_contains "$(cat "$PKG/bounds.stderr")" 'Duplicate Parts field'
                assert_not_contains "$(cat "$PKG/bounds.txt")" 'No spec bounds apply'
                released_context_retained
            fi
            BASE="$(git rev-parse HEAD)"
            advance 'change code with the same invalid scope'
            if build; then
                assert_contains "$(obligations_section)" '**Required full context:** A BASE obligation could not be resolved.'
                assert_contains "$(non_verification_gaps)" 'bounds unresolved BASE obligation: shared bounds unavailable'
                assert_contains "$(cat "$PKG/bounds-base.stderr")" 'Duplicate Parts field'
                assert_contains "$(cat "$PKG/bounds.stderr")" 'Duplicate Parts field'
                released_context_retained
            fi

            it "A historical-only record still validates its header without endpoint bounds"
            historical="$(git rev-parse HEAD)"
            BASE="$(git rev-parse "$BASE^")"
            git rm -q "$record" || exit 1
            advance 'close change with invalid scope'
            if build; then
                assert_not_contains "$(obligations_section)" 'No spec files at BASE or HEAD; no spec bounds apply.'
                assert_contains "$(obligations_section)" 'Historical child record — scope evidence only, not a substitute for BASE'
                assert_contains "$(non_verification_gaps)" 'bounds bounds unavailable; inspect bounds.stderr'
                assert_contains "$(cat "$PKG/bounds.stderr")" "$record:5: Duplicate Parts field"
                assert_contains "$(cat "$PKG/bounds-inputs.tsv")" "$record"$'\t'"$historical"
                assert_eq '' "$(cat "$PKG/bounds.txt")" 'diagnostic only; no HEAD bounds'
                assert_contains "$(cat "$PKG/bounds-base.txt")" 'No spec bounds apply at this revision.'
                released_context_retained
            fi ;;
        merged-history)
            record="specs/changes/$ID.md"
            it "A no-ff merge that prunes a closing record keeps the released missing-child warning"
            git checkout -qb closing "$BASE" || exit 1
            mkdir -p specs/changes
            printf '# Change\n\n**Tier**: T1\n\n## Acceptance\n\nMerged acceptance. See [contract](../missing.md#contract).\n' > "$record"
            git add "$record" && git commit -qm 'open selected record on side branch' || exit 1
            historical="$(git rev-parse HEAD)"
            git rm -q "$record" && git commit -qm 'close selected record on side branch' || exit 1
            git checkout -q "$ID" && git merge -q --no-ff -m 'merge closing branch' closing || exit 1
            merged_base="$(git rev-parse HEAD)"
            assert_eq "$BASE" "$(git merge-base origin/HEAD HEAD)" 'BASE is the trusted merge base'
            assert_eq '' "$(git ls-tree -r --name-only "$BASE" -- specs)" 'BASE has no specs'
            assert_eq '' "$(git ls-tree -r --name-only HEAD -- specs)" 'HEAD has no specs'
            assert_eq '' "$(git log -1 --format=%H HEAD -- "$record")" 'default path history prunes both record commits'
            if build; then
                assert_not_contains "$(obligations_section)" 'No spec files at BASE or HEAD; no spec bounds apply.'
                assert_contains "$(non_verification_gaps)" "child actual child record missing or unrecoverable: $record"
                assert_not_contains "$(cat "$PKG/context-manifest.tsv")" 'child-historical'
                assert_eq unavailable "$(cat "$PKG/bounds-status.txt")"
                released_context_retained
            fi

            it "The legacy lookup wins when incomparable closures include a first-parent record"
            git checkout -qb another-closing "$BASE" || exit 1
            mkdir -p specs/changes
            printf '# Another scope\n' > "$record"
            git add "$record" && git commit -qm 'open another record with the same path' || exit 1
            git rm -q "$record" && git commit -qm 'close the other record' || exit 1
            git checkout -qb both-closings closing && git merge -q --no-ff -m 'merge another closing branch' another-closing || exit 1
            if build; then
                assert_contains "$(obligations_section)" 'Merged acceptance.'
                assert_contains "$(cat "$PKG/context-manifest.tsv")" "$historical"$'\t'"$record"
                assert_contains "$(non_verification_gaps)" "link missing/unsafe context $historical:specs/missing.md"
                assert_not_contains "$(non_verification_gaps)" 'actual child record missing or unrecoverable'
                released_context_retained
            fi

            it "A same-ID follow-up keeps the released warning when trusted BASE already contains a merged closure"
            BASE="$merged_base"
            git checkout -q "$ID" && git update-ref refs/remotes/origin/main "$BASE" || exit 1
            advance 'follow up after the merged closure'
            assert_eq "$BASE" "$(git merge-base origin/HEAD HEAD)" 'merged closure is the trusted BASE'
            assert_eq '' "$(git log -1 --format=%H HEAD -- "$record")" 'default lookup is empty'
            assert_eq '' "$(git log --full-history --format=%H "$BASE..HEAD" -- "$record")" 'range misses older history'
            assert_contains "$(git log --full-history --format=%H "$BASE" -- "$record")" "$historical" 'pre-deletion commit is reachable from BASE'
            for style in full delta; do
                args=()
                [ "$style" != delta ] || args=(--since "$BASE")
                if build ${args[@]+"${args[@]}"}; then
                    assert_contains "$(non_verification_gaps)" "child actual child record missing or unrecoverable: $record"
                    assert_not_contains "$(cat "$PKG/context-manifest.tsv")" 'child-historical'
                    assert_not_contains "$(obligations_section)" 'No spec files at BASE or HEAD; no spec bounds apply.'
                    assert_not_contains "$(obligations_section)" '**Required full context:**'
                    released_context_retained ${args[@]+"${args[@]}"}
                fi
            done ;;
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
            git add specs/product; git commit -qm 'change Unicode path' || exit 1
            if build; then
                assert_contains "$(cat "$PKG/bounds.txt")" C-77 'Unicode file included in actual bounds'
                assert_eq collected "$(cat "$PKG/bounds-status.txt")"
            fi
            unsafe=$'specs/product/constraints/line\nbreak.md'
            printf '# Constraint\n\n- **C-78 Rejected path** — Scope: all parts.\n' > "$unsafe"
            git add specs/product; git commit -qm 'literal path controls' || exit 1
            if build; then
                assert_eq unavailable "$(cat "$PKG/bounds-status.txt")" 'incomplete canon is not complete bounds'
                assert_eq '' "$(cat "$PKG/bounds.txt")"
                assert_contains "$(cat "$PKG/bounds-inputs.tsv")" "$(git rev-parse HEAD:specs/product/constraints/é.md)" 'literal bounds input blob'
                assert_contains "$(cat "$PKG/context-manifest.tsv")" 'specs/product/constraints/é.md' 'literal source path provenance'
                assert_contains "$(find "$PKG" -type f -name '*.txt' -exec cat {} \;)" CHANGED_LITERAL_BODY 'changed literal canon supplied'
                assert_contains "$(cat "$PKG/context-gaps.txt")" 'unsafe spec input' 'unsupported control path has explicit rejection gap'
                integrity
            fi ;;
        facts)
            it "Only copied facts get a spot in the default reading list"
            if build; then
                assert_eq $'diff.patch\nindex.md' "$(default_read_paths)" 'diff and inline obligations without facts'
                assert_contains "$(default_reads)" '2. `index.md`, [Review obligations]'
                assert_not_contains "$(default_reads)" 'evidence/facts/'
                assert_eq absent "$([ -e "$PKG/evidence/facts" ] || echo absent)"
                assert_contains "$(cat "$PKG/index.md")" '## Open only if a finding needs it'
                assert_eq 1 "$(grep -Fc 'Exact-head CI: not collected' "$PKG/index.md")"
                assert_not_contains "$(cat "$PKG/context-gaps.txt")" 'CI'
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
            printf 'Conflicting nested leaf\n' > proof/Facts
            reject_reserved proof/Facts
            mkdir -p other third
            printf 'Cached CI note\n' > "${cache%/facts}/ci.md"
            printf 'Existing numbered note\n' > proof/CI-2.MD
            printf 'Second CI note\n' > other/ci.md
            printf 'Third CI note\n' > third/CI.md
            if build --facts --evidence proof/result.txt --evidence "${cache%/facts}/ci.md" \
                --evidence proof/CI-2.MD --evidence other/ci.md --evidence third/CI.md --evidence other/ci.md; then
                assert_eq 2 "$(jq .ROUND <<<"$OUTPUT")" 'validation failures do not allocate a round'
                assert_eq $'diff.patch\nevidence/facts/summary.md\nindex.md' "$(default_read_paths)" 'exact default read order'
                assert_contains "$(cat "$PKG/index.md")" 'no other file is a default read'
                assert_file "$PKG/evidence/result.txt"
                assert_eq absent "$([ -e "$PKG/evidence/.prdkit" ] && echo present || echo absent)"
                for mapping in "ci.md:${cache%/facts}/ci.md" 'CI-2.MD:proof/CI-2.MD' 'ci-3.md:other/ci.md' 'CI-4.md:third/CI.md'; do
                    name="${mapping%%:*}"; source="${mapping#*:}"
                    run cmp "$PKG/evidence/$name" "$source"
                    assert_eq 0 "$STATUS" "shallow copy of $source"
                    assert_eq "caller-supplied:$source (verify producer revision/result)" \
                        "$(awk -F '\t' -v path="evidence/$name" '$1 == path { print $4 }' "$PKG/manifest.tsv")"
                done
                assert_eq 1 "$(grep -Fc 'caller-supplied:other/ci.md ' "$PKG/manifest.tsv")" 'repeated source is copied once'
                assert_not_contains "$(cat "$PKG/index.md")" 'Exact-head CI: not collected'
                assert_contains "$(cat "$PKG/index.md")" 'Exact-head CI: see the facts summary'
                assert_not_contains "$(cat "$PKG/context-gaps.txt")" 'CI'
                assert_file "$PKG/bounds.txt"
                assert_file "$PKG/bounds-inputs.tsv"
                assert_contains "$(cat "$PKG/context-manifest.tsv")" 'trusted default-branch policy'
                for name in summary.md index.json; do
                    assert_file "$PKG/evidence/facts/$name"
                    assert_contains "$(cat "$PKG/manifest.tsv")" "caller-supplied:$cache/$name"
                done
                integrity
            fi

            it "Colliding 255-byte basenames preserve both bytes and original paths"
            long="$(awk 'BEGIN { for (i = 0; i < 252; i++) printf "a"; print ".md" }')"
            printf 'first long attachment\n' > "proof/$long"
            printf 'second long attachment\n' > "other/$long"
            # Occupy the first shortened name too; the next suffix must still fit and be unique.
            short="$(printf '%s' "$long" | git hash-object --stdin)"
            printf 'separate attachment\n' > "third/attachment-${short:0:8}-2"
            if build --evidence "third/attachment-${short:0:8}-2" --evidence "proof/$long" --evidence "other/$long"; then
                assert_eq 255 "$(printf '%s' "$long" | wc -c | tr -d ' ')" '255-byte fixture'
                for src in "proof/$long" "other/$long" "third/attachment-${short:0:8}-2"; do
                    row="$(awk -F '\t' -v p="caller-supplied:$src (verify producer revision/result)" '$4 == p { print $1 }' "$PKG/manifest.tsv")"
                    case "$src" in
                        proof/*) assert_eq "evidence/$long" "$row" ;;
                        other/*) assert_eq "evidence/attachment-${short:0:8}-3" "$row" ;;
                    esac
                    run cmp "$src" "$PKG/$row"
                    assert_eq 0 "$STATUS" "exact bytes for $row"
                done
                integrity
            fi ;;
        lean)
            it "One line of source change with installed policy stays below 4 KiB and four default reads"
            assert_eq $'1\t1\tlabel.txt' "$(git diff --numstat "$BASE" HEAD)"
            run env PRDKIT_TODAY=2026-01-02 bash .prdkit/scripts/bash/facts.sh "$ID" --base "$BASE"
            assert_eq 0 "$STATUS" "$OUTPUT"
            if build --facts; then
                bytes="$(wc -c < "$PKG/index.md")"
                if [ "$bytes" -le 4096 ]; then _ok "index is $bytes bytes"; else _no 'index exceeds 4 KiB' "$bytes"; fi
                assert_eq $'diff.patch\nevidence/facts/summary.md\nindex.md\nobligations.md' "$(default_read_paths)"
                assert_not_contains "$(cat "$PKG/index.md")" '**Required full context:**'
                assert_not_contains "$(cat "$PKG/index.md")" 'Release-label edits require the application smoke check.'
                assert_contains "$(cat "$PKG/obligations.md")" 'Release-label edits require the application smoke check.'
                assert_contains "$(cat "$PKG/obligations.md")" 'Acceptance: Preserve the exported public label.'
                assert_contains "$(cat "$PKG/obligations.md")" 'Keep the published label stable for automated clients.'
                assert_contains "$(cat "$PKG/obligations.md")" 'coordinator must verify the copied facts pair'
                assert_contains "$(cat "$PKG/manifest.tsv")" $'obligations.md\t'
                for source in .prdkit/memory/{constitution,agents,config}.md; do
                    artifact="$(awk -F '\t' -v p="$source" '$3 == p && $7 == "policy" {print $1}' "$PKG/context-manifest.tsv")"
                    run cmp "$PKG/$artifact" "$source"
                    assert_eq 0 "$STATUS" "trusted $source remains byte-exact"
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
                section="$(obligations_section)"
                assert_contains "$section" 'Acceptance: Preserve the exported public label.'
                assert_contains "$section" 'Release-label edits require the application smoke check.'
                assert_contains "$section" 'Keep the published label stable for automated clients.'
                assert_eq 1 "$(printf '%s\n' "$section" | grep -Fc 'Keep the published label stable for automated clients.')" 'unchanged bound appears once'
                assert_eq 1 "$(printf '%s\n' "$section" | grep -Fc 'Acceptance: Preserve the exported public label.')" 'unchanged acceptance appears once'
                assert_not_contains "$section" 'Proposed by this change'
                assert_contains "$section" '**Rigor**: full'
                assert_contains "$section" "Source: specs/changes/$ID.md:"
                assert_contains "$section" 'Source: .prdkit/memory/constitution.md:'
                assert_contains "$section" 'Source: specs/product/constraints.md:'
                assert_contains "$section" '### Unresolved context and verification'
                assert_contains "$section" 'coordinator must verify the copied facts pair'
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
                assert_contains "$(cat "$PKG/obligations.md")" 'EXPLICIT_END first.md'
            fi
            if build --context first.md --context second.md; then
                section="$(obligations_section)"
                assert_contains "$section" 'captured obligations exceed the 16384-byte excerpt cap'
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
        reconcile)
            it "Binding BASE acceptance and bounds remain visible before proposed replacements"
            printf '\n- **C-02 Removed bound**: Scope: all.\n  Retain the public alias.\n' >> specs/product/constraints.md
            git add specs/product/constraints.md; git commit -qm 'extend the binding fixture'
            BASE="$(git rev-parse HEAD)"
            git update-ref refs/remotes/origin/main "$BASE"
            printf 'revised label\n' > label.txt
            sed 's/Preserve the exported public label/Change the exported public label/' "specs/changes/$ID.md" > .git/record
            cp .git/record "specs/changes/$ID.md"
            printf '# Constraints\n\n- **C-01 Example bound**: Scope: all.\n  Label changes are allowed for automated clients.\n\n- **C-03 New bound**: Scope: all.\n  Document the alias.\n' > specs/product/constraints.md
            printf '\n- Proposed policy: smoke checks are optional.\n' >> .prdkit/memory/constitution.md
            git commit -qam 'relax an existing bound and acceptance, remove another and propose a new bound'
            binding='BASE, binding for this review'
            proposal='Proposed by this change — not yet an obligation; the reviewer must reconcile'
            removed='BASE, removed by this change — the reviewer must judge'
            if build; then
                section="$(obligations_section)"
                assert_contains "$section" "C-01 — $binding"
                assert_contains "$section" "C-01 — $proposal"
                assert_contains "$section" "C-02 — $removed"
                assert_contains "$section" "C-03 — $proposal"
                assert_not_contains "$section" "C-03 — $binding"
                assert_contains "$section" 'Retain the public alias.'
                assert_contains "$section" 'Document the alias.'
                assert_contains "$section" "Child record — $binding"
                assert_contains "$section" "Child record — $proposal"
                assert_contains "$section" 'Release-label edits require the application smoke check.'
                assert_not_contains "$section" 'smoke checks are optional'
                assert_eq $'Acceptance: Preserve the exported public label.\nAcceptance: Change the exported public label.\nKeep the published label stable for automated clients.\nLabel changes are allowed for automated clients.' \
                    "$(printf '%s\n' "$section" | sed -nE 's/^ +((Acceptance:|Keep the published|Label changes).*)/\1/p')" \
                    'base text is followed by the proposed text, without an unlabeled duplicate'
                assert_contains "$(cat "$PKG/bounds-base.txt")" C-02
                assert_not_contains "$(cat "$PKG/bounds-base.txt")" C-03
                assert_contains "$(cat "$PKG/bounds-base-inputs.tsv")" "$(git rev-parse "$BASE:specs/product/constraints.md")"
                integrity
            fi
            it "Deleting the child keeps BASE acceptance and the historical scope distinct"
            git rm -q "specs/changes/$ID.md"; git commit -qm 'remove proposed child record'
            if build; then
                section="$(obligations_section)"
                assert_contains "$section" "Child record — $removed"
                assert_contains "$section" 'Acceptance: Preserve the exported public label.'
                assert_contains "$section" 'Historical child record — scope evidence only, not a substitute for BASE'
                assert_contains "$(cat "$PKG/bounds-inputs.tsv")" "$(git rev-parse "HEAD^:specs/changes/$ID.md")"
            fi
            it "A new child record is proposed only and cannot scope away BASE bounds"
            ID=002-new
            mkdir -p specs/changes
            printf '# Change\n\n**Tier**: T1\n\n## Acceptance\n\nA new proposed expectation.\n' > "specs/changes/$ID.md"
            git add "specs/changes/$ID.md" && git commit -qm 'add a proposed child record' || exit 1
            if build; then
                section="$(obligations_section)"
                assert_contains "$section" "Child record — $proposal"
                assert_not_contains "$section" "Child record — $binding"
                assert_contains "$section" 'A new proposed expectation.'
                assert_contains "$section" 'Retain the public alias.'
                assert_contains "$(cat "$PKG/bounds-base.txt")" 'Bounds for every change'
            fi ;;
        references)
            it "Removing Parent and child references retains binding BASE obligations"
            record="specs/changes/$ID.md"
            parent=specs/changes/900-programme.md
            hold='Owner hold: Do not rename the legacy partner endpoint until integration signs off.'
            sed 's/\*\*Tier\*\*: T1/**Tier**: T1 · **Parent**: 900-programme/' "$record" > .git/record
            cp .git/record "$record"
            printf '\nR-11; [contract](../decisions/guidance.md#contract).\n' >> "$record"
            mkdir -p specs/decisions
            printf '# Guidance\n\n## Contract\n\nOriginal linked contract.\n' > specs/decisions/guidance.md
            printf '# Rules\n\n- **R-11 Rule**: Original cited rule.\n- **R-12 Rule**: Parent-only cited rule.\n' > specs/decisions/rules.md
            printf '# Design\n\nOriginal design direction.\n' > specs/design.md
            printf 'Original requested context.\n' > requested.txt
            cat > "$parent" <<'EOF'
# Programme

## Outcome checkpoint

Follow the published target before expanding visibility.

## Children

| Child | Outcome |
|---|---|
| 001-small | Keep the public contract. |
| 002-unrelated | Not a selected obligation. |

## Holds and lane limits

Owner hold: Do not rename the legacy partner endpoint until integration signs off.
R-12; [parent terms](#parent-terms).

## Parent terms

Original linked parent terms.
EOF
            git add specs requested.txt && git commit -qm 'binding parent, references and targets' || exit 1
            BASE="$(git rev-parse HEAD)"
            git update-ref refs/remotes/origin/main "$BASE"
            parent_blob="$(git rev-parse "$BASE:$parent")"
            sed '/^R-11;/d; s/Parent\*\*: 900-programme/Parent**: —/' "$record" > .git/record
            cp .git/record "$record"
            printf 'revised label\n' > label.txt
            printf 'Proposed requested context.\n' > requested.txt
            git rm -q specs/design.md
            git commit -qam 'remove parent reference and change the label' || exit 1
            if build --context requested.txt; then
                section="$(obligations_section)"
                assert_not_contains "$section" '**Required full context:**'
                assert_contains "$section" "$hold"
                assert_not_contains "$(cat "$PKG/diff.patch")" "$hold" 'hold can only come from committed BASE context'
                assert_contains "$section" 'Follow the published target before expanding visibility.'
                assert_contains "$section" 'Keep the public contract.'
                assert_contains "$section" '| Child | Outcome |'
                assert_not_contains "$section" 'Not a selected obligation.'
                assert_contains "$section" 'Original cited rule.'
                assert_contains "$section" 'Parent-only cited rule.'
                assert_contains "$section" 'Original linked contract.'
                assert_contains "$section" 'Original linked parent terms.'
                assert_contains "$section" 'Original design direction.'
                assert_contains "$section" 'Canon (specs/design.md) — BASE, removed by this change'
                assert_contains "$section" 'Explicit context (requested.txt) — BASE, binding for this review'
                assert_contains "$section" 'Explicit context (requested.txt) — Proposed by this change'
                assert_eq 'Proposed requested context.' "$(cat "$PKG/context/requested.txt")" 'explicit HEAD snapshot unchanged'
                assert_contains "$section" 'Parent obligation (900-programme): Holds and lane limits — BASE, removed by this change'
                assert_contains "$(cat "$PKG/context-manifest.tsv")" "$BASE"$'\t'"$parent"$'\t'"$parent_blob"
            fi

            it "A worktree symlink cannot mask the unchanged BASE parent object"
            rm "$parent"
            ln -s "$ID.md" "$parent"
            if build --context requested.txt; then
                section="$(obligations_section)"
                assert_contains "$section" "$hold"
                assert_not_contains "$section" '**Required full context:**'
                assert_contains "$(cat "$PKG/context-manifest.tsv")" "$BASE"$'\t'"$parent"$'\t'"$parent_blob"
            fi
            rm "$parent"
            git show "$BASE:$parent" > "$parent"

            it "Keeping references compares their targets at both revisions"
            git show "$BASE:$record" > "$record"
            git show "$BASE:$parent" | sed 's/until integration signs off/without integration sign-off/' > "$parent"
            sed 's/Original linked contract/Proposed linked contract/' specs/decisions/guidance.md > .git/guidance
            cp .git/guidance specs/decisions/guidance.md
            git commit -qam 'change parent hold and linked contract in place' || exit 1
            if build; then
                section="$(obligations_section)"
                assert_contains "$section" 'Parent outcome checkpoint (900-programme) — unchanged from BASE'
                assert_contains "$section" 'Parent obligation (900-programme): Holds and lane limits — BASE, binding for this review'
                assert_contains "$section" 'Parent obligation (900-programme): Holds and lane limits — Proposed by this change'
                assert_contains "$section" 'Linked context (specs/decisions/guidance.md#contract) — BASE, binding for this review'
                assert_contains "$section" 'Linked context (specs/decisions/guidance.md#contract) — Proposed by this change'
                assert_contains "$section" 'Proposed linked contract.'
                assert_eq 1 "$(printf '%s\n' "$section" | grep -Fc 'Follow the published target')" 'unchanged checkpoint only once'
            fi

            it "A blocked HEAD parent leaves its BASE hold unresolved, not removed"
            previous="$(git rev-parse HEAD)"
            shim="$(mktemp -d)"; track_tmp "$shim"
            {
                printf '#!/usr/bin/env bash\nreal=%q\n' "$(command -v mkdir)"
                cat <<'EOF'
"$real" "$@" || exit
case "$1" in
    */material/specs/changes) ln -s 001-small.md "$1/900-programme.md" ;;
esac
EOF
            } > "$shim/mkdir"
            {
                printf '#!/usr/bin/env bash\nreal=%q\nblocked=%q\ntrace=%q\n' \
                    "$(command -v git)" "$(git rev-parse "HEAD:$parent")" "$shim/blocked-blob-opens"
                cat <<'EOF'
if [ "${3:-}" = cat-file ] && [ "${4:-}" = blob ] && [ "${5:-}" = "$blocked" ]; then
    printf 'opened blocked HEAD parent\n' >> "$trace"
fi
exec "$real" "$@"
EOF
            } > "$shim/git"
            chmod +x "$shim/mkdir" "$shim/git"
            if PATH="$shim:$PATH" build; then
                assert_eq unavailable "$(cat "$PKG/bounds-status.txt")"
                assert_contains "$(non_verification_gaps)" 'HEAD references unresolved'
                assert_contains "$(cat "$PKG/context-manifest.tsv")" \
                    $'\treference-base\tParent obligation (900-programme): Holds and lane limits'
                assert_not_contains "$(cat "$PKG/context-manifest.tsv")" \
                    $'\treference-removed\tParent obligation (900-programme)'
                assert_contains "$(obligations_section)" "$hold"
                assert_eq '' "$([ ! -e "$shim/blocked-blob-opens" ] || cat "$shim/blocked-blob-opens")"
            fi

            it "An unsafe HEAD parent cannot be opened even when its child was captured"
            rm "$parent" && ln -s "$ID.md" "$parent" && git add "$parent" &&
                git commit -qm 'replace retained parent with symlink' || exit 1
            if build; then
                assert_contains "$(non_verification_gaps)" "missing/unsafe parent $(git rev-parse HEAD):$parent"
                assert_contains "$(cat "$PKG/context-manifest.tsv")" \
                    $'\treference-base\tParent obligation (900-programme): Holds and lane limits'
                assert_not_contains "$(cat "$PKG/context-manifest.tsv")" \
                    $'\treference-removed\tParent obligation (900-programme)'
                assert_contains "$(obligations_section)" "$hold"
            fi
            git checkout -q "$previous" || exit 1

            it "An unresolved BASE reference requires full context even after HEAD drops it"
            git rm -q "$parent" specs/decisions/guidance.md
            printf '\nR-99.\n' >> "$record"
            git commit -qam 'binding references to unavailable targets' || exit 1
            BASE="$(git rev-parse HEAD)"
            git update-ref refs/remotes/origin/main "$BASE"
            sed '/^R-/d; s/Parent\*\*: 900-programme/Parent**: —/' "$record" > .git/record
            cp .git/record "$record"
            git commit -qam 'remove unresolved references from candidate' || exit 1
            if build; then
                section="$(obligations_section)"
                gaps="$(cat "$PKG/context-gaps.txt")"
                assert_contains "$section" '**Required full context:** A BASE obligation could not be resolved.'
                assert_not_contains "$section" 'Preserve the exported public label'
                assert_contains "$gaps" "parent unresolved BASE obligation: missing/unsafe parent $BASE:$parent"
                assert_contains "$gaps" "unresolved BASE obligation: missing/unsafe context $BASE:specs/decisions/guidance.md"
                assert_contains "$gaps" "unresolved BASE obligation: missing/ambiguous spec ID R-99 at $BASE"
            fi ;;
        reference-style)
            it "The dropped BASE parent retains its reference-style upstream readiness gate"
            record="specs/changes/$ID.md"
            parent=specs/changes/900-programme.md
            upstream=specs/changes/901-upstream.md
            hold='Do not rename the customer-facing endpoint until the upstream cutover is signed off.'
            sed 's/\*\*Tier\*\*: T1/**Tier**: T1 · **Parent**: 900-programme/' "$record" > .git/record
            cp .git/record "$record"
            cat > "$parent" <<'EOF'
# Programme

## Outcome checkpoint

Keep the endpoint transition compatible.

## Children

| Child | Outcome |
|---|---|
| 001-small | Preserve the published contract. |

## Dependencies

The readiness gate for [the upstream change][upstream-ready] applies.

## References

[upstream-ready]: 901-upstream.md#readiness
EOF
            printf '# Upstream change\n\n## Readiness\n\n%s\n' "$hold" > "$upstream"
            git add specs && git commit -qm 'establish ordinary Markdown reference-style dependency' || exit 1
            BASE="$(git rev-parse HEAD)"
            git update-ref refs/remotes/origin/main "$BASE"
            sed 's/Parent\*\*: 900-programme/Parent**: —/' "$record" > .git/record
            cp .git/record "$record"
            printf 'endpoint renamed\n' > label.txt
            git commit -qam 'detach the child and rename the endpoint' || exit 1
            if build; then
                section="$(obligations_section)"
                assert_contains "$section" 'Linked context (specs/changes/901-upstream.md#readiness) — BASE, removed by this change'
                assert_contains "$section" "$hold"
                assert_contains "$(cat "$PKG/context-manifest.tsv")" "$BASE"$'\t'"$upstream"$'\t'"$(git rev-parse "$BASE:$upstream")"
                assert_not_contains "$(cat "$PKG/diff.patch")" "$hold"
                assert_not_contains "$section" '**Required full context:**'
            fi

            it "Shortcut and collapsed references normalize case and whitespace and use each revision's definitions"
            git checkout -qb reference-forms "$BASE" || exit 1
            sed '/^The readiness gate/,$d' "$parent" > .git/parent
            cp .git/parent "$parent"
            cat >> "$parent" <<'EOF'
The [ UpStream   Ready ] gate and [STRASSE   Check][] apply.
The [multiline reference][Multi
 Word] also applies.
The `code [not-a-reference]` and \[literal] are not references.
<!-- [comment] -->

~~~md
[example]: missing.md#ignored
[Not an obligation]
~~~

````md
```
[Also not an obligation]
````

## References

[upstream ready]: 901-upstream.md#readiness
[UPSTREAM READY]: 901-upstream.md#unused
[Straße Check]:
  <901-upstream.md#rollback>
> [Multi   Word]: 901-upstream.md#schedule
[unused]: missing.md#ignored
EOF
            printf '\n## Rollback\n\nKeep the previous route ready.\n\n## Schedule\n\nKeep the rollout window.\n' >> "$upstream"
            git commit -qam 'establish shortcut and collapsed bindings' || exit 1
            BASE="$(git rev-parse HEAD)"
            git update-ref refs/remotes/origin/main "$BASE"
            sed 's@901-upstream.md#readiness@902-new.md#readiness@' "$parent" > .git/parent
            cp .git/parent "$parent"
            printf '# Another dependency\n\n## Readiness\n\nProposed readiness replacement.\n' > specs/changes/902-new.md
            git add specs && git commit -qm 'retarget only the shortcut definition' || exit 1
            if build; then
                section="$(obligations_section)"
                assert_contains "$section" 'Linked context (specs/changes/901-upstream.md#readiness) — BASE, removed by this change'
                assert_contains "$section" 'Linked context (specs/changes/902-new.md#readiness) — Proposed by this change'
                assert_contains "$section" 'Linked context (specs/changes/901-upstream.md#rollback) — unchanged from BASE'
                assert_contains "$section" 'Linked context (specs/changes/901-upstream.md#schedule) — unchanged from BASE'
                assert_contains "$section" 'Keep the previous route ready.'
                assert_contains "$section" 'Proposed readiness replacement.'
                assert_not_contains "$section" '**Required full context:**'
                assert_eq 'verification no verification evidence supplied; dispatch pending' "$(cat "$PKG/context-gaps.txt")" 'unused, escaped, fenced or duplicate markup does not create gaps'
            fi

            it "An undefined label at a selected HEAD usage forces full context with the usage location"
            sed 's/\[Multi   Word\]:/[Something Else]:/' "$parent" > .git/parent
            cp .git/parent "$parent"
            git commit -qam 'drop a definition at HEAD' || exit 1
            if build; then
                section="$(obligations_section)"
                use_line="$(awk '/\[multiline reference\]/ { print NR }' "$parent")"
                assert_contains "$section" '**Required full context:** A reference label is undefined.'
                assert_not_contains "$section" 'Preserve the exported public label'
                assert_contains "$(cat "$PKG/context-gaps.txt")" "undefined reference label multi\\ word at $(git rev-parse HEAD):$parent:$use_line"
            fi

            it "HEAD cannot erase an undefined BASE collapsed reference by detaching the child"
            git checkout -qb undefined-collapsed "$BASE" || exit 1
            sed 's/\[STRASSE   Check\]\[\]/[unbound-collapsed][]/' "$parent" > .git/parent
            cp .git/parent "$parent"
            git commit -qam 'establish a parent with an unresolved collapsed reference' || exit 1
            BASE="$(git rev-parse HEAD)"
            git update-ref refs/remotes/origin/main "$BASE"
            sed 's/Parent\*\*: 900-programme/Parent**: —/' "$record" > .git/record
            cp .git/record "$record"
            git commit -qam 'remove the parent reference' || exit 1
            if build; then
                section="$(obligations_section)"
                use_line="$(awk '/\[unbound-collapsed\]/ { print NR }' "$parent")"
                assert_contains "$section" '**Required full context:** A BASE obligation could not be resolved.'
                assert_contains "$(cat "$PKG/context-gaps.txt")" "unresolved BASE obligation: undefined reference label unbound-collapsed at $BASE:$parent:$use_line"
            fi ;;
        plain-brackets)
            it "Undefined bare brackets in child prose do not suppress inline BASE obligations"
            record="specs/changes/$ID.md"
            prose='Retries are clamped to [0, 1]; keep the [optional] indicator localized.'
            printf '\n%s\n' "$prose" >> "$record"
            git commit -qam 'bind acceptance with literal bracket notation' || exit 1
            BASE="$(git rev-parse HEAD)"
            git update-ref refs/remotes/origin/main "$BASE"
            printf 'implementation with literal brackets\n' > label.txt
            git commit -qam 'implementation-only change' || exit 1
            if build; then
                section="$(obligations_section)"
                assert_contains "$section" "$prose"
                assert_contains "$section" 'Acceptance: Preserve the exported public label.'
                assert_contains "$section" 'Keep the published label stable for automated clients.'
                assert_not_contains "$section" '**Required full context:**'
                assert_not_contains "$(cat "$PKG/context-gaps.txt")" 'undefined reference label'
                assert_not_contains "$(cat "$PKG/diff.patch")" "$prose"
            fi

            it "Selected parent checklists stay inline for unordered and ordered task markers"
            git checkout -qb parent-tasks "$BASE^" || exit 1
            parent=specs/changes/900-programme.md
            sed 's/\*\*Tier\*\*: T1/**Tier**: T1 · **Parent**: 900-programme/' "$record" > .git/record
            cp .git/record "$record"
            cat > "$parent" <<'EOF'
# Programme

## Outcome checkpoint

Keep the rollout compatible.

## Children

| Child | Outcome |
|---|---|
| 001-small | Keep the existing interface. |

## Dependencies

- [x] The owner approved the rollout window.
- [ ] Keep the old label available.
* [X] Confirm support handover.
+ [x] Confirm documentation handover.
1. [X] Record the approval.
2) [x] Check the rollout.
EOF
            git add specs && git commit -qm 'bind a selected parent checklist' || exit 1
            BASE="$(git rev-parse HEAD)"
            git update-ref refs/remotes/origin/main "$BASE"
            printf 'implementation with parent checklist\n' > label.txt
            git commit -qam 'implementation-only change with unchanged checklist' || exit 1
            if build; then
                section="$(obligations_section)"
                assert_contains "$section" '[x] The owner approved the rollout window.'
                assert_contains "$section" '[x] Check the rollout.'
                assert_contains "$section" 'Acceptance: Preserve the exported public label.'
                assert_not_contains "$section" '**Required full context:**'
                assert_eq 'verification no verification evidence supplied; dispatch pending' "$(cat "$PKG/context-gaps.txt")" 'the parent checklist adds no context gap'
            fi

            it "Task markers are not shortcuts even if the document defines x"
            printf '\n## References\n\n[x]: missing.md#not-a-task-destination\n' >> "$parent"
            git commit -qam 'add an unused definition matching a task marker' || exit 1
            BASE="$(git rev-parse HEAD)"
            git update-ref refs/remotes/origin/main "$BASE"
            printf 'implementation with unused definition\n' > label.txt
            git commit -qam 'implementation-only change with unchanged definition' || exit 1
            if build; then
                section="$(obligations_section)"
                assert_contains "$section" '[x] The owner approved the rollout window.'
                assert_not_contains "$section" '**Required full context:**'
                assert_not_contains "$(cat "$PKG/context-gaps.txt")" 'missing.md'
            fi ;;
        edge-blanks)
            it "A moved bound without the separator blank line renders once from BASE"
            rule='- **C-05 Moving bound**: Scope: all.'
            original=specs/product/constraints.md
            moved=specs/product/constraints/labels.md
            printf '\n%s\n  Keep the move sentinel.\n\n' "$rule" >> "$original"
            git add specs && git commit -qm 'bind a rule with trailing separator' || exit 1
            BASE="$(git rev-parse HEAD)"
            git update-ref refs/remotes/origin/main "$BASE"
            sed '/C-05 Moving bound/,$d' "$original" > .git/constraints
            cp .git/constraints "$original"
            mkdir -p specs/product/constraints
            printf '# Moved rules\n\n%s\n  Keep the move sentinel.\n' "$rule" > "$moved"
            git add specs && git commit -qm 'move the bound and drop separator blank' || exit 1
            if build; then
                section="$(obligations_section)"
                assert_contains "$section" 'C-05 — unchanged from BASE'
                assert_not_contains "$section" 'C-05 — Proposed by this change'
                assert_eq 1 "$(printf '%s\n' "$section" | grep -Fc 'Keep the move sentinel.')" 'move renders once'
                artifact="$(awk -F '\t' '$7 == "bound-shared" && $8 == "C-05" {print $1}' "$PKG/context-manifest.tsv")"
                run cmp "$PKG/$artifact" <(printf '%s\n  Keep the move sentinel.\n\n' "$rule")
                assert_eq 0 "$STATUS" 'the binding excerpt retains the original separator bytes'
            fi
            it "Other whitespace changes are not normalized"
            printf '# Moved rules\n\n%s\n  Keep the move sentinel. \n' "$rule" > "$moved"
            git commit -qam 'edit nonblank line whitespace' || exit 1
            if build; then
                section="$(obligations_section)"
                assert_contains "$section" 'C-05 — BASE, binding for this review'
                assert_contains "$section" 'C-05 — Proposed by this change'
            fi ;;
        nontext)
            it "Invalid UTF-8 and controls never enter the required index, and source bytes are retained"
            printf 'opaque \377\n' > malformed.dat
            printf 'escape \033[31m\n' > escape.dat
            printf 'lone CR\rhere\n' > cr.dat
            printf 'C1 \302\205\n' > c1.dat
            printf 'UTF-8 surrogate \355\240\200\n' > surrogate.dat
            printf 'NUL \000\n' > nul.dat
            printf 'Valid café\twith tab and 😀\n' > valid.txt
            git add ./*.dat valid.txt; git commit -qm 'snapshot text and non-text samples'
            for file in malformed.dat escape.dat cr.dat c1.dat surrogate.dat nul.dat; do
                if build --context "$file"; then
                    section="$(obligations_section)"
                    assert_contains "$section" '**Required full context:** A captured artifact cannot be included as inline text.'
                    assert_contains "$section" 'No partial obligation list is shown'
                    assert_not_contains "$section" 'Preserve the exported public label'
                    assert_not_contains "$section" "$file"
                    run cmp "$file" "$PKG/context/$file"
                    assert_eq 0 "$STATUS" 'original bytes unchanged'
                    run python3 -I -B -c 'import pathlib,sys,unicodedata as u; text=pathlib.Path(sys.argv[1]).read_bytes().decode(); assert all(c in "\t\n" or u.category(c)!="Cc" for c in text)' "$PKG/index.md"
                    assert_eq 0 "$STATUS" 'required index remains valid safe UTF-8'
                fi
            done
            if build --context valid.txt; then
                section="$(obligations_section)"
                assert_contains "$section" $'Valid café\twith tab and 😀'
                assert_not_contains "$section" '**Required full context:**'
            fi ;;
        *) echo "unknown fixture group: $mode" >&2; exit 2 ;;
    esac
done
finish
