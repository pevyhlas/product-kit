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

review_bounds_file_path() { # bounds files, supporting design canon, or a change scope record
    local path="$1" record="${1#specs/changes/}"
    spec_file_path "$path" || [ "$path" = specs/design.md ] ||
        { [[ "$path" = specs/changes/*.md && "$record" != */* ]] && is_change_id "${record%.md}"; }
}

review_bounds_list() { # rev, spool, diagnostic callback; preflight names and entry types
    local rev="$1" paths="$2" note="$3" entry meta path count=0 expected presence=absent collision
    local problem="cannot completely enumerate spec entries at $1" LC_ALL=C
    export LC_ALL
    bounds_spec_presence=unknown
    # Trust Git's successful output, checking only transport framing and spec input safety.
    # Include directory rows and ASCII case variants of the root so aliases such as Specs/ are visible.
    # Unicode case-folding and normalization aliases are outside this check's threat model.
    if git -C "$REPO_ROOT" ls-tree -r -t -z "$rev" > "$paths.tree" &&
        expected="$(verify_nul_count "$paths.tree")" && : > "$paths" && : > "$paths.names"; then
        while IFS= read -r -d '' entry; do
            meta="${entry%%$'\t'*}"; path="${entry#*$'\t'}"
            [[ "$entry" != "$path" && "$meta" =~ ^[0-7]{6}\ (tree|blob|commit)\ ([0-9a-f]{40}|[0-9a-f]{64})$ ]] || break
            case "$path" in
                [sS][pP][eE][cC][sS]|[sS][pP][eE][cC][sS]/*) ;;
                *) count=$((count+1)); continue ;;
            esac
            # In C, printable bytes are ASCII. Reject controls too before the line-based check.
            case "$path" in
                *[![:print:]]*) problem="unsafe spec input $(printf '%q' "$path") at $rev (non-ASCII or control byte)"; break ;;
            esac
            if [[ "$meta" = '040000 tree '* ]] && review_bounds_file_path "$path"; then
                problem="unsafe spec input $(printf '%q' "$path") at $rev"; break
            fi
            case "$meta:$path" in
                '100'[67]*:specs|'100'[67]*:specs/product|'100'[67]*:specs/architecture|\
                '100'[67]*:specs/parts|'100'[67]*:specs/decisions|'100'[67]*:specs/changes)
                    problem="unsafe spec input $(printf '%q' "$path") at $rev"; break ;;
            esac
            case "$meta" in
                '040000 tree '*|'100644 blob '*|'100755 blob '*) ;;
                *) problem="unsafe spec input $(printf '%q' "$path") at $rev"; break ;;
            esac
            safe_path "$path" object || { problem="unsafe spec input $(printf '%q' "$path") at $rev"; break; }
            printf '%s\n' "$path" >> "$paths.names" || break
            case "$path" in
                specs|specs/*) printf '%s\0' "$entry" >> "$paths" || break ;;
            esac
            case "$path" in specs/*.md) presence=present ;; esac
            count=$((count+1))
        done < "$paths.tree" || count=-1
        if [ "$count" -eq "$expected" ] &&
            collision="$(awk 'seen[tolower($0)]++ { print; exit }' "$paths.names")"; then
            if [ -z "$collision" ]; then
                bounds_spec_presence="$presence"
                return 0
            fi
            problem="ASCII case-fold collision in spec input $collision at $rev"
        fi
    fi
    : > "$paths"
    : > "$paths.unsafe"
    "$note" canon "$problem"
    return 1
}

review_write_blob() ( # blob (or - to reserve an empty file), fresh destination
    set -o noclobber
    # Bash noclobber alone does not reject every kind of nonregular destination.
    [ ! -e "$2" ] && [ ! -L "$2" ] && { exec 3> "$2"; } || return 1
    [ "$1" = - ] || git -C "$REPO_ROOT" cat-file blob "$1" >&3
)

review_entry_identity() {
    stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1"
}

review_staged_blob() { # checked spool, exact path -> blob; never resolve a filesystem alias
    [ ! -f "$1.unsafe" ] && [ -f "$1.captured" ] || return 1
    LC_ALL=C needle="$2" awk -F '\t' '$1 == ENVIRON["needle"] { print $3; found=1; exit }
        END { exit !found }' "$1.captured"
}

review_bounds_stage() { # rev, material dir, checked spool, diagnostic callback
    local rev="$1" material="$2" paths="$3" note="$4" entry path blob kind identity status=0 failed='' written=0
    local use_stat=true seen=() prior checked=0
    local LC_ALL=C
    export LC_ALL
    [ ! -f "$paths.unsafe" ] || return 1
    if ! { mkdir -p "$material/.prdkit" && : > "$paths.captured" &&
        : > "$paths.reserved" && : > "$paths.identities"; }; then
        : > "$paths.unsafe"
        "$note" canon "cannot prepare spec inputs at $rev"
        return 1
    fi
    # The Git tree is in parent-first order. Create each directory and leaf exclusively,
    # then verify all bytes and identities together before allowing any spec parsing.
    while IFS= read -r -d '' entry; do
        path="${entry#*$'\t'}"
        if [[ "$entry" = '040000 tree '* ]]; then
            mkdir "$material/$path" 2>/dev/null || { failed="$path"; break; }
            kind=dir; blob=-
        else
            kind=blob
            blob="$(review_bounds_entry_blob "$entry")" || { failed="$path"; break; }
            review_write_blob - "$material/$path" 2>/dev/null || { failed="$path"; break; }
        fi
        printf '%s\t%s\t%s\n' "$path" "$kind" "$blob" >> "$paths.reserved" || { failed="$path"; break; }
    done < "$paths"
    if [ -z "$failed" ]; then
        # Only fill names this capture created exclusively. Never read a candidate
        # blob at all when reservation found a collision.
        : > "$paths.written" || { : > "$paths.unsafe"; return 1; }
        while IFS=$'\t' read -r path kind blob; do
            if [ "$kind" = blob ] && ! git -C "$REPO_ROOT" cat-file blob "$blob" > "$material/$path"; then
                "$note" canon "unreadable/non-text input $path at $rev"
                rm -f "$material/$path" || { failed="$path"; break; }
                status=1; continue
            fi
            printf '%s\t%s\t%s\n' "$path" "$kind" "$blob" >> "$paths.written" || { failed="$path"; break; }
            written=$((written+1))
        done < "$paths.reserved"
    fi
    if [ -z "$failed" ]; then
        review_entry_identity "$material" >/dev/null 2>&1 || use_stat=false
        while IFS=$'\t' read -r path kind blob; do
            if [ -L "$material/$path" ] ||
                { [ "$kind" = dir ] && [ ! -d "$material/$path" ]; } ||
                { [ "$kind" != dir ] && [ ! -f "$material/$path" ]; }; then
                failed="$path"; break
            fi
            if $use_stat; then
                identity="$(review_entry_identity "$material/$path")" || { failed="$path"; break; }
            else
                # Bash's same-file test also compares device and inode, even
                # when no GNU/BSD stat utility is on PATH.
                for prior in ${seen[@]+"${seen[@]}"}; do
                    if [ "$material/$path" -ef "$material/$prior" ]; then failed="$path"; break 2; fi
                done
                seen+=("$path")
                checked=$((checked+1))
                identity="$checked"
            fi
            if [ "$kind" = blob ] &&
                [ "$(git -C "$REPO_ROOT" hash-object --no-filters "$material/$path")" != "$blob" ]; then
                failed="$path"; break
            fi
            printf '%s\n' "$identity" >> "$paths.identities" || { failed="$path"; break; }
        done < "$paths.written"
    fi
    if [ -n "$failed" ] ||
        ! awk -v expected="$written" 'seen[$0]++ { duplicate=1; exit }
            END { exit (duplicate || NR != expected) }' "$paths.identities"; then
        : > "$paths.unsafe"
        "$note" canon "spec materialization collision or verification mismatch${failed:+: $failed} at $rev"
        return 1
    fi
    while IFS=$'\t' read -r path kind blob; do
        [ "$kind" = blob ] || continue
        case "$path" in
            specs/changes/*) ;; # A specific record is checked when selected.
            specs/*.md)
                if ! review_file_without_nul "$material/$path"; then
                    "$note" canon "unreadable/non-text input $path at $rev"
                    rm -f "$material/$path" || { : > "$paths.unsafe"; return 1; }
                    status=1; continue
                fi ;;
        esac
        printf '%s\t%s\t%s\n' "$path" "$rev" "$blob" >> "$paths.captured" ||
            { : > "$paths.unsafe"; return 1; }
    done < "$paths.written"
    return "$status"
}

review_bounds_inputs() { # rev, material dir, optional output TSV, checked spool, diagnostic callback
    local rev="$1" material="$2" inputs="${3:-/dev/null}" paths="$4" note="$5"
    [ ! -f "$paths.unsafe" ] || return 1
    # Keep the bounds tool's spec subset and order, recording the same blobs
    # we verified above. A filesystem lookup must not invent a Git path.
    if ! verify_lines spec_files "$material" > "$paths.selected" ||
        ! { [ ! -f "$material/specs/product/lifecycle.md" ] || printf '%s\n' specs/product/lifecycle.md; } > "$paths.lifecycle" ||
        ! awk -F '\t' '
                FILENAME == ARGV[1] { rows[$1] = $0; next }
                FILENAME == ARGV[2] { if (!($0 in rows)) failed=1; next }
                $0 in rows { print rows[$0]; next }
                { failed = 1 }
                END { exit failed }
            ' "$paths.captured" "$paths.lifecycle" "$paths.selected" > "$paths.selected-rows"; then
        "$note" canon "cannot inventory materialized spec inputs at $rev"
        : > "$paths.unsafe"
        return 1
    fi
    cat "$paths.selected-rows" >> "$inputs"
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

review_bounds_record() { # rev, path, staged dir, optional input TSV, checked spool
    local rev="$1" path="$2" material="$3" inputs="$4" entry blob
    blob="$(review_staged_blob "$5" "$path")" || return 1
    entry="$(git -C "$REPO_ROOT" ls-tree "$rev" -- ":(literal)$path")" &&
        [ "$(review_bounds_entry_blob "$entry" plain)" = "$blob" ] &&
        review_file_without_nul "$material/$path" || return 1
    if [ -n "$inputs" ]; then printf '%s\t%s\t%s\n' "$path" "$rev" "$blob" >> "$inputs"; fi
}

review_bounds_items() { # material dir, output, description, diagnostic callback
    if ! spec_items "$1" > "$2"; then
        "$4" canon "$3"
        return 1
    fi
}

review_bounds_capture_head() { # HEAD, material dir, input TSV, checked spool, spec IDs, diagnostic callback
    local rev="$1" material="$2" inputs="$3" paths="$4" items="$5" note="$6" ok=true
    local LC_ALL=C
    export LC_ALL
    if ! review_bounds_inputs "$rev" "$material" "$inputs" "$paths" "$note"; then
        : > "$items"
        return 1
    fi
    review_bounds_items "$material" "$items" "HEAD spec ID inventory incomplete at $rev" "$note" || ok=false
    "$ok"
}

review_bounds_run() ( # material dir, scope (empty if unavailable), inventory complete, status path, scope file
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
        record="$5"
        if ! review_record_format "$record" || ! tiers="$(record_tiers < "$record")" ||
            [[ ! "$tiers" =~ ^T[0-3]$ ]]; then
            printf 'Change record must be LF-terminated Markdown with exactly one valid Tier and no unsupported State review field: specs/changes/%s.md\n' "$scope" >&2
            return 1
        fi
    fi
    local status=0
    (bounds_for_root "$material" "$scope" true "$state_path" "${5:-}") > "$state_path.output" || status=$?
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
    REPO_ROOT="$1"; base="$2"; head="$3"; id="$4"
    is_change_id "$id" && [[ "$base" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ &&
        "$head" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]] || exit 2
    work="$(mktemp -d)"
    trap 'rm -rf "$work"' EXIT
    scope=''; scope_file=''; complete=true
    path="specs/changes/$id.md"
    review_bounds_list "$head" "$work/specs" review_bounds_note || complete=false
    review_bounds_list "$base" "$work/base-specs" review_bounds_note || complete=false
    review_bounds_stage "$head" "$work/material" "$work/specs" review_bounds_note || complete=false
    # A BASE alias blocks the reported state too. Ordinary BASE content gaps don't
    # change the HEAD result; only unsafe inventories or unverified material do.
    review_bounds_stage "$base" "$work/base" "$work/base-specs" review_bounds_note || :
    review_bounds_inputs "$base" "$work/base" "" "$work/base-specs" review_bounds_note || :
    if rev="$(review_bounds_record_rev "$head" "$path")"; then
        spool="$work/specs"; record_material="$work/material"
        if [ "$rev" = "$base" ] && [ "$rev" != "$head" ]; then
            spool="$work/base-specs"; record_material="$work/base"
        elif [ "$rev" != "$head" ]; then
            spool="$work/historical"
            record_material="$work/history"
            review_bounds_list "$rev" "$spool" review_bounds_note || :
            review_bounds_stage "$rev" "$record_material" "$spool" review_bounds_note || :
            review_bounds_inputs "$rev" "$record_material" "" "$spool" review_bounds_note || :
        fi
        if [ ! -f "$work/specs.unsafe" ] &&
            review_bounds_record "$rev" "$path" "$record_material" "" "$spool"; then
            scope="$id"; scope_file="$record_material/$path"
        else review_bounds_note child "unreadable child record $rev:$path"; fi
    fi
    review_bounds_capture_head "$head" "$work/material" "$work/inputs" "$work/specs" "$work/items" review_bounds_note || complete=false
    if [ -f "$work/specs.unsafe" ] || [ -f "$work/base-specs.unsafe" ]; then
        complete=false
        if [ -n "${5:-}" ]; then : > "$5"; fi
    fi
    rc=0
    review_bounds_run "$work/material" "$scope" "$complete" "$work/state" "$scope_file" > "$work/bounds" || rc=$?
    cat "$work/state"
    printf '%s\n' "${rev:--}"
    cat "$work/bounds"
    exit "$rc"
fi
