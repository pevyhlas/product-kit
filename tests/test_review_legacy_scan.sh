#!/usr/bin/env bash
# §4.1 plumbing/history cases. Gate/receipt clearance is exercised separately.
# shellcheck disable=SC2016 # Markdown fences are literal.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
source "$PK_ROOT/scripts/review-fingerprint-lib.sh"
source "$PK_ROOT/scripts/review-legacy-lib.sh"
STATUS=0; OUTPUT=""
PROJ="$(mktemp -d)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
git init -q; git config user.name test; git config user.email test@example.invalid
git commit -qm root --allow-empty
ROOT="$(git rev-parse HEAD)"
A=specs/changes/001-original.md; B=specs/changes/002-carrier.md
CLEAN='0 critical, 0 high, 0 medium, 0 low'
FAIL="**Review**: round 1 · ignored-range · code · FAIL · $CLEAN · ignored-link"
PASS="**Review**: round 2 · ignored-range · code · PASS · $CLEAN · ignored-link"
commit() { git add -A && git commit -qm "$1" || exit 1; }
record() { printf '# Record\n**Tier**: T1\n## State\n%s\n' "${2:-}" > "$1"; }
fresh() {
    git reset -q --hard "$ROOT" || exit 1
    mkdir -p specs/changes
    BASE="$ROOT"; CHECKED=002-carrier; RIGOR=light
    CACHE="$(mktemp -d)"; track_tmp "$CACHE"
}
scan() {
    run review_legacy_collect "$PROJ" "$CHECKED" "$BASE" "${1:-HEAD}" "$RIGOR" "$CACHE" "$CACHE/result"
    assert_eq 0 "$STATUS" "scan completes: $OUTPUT"
    FOUND="$(cat "$CACHE/result")"
    COUNT="$(awk 'END { print NR+0 }' "$CACHE/result")"
}

it 'checked inherited FAIL is retained despite a later 1.x PASS and deduplicated by identity'
fresh; record "$A" "$FAIL"; printf '%s\n%s\n' "$FAIL" "$PASS" >> "$A"; commit inherited
BASE="$(git rev-parse HEAD)"; CHECKED=001-original
scan
assert_eq 1 "$COUNT"
DIGEST="$(printf 'prdkit-legacy\000001-original\000%s' "$FAIL" | review_sha256)"
assert_eq "${DIGEST:0:32}" "${FOUND%%$'\037'*}" 'identity is the specified NUL-domain SHA-256 prefix'

it 'named reviewers and owner PASS survive both NUL-sentinel awk behaviors'
AWK_SHIM="$(mktemp -d)"; track_tmp "$AWK_SHIM"
REAL_AWK="$(command -v awk)"; export REAL_AWK
cat > "$AWK_SHIM/awk" <<'EOF'
#!/usr/bin/env bash
# Model both the empty NUL sentinel and record truncation, independently.
args=()
for arg in "$@"; do
    if [ "${AWK_SHIM_NUL_LENGTH:-0}" = 1 ]; then arg="${arg//sprintf\(\"%c\",0\)/\"x\"}"
    else arg="${arg//sprintf\(\"%c\",0\)/\"\"}"; fi
    if [ "${AWK_SHIM_TRUNCATE_NUL:-false}" = true ] && [[ "$arg" = *'$0'* ]]; then
        arg='{ _shim_nul=sprintf("%c",0); if (_shim_nul!="" && (_shim_pos=index($0,_shim_nul))) $0=substr($0,1,_shim_pos-1) } '"$arg"
    fi
    args+=("$arg")
done
exec "$REAL_AWK" "${args[@]}"
EOF
chmod +x "$AWK_SHIM/awk"
for mode in native empty-nul; do
    fresh; record "$A" "$FAIL"
    printf '**Review**: round 2 · ignored · owner · PASS\n' >> "$A"
    commit "$mode"
    if [ "$mode" = empty-nul ]; then
        run env PATH="$AWK_SHIM:$PATH" awk 'BEGIN { print length(sprintf("%c",0)) }'
        assert_eq 0 "$OUTPUT" 'the shim exercises an empty sentinel'
        PATH="$AWK_SHIM:$PATH" scan
    else scan; fi
    assert_eq 1 "$COUNT" 'owner PASS adds no blocker'
    assert_eq code "$(printf '%s\n' "$FOUND" | awk -F '\037' '{ print $3 }')" 'named reviewer remains code, never unnamed'
done

