#!/usr/bin/env bash
# Object-bound package context. Standard tools only. Caller owns package/scratch paths,
# inventory(), safe_path(), HEAD_SHA, POLICY_AT, CHANGE_ID and SCRIPT_DIR.
# No candidate scripts execute. The installed bounds command is called on object materialization.
# shellcheck disable=SC2154,SC2034 # Builder globals and bounds' cross-source outputs.

context_select_spans() { # source file; at/selector passed as awk -v arguments
    awk "$@" "$SPEC_SKIP_AWK"'
        { text[NR]=$0; if (spec_skip($0)) next; live[NR]=1
          if ($0 ~ /^#+[ \t]+/) {
              h=$0; sub(/[ \t]+.*/, "", h); level[NR]=length(h)
              title=$0; sub(/^#+[ \t]+/, "", title); sub(/[ \t]+#+[ \t]*$/, "", title)
              slug=tolower(title); gsub(/[^a-z0-9 _-]/, "", slug); gsub(/ /, "-", slug)
              if (selector!="" && (title==selector || slug==selector)) { count++; at=NR }
          } }
        END {
            if (selector!="" && count!=1) exit 1
            if (!at || !live[at]) exit 1
            depth=level[at] ? level[at] : 100
            for (i=at-1;i>0;i--) if (level[i] && level[i]<depth) { parents[++n]=i; depth=level[i] }
            for (i=n;i>0;i--) print parents[i] "\t" parents[i]
            end=NR
            if (level[at]) {
                for (i=at+1;i<=NR;i++) if (level[i] && level[i]<=level[at]) { end=i-1; break }
            } else if (text[at] ~ /^\|/) {
                # Column names and delimiter, never sibling rows, give the selected row meaning.
                first=at; while (first>1 && text[first-1] ~ /^\|/) first--
                if (first>=at || text[first+1] !~ /^\|[-| :\t]+$/) exit 1
                print first "\t" first+1
                end=at
            }
            else if (text[at] ~ /^[ \t]*[-*+][ \t]+/) {
                match(text[at],/^[ \t]*/); indent=RLENGTH; gap=0
                for (i=at+1;i<=NR;i++) {
                    if (!live[i]) continue
                    if (text[i] ~ /^[ \t]*$/) { gap=1; continue }
                    match(text[i],/^[ \t]*/); d=RLENGTH
                    if (level[i] || text[i] ~ /^\|/ || (d<=indent && (gap || text[i] ~ /^[ \t]*[-*+][ \t]+/))) { end=i-1; break }
                    gap=0
                }
            } else exit 1
            print at "\t" end
        }'
}

context_gap() {
    # Verification is a dispatch reminder even for a complete structural package.
    [ "$1" = verification ] || reuse_context=custom
    if [ "${reference_side:-}" = BASE ]; then
        base_reference_gap=true
        set -- "$1" "unresolved BASE obligation:" "${@:2}"
    fi
    printf '%s\n' "$*" >> "$PACKAGE_DIR/context-gaps.txt"
    printf -- '-\t-\t-\t-\t-\t-\t%s\t%s\n' "$(spec_field "$1")" "$(spec_field "$*")" >> "$PACKAGE_DIR/context-manifest.tsv"
}

context_object() { # rev path -> blob; never dereference a symlink/tree/submodule
    local entry
    # Objects are checked at their own revision. A worktree symlink cannot hide a BASE blob.
    safe_path "$2" object || return 1
    entry="$(git -C "$REPO_ROOT" ls-tree "$1" -- ":(literal)$2")" || return 1
    case "$entry" in 100644\ blob\ *|100755\ blob\ *) ;; *) return 1 ;; esac
    entry="${entry#* blob }"; printf '%s\n' "${entry%%$'\t'*}"
}

context_slice() ( # Preserve the source's bytes, including any missing final LF.
    set -o pipefail
    if [ "$3" = all ]; then cat "$1"
    else head -n "$3" "$1" | tail -n "+$2"; fi
)

context_span() { # rev path first last obligation reason
    local rev="$1" path="$2" first="$3" last="$4" obligation="$5" reason="$6" blob name=""
    local artifact source_rev source_path source_blob source_first source_last rest fresh=false end="$4"
    if ! blob="$(context_object "$rev" "$path")" ||
        ! GIT_NO_LAZY_FETCH=1 git -C "$REPO_ROOT" cat-file blob "$blob" > "$CTX_TMP/blob"; then
        context_gap "$obligation" "missing/unsafe/unreadable context $rev:$path"; return
    fi
    [ "$last" != all ] || last="$(awk 'END { print NR }' "$CTX_TMP/blob")"
    [ "$last" != 0 ] || first=0
    # Reuse exact spans, recording every obligation below. Explicit snapshots live exclusively
    # under context/<repo-path>; generated files must never share that namespace.
    while IFS=$'\t' read -r artifact source_rev source_path source_blob source_first source_last rest; do
        if [ "$source_rev" = "$rev" ] && [ "$source_path" = "$path" ] && [ "$source_blob" = "$blob" ] &&
            [ "$source_first" = "$first" ] && [ "$source_last" = "$last" ]; then name="$artifact"; break; fi
    done < "$PACKAGE_DIR/context-manifest.tsv"
    if [ -z "$name" ]; then
        name="context-sections/$CTX_N.txt"; CTX_N=$((CTX_N+1)); fresh=true
        mkdir -p "$PACKAGE_DIR/context-sections"
        if [ -e "$PACKAGE_DIR/$name" ] || [ -L "$PACKAGE_DIR/$name" ]; then
            echo "ERROR: generated context artifact collision: $name; incomplete round retained" >&2; exit 1
        fi
        if [ "$last" = 0 ]; then
            : > "$PACKAGE_DIR/$name"; context_gap "$obligation" "empty required context $rev:$path"
        elif ! context_slice "$CTX_TMP/blob" "$first" "$end" > "$PACKAGE_DIR/$name"; then
            context_gap "$obligation" "cannot copy context $rev:$path:$first-$last"
            return
        fi
    fi
    if $fresh; then inventory "$name" "$rev:$path:$first-$last"; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$rev" "$path" "$blob" "$first" "$last" \
        "$(spec_field "$obligation")" "$(spec_field "$reason")" >> "$PACKAGE_DIR/context-manifest.tsv"
}

