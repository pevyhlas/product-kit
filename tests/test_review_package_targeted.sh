#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC2153 # STATUS/OUTPUT are assigned by the sourced fixture runner.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
STATUS=0; OUTPUT=""
P="$(make_inited_project)"; track_tmp "$P"; cd "$P"
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
**Tags**: sample **Parent**: 999-not-a-parent

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

F2="$(git rev-parse HEAD)"; BUILD="$PK_ROOT/scripts/build-review-package.sh"
package() { PKG="$(bash "$BUILD" "$ID" "$BASE" | jq -er .PACKAGE_DIR)"; }
advance() { printf '%s\n' "$1" >> src/app.txt; git add src/app.txt; git commit -qm "$1"; }
package
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

it "Standalone changes, symlink context and deleted child provenance stay explicit"
sed 's/Parent\*\*: 900-programme/Parent**: —/' "specs/changes/$ID.md" > .git/record
cp .git/record "specs/changes/$ID.md"; git add "specs/changes/$ID.md"; git commit -qm 'standalone change'
advance context-gaps
package
assert_not_contains "$(cat "$PKG/context-gaps.txt")" 'parent' 'standalone change does not request a parent for the Opened date'
ln -s app.txt src/link.txt; git add src/link.txt
git commit -qm 'synthetic link'
run bash "$BUILD" "$ID" "$BASE" --context src/link.txt
assert_eq 1 "$STATUS" 'symlink cannot masquerade as whole context'
printf 'dirty worktree\n' > specs/parts/p1.md
advance dirty-control
package
assert_not_contains "$(cat "$PKG"/context-sections/*.txt)" 'dirty worktree' 'committed canon only'
git rm -q "specs/changes/$ID.md"
mkdir -p .prdkit/history/log; printf -- '- 2026-01-03 %s: closed\n' "$ID" > ".prdkit/history/log/$ID.md"
git add .prdkit/history/log; git commit -qm 'synthetic close'
run bash "$BUILD" "$ID" "$BASE"
assert_eq 0 "$STATUS" "closing package: $OUTPUT"
PKG="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
assert_contains "$(cat "$PKG/context-manifest.tsv")" "$(git rev-parse HEAD^)" 'historical child revision bound'
assert_contains "$(cat "$PKG/context-manifest.tsv")" 'historical when source_rev differs' 'not represented as an H blob'
finish