it 'untouched inherited siblings are excluded, changed/deleted/moved/type-replaced siblings are included'
for operation in untouched edit delete move symlink submodule executable; do
    fresh; record "$A" "$FAIL"; commit inherited; BASE="$(git rev-parse HEAD)"
    record "$B"
    case "$operation" in
        untouched) ;;
        edit) record "$A" "$PASS" ;;
        delete) rm "$A" ;;
        move) mv "$A" specs/changes/003-moved.md ;;
        symlink) rm "$A"; ln -s 002-carrier.md "$A" ;;
        submodule) git rm -q "$A"; git add "$B"; git update-index --add --cacheinfo "160000,$ROOT,$A" ;;
        executable) chmod +x "$A" ;;
    esac
    if [ "$operation" = submodule ]; then git commit -qm submodule || exit 1
    else commit "$operation"; fi
    scan
    if [ "$operation" = untouched ]; then assert_eq 0 "$COUNT"; else assert_eq 1 "$COUNT" "$operation preserves origin blocker"; fi
done

it 'branch lines survive deletion, transfer and a closed predecessor on the same history'
fresh; record "$A" "$FAIL"; commit predecessor; rm "$A"; record "$B"; commit successor
scan
assert_eq 1 "$COUNT"
assert_contains "$FOUND" $'\037001-original\037code\037'
record "$B" "$FAIL"; commit transfer
scan
assert_eq 2 "$COUNT" 'the same text in another change has another identity'

it 'only active parsed State lines matter, including when fenced text later becomes active'
fresh
printf '# Record\n%s\n## State\n<!--\n%s\n-->\n```\n%s\n```\n## Other\n%s\n' "$FAIL" "$FAIL" "$FAIL" "$FAIL" > "$A"
commit ignored; scan; assert_eq 0 "$COUNT"
record "$A" "$FAIL"; commit activated; rm "$A"; commit removed
scan; assert_eq 1 "$COUNT" 'parent raw text never masks newly active text'

it 'a merge-only resolution line is new; ordinary branch-side lines are found in their own commits'
fresh; record "$A"; commit fork; BASE="$(git rev-parse HEAD)"
printf left > left.txt; commit left; LEFT="$(git rev-parse HEAD)"
git checkout -q --detach "$BASE"; printf right > right.txt; commit right; RIGHT="$(git rev-parse HEAD)"
record "$A" "$FAIL"; git add "$A"; TREE="$(git write-tree)"
MERGE="$(git commit-tree "$TREE" -p "$LEFT" -p "$RIGHT" -m resolution)"
scan "$MERGE"; assert_eq 1 "$COUNT"

it 'a merge dropping its branch-side FAIL cannot simplify away that introduction'
fresh; record "$A"; commit fork; BASE="$(git rev-parse HEAD)"
record "$A" "$FAIL"; commit predecessor; LEFT="$(git rev-parse HEAD)"
git checkout -q --detach "$BASE"; record "$A" 'parallel state'; commit parallel; RIGHT="$(git rev-parse HEAD)"
MERGE="$(git commit-tree "$(git rev-parse "$RIGHT^{tree}")" -p "$RIGHT" -p "$LEFT" -m 'drop FAIL in resolution')"
scan "$MERGE"; assert_eq 1 "$COUNT"

it 'a merge taking a line from any parent does not introduce it under another origin'
fresh; record "$A" "$FAIL"; commit inherited; FORK="$(git rev-parse HEAD)"
# Default removes the record; branch moves it. Fork-point text excludes the branch move.
rm "$A"; commit closed; BASE="$(git rev-parse HEAD)"
git checkout -q --detach "$FORK"; mv "$A" "$B"; commit moved; SIDE="$(git rev-parse HEAD)"
MERGE="$(git commit-tree "$(git rev-parse "$SIDE^{tree}")" -p "$BASE" -p "$SIDE" -m 'take second parent')"
scan "$MERGE"; assert_eq 0 "$COUNT"

it 'base merges advance start and never revive default-branch lines, including restores and moves'
for operation in keep restore move; do
    fresh; record "$A" "$FAIL"; commit inherited; FORK="$(git rev-parse HEAD)"
    rm "$A"; commit 'default closes'; BASE="$(git rev-parse HEAD)"
    git checkout -q --detach "$FORK"
    case "$operation" in
        keep) printf branch > source.txt; commit branch ;;
        restore) rm "$A"; commit removed; record "$A" "$FAIL"; commit restored ;;
        move) mv "$A" "$B"; commit moved; mv "$B" "$A"; commit returned ;;
    esac
    SIDE="$(git rev-parse HEAD)"
    MERGE="$(git commit-tree "$(git rev-parse "$BASE^{tree}")" -p "$SIDE" -p "$BASE" -m 'merge default closing')"
    scan "$MERGE"; assert_eq 0 "$COUNT" "$operation does not revive inherited FAIL"