context_select() { # rev path selector obligation reason [source line]
    local rev="$1" path="$2" selector="$3" obligation="$4" reason="$5" at="${6:-0}" blob a b spans body n=0
    if ! blob="$(context_object "$rev" "$path")" ||
        ! GIT_NO_LAZY_FETCH=1 git -C "$REPO_ROOT" cat-file blob "$blob" > "$CTX_TMP/select" ||
        ! review_file_without_nul "$CTX_TMP/select"; then
        context_gap "$obligation" "missing/unsafe context $rev:$path"; return
    fi
    if ! spans="$(context_select_spans -v at="$at" -v selector="$selector" < "$CTX_TMP/select")"; then
        context_gap "$obligation" "ambiguous/missing/unsupported section $rev:$path#$selector (line $at)"; return
    fi
    body="${spans##*$'\n'}"
    while IFS=$'\t' read -r a b; do
        if [ -n "${reference_key:-}" ]; then
            if [ "$a"$'\t'"$b" = "$body" ]; then
                context_queue_reference "$reference_key" "$rev" "$path" "$a" "$b" "$reason"
            else
                n=$((n+1))
                context_queue_reference "$reference_key:context:$n" "$rev" "$path" "$a" "$b" "$reason (heading or columns)"
            fi
            if [ "${reference_parent:-false}" = true ]; then
                printf '%s\t%s\n' "$a" "$b" >> "$CTX_TMP/parent-spans"
            fi
            continue
        fi
        context_span "$rev" "$path" "$a" "$b" "$obligation" "$reason"
    done <<< "$spans"
}

context_list_specs() { # rev, list file; sets spec_presence
    local rev="$1" paths="$2" entry path
    spec_presence=absent
    if ! GIT_NO_LAZY_FETCH=1 git -C "$REPO_ROOT" ls-tree -r -t -z "$rev" -- specs > "$paths" ||
        ! verify_nul_count "$paths" >/dev/null; then
        spec_presence=unknown
        context_gap canon "cannot completely enumerate spec entries at $rev"
        return
    fi
    while IFS= read -r -d '' entry; do
        path="${entry#*$'\t'}"
        if context_spec_entry "$entry" "$path"; then spec_presence=present; return; fi
    done < "$paths"
}

