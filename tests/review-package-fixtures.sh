#!/usr/bin/env bash
# Test evidence only: relative path -> type/mode/size/hash, including empty directories.
# Unlike an unordered hash multiset, this detects swaps, in-place corruption and mode changes.
package_snapshot() {
    local root="$1" entry relative mode bytes oid target
    if [ ! -e "$root" ]; then printf 'ABSENT\n'; return; fi
    while IFS= read -r -d '' entry; do
        relative="${entry#"$root"}"; relative="${relative#/}"; relative="${relative:-.}"
        mode="$(LC_ALL=C ls -ld "$entry")"; mode="${mode%% *}"
        bytes=-; oid=-
        if [ -L "$entry" ]; then
            target="$(readlink "$entry")"
            bytes="$(printf '%s' "$target" | wc -c | tr -d ' ')"
            oid="$(printf '%s' "$target" | git hash-object --stdin)"
        elif [ -f "$entry" ]; then
            bytes="$(wc -c < "$entry" | tr -d ' ')"; oid="$(git hash-object --no-filters "$entry")"
        fi
        printf '%q\t%s\t%s\t%s\n' "$relative" "$mode" "$bytes" "$oid"
    done < <(find "$root" -print0) | LC_ALL=C sort
}
