#!/usr/bin/env bash
# Minimum automatic context for fixtures asserting a full package can be reused.
package_context_fixture() {
    mkdir -p .prdkit/memory specs/product specs/changes
    local p files
    files=(specs/{product,architecture}.md)
    if [ "${2:-}" != installed-policy ]; then files+=(.prdkit/memory/{constitution,agents,config}.md); fi
    for p in "${files[@]}"; do
        printf '# %s\n' "${p##*/}" > "$p"
    done
    printf '# Lifecycle\n\n**Now**: Demo · **Next**: MVP\n' > specs/product/lifecycle.md
    printf '# Change\n\n**Tier**: T1\n' > "specs/changes/$1.md"
}

# Same one-line change and three unchanged review obligations in baseline and candidate.
package_small_obligation_fixture() {
    local id="$1"
    package_context_fixture "$id" "${2:-}"
    printf '\n## Acceptance\n\nAcceptance: Preserve the exported public label.\n' >> "specs/changes/$id.md"
    printf '\n## Review policy\n\n- **Rigor**: full\n- Release-label edits require the application smoke check.\n' >> .prdkit/memory/constitution.md
    printf '# Constraints\n\n- **C-01 Example bound**: Scope: all.\n  Keep the published label stable for automated clients.\n' > specs/product/constraints.md
    printf 'old label\n' > label.txt
    snapshot_upgrade_fixture "$PWD" || return 1
    git checkout -qb "$id" || return 1
    printf 'new label\n' > label.txt
    git commit -qam 'edit one label'
}

# Test evidence only: relative path -> inode/type/mode/size/hash, including empty directories.
# Unlike an unordered hash multiset, this detects swaps, in-place corruption and mode changes.
package_snapshot() {
    local root="$1" entry relative mode inode bytes oid target
    if [ ! -e "$root" ] && [ ! -L "$root" ]; then printf 'ABSENT\n'; return; fi
    while IFS= read -r -d '' entry; do
        relative="${entry#"$root"}"; relative="${relative#/}"; relative="${relative:-.}"
        # Only numeric inode/mode prefixes are read; names come from find -print0, not ls.
        # shellcheck disable=SC2012
        IFS=$'\t' read -r inode mode <<< "$(LC_ALL=C ls -ldin "$entry" | awk '{ print $1 "\t" $2 }')"
        bytes=-; oid=-
        if [ -L "$entry" ]; then
            target="$(readlink "$entry")"
            bytes="$(printf '%s' "$target" | wc -c | tr -d ' ')"
            oid="$(printf '%s' "$target" | git hash-object --stdin)"
        elif [ -f "$entry" ]; then
            bytes="$(wc -c < "$entry" | tr -d ' ')"; oid="$(git hash-object --no-filters "$entry")"
        fi
        printf '%q\t%s\t%s\t%s\t%s\n' "$relative" "$inode" "$mode" "$bytes" "$oid"
    done < <(find "$root" -print0) | LC_ALL=C sort
}
