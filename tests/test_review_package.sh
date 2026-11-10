#!/usr/bin/env bash
#
# Behavioral tests for scripts/build-review-package.sh:
#   - round numbering: first call creates round-1, second call round-2
#   - the package covers the FULL multi-commit BASE..HEAD range (the HEAD~1
#     failure mode — only the last commit's diff — must not reappear)
#   - JSON output shape: {"ROUND":N,"BASE_SHA":"...","HEAD_SHA":"...","PACKAGE_DIR":"...","REPORT_PATH":"..."}
#   - raw packages go to the gitignored .prdkit/cache/evidence/, never specs/
#   - revision and usage errors exit non-zero

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$PK_ROOT/scripts/build-review-package.sh"
STATUS=0; OUTPUT="" # assigned by run() in lib.sh

# A fixture repo: an initial commit (the BASE), then two commits touching different files.
setup_fixture_repo() {
    local d
    d="$(mktemp -d)"
    d="$(cd "$d" && pwd -P)"
    git -C "$d" init -q
    git -C "$d" config user.email t@example.com
    git -C "$d" config user.name test
    echo "seed" > "$d/seed.txt"
    printf '.prdkit/cache/\n' > "$d/.gitignore"
    git -C "$d" add -A
    git -C "$d" commit -q -m "init"
    echo "$d"
}

it "First call creates round-1, second call creates round-2"
dir="$(setup_fixture_repo)"; track_tmp "$dir"
BASE="$(git -C "$dir" rev-parse HEAD)"
echo "first change" > "$dir/alpha.txt"
git -C "$dir" add -A && git -C "$dir" commit -q -m "change: add alpha"
echo "second change" > "$dir/beta.txt"
git -C "$dir" add -A && git -C "$dir" commit -q -m "change: add beta"

PKG="$dir/.prdkit/cache/evidence/001-demo/reviews"
out1="$(cd "$dir" && bash "$SCRIPT" 001-demo "$BASE")"
assert_file "$PKG/round-1/commits.txt" "round-1 commits.txt written"
assert_file "$PKG/round-1/diffstat.txt" "round-1 diffstat.txt written"
assert_file "$PKG/round-1/diff.patch" "round-1 diff.patch written"
assert_eq "absent" "$([ -e "$dir/specs" ] && echo present || echo absent)" "nothing written under specs/"
assert_eq "" "$(git -C "$dir" status --porcelain --untracked-files=all -- .prdkit)" "package is gitignored"

FIX_BASE="$(git -C "$dir" rev-parse HEAD)"
echo "fix" >> "$dir/alpha.txt"
git -C "$dir" add -A && git -C "$dir" commit -q -m "change: fix alpha"
out2="$(cd "$dir" && bash "$SCRIPT" 001-demo "$FIX_BASE")"
assert_file "$PKG/round-2/diff.patch" "round-2 diff.patch written"
assert_eq "absent" "$([ -d "$PKG/round-3" ] && echo present || echo absent)" "no round-3 after two calls"

it "Output JSON reports ROUND, PACKAGE_DIR and REPORT_PATH"
assert_contains "$out1" '"ROUND":1' "first call reports ROUND 1"
assert_contains "$out1" "\"PACKAGE_DIR\":\"$PKG/round-1\"" "first call reports the absolute round-1 package dir"
assert_contains "$out1" "\"REPORT_PATH\":\"$PKG/round-1/report.md\"" "report lands next to its package"
assert_contains "$out2" '"ROUND":2' "second call reports ROUND 2"
assert_contains "$out2" "\"BASE_SHA\":\"$FIX_BASE\",\"HEAD_SHA\":\"$(git -C "$dir" rev-parse HEAD)\"" "both ends resolved to the hashes a Review line records"

it "diff.patch and commits.txt cover the full multi-commit range"
patch="$(cat "$PKG/round-1/diff.patch")"
assert_contains "$patch" "first change" "diff.patch contains the FIRST commit's change"
assert_contains "$patch" "second change" "diff.patch contains the SECOND commit's change"
commits="$(cat "$PKG/round-1/commits.txt")"
assert_contains "$commits" "change: add alpha" "commits.txt lists the first commit"
assert_contains "$commits" "change: add beta" "commits.txt lists the second commit"
diffstat="$(cat "$PKG/round-1/diffstat.txt")"
assert_contains "$diffstat" "alpha.txt" "diffstat.txt covers alpha.txt"
assert_contains "$diffstat" "beta.txt" "diffstat.txt covers beta.txt"