done

it 'every merge base of C and start excludes inherited text in a criss-cross subhistory'
fresh; record "$A"; commit fork; FORK="$(git rev-parse HEAD)"
record "$A" "$FAIL"; commit inherited; X="$(git rev-parse HEAD)"
git checkout -q --detach "$FORK"; printf other > other.txt; commit other; Y="$(git rev-parse HEAD)"
BASE="$(git commit-tree "$(git rev-parse "$Y^{tree}")" -p "$X" -p "$Y" -m 'default removes FAIL')"
C="$(git commit-tree "$(git rev-parse "$X^{tree}")" -p "$Y" -p "$X" -m 'parallel merge')"
# Delete then restore at another path, so parent comparison alone cannot exclude it.
git checkout -q --detach "$C"; rm "$A"; commit removed; record "$B" "$FAIL"; commit restored
SIDE="$(git rev-parse HEAD)"
assert_eq 2 "$(git merge-base --all "$SIDE" "$BASE" | wc -l | tr -d ' ')" 'fixture has two fork points'
MERGE="$(git commit-tree "$(git rev-parse "$BASE^{tree}")" -p "$SIDE" -p "$BASE" -m integration)"
scan "$MERGE"; assert_eq 0 "$COUNT" 'all fork-point trees, at any path, govern inherited text'

it 'an unrelated merged root has no fork-point records and still introduces its active lines'
fresh; record "$A" "$FAIL"; git add "$A"
SIDE="$(git commit-tree "$(git write-tree)" -m 'unrelated root')"
MERGE="$(git commit-tree "$(git rev-parse "$SIDE^{tree}")" -p "$BASE" -p "$SIDE" -m 'join histories')"
scan "$MERGE"; assert_eq 1 "$COUNT"

it 'attributes and textconv cannot change the scan, including executable and awkwardly named records'
fresh
mkdir -p 'specs/changes/nested folder'
record 'specs/changes/nested folder/003-quoted"name.md' "$FAIL"
chmod +x 'specs/changes/nested folder/003-quoted"name.md'
printf 'specs/changes/** -diff\n' > .gitattributes; commit binary
scan; assert_eq 1 "$COUNT"
printf 'specs/changes/** diff=hide\n' > .gitattributes
git config diff.hide.textconv 'touch .git/textconv-called'
commit textconv; scan; assert_eq 1 "$COUNT"
assert_eq no "$([ -e .git/textconv-called ] && echo yes || echo no)" 'no diff driver invoked'

it 'raw blob and line identities preserve NUL bytes without passing them through shell variables'
fresh
printf '# Record\nignored\000bytes\n## State\n%s\000suffix\n' "$FAIL" > "$A"; commit binary
if review_legacy_awk_preserves_nul "$CACHE"; then
    scan; assert_eq 1 "$COUNT"
    DIGEST="$(printf 'prdkit-legacy\000001-original\000%s\000suffix' "$FAIL" | review_sha256)"
    assert_eq "${DIGEST:0:32}" "${FOUND%%$'\037'*}" 'identity includes every byte of the active line'
else
    run review_legacy_collect "$PROJ" "$CHECKED" "$BASE" HEAD "$RIGOR" "$CACHE" "$CACHE/result"
    assert_eq 1 "$STATUS" 'non-preserving native awk must refuse binary records'
    assert_eq no "$([ -f "$CACHE/result" ] && echo yes || echo no)" 'no partial result'
    assert_contains "$OUTPUT" "$A: awk cannot read NUL bytes"
    assert_contains "$OUTPUT" 'run the gate with an awk that preserves them (for example gawk)'
fi

it 'NUL suffixes remain distinct identities, or the scan refuses before the exclusion join'
fresh; CHECKED=001-original
printf '# Record\n## State\n%s\000first\n' "$FAIL" > "$A"; commit inherited
BASE="$(git rev-parse HEAD)"
printf '# Record\n## State\n%s\000second\n' "$FAIL" > "$A"; commit introduced
if review_legacy_awk_preserves_nul "$CACHE"; then
    scan; assert_eq 2 "$COUNT" 'a different NUL suffix cannot be excluded as the parent line'
    for suffix in first second; do
        DIGEST="$(printf 'prdkit-legacy\000001-original\000%s\000%s' "$FAIL" "$suffix" | review_sha256)"
        assert_contains "$FOUND" "${DIGEST:0:32}"
    done
