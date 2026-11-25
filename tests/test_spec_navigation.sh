#!/usr/bin/env bash
# Real installed reader and budget behavior; raw Markdown remains the source artifact.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project --with agent-tiers)"; track_tmp "$PROJ"
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
run bash "$READER" --target '\156av-rec-1' "$FILE"
assert_eq 1 "$STATUS" "a target selector is literal, not an awk escape"
bash "$READER" --raw "$FILE" > raw.md
assert_eq "$before" "$(git hash-object raw.md)" "raw read is byte-for-byte"

it "focused views use the legacy validated footer and reading-line weights"
run bash "$READER" --index "$FILE"
assert_eq 0 "$STATUS"
assert_eq '1: # Requirements (106 reading lines)' "${OUTPUT#*$'\n'}" "the index is a heading tree, not a source dump"
run bash "$READER" --section r-50 "$FILE"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" "content_blob=$before" "the source is the working-tree blob"
assert_contains "$OUTPUT" '105:   Tracking: [REC-50][nav-rec-50]' "original numbering"
assert_not_contains "$OUTPUT" 'projection=' "section has no stats preamble"
assert_not_contains "$OUTPUT" 'https://tracker.example.test' "validated footer is not repeated"

it "nested headings and item IDs identify exactly one original span"
SECTIONS=specs/sections.md
cat > "$SECTIONS" <<'MD'
# Product
Preface cites R-02.
## Accounts ##
- **R-01 Creation**: create accounts.
Tracking: [REC-1][nav-a] [REC-2][nav-b]
Tracking: [REC-1][nav-a]
<!-- examples
## Hidden comment
- **R-90 Comment**
-->
````markdown
## Hidden backticks
```
- **R-91 Code**
````
~~~
## Hidden tildes
~~~
### Safety
MD
long_line="$(awk 'BEGIN { for (i=1;i<=101;i++) printf "é" }')"
printf '%s\n' "$long_line" >> "$SECTIONS"
cat >> "$SECTIONS" <<'MD'
## Other
- **R-02 Other**: unrelated.
Tracking: [REC-2][nav-b]
## Shared
## Shared
## H-07 Hold details
## Path \name (literal?)
<!-- prdkit:navigation:v1 begin -->
[nav-a]: https://example.test/items/REC-1
[nav-b]: https://example.test/items/REC-2
<!-- prdkit:navigation:v1 end -->
MD
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq "$(cat <<'INDEX'
1: # Product (28 reading lines)
3:   ## Accounts (19 reading lines)
19:     ### Safety (3 reading lines)
21:   ## Other (3 reading lines)
24:   ## Shared (1 reading line)
25:   ## Shared (1 reading line)
26:   ## H-07 Hold details (1 reading line)
27:   ## Path \name (literal?) (1 reading line)
INDEX
)" "${OUTPUT#*$'\n'}" "nested counts include descendants, long lines and literal source examples"
for heading in ' Accounts ' r-01; do
    run bash "$READER" --section "$heading" "$SECTIONS"
    assert_eq 0 "$STATUS" "$heading resolves"
    assert_eq "$(awk 'NR >= 3 && NR <= 20 { print NR ": " $0 }' "$SECTIONS")" "${OUTPUT#*$'\n'}" \
        "selection stops before the next sibling and retains literal examples"
done
run bash "$READER" --section R-02 "$SECTIONS"
assert_eq 0 "$STATUS" "a prose reference in another section is not a definition"
assert_eq "$(awk 'NR >= 21 && NR <= 23 { print NR ": " $0 }' "$SECTIONS")" "${OUTPUT#*$'\n'}"
run bash "$READER" --section h-07 "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq '26: ## H-07 Hold details' "${OUTPUT#*$'\n'}"
run bash "$READER" --section 'path   \name (literal?)' "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq '27: ## Path \name (literal?)' "${OUTPUT#*$'\n'}" "selector is literal and last section stops at EOF"

it "ambiguous or missing selectors report candidate locations and no selected content"
run bash "$READER" --section Shared "$SECTIONS"
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'Ambiguous section selector'
assert_contains "$OUTPUT" 'Available candidates:'
assert_not_contains "$OUTPUT" 'Source:' "no source header promises a selected section"
assert_contains "$OUTPUT" '24:   ## Shared'
assert_contains "$OUTPUT" '25:   ## Shared'
for heading in R-90 R-91 'Hidden backticks' 'Hidden tildes' 'Hidden comment' REC-1 REC-2 nav-a ''; do
    run bash "$READER" --section "$heading" "$SECTIONS"
    assert_eq 2 "$STATUS"
    assert_contains "$OUTPUT" 'Available candidates:'
    assert_contains "$OUTPUT" '3:   ## Accounts [IDs: R-01]'
done
bash "$READER" --section "$SECTIONS" > stdout 2> stderr
assert_eq 2 "$?"
assert_eq '' "$(cat stdout)" "selection errors go to stderr"
assert_contains "$(cat stderr)" 'Missing section selector. Available candidates:'
run bash "$READER" --section Accounts --index "$SECTIONS"
assert_eq 2 "$STATUS" "modes are mutually exclusive"
run bash "$READER" --help
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '--index'
assert_contains "$OUTPUT" '--section'

it "record IDs register only from well-formed rows inside a delimited table"
printf '%s\n' '# Records' '## Paused' '| Record |' '|---|' \
    '| HOLD stop-01 owner=owner scope=all since=2026-01-01 until=lifted — Pause. |' \
    '| HOLD prose-01 is a note. |' \
    '| HOLD wrong-date owner=owner scope=all since=yesterday until=lifted |' \
    '| WAIVER missing-field owner=owner check=A1 expires=2026-01-01 |' \
    '| HOLD broken-ref owner=owner scope=all since=2026-01-01 until=lifted — ref=specs/authority.md#H-01@short |' \
    '## Notes' 'HOLD stop-01 owner=owner scope=all since=2026-01-01 until=lifted' \
    'HOLD plain-01 owner=owner scope=all since=2026-01-01 until=lifted' \
    '| Record |' '| HOLD no-table owner=owner scope=all since=2026-01-01 until=lifted |' > "$SECTIONS"
run bash "$READER" --section stop-01 "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq "$(awk 'NR >= 2 && NR <= 9 { print NR ": " $0 }' "$SECTIONS")" "${OUTPUT#*$'\n'}"
for id in prose-01 wrong-date missing-field broken-ref plain-01 no-table; do
    run bash "$READER" --section "$id" "$SECTIONS"
    assert_eq 2 "$STATUS" "$id is not defined"
    assert_contains "$OUTPUT" 'No match for section selector'
done

it "part definitions in a Parts table or a part heading resolve, but citations do not"
cp "$PK_ROOT/examples/request-service/specs/architecture.md" "$SECTIONS"
printf '\n## Citations\n\n| Reference | Note |\n|---|---|\n| P1 citation | P2 is also cited. |\n' >> "$SECTIONS"
printf '\n## Discussion\n\n| Part | Note |\n| P1 is referenced here | This is just an example. |\n| P9 not a part | Also an example. |\n' >> "$SECTIONS"
run bash "$READER" --section p1 "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq "$(awk 'NR >= 19 && NR <= 25 { print NR ": " $0 }' "$SECTIONS")" "${OUTPUT#*$'\n'}"
run bash "$READER" --section P9 "$SECTIONS"
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'No match for section selector'
printf '%s\n' '# P1.2 Storage' '## Why it exists' 'P1.2 keeps records.' \
    '## Retired' '- P3 Older component: retired: moved elsewhere' > "$SECTIONS"
run bash "$READER" --section P1.2 "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq "$(awk '{ print NR ": " $0 }' "$SECTIONS")" "${OUTPUT#*$'\n'}"
run bash "$READER" --section P3 "$SECTIONS"
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'No match for section selector' "plain retired items are not focused definitions"

it "focused views refuse Setext boundaries without changing raw or compact accounting"
for underline in '---' '===='; do
    printf '%s\n' '# Spec' '## Scope' 'In scope.' '' 'Exceptions' "$underline" '- **R-08 Separate item**' '## Following' > "$SECTIONS"
    for mode in index section; do
        args=(--index)
        if [ "$mode" = section ]; then args=(--section Scope); fi
        bash "$READER" "${args[@]}" "$SECTIONS" > stdout 2> stderr
        assert_eq 2 "$?" "$mode refuses $underline"
        assert_eq '' "$(cat stdout)"
        assert_contains "$(cat stderr)" "$SECTIONS: 6: Setext"
        assert_contains "$(cat stderr)" 'use --raw'
    done
    run bash "$READER" --stats "$SECTIONS"
    assert_eq 0 "$STATUS"
    assert_contains "$OUTPUT" 'raw_reading_lines=8 prose_reading_lines=8'
    bash "$READER" --raw "$SECTIONS" > raw.md
    run cmp -s "$SECTIONS" raw.md
    assert_eq 0 "$STATUS"
done
printf '%s\n' '# Spec' 'Body.' '' '---' '```md' 'Fenced example' '===' '```' \
    '<!-- example' 'Commented example' '---' '-->' '## Next' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS" "a thematic break after a blank and literal examples are not headings"
assert_eq $'1: # Spec (13 reading lines)\n13:   ## Next (1 reading line)' "${OUTPUT#*$'\n'}"
run bash "$READER" --section Next "$SECTIONS"
assert_eq 0 "$STATUS"

it "Setext refusal distinguishes paragraphs from delimited tables and references"
printf '%s\n' '# Scope' '' '| Exceptions' '----------' '- **R-08 Separate subsection**' '' '## Following' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" "$SECTIONS: 4: Setext"
run bash "$READER" --section R-08 "$SECTIONS"
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" "$SECTIONS: 4: Setext"
printf '%s\n' '# Scope' '' '[ref]: https://example.test' '---' '' \
    '| Item | Note |' '|:---|---:|' '| Example | Note |' '---' '' '- A list item' '---' '## Following' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq $'1: # Scope (13 reading lines)\n13:   ## Following (1 reading line)' "${OUTPUT#*$'\n'}"

it "only contiguous, correctly indented, matching fence runs can close a column-zero example"
for fence in '```' '~~~'; do
    printf '%s\n' '# Spec' "$fence${fence:0:1}md" "$fence $fence" "    $fence$fence" \
        "$fence$fence trailing text" "$fence" '## Fake' '- **R-02 Fenced example**' \
        "   $fence$fence   " '## Real' 'A paragraph starts here.' '    Code.' '### Still visible' '- **R-03 Real item**' > "$SECTIONS"
    run bash "$READER" --index "$SECTIONS"
    assert_eq 0 "$STATUS"
    assert_eq $'1: # Spec (14 reading lines)\n10:   ## Real (5 reading lines)\n13:     ### Still visible (2 reading lines)' "${OUTPUT#*$'\n'}"
    run bash "$READER" --section R-02 "$SECTIONS"
    assert_eq 2 "$STATUS"
    assert_not_contains "$OUTPUT" 'Fake'
    run bash "$READER" --section R-03 "$SECTIONS"
    assert_eq 0 "$STATUS"
    assert_eq $'13: ### Still visible\n14: - **R-03 Real item**' "${OUTPUT#*$'\n'}"
