#!/usr/bin/env bash
# Equal content and compatible package context avoid another allocation. No host needed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
source "$PK_ROOT/scripts/review-fingerprint-lib.sh"
source "$TESTS_DIR/review-package-fixtures.sh"
STATUS=0; OUTPUT=""
SCRIPT="$PK_ROOT/scripts/build-review-package.sh"
P="$(mktemp -d)"; track_tmp "$P"; cd "$P"
git init -q; git config user.name test; git config user.email test@example.invalid
printf '.prdkit/cache/\n' > .gitignore
mkdir -p src specs/changes
i=1; while [ "$i" -le 30 ]; do echo "line $i"; i=$((i+1)); done > src/app.txt
printf '# Change\n\n**Tier**: T1\n\n## State\n\n**Step**: review\n' > specs/changes/001-equal.md
git add -A; git commit -qm base; BASE="$(git rev-parse HEAD)"; MAIN="$(git symbolic-ref --short HEAD)"
git update-ref "refs/remotes/origin/$MAIN" "$BASE"; git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$MAIN"
git checkout -qb 001-equal
sed 's/line 15/changed fifteen/' src/app.txt > src/new; mv src/new src/app.txt; git commit -qam change
F1="$(git rev-parse HEAD)"
first="$(bash "$SCRIPT" 001-equal "$BASE")"; PKG="$(printf '%s' "$first" | jq -r .PACKAGE_DIR)"
ROOT="$(dirname "$PKG")"
snapshot() { package_snapshot "$ROOT"; }
before="$(snapshot)"
equal() {
    run bash "$SCRIPT" 001-equal "$1" ${2:+--since "$2"}
    assert_eq 1 "$STATUS" "equal refused: $OUTPUT"
    assert_contains "$OUTPUT" 'no round needed' 'explicit equality, not unknown'
    assert_eq "$before" "$(snapshot)" 'all artifacts byte-identical'
}
it "A changed record needs fresh context even when the review fingerprint is unchanged"
printf '\nrecord note\n' >> specs/changes/001-equal.md
git commit -qam metadata
equal "$BASE" "$F1"
run bash "$SCRIPT" 001-equal "$BASE"
assert_eq 0 "$STATUS" "fresh package for the new record: $OUTPUT"
pkg="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
assert_contains "$(cat "$pkg/index.md")" 'package context or bindings differ'
assert_contains "$(cat "$pkg"/context-sections/*.txt)" 'record note'
before="$(snapshot)"
equal "$BASE"
printf 'try\n' >> src/app.txt; git commit -qam try; git revert --no-edit HEAD >/dev/null
equal "$BASE" "$F1"
equal "$BASE"

it "Squash and rebase equivalents refuse"
tree="$(git rev-parse 'HEAD^{tree}')"; squashed="$(git commit-tree "$tree" -p "$BASE" -m synthetic-squash)"
run bash "$SCRIPT" 001-equal "$BASE" "$squashed" --since "$F1"
assert_eq 1 "$STATUS" 'squashed equivalent refused'
assert_contains "$OUTPUT" 'no round needed' 'squash comparison known'
git checkout -q "$MAIN"
printf 'base addition\n' > other.txt; git add other.txt; git commit -qm nonoverlap
TIP="$(git rev-parse HEAD)"; git update-ref "refs/remotes/origin/$MAIN" "$TIP"
git checkout -q 001-equal; git merge -q --no-edit "$MAIN"
equal "$TIP" "$F1"
git rebase -q "$MAIN" >/dev/null 2>&1
equal "$TIP" "$F1"

it "An overlapping base/context edit is not equal"
git checkout -q "$MAIN"
sed 's/line 18/base eighteen/' src/app.txt > src/new; mv src/new src/app.txt; git commit -qam overlap
TIP="$(git rev-parse HEAD)"; git update-ref "refs/remotes/origin/$MAIN" "$TIP"
git checkout -q 001-equal; git merge -q --no-edit "$MAIN"
run bash "$SCRIPT" 001-equal "$TIP" --since "$F1"
assert_eq 0 "$STATUS" "overlap allocates a changed-content round: $OUTPUT"
assert_eq 3 "$(printf '%s' "$OUTPUT" | jq .ROUND)" 'overlap is round 3'