it "Round numbering is independent per change and works from a subdirectory"
mkdir -p "$dir/sub"
out3="$(cd "$dir/sub" && bash "$SCRIPT" 002-other "$BASE")"
assert_contains "$out3" '"ROUND":1' "a different change starts at round 1"
assert_file "$dir/.prdkit/cache/evidence/002-other/reviews/round-1/diff.patch" "002-other round-1 package written at the repo root"

it "An unignored cache is reported"
rm "$dir/.gitignore"
warn="$(cd "$dir" && bash "$SCRIPT" 003-warn "$BASE" 2>&1 >/dev/null)"
assert_contains "$warn" "not gitignored" "missing ignore entry warned"

it "Bad revision is an error"
output="$(cd "$dir" && bash "$SCRIPT" 001-demo deadbeef1234 2>&1)" && status=$? || status=$?
assert_eq "1" "$status" "unresolvable BASE_SHA exits 1"
assert_contains "$output" "does not resolve" "error names the bad revision"

it "Missing arguments and a non-change id are errors"
(cd "$dir" && bash "$SCRIPT" 001-demo 2>/dev/null) && status=$? || status=$?
assert_eq "1" "$status" "missing BASE_SHA exits 1"
(cd "$dir" && bash "$SCRIPT" "specs/features/001-demo" "$BASE" 2>/dev/null) && status=$? || status=$?
assert_eq "1" "$status" "a feature directory path is not a change id"

it "Selected context is frozen at HEAD; evidence is copied and indexed; focused delta keeps full context"
printf 'dirty working copy\n' > "$dir/alpha.txt"
mkdir -p "$dir/results"
printf 'command: test; revision: %s; exit: 0; PASS\n' "$(git -C "$dir" rev-parse HEAD)" > "$dir/results/check.txt"
out="$(cd "$dir" && bash "$SCRIPT" 004-prepared "$BASE" --since "$FIX_BASE" --context alpha.txt --evidence results/check.txt)"
prepared="$dir/.prdkit/cache/evidence/004-prepared/reviews/round-1"
assert_contains "$out" "\"SINCE_SHA\":\"$FIX_BASE\"" "focused range resolved"
assert_contains "$(cat "$prepared/diff.patch")" 'second change' "full diff retained"
assert_not_contains "$(cat "$prepared/delta.patch")" 'second change' "delta excludes earlier unaffected source"
assert_contains "$(cat "$prepared/delta.patch")" '+fix' "delta contains fix"
assert_eq "$(git -C "$dir" show HEAD:alpha.txt)" "$(cat "$prepared/context/alpha.txt")" "context ignores dirty worktree"
printf 'overwritten\n' > "$dir/results/check.txt"
assert_contains "$(cat "$prepared/evidence/results/check.txt")" 'exit: 0; PASS' "evidence remains the packaged copy"
assert_contains "$(cat "$prepared/manifest.tsv")" "$(git -C "$dir" hash-object --no-filters "$prepared/evidence/results/check.txt")" "inventory binds exact copied bytes"
assert_contains "$(cat "$prepared/index.md")" 'not proof of completion' "preflight does not claim semantic readiness"

it "Bad context, path traversal, directories and symlinks fail before a round is allocated"
ln -s results "$dir/linked"
for path in ../outside /outside results linked/check.txt results/missing; do
    run bash -c 'cd "$1" && bash "$2" 005-invalid "$3" --evidence "$4"' _ "$dir" "$SCRIPT" "$BASE" "$path"
    assert_eq 1 "$STATUS" "rejects evidence $path"
done
run bash -c 'cd "$1" && bash "$2" 005-invalid "$3" --context results/check.txt' _ "$dir" "$SCRIPT" "$BASE"
assert_eq 1 "$STATUS" 'untracked context cannot masquerade as HEAD content'
assert_eq absent "$([ -e "$dir/.prdkit/cache/evidence/005-invalid" ] && echo present || echo absent)" 'invalid input leaves no round'

