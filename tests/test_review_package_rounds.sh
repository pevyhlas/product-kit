#!/usr/bin/env bash
# The same completed head is refused before allocating another round. No host needed.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
source "$TESTS_DIR/review-package-fixtures.sh"
STATUS=0; OUTPUT=""
SCRIPT="$PK_ROOT/scripts/build-review-package.sh"
P="$(mktemp -d)"; track_tmp "$P"; cd "$P"
git init -q; git config user.name test; git config user.email test@example.invalid
printf '.prdkit/cache/\n' > .gitignore
mkdir -p src specs/changes
package_context_fixture 001-equal
printf '\n## Configuration\n- review-integration-branches: origin/integration\n' >> .prdkit/memory/config.md
i=1; while [ "$i" -le 30 ]; do echo "line $i"; i=$((i+1)); done > src/app.txt
printf '# Change\n\n**Tier**: T1\n\n## State\n\n**Step**: review\n' > specs/changes/001-equal.md
git add -A; git commit -qm base; BASE="$(git rev-parse HEAD)"; MAIN="$(git symbolic-ref --short HEAD)"
git update-ref "refs/remotes/origin/$MAIN" "$BASE"; git symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$MAIN"
git checkout -qb 001-equal
sed 's/line 15/changed fifteen/' src/app.txt > src/new; mv src/new src/app.txt; git commit -qam change
F1="$(git rev-parse HEAD)"
first="$(bash "$SCRIPT" 001-equal "$BASE")"; PKG="$(printf '%s' "$first" | jq -r .PACKAGE_DIR)"
ROOT="$(dirname "$PKG")"
it "Old, otherwise valid packages are regenerated without editing their files"
# Keep coverage for both the pre-lean layout and the prior lean layout.
cp -R "$PKG" "$ROOT/round-2"
sed 's/^package14/package12/' "$PKG/completed.tsv" > "$P/old-binding"
cp "$P/old-binding" "$PKG/completed.tsv"
sed 's/^package14/package13/' "$ROOT/round-2/completed.tsv" > "$P/old-binding"
cp "$P/old-binding" "$ROOT/round-2/completed.tsv"
old_snapshot="$(package_snapshot "$PKG")"
old_lean_snapshot="$(package_snapshot "$ROOT/round-2")"
run bash "$SCRIPT" 001-equal "$BASE"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 3 "$(jq .ROUND <<<"$OUTPUT")" 'same source may get the new package format'
assert_eq "$old_snapshot" "$(package_snapshot "$PKG")" 'old round left byte-exact'
assert_eq "$old_lean_snapshot" "$(package_snapshot "$ROOT/round-2")" 'old lean round left byte-exact'
run bash "$SCRIPT" 001-equal "$BASE"
assert_eq 1 "$STATUS" 'current format retains exact-head duplicate refusal'
assert_contains "$OUTPUT" 'no round needed'
it "A new exact head can be packaged even when only the record changed"
printf '\nrecord note\n' >> specs/changes/001-equal.md; git commit -qam metadata
TIP="$BASE"
run bash "$SCRIPT" 001-equal "$TIP" --since "$F1"
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 4 "$(printf '%s' "$OUTPUT" | jq .ROUND)" 'new review head packaged'
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
TIP="$F1"; git update-ref "refs/remotes/origin/$MAIN" "$TIP"
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
assert_eq "$before" "$(package_snapshot "$old_pkg")" 'prior artifacts not touched'

it "An integration advance during merge-base lookup cannot relabel the assembled patch"
# The default tip lacks the full range's start, so the configured ref is selected.
default_ref="refs/remotes/origin/$MAIN"; integration=refs/remotes/origin/integration
git update-ref "$default_ref" "$BASE"; git update-ref "$integration" "$TIP"
shim="$(mktemp -d)"; track_tmp "$shim"
cat > "$shim/git" <<'SH'
#!/usr/bin/env bash
if [ "${3:-}" = merge-base ] && { [ "${4:-}" = "$INTEGRATION" ] || [ "${4:-}" = "$START" ]; } &&
    [ "$#" = 5 ] && [ ! -f "$MOVED" ]; then
    "$REAL_GIT" "$@" || exit 1
    "$REAL_GIT" update-ref "$INTEGRATION" "$ADVANCE" "$START" && : > "$MOVED"
    exit $?
