#!/usr/bin/env bash
# Real installed reader and budget behavior; raw Markdown remains the source artifact.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
READER="$PROJ/.prdkit/scripts/bash/read-spec.sh"
source "$PROJ/.prdkit/scripts/bash/spec-lib.sh"
mkdir -p specs/product
FILE=specs/product/requirements.md

fixture() {
    {
        printf '# Requirements\n\nAn authored [citation][paper] stays visible.\n[paper]: https://example.test/paper "Evidence"\n\n'
        i=1
        while [ "$i" -le 50 ]; do
            printf -- '- **R-%02d Item**: keep this requirement.\n  Tracking: [REC-%d][nav-rec-%d]\n' "$i" "$i" "$i"
            i=$((i + 1))
        done
        printf '\n<!-- prdkit:navigation:v1 begin -->\n'
        i=1
        while [ "$i" -le 50 ]; do
            printf '[nav-rec-%d]: https://tracker.example.test/items/REC-%d\n' "$i" "$i"
            i=$((i + 1))
        done
        printf '<!-- prdkit:navigation:v1 end -->\n'
    } > "$FILE"
}
fixture
before="$(git hash-object "$FILE")"
it "fifty definitions share one recognizer for prose budget and context omission"
run spec_reading_lines "$FILE"
assert_eq '106 158' "$OUTPUT" "visible IDs and prose count; 52 footer lines do not"
run bash "$READER" --stats "$FILE"
assert_eq 0 "$STATUS" "stats succeeds"
assert_contains "$OUTPUT" 'state=valid' "valid footer recognized"
assert_contains "$OUTPUT" 'raw_lines=158' "raw line count"
assert_contains "$OUTPUT" 'prose_reading_lines=106' "stats agrees with budget"
assert_contains "$OUTPUT" 'omitted_lines=52 definitions=50' "exact navigation omission count"
assert_contains "$OUTPUT" "raw_bytes=$(wc -c < "$FILE" | tr -d ' ')" "exact raw bytes"
assert_contains "$OUTPUT" "content_blob=$before" "identity binds the actual source bytes"
run bash "$READER" "$FILE"
assert_eq 0 "$STATUS" "compact read succeeds"
assert_contains "$OUTPUT" '6: - **R-01 Item**' "original line numbers survive"
assert_contains "$OUTPUT" 'Tracking: [REC-50][nav-rec-50]' "record IDs and mappings survive"
assert_contains "$OUTPUT" '[paper]: https://example.test/paper "Evidence"' "authored evidence stays"
assert_not_contains "$OUTPUT" 'https://tracker.example.test/items/' "navigation URLs never reach compact context"
assert_not_contains "$OUTPUT" '<!-- prdkit:navigation:v1' "valid envelope is omitted"
assert_eq "$before" "$(git hash-object "$FILE")" "source is unchanged"
run bash "$READER" --target NAV-REC-1 "$FILE"
assert_eq 0 "$STATUS" "individual target lookup succeeds"
assert_contains "$OUTPUT" '108: [nav-rec-1]: https://tracker.example.test/items/REC-1' "lookup keeps raw location"
run bash "$READER" --target nav-missing "$FILE"
assert_eq 1 "$STATUS" "unknown target fails"
bash "$READER" --raw "$FILE" > raw.md
assert_eq "$before" "$(git hash-object raw.md)" "raw read is byte-for-byte"

it "doctor excludes valid navigation from reading-budget excess and counts invalid navigation"
# Make 158 raw lines fit the 150-line observed budget after only generated navigation is omitted.
cp "$FILE" specs/observed.md
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh" --json
assert_eq 0 "$STATUS" "doctor accepts the valid footer"
assert_not_contains "$OUTPUT" 'Budget: specs/observed.md' "doctor does not count valid navigation"
assert_not_contains "$OUTPUT" 'Generated navigation retained' "valid footer needs no advisory"
assert_eq 0 "$(printf '%s\n' "$OUTPUT" | jq '.budget_excess_reading_lines')" "valid footer contributes no excess"
sed 's/v1 end/v2 end/' "$FILE" > specs/observed.md
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh" --json
assert_eq 0 "$STATUS" "retaining the invalid footer is advisory"
assert_contains "$OUTPUT" 'specs/observed.md: Generated navigation retained' "invalid footer gets a diagnostic"
assert_eq 8 "$(printf '%s\n' "$OUTPUT" | jq '.budget_excess_reading_lines')" "all 158 lines count when the footer is invalid"
rm specs/observed.md