else
    run review_legacy_collect "$PROJ" "$CHECKED" "$BASE" HEAD "$RIGOR" "$CACHE" "$CACHE/result"
    assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" "$A: awk cannot read NUL bytes"
fi

it 'Linux also exercises refusal with an empty sentinel or a truncating record reader'
for length in 0 1; do
    fresh; record specs/changes/000-earlier.md "$FAIL"
    printf '# Record\n## State\n%s\000hidden suffix\n' "$FAIL" > "$A"; commit binary
    # Reuse a preserving reader's cache when available: cache reuse must not bypass the guard.
    if review_legacy_awk_preserves_nul "$CACHE"; then scan; fi
    PATH="$AWK_SHIM:$PATH" AWK_SHIM_NUL_LENGTH="$length" AWK_SHIM_TRUNCATE_NUL=true \
        run review_legacy_awk_preserves_nul "$CACHE"
    assert_eq 1 "$STATUS" 'both sentinel and byte-exact round-trip checks are required'
    PATH="$AWK_SHIM:$PATH" AWK_SHIM_NUL_LENGTH="$length" AWK_SHIM_TRUNCATE_NUL=true \
        run review_legacy_collect "$PROJ" "$CHECKED" "$BASE" HEAD "$RIGOR" "$CACHE" "$CACHE/refused"
    assert_eq 1 "$STATUS"
    assert_eq no "$([ -f "$CACHE/refused" ] && echo yes || echo no)" 'earlier blockers are not published as a partial scan'
    assert_contains "$OUTPUT" "$A: awk cannot read NUL bytes"
    assert_contains "$OUTPUT" 'run the gate with an awk that preserves them (for example gawk)'
done

it 'unreadable counts/verdicts block, including low counts; readable owner PASS needs no counts'
fresh
record "$A" "$PASS"
printf '%s\n' \
    '**Review**: round 3 · ignored · code · PASS · missing counts' \
    '**Review**: round 4 · ignored · code · MAYBE · 0 critical, 0 high, 0 medium, 0 low' \
    '**Review**: round 5 · ignored · code · PASS · 0 critical, 0 high, 0 medium' \
    '**Review**: round 6 · ignored · owner · PASS' \
    '**Review**: round 7 · ignored · owner · FAIL' \
    '**Review**: round 8 · ignored · owner · unreadable' \
    '**Review**: broken' >> "$A"
commit malformed; scan; assert_eq 6 "$COUNT"
assert_contains "$FOUND" '(unnamed)'
assert_contains "$FOUND" 'owner legacy verdict'
fresh; record "$A" "**Review**: round 1 · ignored · code · PASS · 0 critical, 0 high, 1 medium, 2 low"
commit medium; scan; assert_eq 0 "$COUNT"
RIGOR=full; scan; assert_eq 1 "$COUNT"
RIGOR=unknown; scan; assert_eq 1 "$COUNT"

it 'unavailable evidence fails without a partial or empty success'
run review_legacy_collect "$PROJ" "$CHECKED" "$BASE" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa light "$CACHE" "$CACHE/missing"
assert_eq 1 "$STATUS"
assert_eq no "$([ -f "$CACHE/missing" ] && echo yes || echo no)"
git config remote.origin.promisor true
git config remote.origin.url https://example.invalid/never-fetch
# On old Git this rejects before object reads; newer Git enforces GIT_NO_LAZY_FETCH.
run review_legacy_collect "$PROJ" "$CHECKED" "$BASE" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa light "$CACHE" "$CACHE/missing"
assert_eq 1 "$STATUS"
git config --unset remote.origin.promisor
fresh; record "$A" "$FAIL"; commit failure
BLOB="$(git rev-parse "HEAD:$A")"
rm ".git/objects/${BLOB:0:2}/${BLOB:2}"
run review_legacy_collect "$PROJ" "$CHECKED" "$BASE" HEAD light "$CACHE" "$CACHE/missing-blob"
assert_eq 1 "$STATUS" 'missing raw blob is not an empty record'
assert_eq no "$([ -f "$CACHE/missing-blob" ] && echo yes || echo no)"
finish
