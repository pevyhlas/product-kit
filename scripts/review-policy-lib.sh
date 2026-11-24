#!/usr/bin/env bash
# Reviewer eligibility from committed policy. Source spec-lib.sh first. No network/dependencies.
# shellcheck disable=SC2154 # root is supplied by the gate.
read_rigor() { # rev -> light|full|unknown; caller supplies root
    { git -C "$root" show "$1:.prdkit/memory/constitution.md" 2>/dev/null || true; } | read_rigor_text
}

read_rigor_text() { # validated constitution bytes on stdin; the same strict grammar
    tr -d '\r' | awk '
        { line = $0 }
        sub(/^[-*[:space:]]*[Rr]igor\**:\**[[:space:]]*/, "", line) { n++; value = tolower(line) }
        END {
            if (n == 1 && value ~ /^(light|full)([[:space:]]|$)/) { sub(/[[:space:]].*/, "", value); print value }
            else print "unknown"
        }'
}

review_registry() { # agents.md on stdin -> identity, role, policy line
    awk "$SPEC_SKIP_AWK"'
        function trim(s) { gsub(/^[[:space:]`]+|[[:space:]`]+$/, "", s); return tolower(s) }
        { if (spec_skip($0)) next }
        /^## / { section = $0; identity = role = 0; next }
        /^\|/ {
            n = split($0, c, "|")
            if (section == "## Review registry" && trim(c[2]) == "identity" && trim(c[3]) == "role") {
                identity = 2; role = 3; next
            }
            if (!identity || c[2] ~ /^[[:space:]:-]+$/) next
            id = trim(c[identity]); kind = trim(c[role])
            if (id !~ /^[a-z0-9][a-z0-9_.-]*$/) next
            if (kind != "reviewer" && kind != "maker") kind = "invalid"
            print id "\037" kind "\037" NR
            next
        }
        /^[[:space:]]*$/ { next }
        { identity = role = 0 }
    '
}

review_eligibility() { # registry identity -> reviewer|maker|ambiguous|unregistered
    printf '%s\n' "$1" | awk -F '\037' -v id="$2" '
        $1 == id { n++; if ($2 == "maker") maker = 1; if ($2 != "reviewer") invalid = 1 }
        END {
            if (maker) print "maker"
            else if (n > 1 || invalid) print "ambiguous"
            else if (n == 1) print "reviewer"
            else print "unregistered"
        }'
}

# Review text in State is not an authority in the current record format.
review_record_format() { # record file -> 0 current, 1 unreadable, 2 unsupported review field
    verify_lf_file "$1" || return 1
    local found
    found="$(LC_ALL=C awk "$SPEC_SKIP_AWK"'
        { gsub(/[\035-\037]/, " "); if (spec_skip($0)) next }
        /^ ? ? ?##([[:space:]]|$)/ { state = ($0 ~ /^ ? ? ?##[[:space:]]+State([[:space:]]*|[[:space:]]+#+[[:space:]]*)$/) }
        state && /(^[[:space:]]*|·[[:space:]]*)\*\*Review\*\*:/ { print NR; exit }
    ' "$1")" || return 1
    [ -z "$found" ] || return 2
}

# Check the inherited checked record and both sides of every changed record. A
# candidate cannot erase unsupported evidence by deleting or moving its record
# or by merging away a branch-side commit. Save the touched record paths for
# the gate's tier floor. No verdict parsing or clearance.
review_record_history() ( # root id base head work -> first diagnostic, if any
    local root="$1" id="$2" base="$3" head="$4" work="$5" start entry commit meta mode new_mode old new blob expected checked=0
    export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1
    set -o pipefail
    spec_objects_local "$root" &&
        [ "$(git -C "$root" rev-parse --is-shallow-repository)" = false ] &&
        start="$(git -C "$root" merge-base --all "$base" "$head")" &&
        [[ -n "$start" && "$start" != *$'\n'* ]] || return 1
    entry="$(git -C "$root" ls-tree "$start" -- "specs/changes/$id.md")" || return 1
    : > "$work/record-blobs" || return 1
    case "$entry" in
        '100644 blob '*|'100755 blob '*)
            meta="${entry%%$'\t'*}"
            printf '%s\n' "${meta##* }" >> "$work/record-blobs" || return 1 ;;
    esac
    git -C "$root" rev-list "$start..$head" > "$work/record-commits" || return 1
    verify_lf_file "$work/record-commits" allow-empty || return 1
    # Include the net diff so an inherited record changed across the range is
    # checked too; use all branch-side merge parents, not a simplified log.
    git -C "$root" diff-tree --no-commit-id --no-renames --no-abbrev -r -z "$start" "$head" -- specs/changes/ > "$work/record-diff" || return 1
    while IFS= read -r commit; do
        git -C "$root" diff-tree --no-commit-id --no-renames --no-abbrev --root -m -r -z "$commit" -- specs/changes/ >> "$work/record-diff" || return 1
    done < "$work/record-commits"
    expected="$(verify_nul_count "$work/record-diff")" || return 1
    : > "$work/record-paths.tmp" || return 1
    while IFS= read -r -d '' meta; do
        [[ "$meta" =~ ^:[0-7]{6}\ [0-7]{6}\ [0-9a-f]+\ [0-9a-f]+\ [AMDT]$ ]] || return 1
        IFS= read -r -d '' entry || return 1
        [ -n "$entry" ] || return 1
        checked=$((checked + 2))
        case "$entry" in *.md) ;; *) continue ;; esac
        printf '%s\0' "$entry" >> "$work/record-paths.tmp" || return 1
        read -r mode new_mode old new _ <<< "${meta#:}"
        case "$mode" in 100644|100755) printf '%s\n' "$old" >> "$work/record-blobs" || return 1 ;; esac
        case "$new_mode" in 100644|100755) printf '%s\n' "$new" >> "$work/record-blobs" || return 1 ;; esac
    done < "$work/record-diff"
    [ "$checked" -eq "$expected" ] || return 1
    mv "$work/record-paths.tmp" "$work/record-paths" || return 1
    LC_ALL=C sort -u "$work/record-blobs" > "$work/record-unique" || return 1
    while IFS= read -r blob; do
        git -C "$root" cat-file blob "$blob" > "$work/record-text" || return 1
        if review_record_format "$work/record-text"; then continue
        elif [ "$?" -eq 2 ]; then
            printf 'Unsupported **Review** field in change record history (blob %s): current reviews are native GitHub reviews, not State text.\n' "$blob"
            return 0
        else
            printf 'Invalid change record text in history (blob %s): expected LF-terminated Markdown.\n' "$blob"
            return 0
        fi
    done < "$work/record-unique"
)