context_spec_entry() { # ls-tree entry, path; include obstructions at normal spec directories
    case "$2" in
        specs/*.md) return 0 ;;
        specs|specs/product|specs/architecture|specs/parts|specs/decisions|specs/changes)
            [[ "$1" != '040000 tree '* ]] ;;
        *) return 1 ;;
    esac
}

context_collect_specs() { # rev material-root inputs-name list-file; nonzero on incomplete capture
    local rev="$1" material="$2" inputs="$3" paths="$4" entry path blob status=0 listed
    if ! mkdir -p "$material/.prdkit"; then
        context_gap canon "cannot prepare spec inputs at $rev"
        return 1
    fi
    while IFS= read -r -d '' entry; do
        path="${entry#*$'\t'}"
        case "$path" in specs/changes/*) continue ;; esac
        context_spec_entry "$entry" "$path" || continue
        if [[ "$path" = specs/*.md ]] && blob="$(context_object "$rev" "$path")"; then
            if mkdir -p "$(dirname "$material/$path")" &&
                GIT_NO_LAZY_FETCH=1 git -C "$REPO_ROOT" cat-file blob "$blob" > "$material/$path" &&
                review_file_without_nul "$material/$path"; then
                continue
            fi
            context_gap canon "unreadable/non-text input $path at $rev"; rm -f "$material/$path"
        else context_gap canon "unsafe spec input $(printf '%q' "$path") at $rev"; fi
        status=1
    done < "$paths"
    if [ -n "$inputs" ]; then
        if ! listed="$(verify_lines spec_files "$material")"; then
            context_gap canon "cannot inventory materialized spec inputs at $rev"
            return 1
        fi
        while IFS= read -r path; do
            [ -n "$path" ] || continue
            if ! blob="$(context_object "$rev" "$path")"; then
                context_gap canon "cannot resolve materialized spec input $rev:$path"
                status=1; continue
            fi
            printf '%s\t%s\t%s\n' "$path" "$rev" "$blob" >> "$PACKAGE_DIR/$inputs"
        done <<< "$listed"
    fi
    return "$status"
}

context_collect_record() { # rev path material-root inputs-name
    local rev="$1" path="$2" material="$3" inputs="$4" blob
    blob="$(context_object "$rev" "$path")" || return 1
    mkdir -p "$(dirname "$material/$path")" || return 1
    if ! git -C "$REPO_ROOT" cat-file blob "$blob" > "$material/$path" ||
        ! review_file_without_nul "$material/$path"; then
        rm -f "$material/$path"
        return 1
    fi
    if [ -n "$inputs" ]; then printf '%s\t%s\t%s\n' "$path" "$rev" "$blob" >> "$PACKAGE_DIR/$inputs"; fi
}

context_body_key() { # ignore only complete blank lines at the edges, for comparison only
    local eof_lf=1 last
    last="$(tail -c 1 "$1" && printf x)" || return 1
    [ "$last" = $'\nx' ] || eof_lf=0
    # Keep one line of lookahead so awk never adds LF to an unterminated line.
    LC_ALL=C awk -v eof_lf="$eof_lf" '
        function emit(line, lf, i) {
            if (lf && line ~ /^[ \t]*$/) {
                if (started) blank[++n]=line
            } else {
                for (i=1; i<=n; i++) print blank[i]
                n=0; started=1; printf "%s%s", line, (lf ? "\n" : "")
            }
        }
        { if (NR>1) emit(prev, 1); prev=$0 }
        END { if (NR) emit(prev, eof_lf) }
    ' "$1"
}

context_bodies_equal() {
    cmp -s "$1" "$2" && return 0
    review_file_without_nul "$1" && review_file_without_nul "$2" &&
        context_body_key "$1" > "$CTX_TMP/body-key-base" &&
        context_body_key "$2" > "$CTX_TMP/body-key-head" &&
        cmp -s "$CTX_TMP/body-key-base" "$CTX_TMP/body-key-head"
}

context_review_child() { # record path, usable HEAD or historical record revision
    local path="$1" rev="$2" base_blob head_blob entry
    base_blob="$(context_object "$BASE_SHA" "$path")" || {
        entry="$(git -C "$REPO_ROOT" ls-tree "$BASE_SHA" -- ":(literal)$path")" || entry=unreadable
        if [ -n "$entry" ]; then reference_side=BASE context_gap child "unsafe/unreadable base child record $BASE_SHA:$path"; fi
    }
    if [ "$rev" = "$HEAD_SHA" ]; then
        head_blob="$(context_object "$HEAD_SHA" "$path")"
        if [ "$base_blob" = "$head_blob" ] || {
            [ -n "$base_blob" ] &&
                git -C "$REPO_ROOT" cat-file blob "$base_blob" > "$CTX_TMP/base-child" &&
                git -C "$REPO_ROOT" cat-file blob "$head_blob" > "$CTX_TMP/head-child" &&
                context_bodies_equal "$CTX_TMP/base-child" "$CTX_TMP/head-child"
        }; then
            reference_side=BASE context_span "$BASE_SHA" "$path" 1 all child-shared "Child record"
            return
        fi
        if [ -n "$base_blob" ]; then reference_side=BASE context_span "$BASE_SHA" "$path" 1 all child-base "Child record"; fi
        context_span "$HEAD_SHA" "$path" 1 all child-proposed "Child record"
    else
        if [ -n "$base_blob" ]; then
            entry="$(git -C "$REPO_ROOT" ls-tree "$HEAD_SHA" -- ":(literal)$path")" || entry=unreadable
            if [ -z "$entry" ]; then
                reference_side=BASE context_span "$BASE_SHA" "$path" 1 all child-removed "Child record"
            else
                reference_side=BASE context_span "$BASE_SHA" "$path" 1 all child-base "Child record"
            fi
        fi
        if [ -n "$rev" ] && [ "$base_blob" != "$(context_object "$rev" "$path")" ]; then
            context_span "$rev" "$path" 1 all child-historical "actual record (historical when source_rev differs from HEAD)"
        fi
    fi
}

context_bound_body() { # material-root items ID; 1 absent, 2 unresolved
    local material="$1" items="$2" id="$3" locations line spans
    locations="$(awk -F '\037' -v id="$id" '$1==id { print $7 }' "$items")" || return 2
    [ -n "$locations" ] || return 1
    [[ "$locations" != *$'\n'* ]] || return 2
    bound_path="${locations%:*}"; line="${locations##*:}"
    spans="$(context_select_spans -v at="$line" < "$material/$bound_path")" || return 2
    IFS=$'\t' read -r bound_first bound_last <<< "${spans##*$'\n'}" || return 2
    context_slice "$material/$bound_path" "$bound_first" "$bound_last" > "$CTX_TMP/bound-body" || return 2
}

context_compare_bound() {
    local id="$1" base_material="$2" base_items="$3" base_status=0 head_status=0 base_kind
    local bound_path bound_first bound_last base_path base_first base_last
    context_bound_body "$base_material" "$base_items" "$id" || base_status=$?
    if [ "$base_status" -eq 0 ]; then
        base_path="$bound_path"; base_first="$bound_first"; base_last="$bound_last"
        mv "$CTX_TMP/bound-body" "$CTX_TMP/base-body"
    elif [ "$base_status" -eq 2 ]; then reference_side=BASE context_gap "$id" "ambiguous/unreadable bound body at BASE $BASE_SHA"; fi
    context_bound_body "$CTX_TMP/material" "$CTX_TMP/items" "$id" || head_status=$?
    if [ "$head_status" -eq 2 ]; then context_gap "$id" "ambiguous/unreadable bound body at HEAD $HEAD_SHA"; fi
    # Compare the body, not its line numbers or parent headings. An ID can move
    # without changing a rule; the inventories still preserve both scope decisions.
    if [ "$base_status" -eq 0 ] && [ "$head_status" -eq 0 ] &&
        context_bodies_equal "$CTX_TMP/base-body" "$CTX_TMP/bound-body"; then
        reference_side=BASE context_span "$BASE_SHA" "$base_path" "$base_first" "$base_last" bound-shared "$id"
    else
        if [ "$base_status" -eq 0 ]; then
            base_kind=bound-base
            if [ "$head_status" -eq 1 ] && $head_capture; then base_kind=bound-removed; fi
            reference_side=BASE context_span "$BASE_SHA" "$base_path" "$base_first" "$base_last" "$base_kind" "$id"
        fi
        if [ "$head_status" -eq 0 ]; then
            context_span "$HEAD_SHA" "$bound_path" "$bound_first" "$bound_last" bound-proposed "$id"
        fi
    fi
    if [ "$head_status" -eq 0 ]; then
        context_select "$HEAD_SHA" "$bound_path" "" bound-context "$id (supporting headings)" "$bound_first"
    fi
    if [ "$base_status" -eq 0 ]; then
        reference_side=BASE context_select "$BASE_SHA" "$base_path" "" bound-context "$id (supporting headings)" "$base_first"
    fi
}

context_review_bounds() { # record path and resolution at HEAD (possibly historical)
    local path="$1" rev="$2"
    local base_bounds="$PACKAGE_DIR/bounds.txt" base_scope="$CHANGE_ID" head_scope="$CHANGE_ID"
    local head_bounds_ok=true base_capture=true file id
    [ -n "$rev" ] || head_scope=--all
    : > "$CTX_TMP/head-bound-ids"
    if { [ -n "$rev" ] || { [ "$head_specs" = absent ] && $head_capture; }; } &&
        (bounds_for_root "$CTX_TMP/material" "$head_scope" "$head_capture") > "$PACKAGE_DIR/bounds.txt" 2> "$PACKAGE_DIR/bounds.stderr"; then
        awk '/^- [CNQ]-[0-9]/ { print $2 }' "$PACKAGE_DIR/bounds.txt" > "$CTX_TMP/head-bound-ids"
    else head_bounds_ok=false; context_gap bounds "bounds unavailable; inspect bounds.stderr"; fi
    # Fast path: identical relevant spec tree and child. If the child did not yet exist at
    # BASE, err towards inclusion: scope all BASE bounds, never via the proposed record.
    if ! $shared_inputs; then
        base_material="$CTX_TMP/base"; base_items="$CTX_TMP/base-items"; base_bounds="$PACKAGE_DIR/bounds-base.txt"
        printf 'path\tsource_rev\tsource_blob\n' > "$PACKAGE_DIR/bounds-base-inputs.tsv"
        reference_side=BASE context_collect_specs "$BASE_SHA" "$base_material" bounds-base-inputs.tsv "$CTX_TMP/spec-paths-base" || base_capture=false
        [ "$base_specs" != unknown ] || base_capture=false
        if ! context_collect_record "$BASE_SHA" "$path" "$base_material" bounds-base-inputs.tsv; then
            if context_object "$BASE_SHA" "$path" >/dev/null; then
                reference_side=BASE context_gap child "unreadable base child record $BASE_SHA:$path"
                base_capture=false
            fi
            base_scope=--all
        fi
        if ! spec_items "$base_material" > "$base_items"; then
            reference_side=BASE context_gap bounds "BASE spec ID inventory incomplete at $BASE_SHA"
            base_capture=false
        fi
        if ! (bounds_for_root "$base_material" "$base_scope" "$base_capture") > "$base_bounds" 2> "$PACKAGE_DIR/bounds-base.stderr"; then
            reference_side=BASE context_gap bounds "BASE bounds unavailable; inspect bounds-base.stderr"
        fi
        for file in bounds-base-inputs.tsv bounds-base.txt bounds-base.stderr; do
            inventory "$file" "BASE bounds and object-materialized inputs"
        done
    elif ! $head_bounds_ok; then
        reference_side=BASE context_gap bounds "shared bounds unavailable at $BASE_SHA; inspect bounds.stderr"
    fi
    # A HEAD scope edit, stage change or deletion must not hide a BASE bound.
    { cat "$CTX_TMP/head-bound-ids"; if [ -f "$base_bounds" ]; then awk '/^- [CNQ]-[0-9]/ { print $2 }' "$base_bounds"; fi; } |
        LC_ALL=C sort -u > "$CTX_TMP/review-bound-ids"
    while IFS= read -r id; do context_compare_bound "$id" "$base_material" "$base_items"; done < "$CTX_TMP/review-bound-ids"
    for file in bounds.txt bounds.stderr; do
        [ ! -f "$PACKAGE_DIR/$file" ] || inventory "$file" "bounds from object-materialized inputs"
    done
}

context_queue_reference() { # stable key, rev, path, first, last, description
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$(spec_field "$6")" \
        >> "$CTX_TMP/references-$reference_side"
}

context_reference_select() {
    local reference_key="$1"; shift
    context_select "$@"
}

context_reference_id() { # rev, ID inventory, ID, reason
    local rev="$1" items="$2" id="$3" reason="$4" locations path line
    if ! locations="$(awk -F '\037' -v id="$id" '$1==id { print $7 }' "$items")" ||
        [ -z "$locations" ] || [[ "$locations" == *$'\n'* ]]; then
        context_gap "$id" "missing/ambiguous spec ID $id at $rev ($reason)"; return
    fi
    path="${locations%:*}"; line="${locations##*:}"
    context_reference_select "id:$id" "$rev" "$path" "" "$id" "$reason ($id)" "$line"
}

context_reference_links() { # rev, material, source path, optional TSV of selected line ranges
    local rev="$1" material="$2" source="$3" spans="${4:-}" file line target dest issue anchor
    # Use the same link parser for both revisions and for selected parent text.
    if ! spec_links "$material" --with-destinations "$source" > "$CTX_TMP/reference-links"; then
        context_gap link "cannot enumerate links in $rev:$source"; return
    fi
    while IFS=$'\037' read -r file line target issue dest; do
        if [ -n "$spans" ] && ! awk -v n="$line" '$1<=n && n<=$2 { found=1 } END { exit !found }' "$spans"; then
            continue
        fi
        anchor=
        case "$dest" in *\#*) anchor="${dest#*\#}" ;; esac
        if [ "$issue" = undefined ]; then
            undefined_link_gap=true
            context_gap link "undefined reference label $(printf '%q' "$dest") at $rev:$source:$line; supply explicit context"
        elif [ -z "$target" ]; then
            context_gap link "unsupported destination $(printf '%q' "$dest") at $rev:$source:$line; supply explicit context"
        elif [ -n "$anchor" ] && safe_path "$target" object && [[ "$anchor" != *[[:cntrl:]\\]* ]]; then
            context_reference_select "link:$target#$anchor" "$rev" "$target" "$anchor" link "Linked context ($target#$anchor)"
        else
            context_gap link "explicit section needed for $target ($rev:$source line $line); supply the bound source"
        fi
    done < "$CTX_TMP/reference-links"
    if ! awk -v ranges="${spans:+1}" "$SPEC_SKIP_AWK"'
        FILENAME==ARGV[1] && ranges { from[++n]=$1; to[n]=$2; next }
        { if (spec_skip($0)) next; if (ranges) {
              live=0; for (i=1; i<=n; i++) if (from[i]<=FNR && FNR<=to[i]) live=1
              if (!live) next
          } }
        /-[0-9][0-9]+[[:space:]]*(to|through|–|—|\.\.)[[:space:]]*(P[0-9]+(\.[0-9]+)?\.[BI]|[JRQCDN])?-[0-9]/ {
            print "ID range at line " FNR " requires explicit complete context"
        }' ${spans:+"$spans"} "$material/$source" > "$CTX_TMP/reference-notes"; then
        context_gap reference "cannot check ID ranges in $rev:$source"; return
    fi
    while IFS= read -r line; do context_gap reference "$rev:$source: $line"; done < "$CTX_TMP/reference-notes"
}

context_reference_parent() { # rev, parent ID, scratch material, ID inventory
    local rev="$1" parent="$2" material="$3" items="$4" path="specs/changes/$2.md"
    local blob b checkpoint row line title seq id reference_parent=true
    if ! blob="$(context_object "$rev" "$path")" ||
        ! git -C "$REPO_ROOT" cat-file blob "$blob" > "$CTX_TMP/parent" ||
        ! review_file_without_nul "$CTX_TMP/parent"; then
        context_gap parent "missing/unsafe parent $rev:$path"; return
    fi
    : > "$CTX_TMP/parent-spans"
    b="$(awk "$SPEC_SKIP_AWK"' { if (!spec_skip($0) && $0 ~ /^## /) { print NR-1; exit } }' "$CTX_TMP/parent")"
    if [ -n "$b" ] && [ "$b" -gt 0 ]; then
        context_queue_reference "parent:$parent:header" "$rev" "$path" 1 "$b" "Parent header ($parent)"
        printf '1\t%s\n' "$b" >> "$CTX_TMP/parent-spans"
    else context_gap parent "unsupported parent structure without sections: $rev:$path"; fi
    checkpoint="$(awk "$SPEC_SKIP_AWK"'
        { if (spec_skip($0)) next }
        /^#+ / && tolower($0) ~ /outcome checkpoint/ { print NR }' "$CTX_TMP/parent")"
    if [ -z "$checkpoint" ] || [[ "$checkpoint" == *$'\n'* ]]; then
        context_gap parent "missing/ambiguous outcome checkpoint in $rev:$path"
    else
        context_reference_select "parent:$parent:checkpoint" "$rev" "$path" "" checkpoint "Parent outcome checkpoint ($parent)" "$checkpoint"
    fi
    row="$(awk -v id="$CHANGE_ID" "$SPEC_SKIP_AWK"'
        { if (spec_skip($0)) next }
        /^\|/ && $0 ~ ("(^|[^a-z0-9-])" id "([^a-z0-9-]|$)") { print NR }' "$CTX_TMP/parent")"
    if [ -z "$row" ] || [[ "$row" == *$'\n'* ]]; then
        context_gap parent "missing/ambiguous child row in $rev:$path"
    else
        context_reference_select "parent:$parent:child" "$rev" "$path" "" child-row "Parent child row ($parent)" "$row"
    fi
    while IFS=$'\t' read -r line seq title; do
        if awk -v n="$line" '$1<n && n<=$2 { found=1 } END { exit !found }' "$CTX_TMP/parent-spans"; then
            continue # Already included in full by a selected enclosing section.
        fi
        context_reference_select "parent:$parent:section:$seq:$title" "$rev" "$path" "" parent-obligation "Parent obligation ($parent): $title" "$line"
    done < <(awk "$SPEC_SKIP_AWK"'
        { if (spec_skip($0)) next }
        /^#+ / && tolower($0) ~ /depend|hold|limit|architect|critical path|original goal|lane/ {
            title=$0; sub(/^#+[ \t]+/,"",title); gsub(/[[:cntrl:]]/," ",title)
            print NR "\t" ++seen[title] "\t" title
        }' "$CTX_TMP/parent")
    # Scan only the selected ranges, never unrelated siblings. Parse the original
    # file so heading/fence state and relative paths are interpreted correctly.
    if ! (set -o pipefail; awk "$SPEC_SKIP_AWK $SPEC_ID_AWK"'
        FILENAME==ARGV[1] { from[++n]=$1; to[n]=$2; next }
        { if (spec_skip($0)) next
          for (i=1; i<=n; i++) if (from[i]<=FNR && FNR<=to[i]) { spec_ids($0, ""); break } }
        ' "$CTX_TMP/parent-spans" "$CTX_TMP/parent" | cut -d "$(printf '\037')" -f1 | LC_ALL=C sort -u) > "$CTX_TMP/parent-ids"; then
        context_gap reference "cannot enumerate citations in $rev:$path"
    fi
    reference_parent=false
    while IFS= read -r id; do
        context_reference_id "$rev" "$items" "$id" "Selected parent obligation citation"
    done < "$CTX_TMP/parent-ids"
    if ! mkdir -p "$material/specs/changes" || ! cp "$CTX_TMP/parent" "$material/$path"; then
        context_gap parent "cannot materialize parent links from $rev:$path"; return
    fi
    context_reference_links "$rev" "$material" "$path" "$CTX_TMP/parent-spans"
}

context_reference_record() { # record/target revisions, scratch material, ID inventory
    local rev="$1" material="$2" items="$3" record="$4"
    local header parent_field parent count id
    header="$(awk "$SPEC_SKIP_AWK $SPEC_CHANGE_TAG_AWK"'
        { $0 = change_without_tags($0) }
        { if (spec_skip($0)) next } /^## / { exit } { print }' "$material/$record")"
    count="$(printf '%s\n' "$header" | awk '{ n+=gsub(/\*\*Parent\*\*:/,"&") } END { print n+0 }')"
    parent_field="$(printf '%s\n' "$header" | awk '/\*\*Parent\*\*:/ { sub(/^.*\*\*Parent\*\*:[[:space:]]*/, ""); sub(/·.*/, ""); sub(/[[:space:]]+$/, ""); print }')"
    parent="$(printf '%s\n' "$parent_field" | grep -Eo '[0-9]{3,}-[a-z0-9]+(-[a-z0-9]+)*' | LC_ALL=C sort -u || true)"
    if [ "$count" -gt 1 ] || [[ "$parent" == *$'\n'* ]]; then
        context_gap parent "ambiguous Parent field at $rev:$record"
    elif [ -n "$parent" ] && [ "$parent" != "$CHANGE_ID" ]; then
        context_reference_parent "$rev" "$parent" "$material" "$items"
    elif [ "$count" -gt 0 ]; then
        printf '%s\n' "$parent_field" | grep -Eiq '^(none|—|n/a)$' ||
            context_gap parent "unsupported Parent field at $rev:$record; supply explicit context"
    fi
    if ! (set -o pipefail; spec_citations "$material" "$record" | cut -d "$(printf '\037')" -f1 | LC_ALL=C sort -u) > "$CTX_TMP/child-ids"; then
        context_gap reference "cannot enumerate citations in $rev:$record"
    fi
    while IFS= read -r id; do
        context_reference_id "$rev" "$items" "$id" "Child spec/acceptance/design/dependency citation"
    done < "$CTX_TMP/child-ids"
    context_reference_links "$rev" "$material" "$record"
}