done
printf '%s\n' '# Spec' '<!-- Notes on the prdkit:navigation: format' '## Hidden' \
    '- **R-50 Commented example**' '-->' '## After' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq $'1: # Spec (6 reading lines)\n6:   ## After (1 reading line)' "${OUTPUT#*$'\n'}"
run bash "$READER" --section R-50 "$SECTIONS"
assert_eq 2 "$STATUS"
assert_not_contains "$OUTPUT" 'Hidden'
run bash "$READER" --stats "$SECTIONS"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" 'state=retained-invalid'
assert_contains "$OUTPUT" 'omitted_bytes=0 omitted_lines=0'
printf '%s\n' '# Spec' '' '    ```md' '' '## Real' 'Tracking: [A-1][nav-a]' \
    '<!-- prdkit:navigation:v1 begin -->' '[nav-a]: https://example.test/items/A-1' \
    '<!-- prdkit:navigation:v1 end -->' > "$SECTIONS"
run spec_reading_lines "$SECTIONS"
assert_eq '9 9' "$OUTPUT" "legacy budgets still interpret over-indented fence openers as on main"

it "indented code, continued prose and nested list items remain opaque"
printf '%s\n' '# Scope' '' '## First' 'Paragraph.' \
    '    ## Not a heading' '    - **R-77 Literal, not a bullet**' '' '## Second' \
    '- **R-77 Actual requirement**' '    An indented continuation.' '' '    - **R-78 Nested requirement**' \
    '' 'Outside the list.' '    - **R-79 Literal after the list**' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq $'1: # Scope (15 reading lines)\n3:   ## First (5 reading lines)\n8:   ## Second (8 reading lines)' "${OUTPUT#*$'\n'}"
