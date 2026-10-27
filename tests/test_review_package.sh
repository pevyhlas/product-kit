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
STATUS=0 # assigned by run() in lib.sh

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

it "Focused ranges must chain within the full range"
run bash -c 'cd "$1" && bash "$2" 006-invalid "$3" --since HEAD' _ "$dir" "$SCRIPT" "$BASE"
assert_eq 1 "$STATUS" 'unchanged head cannot request a focused round'
run bash -c 'cd "$1" && bash "$2" 006-invalid HEAD "$3"' _ "$dir" "$SCRIPT" "$BASE"
assert_eq 1 "$STATUS" 'backwards full range rejected'

finish