fi
exec "$REAL_GIT" "$@"
SH
chmod +x "$shim/git"
run env REAL_GIT="$(command -v git)" INTEGRATION="$integration" START="$TIP" ADVANCE="$PARTIAL" \
    MOVED="$shim/moved" PATH="$shim:$PATH" bash "$SCRIPT" 001-equal "$TIP"
assert_eq 0 "$STATUS" "complete the original range: $OUTPUT"
pkg="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
assert_file "$shim/moved"
assert_contains "$(cat "$pkg/diff.patch")" first-part.txt
assert_eq "$TIP" "$(cut -f5 "$pkg/completed.tsv")" 'M2: completion uses the tip checked before the ref advanced' || :
assert_eq "$TIP" "$(cut -f9 "$pkg/completed.tsv")" 'M2: completion records the actual start of diff.patch' || :
run bash "$SCRIPT" 001-equal "$PARTIAL"
assert_eq 0 "$STATUS" "M2: narrowed range needs a new package: $OUTPUT" || :
if [ "$STATUS" = 0 ]; then
    pkg="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
    assert_not_contains "$(cat "$pkg/diff.patch")" first-part.txt
fi
git update-ref "$default_ref" "$PARTIAL"

it "Updated trusted policy or explicit context prevents reuse at the same source"
git checkout -q 001-equal
run bash "$SCRIPT" 007-context "$TIP"
assert_eq 0 "$STATUS" "record a full package at the current policy: $OUTPUT"
git update-ref "refs/remotes/origin/$MAIN" "$(git commit-tree "$PARTIAL^{tree}" -p "$PARTIAL" -m 'advance trusted policy revision')"
run bash "$SCRIPT" 007-context "$TIP"
assert_eq 0 "$STATUS" "fresh package under a new trusted policy revision: $OUTPUT"
pkg="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
run bash "$SCRIPT" 007-context "$TIP" --context empty.txt
assert_eq 0 "$STATUS" "new explicit context needs a new package: $OUTPUT"
pkg="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
assert_file "$pkg/context/empty.txt"
git update-ref "refs/remotes/origin/$MAIN" "$TIP"

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
it "Restored automatic context and incomplete artifacts need new rounds"
for gap in canon historical; do
    id="008-$gap"
    cp specs/changes/001-equal.md "specs/changes/$id.md"
    git add "specs/changes/$id.md"; git commit -qm 'add context record'
    if [ "$gap" = historical ]; then
        historical_blob="$(git rev-parse "HEAD:specs/changes/$id.md")"
        git rm -q "specs/changes/$id.md"; git commit -qm 'retire context record'
        run env DENIED_BLOB="$historical_blob" PATH="$BADGIT:$PATH" bash "$SCRIPT" "$id" "$TIP"
    else
        run env DENIED_BLOB="$(git rev-parse HEAD:specs/architecture.md)" PATH="$BADGIT:$PATH" bash "$SCRIPT" "$id" "$TIP"
    fi
    assert_eq 0 "$STATUS" "structural package with $gap gap: $OUTPUT"
    pkg="$P/.prdkit/cache/evidence/$id/reviews/round-1"
    case "$gap" in
        canon) assert_contains "$(cat "$pkg/context-gaps.txt")" 'unreadable/non-text input specs/architecture.md' ;;
        historical) assert_contains "$(cat "$pkg/context-gaps.txt")" 'bounds unavailable' ;;
    esac
    run bash "$SCRIPT" "$id" "$TIP"
    assert_eq 0 "$STATUS" "M3: $gap context recovered without moving the head: $OUTPUT" || continue
    pkg="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
    assert_file "$pkg/bounds.txt"
done
for damage in missing-patch changed-section changed-obligations manifest; do
    id="009-$damage"
    cp specs/changes/001-equal.md "specs/changes/$id.md"
    git add "specs/changes/$id.md"; git commit -qm 'prepare complete context'
    pkg="$(bash "$SCRIPT" "$id" "$TIP" | jq -r .PACKAGE_DIR)"
    case "$damage" in
        missing-patch) rm "$pkg/diff.patch" ;;
        changed-section) printf 'changed artifact\n' >> "$pkg/context-sections/1.txt" ;;
        changed-obligations) printf 'changed obligations\n' >> "$pkg/index.md" ;;
        manifest) rm "$pkg/manifest.tsv" ;;
    esac
    run bash "$SCRIPT" "$id" "$TIP"
    assert_eq 0 "$STATUS" "M3: $damage gets a fresh round: $OUTPUT" || continue
    pkg="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
    assert_file "$pkg/diff.patch"
done

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