context_reference_canon() { # rev, material root; include BASE even if HEAD deleted the file
    local rev="$1" material="$2" path reason entry
    for path in specs/product.md specs/architecture.md specs/design.md; do
        if [ -f "$material/$path" ]; then
            context_queue_reference "canon:$path" "$rev" "$path" 1 all "Canon ($path)"
        elif [ "$reference_side" = HEAD ] && [ "$path" != specs/design.md ]; then
            entry="$(git -C "$REPO_ROOT" ls-tree "$rev" -- ":(literal)$path")" || entry=unreadable
            if [ -n "$entry" ]; then context_gap canon "missing/unsafe/unreadable context $rev:$path"; fi
        fi
    done
    while IFS= read -r path; do
        case "$path" in
            specs/parts/*) reason="Part and cross-interface obligations ($path)"
                context_queue_reference "canon:$path" "$rev" "$path" 1 all "$reason" ;;
        esac
    done < <(spec_files "$material")
}

context_reference_bytes() { # rev, path, first, last, destination
    local blob
    blob="$(context_object "$1" "$2")" &&
        git -C "$REPO_ROOT" cat-file blob "$blob" > "$CTX_TMP/reference-source" || return 1
    context_slice "$CTX_TMP/reference-source" "$3" "$4" > "$5"
}

context_emit_references() {
    local key br bp bf bl bd hr hp hf hl hd base_kind head_kind
    # Full outer join by logical reference. A reference missing on one side leaves
    # that side empty; all real captures retain revision, path and span.
    awk -F '\t' -v OFS='\t' '
        FILENAME==ARGV[1] { if (!($1 in b)) { b[$1]=$0; keys[++n]=$1 } next }
        !($1 in h) { h[$1]=$0; if (!($1 in b)) keys[++n]=$1 }
        END { for (i=1; i<=n; i++) {
            k=keys[i]; print (k in b ? b[k] : k "\t-\t-\t-\t-\t-"), (k in h ? substr(h[k],length(k)+2) : "-\t-\t-\t-\t-")
        } }' "$CTX_TMP/references-BASE" "$CTX_TMP/references-HEAD" > "$CTX_TMP/reference-pairs"
    while IFS=$'\t' read -r key br bp bf bl bd hr hp hf hl hd; do
        base_kind=reference-base; head_kind=reference-proposed
        if [ "$br" != - ]; then
            if [ "$hr" = - ]; then
                # Missing from an incomplete HEAD canon capture is not proof of removal.
                if [[ "$key" != canon:* ]] || $head_capture; then base_kind=reference-removed; fi
            elif context_reference_bytes "$br" "$bp" "$bf" "$bl" "$CTX_TMP/reference-base-body" &&
                context_reference_bytes "$hr" "$hp" "$hf" "$hl" "$CTX_TMP/reference-head-body" &&
                context_bodies_equal "$CTX_TMP/reference-base-body" "$CTX_TMP/reference-head-body"; then
                base_kind=reference-shared; head_kind=
            fi
            reference_side=BASE context_span "$br" "$bp" "$bf" "$bl" "$base_kind" "$bd"
        fi
        if [ "$hr" != - ] && [ -n "$head_kind" ]; then
            context_span "$hr" "$hp" "$hf" "$hl" "$head_kind" "$hd"
        fi
    done < "$CTX_TMP/reference-pairs"
    # Closing evidence is not a HEAD obligation and cannot hide a removed BASE reference.
    while IFS=$'\t' read -r key hr hp hf hl hd; do
        context_span "$hr" "$hp" "$hf" "$hl" reference-historical "$hd"
    done < "$CTX_TMP/references-historical"
}

review_context_build() {
    local path blob base_blob record record_rev last count a entry base_material base_items hist_material reference_side
    local shared_inputs=false explicit_kind explicit_rev spec_presence base_specs head_specs
    local head_capture=true
    base_reference_gap=false
    undefined_link_gap=false
    no_spec_files=false
    CTX_TMP="$PACKAGE_SCRATCH/context"; mkdir -p "$CTX_TMP/material/.prdkit"
    CTX_N=1
    printf 'artifact\tsource_rev\tsource_path\tsource_blob\tfirst_line\tlast_line\tobligation\treason\n' > "$PACKAGE_DIR/context-manifest.tsv"
    : > "$PACKAGE_DIR/context-gaps.txt"
    if ! git -C "$REPO_ROOT" diff --quiet "$HEAD_SHA" --; then
        context_gap worktree "working tree differs from bound HEAD; only committed objects are packaged, verify local evidence applicability"
    fi
    reference_side=BASE context_list_specs "$BASE_SHA" "$CTX_TMP/spec-paths-base"
    base_specs="$spec_presence"
    context_list_specs "$HEAD_SHA" "$CTX_TMP/spec-paths-head"
    head_specs="$spec_presence"
    if [ "$base_specs" = absent ] && [ "$head_specs" = absent ]; then no_spec_files=true; fi
    record="specs/changes/$CHANGE_ID.md"; record_rev="$HEAD_SHA"
    if ! context_object "$record_rev" "$record" >/dev/null; then
        entry="$(git -C "$REPO_ROOT" ls-tree "$HEAD_SHA" -- ":(literal)$record" 2>/dev/null)" || entry=unreadable
        if [ -n "$entry" ]; then
            record_rev=""; context_gap child "actual child record is unsafe/unreadable at HEAD: $record; no historical substitution"
        else
            last="$(git -C "$REPO_ROOT" log -1 --format=%H "$HEAD_SHA" -- "$record" 2>/dev/null || true)"
            if [ -n "$last" ] && context_object "$last^" "$record" >/dev/null; then
                record_rev="$(git -C "$REPO_ROOT" rev-parse "$last^")"
            else record_rev=""; context_gap child "actual child record missing or unrecoverable: $record"; fi
        fi
    fi
    # Materialize canon from H; bounds scope alone may use the recovered historical child.
    # No checkout, index, hooks or candidate helper is used.
    printf 'path\tsource_rev\tsource_blob\n' > "$PACKAGE_DIR/bounds-inputs.tsv"
    context_review_child "$record" "$record_rev"
    if [ -n "$record_rev" ] && ! context_collect_record "$record_rev" "$record" "$CTX_TMP/material" bounds-inputs.tsv; then
        context_gap child "unreadable child record $record_rev:$record"
        record_rev=""
    fi
    if [ "$record_rev" = "$HEAD_SHA" ] &&
        git -C "$REPO_ROOT" diff --quiet --no-ext-diff --no-textconv "$BASE_SHA" "$HEAD_SHA" -- specs ':!specs/changes' &&
        git -C "$REPO_ROOT" diff --quiet --no-ext-diff --no-textconv "$BASE_SHA" "$HEAD_SHA" -- "$record"; then
        # Shared material also feeds BASE discovery. Record any shared capture failure as binding.
        shared_inputs=true
        reference_side=BASE
    fi
    context_collect_specs "$HEAD_SHA" "$CTX_TMP/material" bounds-inputs.tsv "$CTX_TMP/spec-paths-head" || head_capture=false
    [ "$head_specs" != unknown ] || head_capture=false
    if ! spec_items "$CTX_TMP/material" > "$CTX_TMP/items"; then
        context_gap canon "HEAD spec ID inventory incomplete at $HEAD_SHA"
        head_capture=false
    fi
    reference_side=
    # Reuse the actual bounds computation, including all/later-stage/exception widening.
    source "$SCRIPT_DIR/bounds.sh"
    base_material="$CTX_TMP/material"; base_items="$CTX_TMP/items"
    context_review_bounds "$record" "$record_rev"
    inventory bounds-inputs.tsv "object-materialized bounds inputs"
    # Policy is frozen at the trusted default; proposed policy remains in the full diff.
    for path in .prdkit/memory/constitution.md .prdkit/memory/agents.md .prdkit/memory/config.md; do
        if [ -z "$POLICY_AT" ]; then
            context_gap policy "no trusted policy binding for $path"
        else
            # No registry or optional settings is not an unreadable trusted-policy object.
            if [ "$path" != .prdkit/memory/constitution.md ] &&
                entry="$(git -C "$REPO_ROOT" ls-tree "$POLICY_AT" -- ":(literal)$path")" && [ -z "$entry" ]; then
                continue
            fi
            context_span "$POLICY_AT" "$path" 1 all policy "trusted default-branch policy"
        fi
    done
    : > "$CTX_TMP/references-BASE"; : > "$CTX_TMP/references-HEAD"; : > "$CTX_TMP/references-historical"
    reference_side=BASE
    context_reference_canon "$BASE_SHA" "$base_material"
    if [ -f "$base_material/$record" ]; then
        context_reference_record "$BASE_SHA" "$base_material" "$base_items" "$record"
    fi
    reference_side=HEAD
    context_reference_canon "$HEAD_SHA" "$CTX_TMP/material"
    if [ "$record_rev" = "$HEAD_SHA" ]; then
        context_reference_record "$HEAD_SHA" "$CTX_TMP/material" "$CTX_TMP/items" "$record"
    elif [ -n "$record_rev" ] && [ "$record_rev" != "$BASE_SHA" ]; then
        reference_side=historical
        hist_material="$CTX_TMP/historical"
        context_list_specs "$record_rev" "$CTX_TMP/spec-paths-historical"
        context_collect_specs "$record_rev" "$hist_material" "" "$CTX_TMP/spec-paths-historical" || :
        if ! spec_items "$hist_material" > "$CTX_TMP/historical-items"; then
            context_gap canon "Historical spec ID inventory incomplete at $record_rev"
        fi
        if context_collect_record "$record_rev" "$record" "$hist_material" ""; then
            context_reference_record "$record_rev" "$hist_material" "$CTX_TMP/historical-items" "$record"
        else context_gap child "cannot materialize historical references at $record_rev:$record"
        fi
    fi
    reference_side=
    context_emit_references
    # Keep both sides of changed canon as supporting sources, including deletions.
    if ! git -C "$REPO_ROOT" diff --ignore-submodules=none -z --name-only --no-renames "$BASE_SHA" "$HEAD_SHA" > "$CTX_TMP/changed-paths"; then
        context_gap changed-spec "cannot completely enumerate changed canon"
    fi
    while IFS= read -r -d '' path; do
        case "$path" in specs/changes/*) continue ;; specs/*) ;; *) continue ;; esac
        if context_object "$BASE_SHA" "$path" >/dev/null; then
            reference_side=BASE context_span "$BASE_SHA" "$path" 1 all changed-spec "BASE canon, unabridged"
        else
            entry="$(git -C "$REPO_ROOT" ls-tree "$BASE_SHA" -- ":(literal)$path")" || entry=unreadable
            if [ -n "$entry" ]; then reference_side=BASE context_gap changed-spec "unsafe BASE canon $(printf '%q' "$path") at $BASE_SHA"; fi
        fi
        if blob="$(context_object "$HEAD_SHA" "$path")"; then
            context_span "$HEAD_SHA" "$path" 1 all changed-spec "changed canon, unabridged"
        else
            entry="$(git -C "$REPO_ROOT" ls-tree "$HEAD_SHA" -- ":(literal)$path")" || entry=unreadable
            if [ -n "$entry" ]; then context_gap changed-spec "unsafe changed canon $(printf '%q' "$path"); inspect full diff"; fi
        fi
    done < "$CTX_TMP/changed-paths"
    for path in ${CONTEXT[@]+"${CONTEXT[@]}"}; do
        blob="$(context_object "$HEAD_SHA" "$path")"
        explicit_kind=reference-proposed; explicit_rev="$HEAD_SHA"
        if base_blob="$(context_object "$BASE_SHA" "$path")"; then
            if [ "$base_blob" = "$blob" ]; then
                explicit_kind=reference-shared; explicit_rev="$BASE_SHA"
            elif git -C "$REPO_ROOT" cat-file blob "$base_blob" > "$CTX_TMP/explicit-base" &&
                context_bodies_equal "$CTX_TMP/explicit-base" "$PACKAGE_DIR/context/$path"; then
                reference_side=BASE context_span "$BASE_SHA" "$path" 1 all reference-shared "Explicit context ($path)"
                explicit_kind=explicit-snapshot
            else
                reference_side=BASE context_span "$BASE_SHA" "$path" 1 all reference-base "Explicit context ($path)"
            fi
        else
            entry="$(git -C "$REPO_ROOT" ls-tree "$BASE_SHA" -- ":(literal)$path")" || entry=unreadable
            if [ -n "$entry" ]; then reference_side=BASE context_gap context "unsafe explicit context $BASE_SHA:$path"; fi
        fi
        count="$(awk 'END { print NR }' "$PACKAGE_DIR/context/$path")"; a=1
        [ "$count" != 0 ] || a=0
        printf 'context/%s\t%s\t%s\t%s\t%s\t%s\t%s\tExplicit context (%s)\n' \
            "$path" "$explicit_rev" "$path" "$blob" "$a" "$count" "$explicit_kind" "$path" >> "$PACKAGE_DIR/context-manifest.tsv"
    done
    if [ "${#EVIDENCE[@]}" -eq 0 ]; then context_gap verification "no verification evidence supplied; dispatch pending"
    else context_gap verification "caller-supplied evidence requires revision/result/applicability verification; no semantic inference"; fi
}

# Render from the same immutable artifacts the manifest binds, not from the working tree.
# Keep whole excerpts or require the full context: never cut a rule mid-span.
review_inline_text() ( # 0 valid, 3 invalid, other nonzero I/O failure
    set -o pipefail
    # Work on byte values, independent of the installed locales or awk's Unicode support.
    # Strict UTF-8 per RFC 3629; reject C0/DEL/C1, including all CR (even in CRLF).
    LC_ALL=C od -A n -v -t u1 < "$1" | LC_ALL=C awk '
        { for (i=1; i<=NF; i++) {
            b=$i+0
            if (left) {
                if (b<low || b>high) { bad=1; exit }
                left--; low=128; high=191
            } else if (b<128) {
                if ((b<32 && b!=9 && b!=10) || b==127) { bad=1; exit }
            } else {
                low=128; high=191
                if (b>=194 && b<=223) { left=1; if (b==194) low=160 }
                else if (b>=224 && b<=239) {
                    left=2; if (b==224) low=160; if (b==237) high=159
                } else if (b>=240 && b<=244) {
                    left=3; if (b==240) low=144; if (b==244) high=143
                } else { bad=1; exit }
            }
        } }
        END { if (bad || left) exit 3 }'
)

review_obligation_append() { # artifact, source label; 2 = over cap, 3 = cannot inline as text
    local artifact="$1" label="$2" heading="${3:-}" file="$PACKAGE_DIR/$1" bytes status
    bytes="$(wc -c < "$file")" || return 1
    [ "$((obligation_bytes + bytes))" -le "$obligation_cap" ] || return 2
    if review_inline_text "$file"; then
        :
    else
        status=$?
        [ "$status" != 3 ] || return 3
        return 1
    fi
    if [ -n "$heading" ]; then printf '**%s**\n\n' "$heading" >> "$obligation_draft" || return 1; fi
    {
        printf '    %s\n    Package artifact: %s\n\n' "$label" "$artifact" &&
        LC_ALL=C sed 's/^/    /' "$file" &&
        printf '\n\n'
    } >> "$obligation_draft" || return 1
    obligation_bytes="$(wc -c < "$obligation_draft")" || return 1
    [ "$obligation_bytes" -le "$obligation_cap" ] || return 2
}

review_obligation_capture() {
    local artifact rev path blob first last kind reason heading status
    # Bounds inventory supplies applicability and later-stage status, not the bodies below.
    if [ -f "$PACKAGE_DIR/bounds-base.txt" ]; then
        review_obligation_append bounds-base.txt 'BASE bounds (binding scope and stage; see bounds-base-inputs.tsv)' || return $?
    fi
    if [ -s "$PACKAGE_DIR/bounds.txt" ]; then
        if [ -f "$PACKAGE_DIR/bounds-base.txt" ]; then
            heading='Candidate bounds (for reconciliation; see bounds-inputs.tsv)'
        else heading='Applicable bounds (unchanged scope and stage; see bounds-inputs.tsv)'; fi
        review_obligation_append bounds.txt "$heading" || return $?
    fi
    while IFS=$'\t' read -r artifact rev path blob first last kind reason; do
        heading=''
        case "$kind" in
            bound-base|child-base|reference-base)
                heading="$reason — BASE, binding for this review" ;;
            bound-proposed|child-proposed|reference-proposed)
                heading="$reason — Proposed by this change — not yet an obligation; the reviewer must reconcile" ;;
            bound-removed|child-removed|reference-removed)
                heading="$reason — BASE, removed by this change — the reviewer must judge" ;;
            child-historical)
                heading='Historical child record — scope evidence only, not a substitute for BASE' ;;
            reference-historical)
                heading="$reason — Historical scope evidence, not a substitute for BASE" ;;
            bound-shared|child-shared|reference-shared)
                heading="$reason — unchanged from BASE" ;;
        esac
        review_obligation_append "$artifact" "Source: $path:$first-$last at $rev ($kind: $reason)" "$heading" || return $?
    done < "$PACKAGE_SCRATCH/obligation-spans"
    if [ -s "$PACKAGE_DIR/context-gaps.txt" ]; then
        printf '### Unresolved context and verification\n\n' >> "$obligation_draft" || return 1
        review_obligation_append context-gaps.txt 'Questions to resolve before a verdict' || return $?
    fi
    # Source labels and gaps also contain repo-supplied values. Validate the complete preview.
    review_inline_text "$obligation_draft" || { status=$?; [ "$status" -eq 3 ] && return 3; return 1; }
}

review_context_obligations() {
    local obligation_cap=16384 obligation_bytes=0 obligation_draft="$PACKAGE_SCRATCH/obligations" status
    # Multiple obligations can cite the same excerpt. Include its body just once.
    awk -F '\t' '
        NR>1 && $1!="-" && $7!~/^(changed-spec|bound-context|explicit-snapshot)$/ &&
        !seen[$2 FS $3 FS $4 FS $5 FS $6]++' "$PACKAGE_DIR/context-manifest.tsv" \
        > "$PACKAGE_SCRATCH/obligation-spans"
    : > "$obligation_draft"
    if $no_spec_files; then printf 'No spec files at BASE or HEAD; no spec bounds apply.\n\n'; fi
    if $base_reference_gap; then
        status=4
    elif $undefined_link_gap; then
        status=5
    elif review_obligation_capture; then
        cat "$obligation_draft"
        return
    else
        status=$?
    fi
    case "$status" in
        2) printf '**Required full context:** The captured obligations exceed the %s-byte inline cap.\n\n' "$obligation_cap" ;;
        3) printf '**Required full context:** A captured artifact cannot be included as inline text.\n\n' ;;
        4) printf '**Required full context:** A BASE obligation could not be resolved. See [context-gaps.txt](context-gaps.txt) for the exact gap.\n\n' ;;
        5) printf '**Required full context:** A reference label is undefined. See [context-gaps.txt](context-gaps.txt) for the exact gap.\n\n' ;;
        *) return "$status" ;;
    esac
    cat <<'EOF'
No partial obligation list is shown. Before giving a verdict, read
[context-manifest.tsv](context-manifest.tsv), the scope, policy and obligation excerpts it lists,
[context-gaps.txt](context-gaps.txt), and `bounds.txt` with `bounds-inputs.tsv` if present. Read
`bounds-base.txt` with `bounds-base-inputs.tsv` when present. Use the source revisions and
obligation labels to distinguish binding BASE from proposed HEAD. If required context is
unreadable or a gap remains unresolved, mark the review pending.

EOF
}
