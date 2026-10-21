#!/usr/bin/env bash
# Doc link integrity guard: every relative markdown link in the repo docs must
# resolve to an existing file, so renames and moves can't silently rot the docs.
#
# Scope: README.md and docs/**/*.md. Command files under commands/ are out of
# scope: their relative paths are consumer-project paths, not repo paths (see
# CLAUDE.md, "Consumer paths vs. repo paths"). The docs/commands.md index is in
# scope; its per-command links are additionally covered by test_catalog_sync.sh.
#
# Skipped link forms: external targets (http/https/mailto) and in-page anchors
# (#section). A target's own anchor suffix (file.md#section) is stripped before
# the existence check. Targets resolve relative to the linking file's directory.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

cd "$PK_ROOT" || exit 1

# Build the file list: README.md plus docs/**/*.md.
DOC_FILES=("README.md")
while IFS= read -r f; do
    DOC_FILES+=("$f")
done < <(find docs -name '*.md' | sort)

it "relative markdown links in README.md and docs/ resolve to existing files"

links_checked=0
for f in "${DOC_FILES[@]}"; do
    while IFS= read -r target; do
        [ -n "$target" ] || continue
        case "$target" in
            http://*|https://*|mailto:*) continue ;;  # external link
            '#'*) continue ;;                         # in-page anchor only
        esac
        target="${target%%#*}"   # strip anchor suffix (file.md#section)
        [ -n "$target" ] || continue
        links_checked=$((links_checked+1))
        if [ -e "$(dirname "$f")/$target" ]; then
            _ok "$f → $target"
        else
            _no "$f links to missing target: $target"
        fi
    done < <(grep -oE '\]\([^)]+\)' "$f" 2>/dev/null | sed 's/^](//; s/)$//')
done

it "the scan actually saw links (guard against a silently broken extractor)"
if [ "$links_checked" -gt 0 ]; then
    _ok "checked $links_checked relative link(s)"
else
    _no "no relative links found — extraction pattern or file list is broken"
fi

finish