run bash "$READER" --section R-77 "$SECTIONS"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '8: ## Second'
assert_not_contains "$OUTPUT" 'Literal, not a bullet'
for id in R-78 R-79; do
    run bash "$READER" --section "$id" "$SECTIONS"
    assert_eq 2 "$STATUS"
    assert_contains "$OUTPUT" 'No match for section selector'
done

it "an indented comment closer preserves main's legacy footer and ends the focused literal"
printf '%s\n' '# Spec' '<!-- Note' '    -->' '## Real' 'Tracking: [REC-1][nav-a]' \
    '<!-- prdkit:navigation:v1 begin -->' '[nav-a]: https://example.test/items/REC-1' \
    '<!-- prdkit:navigation:v1 end -->' > "$SECTIONS"
run spec_reading_lines "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq '5 8' "$OUTPUT"
run bash "$READER" --target nav-a "$SECTIONS"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '7: [nav-a]: https://example.test/items/REC-1'
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq $'1: # Spec (5 reading lines)\n4:   ## Real (2 reading lines)' "${OUTPUT#*$'\n'}"
run bash "$READER" --section Real "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq $'4: ## Real\n5: Tracking: [REC-1][nav-a]' "${OUTPUT#*$'\n'}"

it "paragraph continuations cannot hide Setext boundaries; references cannot interrupt prose"
for underline in '---' '==='; do
    printf '%s\n' '## Context' '' 'Some heading text' '    continued on another line' "$underline" \
        '- **R-22 Actual**' '## After' > "$SECTIONS"
    run bash "$READER" --index "$SECTIONS"
    assert_eq 2 "$STATUS"
    assert_contains "$OUTPUT" "$SECTIONS: 5: Setext"
    run bash "$READER" --section R-22 "$SECTIONS"
    assert_eq 2 "$STATUS"
    assert_contains "$OUTPUT" "$SECTIONS: 5: Setext"
done
printf '%s\n' '## Context' 'Some heading text' '[ref]: https://example.test' '---' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" "$SECTIONS: 4: Setext"
printf '%s\n' '## Context' '[ref]:' '    https://example.test' '    "a title"' '---' \
    '' '[unresolved]:' '#' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '8: # (untitled) (1 reading line)' "a reference must not consume a heading"

it "nested fences hide their example IDs but other HTML blocks and quotes refuse"
for fence in '```' '~~~'; do
    printf '%s\n' '# Spec' '## Example' '- An item.' "    $fence" '    - **R-28 Literal example**' \
        "    $fence" '    - **R-29 Nested item**' '## Later' > "$SECTIONS"
    run bash "$READER" --index "$SECTIONS"
    assert_eq 0 "$STATUS"
    assert_eq $'1: # Spec (8 reading lines)\n2:   ## Example (6 reading lines)\n8:   ## Later (1 reading line)' "${OUTPUT#*$'\n'}"
    run bash "$READER" --section R-28 "$SECTIONS"
    assert_eq 2 "$STATUS"
    assert_contains "$OUTPUT" 'No match for section selector'
    assert_not_contains "$OUTPUT" '[IDs: R-28'
    run bash "$READER" --section R-29 "$SECTIONS"
    assert_eq 2 "$STATUS"
    assert_contains "$OUTPUT" 'No match for section selector'
done
printf '%s\n' '# Spec' '- First item' '2. Another list' '    ```' '    - **R-28 Literal**' '    ```' \
    '## Later' '- **R-28 Actual item**' > "$SECTIONS"
run bash "$READER" --section R-28 "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq $'7: ## Later\n8: - **R-28 Actual item**' "${OUTPUT#*$'\n'}"
for context in '<div>' '> quoted context'; do
    printf '%s\n' '# Spec' '## First' 'Actual prose.' "$context" '## Fake' '</div>' '## Later' > "$SECTIONS"
    run bash "$READER" --index "$SECTIONS"
    assert_eq 2 "$STATUS"
    assert_contains "$OUTPUT" "$SECTIONS: 4:"
    assert_contains "$OUTPUT" 'use --raw'
    run bash "$READER" --section First "$SECTIONS"
    assert_eq 2 "$STATUS" "all content is validated before returning even an earlier section"
    assert_contains "$OUTPUT" "$SECTIONS: 4:"
    assert_not_contains "$OUTPUT" 'Source:'
done

it "GFM cells determine part definitions independent of outer and escaped pipes"
for variant in one escaped bare; do
    case "$variant" in
        one) header='| Part'; delimiter='|---|'; row='| P1 Real definition |' ;;
        escaped) header='| Part | State \| Detail |'; delimiter='|---|---|'; row='| P1 Café \| 雪 | test |' ;;
        bare) header='Part | State'; delimiter='--- | ---'; row='P1 Real definition | test' ;;
    esac
    printf '%s\n' '# Spec' '## Parts' "$header" "$delimiter" "$row" \
        '## Tracking' 'Tracking: [P1][nav-p1]' > "$SECTIONS"
    run bash "$READER" --section P1 "$SECTIONS"
    assert_eq 0 "$STATUS" "$variant table defines P1, Tracking does not"
    assert_contains "$OUTPUT" '2: ## Parts'
    assert_contains "$OUTPUT" "5: $row"
    assert_not_contains "$OUTPUT" '## Tracking'