it "Incomplete rounds retain evidence/numbering but do not prove completion"
printf 'fix\n' >> src/app.txt; git commit -qam fix
mkdir "$ROOT/round-7"; printf 'interrupted evidence\n' > "$ROOT/round-7/failed.txt"
run bash "$SCRIPT" 001-equal "$TIP"
assert_eq 0 "$STATUS" 'incomplete old round does not prevent changed source package'
assert_eq 8 "$(printf '%s' "$OUTPUT" | jq .ROUND)" 'incomplete numbering retained'
assert_eq 'interrupted evidence' "$(cat "$ROOT/round-7/failed.txt")" 'old failure byte-exact'
run bash "$SCRIPT" 001-equal "$TIP"
assert_eq 1 "$STATUS" 'omitted --since still refuses completed round 8'
assert_eq absent "$([ -d "$ROOT/round-9" ] && echo present || echo absent)" 'no round 9'

it "Concurrent identical requests cannot allocate duplicate completed rounds"
printf 'another fix\n' >> src/app.txt; git commit -qam another
status1=0; status2=0
bash "$SCRIPT" 001-equal "$TIP" > "$P/one.out" 2> "$P/one.err" & pid1=$!
bash "$SCRIPT" 001-equal "$TIP" > "$P/two.out" 2> "$P/two.err" & pid2=$!
wait "$pid1" || status1=$?
wait "$pid2" || status2=$?
assert_eq 1 "$((status1+status2))" 'exactly one succeeds; other busy or equal'
assert_file "$ROOT/round-9/completed.tsv" 'one completion'
assert_eq absent "$([ -d "$ROOT/round-10" ] && echo present || echo absent)" 'no duplicate round 10'

it "Unsafe actual record never becomes a historical closing record"
printf '# Change\n\n**Tier**: T1\n' > specs/changes/003-mode.md
git add specs/changes/003-mode.md; git commit -qm 'regular mode fixture'
rm specs/changes/003-mode.md; ln -s 001-equal.md specs/changes/003-mode.md
git add specs/changes/003-mode.md; git commit -qm 'unsafe mode fixture'
run bash "$SCRIPT" 003-mode "$TIP"
assert_eq 0 "$STATUS" 'useful structural preview survives unsafe record'
pkg="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
assert_contains "$(cat "$pkg/context-gaps.txt")" 'no historical substitution' 'unsafe current child exposed'
assert_not_contains "$(cat "$pkg/context-manifest.tsv")" 'actual record (historical' 'no false closing-record substitution'

it "Empty explicit whole-file context preserves zero bytes and object provenance"
: > empty.txt; git add empty.txt; git commit -qm 'empty context fixture'
run bash "$SCRIPT" 004-empty "$TIP" --context empty.txt
assert_eq 0 "$STATUS" 'whole-file empty context supported'
pkg="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
assert_eq 0 "$(wc -c < "$pkg/context/empty.txt" | tr -d ' ')" 'empty snapshot retained'
assert_contains "$(cat "$pkg/context-manifest.tsv")" "$(git rev-parse HEAD:empty.txt)" 'empty blob provenance'

it "When the base absorbs part of a package, the remaining range gets a fresh package"
git checkout -qb partial-range "$TIP"
printf 'first part\n' > first-part.txt; git add first-part.txt; git commit -qm 'first part'
PARTIAL="$(git rev-parse HEAD)"
printf 'second part\n' > second-part.txt; git add second-part.txt; git commit -qm 'second part'
run bash "$SCRIPT" 006-partial "$TIP"
assert_eq 0 "$STATUS" "package the entire range: $OUTPUT"
old_pkg="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
before="$(package_snapshot "$old_pkg")"
assert_contains "$(cat "$old_pkg/diff.patch")" first-part.txt 'prior package includes the absorbed part'
git update-ref "refs/remotes/origin/$MAIN" "$PARTIAL"
run bash "$SCRIPT" 006-partial "$PARTIAL"
assert_eq 0 "$STATUS" "remaining range needs a fresh package: $OUTPUT"
pkg="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
assert_eq 2 "$(printf '%s' "$OUTPUT" | jq .ROUND)" 'a new round was allocated'
assert_not_contains "$(cat "$pkg/diff.patch")" first-part.txt 'already integrated part excluded'
assert_contains "$(cat "$pkg/diff.patch")" second-part.txt 'remaining part included'
assert_contains "$(cat "$pkg/index.md")" 'changed from completed round-1' 'old fingerprint uses its recorded tip'
assert_eq "$before" "$(package_snapshot "$old_pkg")" 'prior artifacts not touched'