it "A focused range starts in HEAD's history, before HEAD"
run bash -c 'cd "$1" && bash "$2" 006-invalid "$3" --since HEAD' _ "$dir" "$SCRIPT" "$BASE"
assert_eq 1 "$STATUS" 'unchanged head cannot request a focused round'
run bash -c 'cd "$1" && bash "$2" 006-invalid HEAD "$3"' _ "$dir" "$SCRIPT" "$BASE"
assert_eq 1 "$STATUS" 'backwards full range rejected'

# A change reviewed at PREV, then the base merged in: the new BASE (the merge base) is newer than PREV.
mr="$(setup_fixture_repo)"; track_tmp "$mr"
g() { git -C "$mr" "$@"; }
pkg_of() { printf '%s' "$1" | sed -n 's/.*"PACKAGE_DIR":"\([^"]*\)".*/\1/p'; }
printf '1\n2\n3\n4\n5\n' > "$mr/shared.txt"; g add -A; g commit -q -m shared
MAIN="$(g symbolic-ref --short HEAD)"; START="$(g rev-parse HEAD)"
g checkout -q -b 007-merged
echo v1 > "$mr/feature.txt"; printf '1\n2\nbranch\n4\n5\n' > "$mr/shared.txt"; g add -A; g commit -q -m 'feature v1'
PREV="$(g rev-parse HEAD)"
g checkout -q "$MAIN"
echo 'from the base' > "$mr/base.txt"; printf '1\n2\n3\n4\nbase five\n' > "$mr/shared.txt"; g add -A; g commit -q -m 'base work'
g checkout -q 007-merged; g merge -q --no-edit "$MAIN" >/dev/null
echo v2 > "$mr/feature.txt"; g commit -q -am 'feature v2'
MERGED_BASE="$(g merge-base "$MAIN" HEAD)"

it "After the base is merged in, --since takes the earlier head; the delta leaves out what the base brought"
out="$(cd "$mr" && bash "$SCRIPT" 007-merged "$MERGED_BASE" --since "$PREV")"
pkg="$(pkg_of "$out")"
assert_contains "$out" "\"SINCE_SHA\":\"$PREV\"" "an earlier head older than BASE is accepted"
assert_contains "$(cat "$pkg/delta.patch")" '+v2' "delta shows the commit since PREV"
assert_not_contains "$(cat "$pkg/delta.patch")" 'from the base' "delta leaves out a file the base brought"
assert_not_contains "$(cat "$pkg/delta.patch")" 'base five' "delta leaves out the base's edit to a shared file"
assert_contains "$(cat "$pkg/diff.patch")" '+branch' "full diff still covers the whole change"
assert_contains "$(cat "$pkg/index.md")" "without what the base brought: HEAD against" "index says what the delta covers"
assert_contains "$(cat "$pkg/manifest.tsv")" "automatic merge of $MERGED_BASE into $PREV" "inventory names the delta's source"
out="$(cd "$mr" && bash "$SCRIPT" 007-merged "$START" --since "$PREV")"
pkg="$(pkg_of "$out")"
assert_contains "$(cat "$pkg/delta.patch")" 'from the base' "with the round-1 base as BASE, the plain delta carries the merged base"
assert_contains "$(cat "$pkg/index.md")" "It includes merge $(g rev-parse HEAD^): if that brought the base in, rebuild with the current merge base as BASE" "index says so and names the remedy"

it "Conflict resolutions after a base merge show in the delta, even one that keeps the reviewed side"
PREV2="$(g rev-parse HEAD)"
g checkout -q "$MAIN"
echo 'more from the base' > "$mr/base2.txt"; printf '1\n2\nbase three\n4\nbase five\n' > "$mr/shared.txt"; g add -A; g commit -q -m 'base conflict'
g checkout -q 007-merged
g merge -q --no-edit "$MAIN" >/dev/null 2>&1 || true
printf '1\n2\nbranch\n4\nbase five\n' > "$mr/shared.txt"; g add -A; g commit -q --no-edit
MERGED_BASE2="$(g merge-base "$MAIN" HEAD)"
out="$(cd "$mr" && bash "$SCRIPT" 007-merged "$MERGED_BASE2" --since "$PREV2")"
pkg="$(pkg_of "$out")"
assert_contains "$(cat "$pkg/delta.patch")" '-base three' "the resolution that kept the reviewed line shows"
assert_not_contains "$(cat "$pkg/delta.patch")" 'more from the base' "the base's clean additions stay out"
assert_contains "$(cat "$pkg/index.md")" "That merge conflicts on shared.txt" "index names the conflicted path"