done

refuses_focused() { # expected line and diagnostic prefix; fixture has an Intro heading
    local mode args
    for mode in index section; do
        args=(--index)
        if [ "$mode" = section ]; then args=(--section Intro); fi
        bash "$READER" "${args[@]}" "$SECTIONS" > stdout 2> stderr
        assert_eq 2 "$?" "$mode refuses $1"
        assert_eq '' "$(cat stdout)" "no partial projection"
        assert_contains "$(cat stderr)" "$SECTIONS: $1"
        assert_contains "$(cat stderr)" 'use --raw'
    done
}

it "an empty bullet cannot make a shallow heading or indented code structural"
for spacing in ' ' '  ' '   ' $'\t' $' \t '; do
    printf '%s\n' '# Spec' '## Intro' '-' '' "${spacing}## Next" 'Some content.' > "$SECTIONS"
    refuses_focused '5: Indented ATX heading'
done
printf '%s\n' '# Spec' '## Intro' '-' '' '    - **R-01 Literal**' '## Next' 'Some content.' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq $'1: # Spec (7 reading lines)\n2:   ## Intro (4 reading lines)\n6:   ## Next (2 reading lines)' "${OUTPUT#*$'\n'}"
run bash "$READER" --section R-01 "$SECTIONS"
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'No match for section selector'

