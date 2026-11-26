#!/usr/bin/env bash
# Checked, object-bound bounds inputs shared by the package and facts.
# When sourced, caller supplies REPO_ROOT and loads bounds.sh and review-policy-lib.sh.
# shellcheck disable=SC2154,SC2034

safe_path() { # relative path without traversal, control chars or worktree symlinks
    local p="$1" part current="$REPO_ROOT" rest="$1" source="${2:-worktree}" LC_ALL=C
    case "$p" in ''|/*|*/|*//*|*[[:cntrl:]]*) return 1 ;; esac
    while [ -n "$rest" ]; do
        part="${rest%%/*}"
        case "$part" in .|..) return 1 ;; esac
        current="$current/$part"
        [ "$source" = object ] || [ ! -L "$current" ] || return 1
        if [ "$rest" = "$part" ]; then break; fi
        rest="${rest#*/}"
    done
}

review_bounds_entry_blob() { # ls-tree row (NUL or LF transport), [plain non-executable]
    local meta="${1%%$'\t'*}" oid
    [[ "$1" != "$meta" && -n "${1#*$'\t'}" && "$1" != *$'\n'* ]] || return 1
    [[ "$meta" =~ ^(100644|100755)\ blob\ ([0-9a-f]{40}|[0-9a-f]{64})$ ]] || return 1
    [ "${BASH_REMATCH[1]}" = 100644 ] || [ "${2:-}" != plain ] || return 1
    oid="${BASH_REMATCH[2]}"
    printf '%s\n' "$oid"
}

context_object() { # rev path -> blob; never dereference a symlink/tree/submodule
    local entry
    safe_path "$2" object || return 1
    entry="$(git -C "$REPO_ROOT" ls-tree "$1" -- ":(literal)$2")" || return 1
    review_bounds_entry_blob "$entry"
}