it "CRLF, UTF-8 and missing final newline retain correct counts and source locations"
printf '# Café\nTracking: [A-1][nav-a]\n<!-- prdkit:navigation:v1 begin -->\n[nav-a]: https://example.test/items/A-1\n<!-- prdkit:navigation:v1 end -->' > "$FILE"
run spec_navigation "$FILE" stats
assert_contains "$OUTPUT" "raw_bytes=$(wc -c < "$FILE" | tr -d ' ')" "no-newline bytes match"
assert_contains "$OUTPUT" 'prose_reading_lines=2' "UTF-8 prose budget"
assert_contains "$OUTPUT" 'omitted_lines=3 definitions=1' "no-newline footer works"
printf '# Café\r\nTracking: [A-1][nav-a]\r\n<!-- prdkit:navigation:v1 begin -->\r\n[nav-a]: https://example.test/items/A-1\r\n<!-- prdkit:navigation:v1 end -->\r\n' > "$FILE"
run spec_navigation "$FILE" stats
assert_contains "$OUTPUT" "raw_bytes=$(wc -c < "$FILE" | tr -d ' ')" "CRLF bytes match"
assert_contains "$OUTPUT" 'state=valid' "CRLF footer works"

retained() {
    local reason="$1" raw_lines
    raw_lines="$(awk 'END { print NR }' "$FILE")"
    run spec_reading_lines "$FILE"
    assert_eq "$raw_lines $raw_lines" "$OUTPUT" "$reason counts all short lines"
    run bash "$READER" "$FILE"
    assert_eq 0 "$STATUS" "$reason remains readable"
    assert_contains "$OUTPUT" 'state=retained-invalid' "$reason has a diagnostic state"
    assert_contains "$OUTPUT" 'omitted_bytes=0 omitted_lines=0' "$reason omits nothing"
    assert_contains "$OUTPUT" 'Generated navigation retained:' "$reason explains retention"
    assert_contains "$OUTPUT" 'https://example.test/items/A-1' "$reason keeps the raw target"
    run bash "$READER" --target nav-a "$FILE"
    assert_eq 1 "$STATUS" "$reason does not claim a validated mapping"
}
small() {
    printf '# Spec\nTracking: [A-1][nav-a]\n<!-- prdkit:navigation:v1 begin -->\n[nav-a]: https://example.test/items/A-1\n<!-- prdkit:navigation:v1 end -->\n' > "$FILE"
}
it "mixed, conflicting, malformed and unsupported content stays visible and counted"
small; printf 'Substantive prose after footer.\n' >> "$FILE"; retained 'not a footer'
small; sed '/^\[nav-a\]:/a\
Substantive prose.
' "$FILE" > edit.md; mv edit.md "$FILE"; retained 'mixed prose'
small; sed '/^\[nav-a\]:/a\
[NAV-A]: https://example.test/items/other
' "$FILE" > edit.md; mv edit.md "$FILE"; retained 'duplicate label'
small; printf '[ NAV-A ]: https://example.test/authored\n' | cat - "$FILE" > edit.md; mv edit.md "$FILE"; retained 'authored case-insensitive conflict'
small; sed 's/v1 end/v2 end/' "$FILE" > edit.md; mv edit.md "$FILE"; retained 'unknown version'
small; sed '$d' "$FILE" > edit.md; mv edit.md "$FILE"; retained 'missing end'
small; sed '/^Tracking:/d' "$FILE" > edit.md; mv edit.md "$FILE"; retained 'unreferenced label'
small; sed 's/^Tracking:/Evidence:/' "$FILE" > edit.md; mv edit.md "$FILE"; retained 'authored citation'
small; sed 's/^Tracking:.*$/Tracking: [A-1][nav-a] evidence/' "$FILE" > edit.md; mv edit.md "$FILE"; retained 'mixed tracking line'
small; sed 's|items/A-1$|items/A-1 "Evidence"|' "$FILE" > edit.md; mv edit.md "$FILE"; retained 'definition title'
small; printf 'More evidence [nav-a].\n' | cat - "$FILE" > edit.md; mv edit.md "$FILE"; retained 'shortcut use'
small; printf '<div>\n' | cat - "$FILE" > edit.md; mv edit.md "$FILE"; retained 'HTML context'
small; cat "$FILE" "$FILE" > edit.md; mv edit.md "$FILE"; retained 'multiple blocks'
small; sed '/^\[nav-a\]:/a\
<!-- prdkit:navigation:v1 begin -->
' "$FILE" > edit.md; mv edit.md "$FILE"; retained 'nested blocks'
small; sed 's/^Tracking:.*/Tracking: [A-1][nav-a] [A-2][nav-b]/' "$FILE" > edit.md; mv edit.md "$FILE"; retained 'unresolved mapping'
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh"
assert_contains "$OUTPUT" 'specs/product/requirements.md: Generated navigation retained:' "doctor exposes invalid blocks"

