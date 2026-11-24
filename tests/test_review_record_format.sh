#!/usr/bin/env bash
# Current-format rejection reads raw records and complete local history.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
source "$PK_ROOT/scripts/review-policy-lib.sh"
STATUS=0; OUTPUT=""

PROJECT="$(make_project)"; track_tmp "$PROJECT"
WORK="$(mktemp -d)"; track_tmp "$WORK"
cd "$PROJECT" || exit 1
ID=001-current
RECORD="specs/changes/$ID.md"
mkdir -p specs/changes
printf '# Change\n**Tier**: T0\n## State\n' > "$RECORD"
git add -- "$RECORD"; git commit -qm current
BASE="$(git rev-parse HEAD)"

scan() { run review_record_history "$PROJECT" "$ID" "$1" HEAD "$WORK"; }
refused() {
    assert_eq 0 "$STATUS" 'scanner returns a format finding'
    assert_contains "$OUTPUT" 'native GitHub reviews' 'current format named'
}
old_field() { printf '**Review**: round 1 · older · agent · FAIL\n' >> "$1"; }

it 'examples in fences do not masquerade as active State'
printf '```\n' >> "$RECORD"
old_field "$RECORD"
printf '```\n' >> "$RECORD"
git commit -qam example
scan "$BASE"
assert_eq 0 "$STATUS"
assert_eq '' "$OUTPUT"

it 'a record already at the fork still requires current format'
old_field "$RECORD"
git commit -qam inherited
INHERITED="$(git rev-parse HEAD)"
git commit --allow-empty -qm unrelated
scan "$INHERITED"; refused

it 'a moved sibling record cannot hide an inherited field'
git checkout -qb sibling "$BASE"
SIBLING=specs/changes/002-sibling.md
cp "$RECORD" "$SIBLING"; old_field "$SIBLING"
git add "$SIBLING"; git commit -qm sibling
SIBLING_BASE="$(git rev-parse HEAD)"
git mv "$SIBLING" moved.md; git commit -qm move
scan "$SIBLING_BASE"; refused

it 'an unrelated unmodified sibling at the fork is not in scope'
git checkout -qb untouched "$SIBLING_BASE"
git commit --allow-empty -qm unrelated
scan "$SIBLING_BASE"
assert_eq 0 "$STATUS"
assert_eq '' "$OUTPUT"

it 'an unsupported field dropped by a merge is still checked'
git checkout -qb carrier "$BASE"
old_field "$RECORD"
git commit -qam carrier
git checkout -qb integration "$BASE"
git merge -qs ours carrier
scan "$BASE"; refused

it 'binary blobs cannot obscure an unsupported review field'
git checkout -qb binary "$BASE"
printf '**Review**:\000undecodable\n' >> "$RECORD"
git commit -qam binary
scan "$BASE"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" 'expected LF-terminated Markdown'

it 'criss-cross history refuses to guess a fork'
tree="$(git rev-parse "$BASE^{tree}")"
left="$(git commit-tree "$tree" -p "$BASE" -m left)"
right="$(git commit-tree "$tree" -p "$BASE" -m right)"
cross1="$(git commit-tree "$tree" -p "$left" -p "$right" -m cross1)"
cross2="$(git commit-tree "$tree" -p "$right" -p "$left" -m cross2)"
run review_record_history "$PROJECT" "$ID" "$cross1" "$cross2" "$WORK"
assert_eq 1 "$STATUS"

finish