it "a column-zero table must start the file or follow a heading or blank"
printf '%s\n' '# Spec' '## Tasks' '- Parent' 'Part | State' '--- | ---' 'P1 Actual | yes' '## Real' > "$SECTIONS"
run bash "$READER" --section P1 "$SECTIONS"
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" "$SECTIONS: 4: A table header"
for preceding in '- Parent' 'A paragraph.'; do
    printf '%s\n' '# Spec' '## Intro' 'Read this section.' '## Tasks' "$preceding" \
        'Part | State' '--- | ---' 'P1 Actual | yes' '## Real' > "$SECTIONS"
    refuses_focused '6: A table header'
    run bash "$READER" --section P1 "$SECTIONS"
    assert_eq 2 "$STATUS"
    assert_contains "$OUTPUT" "$SECTIONS: 6: A table header"
done
printf '%s\n' '# Spec' '## Intro' '- Parent' '' 'Part | State' '--- | ---' 'P1 Actual | yes' '## Real' > "$SECTIONS"
run bash "$READER" --section P1 "$SECTIONS"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '7: P1 Actual | yes'
printf '%s\n' 'Part | State' '--- | ---' 'P1 Actual | yes' '## Real' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq '4: ## Real (1 reading line)' "${OUTPUT#*$'\n'}"

