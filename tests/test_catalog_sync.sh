#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
readme="$(cat "$PK_ROOT/README.md")"
index="$(cat "$PK_ROOT/docs/commands.md")"
it "catalogs expose every public entry point including bare /prdkit"
for file in "$PK_ROOT"/commands/*.md; do
    name="$(basename "$file" .md)"
    assert_contains "$readme" "| \`/$name\` |" "README lists $name"
    assert_contains "$index" "[\`/$name\`](../commands/$name.md)" "index links $name"
done
it "catalogs do not expose missing or internal commands"
while IFS= read -r name; do
    assert_file "$PK_ROOT/commands/$name.md" "catalog entry exists: $name"
done < <(grep -oE '/prdkit(-[a-z]+)?' "$PK_ROOT/docs/commands.md" | tr -d / | sort -u)
it "every internal operation is discoverable independently"
for file in "$PK_ROOT"/workflows/*.md; do
    name="$(basename "$file")"
    [ "$name" != README.md ] || continue
    assert_contains "$(cat "$PK_ROOT/workflows/README.md")" "($name)" "workflow index links $name"
done
finish