it "A commit in the base's history as --since gives the whole change"
out="$(cd "$mr" && bash "$SCRIPT" 007-merged "$MERGED_BASE2" --since "$START")"
pkg="$(pkg_of "$out")"
assert_eq "$(cat "$pkg/diff.patch")" "$(cat "$pkg/delta.patch")" "delta equals the full diff"
assert_contains "$(cat "$pkg/index.md")" "is in the base's history" "index says why"

it "Without merge-tree --write-tree, the delta is the change's own commits and names the merges to check"
FAKE="$(mktemp -d)"; track_tmp "$FAKE"
# shellcheck disable=SC2016  # the stub's own $a and $@, expanded when it runs
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = merge-tree ] && { echo "usage: git merge-tree <base-tree> <branch1> <branch2>" >&2; exit 129; }; done\nexec "%s" "$@"\n' "$(command -v git)" > "$FAKE/git"
chmod +x "$FAKE/git"
MERGE1="$(g rev-parse "$PREV2^")"
out="$(cd "$mr" && PATH="$FAKE:$PATH" bash "$SCRIPT" 007-merged "$MERGED_BASE" "$PREV2" --since "$PREV")"
pkg="$(pkg_of "$out")"
assert_contains "$(cat "$pkg/delta.patch")" '+v2' "fallback delta shows the commit since PREV"
assert_not_contains "$(cat "$pkg/delta.patch")" 'from the base' "fallback delta leaves out what the base brought"
# A combined (--cc) or first-parent (-m) diff of the clean merge would carry this base line.
assert_not_contains "$(cat "$pkg/delta.patch")" 'base five' "no merge diff carries base lines into the fallback delta"
assert_not_contains "$(cat "$pkg/delta.patch")" "commit $MERGE1" "the fallback delta leaves the merge commit out"
assert_contains "$(cat "$pkg/index.md")" "the automatic merge was unavailable (merge-tree --write-tree needs Git 2.38+ and full history)" "index says the fallback is in use"
assert_contains "$(cat "$pkg/index.md")" "check merge $MERGE1 in the full diff" "index names the merge to check"
MERGE2="$(g rev-parse HEAD)"
echo v3 > "$mr/feature.txt"; g commit -q -am 'feature v3'
out="$(cd "$mr" && PATH="$FAKE:$PATH" bash "$SCRIPT" 007-merged "$MERGED_BASE2" --since "$PREV2")"
pkg="$(pkg_of "$out")"
assert_contains "$(cat "$pkg/delta.patch")" '+v3' "after a conflicted merge, the fallback delta shows the later commit"
# A plain PREV2..HEAD diff, or a first-parent diff of the merge, would carry this base file.
assert_not_contains "$(cat "$pkg/delta.patch")" 'more from the base' "and nothing the base brought"
assert_not_contains "$(cat "$pkg/delta.patch")" "commit $MERGE2" "the resolving merge stays out of the delta"
assert_contains "$(cat "$pkg/index.md")" "check merge $MERGE2 in the full diff" "index names the resolving merge"

it "A --since outside HEAD's history is refused"
g checkout -q "$MAIN"; echo later > "$mr/later.txt"; g add -A; g commit -q -m 'base later'; UNMERGED="$(g rev-parse HEAD)"
g checkout -q 007-merged
run bash -c 'cd "$1" && bash "$2" 008-invalid "$3" --since "$4"' _ "$mr" "$SCRIPT" "$MERGED_BASE2" "$UNMERGED"
assert_eq 1 "$STATUS" 'a base commit not merged into HEAD is refused'
assert_contains "$OUTPUT" "must be a commit in HEAD's history" 'refusal explained'

finish