it "only column-zero bullets with a same-line bold span define item IDs"
printf '%s\n' '# Spec' '## Mention' '- **R-77 is referenced here but not defined' \
    '- **R-76 Escaped \**' ' - **R-75 Indented**' '1. **R-74 Ordered**' \
    '## Actual' '- **R-88** actual requirement' '* **R-89 With title**' '+ **P2 A part**' > "$SECTIONS"
for id in R-77 R-76 R-75 R-74; do
    run bash "$READER" --section "$id" "$SECTIONS"
    assert_eq 2 "$STATUS"
    assert_contains "$OUTPUT" 'No match for section selector'
done
for id in R-88 R-89 P2; do
    run bash "$READER" --section "$id" "$SECTIONS"
    assert_eq 0 "$STATUS"
    assert_contains "$OUTPUT" '7: ## Actual'
done
printf '%s\n' '## A' '- **R-88**' '## B' '+ **R-88**' > "$SECTIONS"
run bash "$READER" --section R-88 "$SECTIONS"
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'Ambiguous section selector'
assert_contains "$OUTPUT" '1: ## A [IDs: R-88]'
assert_contains "$OUTPUT" '3: ## B [IDs: R-88]'

it "indented fences refuse column-zero structure until a matching closer at any indentation"
for structural in '## Heading' '- **R-90 Example**' '| Part | State |' 'P1 | yes' '~~~' '<!-- comment -->'; do
    printf '%s\n' '# Spec' '## Intro' 'Read this section.' '## Example' '  ````markdown' \
        '    ```' '    ````` trailing text' "$structural" ' ````' '## Later' > "$SECTIONS"
    refuses_focused '8: Column-zero structure'
done
printf '%s\n' '# Spec' '## Intro' $'\t~~~' '- **R-90 not closed' '    ## Example' \
    'some ordinary text' 'escaped \| pipe' $'\t    ~~~~  ' '## Later' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '9:   ## Later (1 reading line)'
printf '%s\n' '# Spec' '## Intro' '  ```' '```' '## Later' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '5:   ## Later (1 reading line)'
printf '%s\n' '# Spec' '## Intro' $'##\tNot a heading' '####### Not a heading' '## Later' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq $'1: # Spec (5 reading lines)\n2:   ## Intro (3 reading lines)\n5:   ## Later (1 reading line)' "${OUTPUT#*$'\n'}"

it "only CommonMark HTML-block openers refuse, not angle-bracket prose"
for opener in '<script' '<?instruction' '<!doctype html>' '<![CDATA[' '  <DiV class=x' \
    '</tbody>' '<hr/>' '<custom-tag bool _a="two words" :v=plain f.g='"'"'single quote'"'"' />' '</em >'; do
    printf '%s\n' '# Spec' '## Intro' 'Read this section.' '' "$opener" '## Later' > "$SECTIONS"
    refuses_focused '5: HTML blocks other than comments'
