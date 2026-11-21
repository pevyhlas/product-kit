#!/usr/bin/env bash
# Interrupted historical completion files are evidence, never a valid comparison or fatal read.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TESTS_DIR/review-package-fixtures.sh"
BUILD="${PACKAGE_TEST_BUILDER:-$PK_ROOT/scripts/build-review-package.sh}"
STATUS=0; OUTPUT=""
for kind in legacy empty unterminated malformed multiline nul; do
    it "Unusable $kind completion preserves evidence and numbering"
    P="$(mktemp -d)"; track_tmp "$P"; cd "$P" || exit 1
    git init -q; git config user.name test; git config user.email test@example.invalid
    printf '.prdkit/cache/\n' > .gitignore
    printf 'base\n' > source.txt; git add -A; git commit -qm base || exit 1
    BASE="$(git rev-parse HEAD)"; MAIN="$(git symbolic-ref --short HEAD)"; REF="refs/remotes/origin/$MAIN"
    git update-ref "$REF" "$BASE"; git symbolic-ref refs/remotes/origin/HEAD "$REF"
    printf 'change\n' >> source.txt; git commit -qam change || exit 1
    HEAD_SHA="$(git rev-parse HEAD)"; ID=001-completion
    ROOT="$P/.prdkit/cache/evidence/$ID/reviews"
    mkdir -p "$ROOT/round-3"
    printf 'interrupted evidence\n' > "$ROOT/round-3/report.txt"
    binding="package2"$'\t'"$ID"$'\t'"$HEAD_SHA"$'\t'"$REF"$'\t'"$BASE"$'\t'"$BASE"$'\tknown'
    case "$kind" in
        legacy) printf '%s\n' "${binding/package2/package1}" > "$ROOT/round-3/completed.tsv" ;;
        empty) : > "$ROOT/round-3/completed.tsv" ;;
        unterminated) printf '%s' "$binding" > "$ROOT/round-3/completed.tsv" ;;
        malformed) printf '%s\textra\n' "$binding" > "$ROOT/round-3/completed.tsv" ;;
        multiline) printf '%s\nextra\n' "$binding" > "$ROOT/round-3/completed.tsv" ;;
        nul) printf 'package2\t%s\t%s\000%s\t%s\t%s\t%s\tknown\n' "$ID" "${HEAD_SHA:0:20}" "${HEAD_SHA:20}" "$REF" "$BASE" "$BASE" > "$ROOT/round-3/completed.tsv" ;;
    esac
    before="$(package_snapshot "$ROOT/round-3")"
    run bash "$BUILD" "$ID" "$BASE"
    assert_eq 0 "$STATUS" "ordinary preview survives $kind binding: $OUTPUT"
    assert_eq "$before" "$(package_snapshot "$ROOT/round-3")" 'old exact entries/bytes preserved'
    [ "$STATUS" = 0 ] || continue
    pkg="$(printf '%s' "$OUTPUT" | jq -r .PACKAGE_DIR)"
    assert_eq 4 "$(printf '%s' "$OUTPUT" | jq .ROUND)" 'incomplete numbering retained'
    assert_contains "$(cat "$pkg/index.md")" 'Fingerprint comparison: unknown' 'unusable binding was not equal/changed evidence'
    assert_file "$pkg/completed.tsv" 'new usable binding published last'
    assert_eq absent "$([ -e "$pkg/completed.pending" ] && echo present || echo absent)" 'no partial publication after success'
    mkdir "$ROOT/round-8"; cp "$ROOT/round-3/completed.tsv" "$ROOT/round-8/completed.tsv"
    printf 'more failure evidence\n' > "$ROOT/round-8/report.txt"
    before="$(package_snapshot "$ROOT")"
    run bash "$BUILD" "$ID" "$BASE"
    assert_eq 1 "$STATUS" 'latest usable binding still detects equality past unusable files'
    assert_contains "$OUTPUT" 'no round needed' 'usable comparison, not fatal read'
    assert_eq "$before" "$(package_snapshot "$ROOT")" 'equal refusal preserves all exact entries'
    printf 'new source\n' >> source.txt; git commit -qam 'new source' || exit 1
    old3="$(package_snapshot "$ROOT/round-3")"; old8="$(package_snapshot "$ROOT/round-8")"
    run bash "$BUILD" "$ID" "$BASE"
    assert_eq 0 "$STATUS" "next changed preview assembles: $OUTPUT"
    [ "$STATUS" = 0 ] || continue
    assert_eq 9 "$(printf '%s' "$OUTPUT" | jq .ROUND)" 'next usable round follows incomplete numbering'
    assert_eq "$old3" "$(package_snapshot "$ROOT/round-3")" 'first partial preserved'
    assert_eq "$old8" "$(package_snapshot "$ROOT/round-8")" 'later partial preserved'
done
finish
