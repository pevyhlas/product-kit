#!/usr/bin/env bash
# Every installed reference resolves; workflows are included in the installation corpus.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
it "public wrappers point to installed protocol and a real operation"
for file in "$PK_ROOT"/commands/*.md; do
    assert_contains "$(cat "$file")" '.prdkit/workflows/protocol.md' "$(basename "$file") loads protocol"
done
it "command frontmatter is one-line YAML every harness loads"
# Harnesses parse frontmatter as YAML. Hold each line to a subset every parser accepts: a key
# and a double-quoted value, or a plain one-line value with no leading indicator, `: ` or ` #`.
# Anything else (a continuation line, a bare colon) is reported with its line number.
# A heredoc inside $(...) does not parse in bash 3.2 when it holds a quote or a backtick.
read -r -d '' frontmatter_awk <<'AWK' || true
NR == 1 { if ($0 != "---") { print "1: no opening ---"; exit } next }
/^---$/ { closed = 1; exit }
/^[a-z][a-z0-9_-]*: "[^"]*"$/ { next }
{
    v = $0
    if (sub(/^[a-z][a-z0-9_-]*: /, "", v) && v != "" && !index("-?:,[]{}#&*!|>'\"%@` \t", substr(v, 1, 1)) \
        && !index(v, ": ") && !index(v, " #") && v !~ /:$/) next
    print NR ": " $0
}
END { if (!closed) print "no closing ---" }
AWK
for file in "$PK_ROOT"/commands/*.md; do
    bad="$(awk "$frontmatter_awk" "$file")"
    if [ -z "$bad" ]; then _ok "$(basename "$file") frontmatter"; else _no "$(basename "$file") frontmatter" "$bad"; fi
done
# Where PyYAML exists, parse it the way a harness does; the subset above runs everywhere.
if python3 -c 'import yaml' 2>/dev/null; then
    for file in "$PK_ROOT"/commands/*.md; do
        if python3 - "$file" 2>/dev/null <<'PY'; then _ok "$(basename "$file") parses as YAML"; else _no "$(basename "$file") parses as YAML"; fi
import sys, yaml
meta = yaml.safe_load(open(sys.argv[1], encoding="utf-8").read().split("---\n", 2)[1])
assert isinstance(meta, dict) and isinstance(meta.get("description"), str) and meta["description"].strip()
PY
    done
fi
it "all workflow/template/helper references resolve to shipped sources"
while IFS= read -r ref; do
    case "$ref" in
        .prdkit/workflows/*) source_path="workflows/${ref##*/}" ;;
        .prdkit/templates/*) source_path="templates/${ref##*/}" ;;
        .prdkit/scripts/bash/*) source_path="scripts/${ref##*/}" ;;
        *) continue ;;
    esac
    assert_file "$PK_ROOT/$source_path" "installed reference $ref"
done < <(grep -rohE '\.prdkit/(workflows/[a-zA-Z0-9-]+\.md|templates/[a-zA-Z0-9-]+\.md|scripts/bash/[a-zA-Z0-9-]+\.sh)' "$PK_ROOT/commands" "$PK_ROOT/workflows" | sort -u)
it "templates have an operational or documented consumer"
for file in "$PK_ROOT"/templates/*.md; do
    name="$(basename "$file")"
    if grep -rqF "$name" "$PK_ROOT/workflows" "$PK_ROOT/scripts" "$PK_ROOT/docs"; then _ok "$name used"; else _no "$name orphaned"; fi
done
finish