it "fenced examples are not footers, including tilde and longer backtick fences"
for fence in '```' '````' '~~~'; do
    small
    { printf '%smarkdown\n' "$fence"; cat "$FILE"; printf '%s\n' "$fence"; } > edit.md
    mv edit.md "$FILE"
    run spec_navigation "$FILE" stats
    assert_contains "$OUTPUT" 'state=absent' "fenced $fence example has no active footer"
    assert_contains "$OUTPUT" 'omitted_bytes=0 omitted_lines=0' "fenced $fence content counts"
    run bash "$READER" "$FILE"
    assert_contains "$OUTPUT" '[nav-a]: https://example.test/items/A-1' "fenced $fence URL stays visible"
done

it "ordinary files retain original long-line and Unicode budget accounting"
printf '# Ordinary\n[paper]: https://example.test/paper "Evidence"\n' > "$FILE"
awk 'BEGIN { for (i=1;i<=101;i++) printf "é"; print "" }' >> "$FILE"
run spec_reading_lines "$FILE"
assert_eq '4 3' "$OUTPUT" "101 Unicode characters count as two reading lines"

it "upgrade installs the reader and preserves authored source"
small; before="$(git hash-object "$FILE")"
rm "$READER"
snapshot_upgrade_fixture "$PROJ" || exit 1
run bash "$PK_ROOT/scripts/init.sh" --upgrade --target "$PROJ"
assert_eq 0 "$STATUS" "upgrade succeeds: $OUTPUT"
assert_eq "$before" "$(git hash-object "$FILE")" "upgrade never rewrites navigation"
run bash "$READER" "$FILE"
assert_contains "$OUTPUT" 'state=valid' "installed upgraded recognizer works"

it "doctor fails truthfully if the navigation/budget parser cannot execute"
mkdir -p failbin
cat > failbin/awk <<'SH'
#!/usr/bin/env bash
case "$*" in *projection=prdkit-navigation-v1*) exit 2 ;; esac
exec "$NAV_REAL_AWK" "$@"
SH
chmod +x failbin/awk
run env NAV_REAL_AWK="$(command -v awk)" PATH="$PROJ/failbin:$PATH" \
    bash "$PROJ/.prdkit/scripts/bash/doctor.sh" --json
assert_eq 1 "$STATUS" "parser failure is a failing doctor result"
assert_contains "$OUTPUT" 'Budget reader failed: specs/product/requirements.md' "the failed budget is named"
assert_not_contains "$OUTPUT" 'integer expression expected' "empty parser output is not used as a count"
finish