done
for prose in '<em>Important</em> context.' '<What it does for the journeys, R and Q its architecture parts-table row cites.>' \
    '<custom foo="missing end>' '<custom attr=unquoted=value>' '<-not-a-tag>' '<https://example.test>' \
    '<script/>' '    <div>'; do
    printf '%s\n' '# Spec' '## Intro' '' "$prose" '' '## Later' > "$SECTIONS"
    run bash "$READER" --index "$SECTIONS"
    assert_eq 0 "$STATUS" "$prose is opaque or paragraph text: $OUTPUT"
    assert_contains "$OUTPUT" '6:   ## Later (1 reading line)'
done
printf '%s\n' '# Spec' '## Intro' 'Paragraph.' '<em>' '## Later' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS" "a type-7 tag does not start a block within a paragraph"

it "the installed reader indexes every shipped template from a spec location"
mkdir -p specs/template-fixtures
for shipped in "$PK_ROOT"/templates/*.md; do
    template="${shipped##*/}"
    copy="specs/template-fixtures/$template"
    cp ".prdkit/templates/$template" "$copy" || exit 1
    run bash "$READER" --index "$copy"
    assert_eq 0 "$STATUS" "$template: $OUTPUT"
    rm "$copy"
done
rmdir specs/template-fixtures

it "invalid navigation is still visible and does not hide a heading in authored content"
printf '%s\n' '# Scope' '## First' 'Text.' '## About prdkit:navigation: v2' 'Separate text.' '## Next' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '4:   ## About prdkit:navigation: v2 (2 reading lines)'
run bash "$READER" --section First "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq $'2: ## First\n3: Text.' "${OUTPUT#*$'\n'}"
run spec_navigation "$SECTIONS" diagnostics
assert_contains "$OUTPUT" 'Generated navigation retained: unknown or malformed navigation marker'
printf '%s\n' '# Spec' 'Tracking: [REC-1][nav-a]' '<!-- prdkit:navigation:v1 begin -->' \
    '[nav-a]: https://example.test/items/REC-1' '## Authored' 'Prose in a malformed footer.' \
    '<!-- prdkit:navigation:v1 end -->' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq $'1: # Spec (7 reading lines)\n5:   ## Authored (3 reading lines)' "${OUTPUT#*$'\n'}"
run bash "$READER" --section Authored "$SECTIONS"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '6: Prose in a malformed footer.'
assert_not_contains "$OUTPUT" 'https://' "content before the heading is not included"
printf '%s\n' 'No headings in this file.' > "$SECTIONS"
run bash "$READER" --index "$SECTIONS"
assert_eq 0 "$STATUS"
assert_eq 'No ATX headings.' "${OUTPUT#*$'\n'}"
run bash "$READER" --section missing "$SECTIONS"
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" '(no ATX headings)'
rm "$SECTIONS"

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
small; sed 's|items/A-1$|items/A-1[detail]|' "$FILE" > edit.md; mv edit.md "$FILE"; retained 'brackets in URL'
small; printf 'More evidence [nav-a].\n' | cat - "$FILE" > edit.md; mv edit.md "$FILE"; retained 'shortcut use'
small; printf '<div>\n' | cat - "$FILE" > edit.md; mv edit.md "$FILE"; retained 'HTML context'
small
sed '/^<!-- .* begin -->/i\
[nav-a]: https://other.example.test/item/42
' "$FILE" > edit.md; mv edit.md "$FILE"; retained 'authored definition conflict'
run bash "$READER" --stats "$FILE"
assert_contains "$OUTPUT" 'navigation label conflicts with an authored definition'
small
sed '/^<!-- .* begin -->/i\
<div>Authored HTML</div>
' "$FILE" > edit.md; mv edit.md "$FILE"; retained 'authored HTML'
run bash "$READER" --stats "$FILE"
assert_contains "$OUTPUT" 'unsupported HTML context; navigation retained'
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