it "Updated trusted policy or explicit context prevents reuse at the same source"
git checkout -q 001-equal
run bash "$SCRIPT" 007-context "$TIP"
assert_eq 0 "$STATUS" "record a full package at the current policy: $OUTPUT"
git update-ref "refs/remotes/origin/$MAIN" "$(git commit-tree "$PARTIAL^{tree}" -p "$PARTIAL" -m 'advance trusted policy revision')"
run bash "$SCRIPT" 007-context "$TIP"
assert_eq 0 "$STATUS" "fresh package under a new trusted policy revision: $OUTPUT"
pkg="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
assert_contains "$(cat "$pkg/index.md")" 'package context or bindings differ'
run bash "$SCRIPT" 007-context "$TIP" --context empty.txt
assert_eq 0 "$STATUS" "new explicit context needs a new package: $OUTPUT"
pkg="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
assert_file "$pkg/context/empty.txt"
git update-ref "refs/remotes/origin/$MAIN" "$TIP"

it "Targeted unreadable current/since/completed content refuses before artifact mutation"
# Selectively deny one old blob, not all object reads: the other comparisons remain usable.
BADGIT="$(mktemp -d)"; track_tmp "$BADGIT"
REAL_GIT="$(command -v git)"; export REAL_GIT
cat > "$BADGIT/git" <<'EOF'
#!/usr/bin/env bash
previous=""; blob=false
for arg in "$@"; do
    if [ "$previous" = cat-file ] && [ "$arg" = blob ]; then blob=true
    elif $blob; then [ "$arg" != "$DENIED_BLOB" ] || exit 128; blob=false; fi
    previous="$arg"
done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$BADGIT/git"
OLD="$(git rev-parse HEAD)"
OLD_BLOB="$(git rev-parse HEAD:src/app.txt)"
printf 'selective current\n' >> src/app.txt; git commit -qam 'selective object fixture'
CURRENT_BLOB="$(git rev-parse HEAD:src/app.txt)"
for denied in "$OLD_BLOB" "$CURRENT_BLOB"; do
    before="$(snapshot)"
    run env DENIED_BLOB="$denied" PATH="$BADGIT:$PATH" bash "$SCRIPT" 001-equal "$TIP" --since "$OLD"
    assert_eq 1 "$STATUS" 'targeted unreadable object refused'
    assert_contains "$OUTPUT" 'targeted comparison unknown' 'unknown, not equal/changed'
    assert_eq "$before" "$(snapshot)" 'all paths/modes/bytes and directories unchanged'
done
run bash "$SCRIPT" 005-completed "$TIP"
assert_eq 0 "$STATUS" 'completed-binding control assembled'
old_package="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"; old_root="$(dirname "$old_package")"
printf 'since version\n' >> src/app.txt; git commit -qam 'comparable since fixture'
SINCE="$(git rev-parse HEAD)"
printf 'head version\n' >> src/app.txt; git commit -qam 'comparable head fixture'
before="$(package_snapshot "$old_root")"
run env DENIED_BLOB="$CURRENT_BLOB" PATH="$BADGIT:$PATH" bash "$SCRIPT" 005-completed "$TIP" --since "$SINCE"
assert_eq 1 "$STATUS" 'unreadable completed head refuses even though current/since are readable'
assert_contains "$OUTPUT" 'completed package comparison unknown' 'completed recomputation stays unknown'
assert_eq "$before" "$(package_snapshot "$old_root")" 'prior completion/report tree preserved without new round'

it "Snapshot negative controls detect path swaps, modes and new directories"
CONTROL="$(mktemp -d)"; track_tmp "$CONTROL"
printf 'a\n' > "$CONTROL/one"; printf 'b\n' > "$CONTROL/two"
before="$(package_snapshot "$CONTROL")"
mv "$CONTROL/one" "$CONTROL/holding"; mv "$CONTROL/two" "$CONTROL/one"; mv "$CONTROL/holding" "$CONTROL/two"
assert_eq different "$([ "$before" = "$(package_snapshot "$CONTROL")" ] && echo equal || echo different)" 'swapped bytes cannot pass'
before="$(package_snapshot "$CONTROL")"; chmod u+x "$CONTROL/one"
assert_eq different "$([ "$before" = "$(package_snapshot "$CONTROL")" ] && echo equal || echo different)" 'mode changes cannot pass'
before="$(package_snapshot "$CONTROL")"; mkdir "$CONTROL/empty"
assert_eq different "$([ "$before" = "$(package_snapshot "$CONTROL")" ] && echo equal || echo different)" 'empty directory allocation cannot pass'
finish