review_bounds_spec_entry() { # include obstructions at normal spec directories
    case "$2" in
        specs/*.md) return 0 ;;
        specs|specs/product|specs/architecture|specs/parts|specs/decisions|specs/changes)
            [[ "$1" != '040000 tree '* ]] ;;
        *) return 1 ;;
    esac
}

review_bounds_list() { # rev, spool, diagnostic callback; sets bounds_spec_presence
    local rev="$1" paths="$2" note="$3" entry path count=0 expected presence=absent
    bounds_spec_presence=unknown
    if git -C "$REPO_ROOT" ls-tree -r -t -z "$rev" -- specs > "$paths" &&
        expected="$(verify_nul_count "$paths")"; then
        while IFS= read -r -d '' entry; do
            path="${entry#*$'\t'}"
            [[ "${entry%%$'\t'*}" =~ ^[0-7]{6}\ (tree|blob|commit)\ ([0-9a-f]{40}|[0-9a-f]{64})$ &&
                "$entry" != "$path" ]] || break
            case "$path" in specs|specs/*) ;; *) break ;; esac
            count=$((count+1))
            if review_bounds_spec_entry "$entry" "$path"; then presence=present; fi
        done < "$paths"
        if [ "$count" -eq "$expected" ]; then bounds_spec_presence="$presence"; return; fi
    fi
    : > "$paths"
    "$note" canon "cannot completely enumerate spec entries at $rev"
    return 1
}

review_bounds_specs() { # rev, material dir, optional input TSV, checked spool, diagnostic callback
    local rev="$1" material="$2" inputs="$3" paths="$4" note="$5" entry path blob status=0
    local LC_ALL=C
    export LC_ALL
    if ! mkdir -p "$material/.prdkit"; then
        "$note" canon "cannot prepare spec inputs at $rev"
        return 1
    fi
    if [ -n "$inputs" ]; then : > "$paths.captured" || return 1; fi
    while IFS= read -r -d '' entry; do
        path="${entry#*$'\t'}"
        case "$path" in specs/changes/*) continue ;; esac
        review_bounds_spec_entry "$entry" "$path" || continue
        if [[ "$path" = specs/*.md ]] && safe_path "$path" object &&
            blob="$(review_bounds_entry_blob "$entry")"; then
            if mkdir -p "$(dirname "$material/$path")" &&
                git -C "$REPO_ROOT" cat-file blob "$blob" > "$material/$path" &&
                review_file_without_nul "$material/$path"; then
                if [ -n "$inputs" ]; then
                    printf '%s\t%s\t%s\n' "$path" "$rev" "$blob" >> "$paths.captured" || return 1
                fi
                continue
            fi
            "$note" canon "unreadable/non-text input $path at $rev"
            rm -f "$material/$path"
        else "$note" canon "unsafe spec input $(printf '%q' "$path") at $rev"; fi
        status=1
    done < "$paths"
    if [ -n "$inputs" ]; then
        # Keep the bounds tool's spec subset and order, recording the same blobs
        # we copied from the checked spool rather than resolving their paths again.
        if ! verify_lines spec_files "$material" > "$paths.selected" ||
            ! awk -F '\t' '
                FILENAME == ARGV[1] { rows[$1] = $0; next }
                $0 in rows { print rows[$0]; next }
                { failed = 1 }
                END { exit failed }
            ' "$paths.captured" "$paths.selected" >> "$inputs"; then
            "$note" canon "cannot inventory materialized spec inputs at $rev"
            return 1
        fi
    fi
    return "$status"
}

review_bounds_record_rev() { # HEAD and path -> scope revision
    local head="$1" path="$2" entry last
    if ! entry="$(git -C "$REPO_ROOT" ls-tree "$head" -- ":(literal)$path")"; then
        printf 'actual child record is unsafe/unreadable at HEAD: %s; no historical substitution\n' "$path" >&2
        return 1
    fi
    if [ -n "$entry" ]; then
        if review_bounds_entry_blob "$entry" plain >/dev/null; then printf '%s\n' "$head"; return; fi
        printf 'actual child record is unsafe/unreadable at HEAD: %s; no historical substitution\n' "$path" >&2
        return 1
    fi
    last="$(git -C "$REPO_ROOT" log -1 --format=%H "$head" -- "$path" 2>/dev/null)" &&
        [ -n "$last" ] &&
        entry="$(git -C "$REPO_ROOT" ls-tree "$last^" -- ":(literal)$path")" &&
        review_bounds_entry_blob "$entry" plain >/dev/null &&
        git -C "$REPO_ROOT" rev-parse "$last^" && return
    printf 'actual child record missing or unrecoverable: %s\n' "$path" >&2
    return 1
}

review_bounds_record() { # rev, path, material dir, optional input TSV
    local rev="$1" path="$2" material="$3" inputs="$4" entry blob
    entry="$(git -C "$REPO_ROOT" ls-tree "$rev" -- ":(literal)$path")" &&
        blob="$(review_bounds_entry_blob "$entry" plain)" &&
        mkdir -p "$(dirname "$material/$path")" || return 1
    if ! git -C "$REPO_ROOT" cat-file blob "$blob" > "$material/$path" ||
        ! review_file_without_nul "$material/$path"; then
        rm -f "$material/$path"
        return 1
    fi
    if [ -n "$inputs" ]; then printf '%s\t%s\t%s\n' "$path" "$rev" "$blob" >> "$inputs"; fi
}

review_bounds_items() { # material dir, output, description, diagnostic callback
    if ! spec_items "$1" > "$2"; then
        "$4" canon "$3"
        return 1
    fi
}

review_bounds_capture_head() { # HEAD, material dir, input TSV, spool, spec IDs, diagnostic callback
    local rev="$1" material="$2" inputs="$3" paths="$4" items="$5" note="$6" ok=true
    local LC_ALL=C
    export LC_ALL
    review_bounds_list "$rev" "$paths" "$note" || ok=false
    review_bounds_specs "$rev" "$material" "$inputs" "$paths" "$note" || ok=false
    review_bounds_items "$material" "$items" "HEAD spec ID inventory incomplete at $rev" "$note" || ok=false
    "$ok"
}

review_bounds_run() ( # material dir, scope (empty if unavailable), inventory complete, status path
    local material="$1" scope="$2" complete="$3" state_path="$4" record tiers
    set -o pipefail
    export LC_ALL=C
    printf 'unavailable\n' > "$state_path" || return 1
    if [ "$complete" != true ]; then
        printf 'Bounds input inventory is incomplete.\n' >&2; return 2
    fi
    if [ -z "$scope" ]; then
        printf 'No usable change record for bounds scope.\n' >&2; return 2
    fi
    if [ "$scope" != --all ]; then
        record="$material/specs/changes/$scope.md"
        if ! review_record_format "$record" || ! tiers="$(record_tiers < "$record")" ||
            [[ ! "$tiers" =~ ^T[0-3]$ ]]; then
            printf 'Change record must be LF-terminated Markdown with exactly one valid Tier and no unsupported State review field: specs/changes/%s.md\n' "$scope" >&2
            return 1
        fi
    fi
    local status=0
    (bounds_for_root "$material" "$scope" true "$state_path") > "$state_path.output" || status=$?
    if [ "$status" -eq 0 ]; then cat "$state_path.output" || status=$?; fi
    rm -f "$state_path.output" || return 1
    if [ "$status" -ne 0 ]; then printf 'unavailable\n' > "$state_path" || return 1; fi
    return "$status"
)

review_bounds_note() { printf '%s\n' "$*" >&2; }

# Internal facts entry point. Checked spools and record material are disposable.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    set -euo pipefail
    script_dir="$(CDPATH="" cd "$(dirname "$0")" && pwd)"
    source "$script_dir/bounds.sh" # also loads common.sh and spec-lib.sh
    source "$script_dir/review-policy-lib.sh"
    export GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1
    REPO_ROOT="$1"; head="$2"; id="$3"
    is_change_id "$id" && [[ "$head" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || exit 2
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    scope=''; complete=true
    path="specs/changes/$id.md"
    if rev="$(review_bounds_record_rev "$head" "$path")"; then
        if review_bounds_record "$rev" "$path" "$work/material" ""; then scope="$id"
        else review_bounds_note child "unreadable child record $rev:$path"; fi
    fi
    review_bounds_capture_head "$head" "$work/material" "$work/inputs" "$work/specs" "$work/items" review_bounds_note || complete=false
    rc=0
    review_bounds_run "$work/material" "$scope" "$complete" "$work/state" > "$work/bounds" || rc=$?
    cat "$work/state"
    printf '%s\n' "${rev:--}"
    cat "$work/bounds"
    exit "$rc"
fi
