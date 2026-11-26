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
    printf '%s\n' "$*" >> "$PACKAGE_DIR/context-gaps.txt"
    printf -- '-\t-\t-\t-\t-\t-\t%s\t%s\n' "$(spec_field "$1")" "$(spec_field "$*")" >> "$PACKAGE_DIR/context-manifest.tsv"
}

context_object() { # rev path -> blob; never dereference a symlink/tree/submodule
    local entry
    safe_path "$2" || return 1
    entry="$(git -C "$REPO_ROOT" ls-tree "$1" -- ":(literal)$2")" || return 1
    case "$entry" in 100644\ blob\ *|100755\ blob\ *) ;; *) return 1 ;; esac
    entry="${entry#* blob }"; printf '%s\n' "${entry%%$'\t'*}"
}

context_span() { # rev path first last obligation reason
    local rev="$1" path="$2" first="$3" last="$4" obligation="$5" reason="$6" blob name=""
    local artifact source_rev source_path source_blob source_first source_last rest fresh=false
    if ! blob="$(context_object "$rev" "$path")" ||
        ! GIT_NO_LAZY_FETCH=1 git -C "$REPO_ROOT" cat-file blob "$blob" > "$CTX_TMP/blob" ||
        ! review_file_without_nul "$CTX_TMP/blob"; then
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
        else sed -n "${first},${last}p" "$CTX_TMP/blob" > "$PACKAGE_DIR/$name"; fi
    fi
    case "$obligation" in parent|checkpoint|child-row|parent-obligation)
        awk "$SPEC_SKIP_AWK $SPEC_ID_AWK"'
            { if (!spec_skip($0)) spec_ids($0, "") }' "$PACKAGE_DIR/$name" |
            cut -d "$(printf '\037')" -f1 >> "$CTX_TMP/parent-ids"
        if grep -q '](' "$PACKAGE_DIR/$name"; then
            context_gap parent-link "selected parent obligation contains a link; supply its required captured context explicitly"
        fi ;;
    esac
    if $fresh; then inventory "$name" "$rev:$path:$first-$last"; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "$rev" "$path" "$blob" "$first" "$last" \
        "$(spec_field "$obligation")" "$(spec_field "$reason")" >> "$PACKAGE_DIR/context-manifest.tsv"
}

context_select() { # rev path selector obligation reason [source line]
    local rev="$1" path="$2" selector="$3" obligation="$4" reason="$5" at="${6:-0}" blob a b spans
    if ! blob="$(context_object "$rev" "$path")" ||
        ! GIT_NO_LAZY_FETCH=1 git -C "$REPO_ROOT" cat-file blob "$blob" > "$CTX_TMP/select" ||
        ! review_file_without_nul "$CTX_TMP/select"; then
        context_gap "$obligation" "missing/unsafe context $rev:$path"; return
    fi
    if ! spans="$(context_select_spans -v at="$at" -v selector="$selector" < "$CTX_TMP/select")"; then
        context_gap "$obligation" "ambiguous/missing/unsupported section $path#$selector (line $at)"; return
    fi
    while IFS=$'\t' read -r a b; do
        context_span "$rev" "$path" "$a" "$b" "$obligation" "$reason"
    done <<< "$spans"
}

context_id() { # actual ID -> unique definition, never select an arbitrary sibling
    local wanted="$1" reason="$2" locations location path line
    locations="$(awk -F '\037' -v id="$wanted" '$1==id { print $7 }' "$CTX_TMP/items")"
    if [ -z "$locations" ] || [[ "$locations" == *$'\n'* ]]; then
        context_gap "$wanted" "missing/ambiguous spec ID $wanted"; return
    fi
    location="$locations"; path="${location%:*}"; line="${location##*:}"
    context_select "$HEAD_SHA" "$path" "" "$wanted" "$reason" "$line"
}

context_collect_specs() { # rev material-root inputs-name
    local rev="$1" material="$2" inputs="$3" path blob
    mkdir -p "$material/.prdkit"
    if ! git -C "$REPO_ROOT" ls-tree -r -z --name-only "$rev" -- specs > "$CTX_TMP/spec-paths"; then
        context_gap canon "cannot completely enumerate spec entries at $rev"
    fi
    while IFS= read -r -d '' path; do
        case "$path" in specs/*.md) ;; *) continue ;; esac
        case "$path" in specs/changes/*) continue ;; esac
        if blob="$(context_object "$rev" "$path")"; then
            mkdir -p "$(dirname "$material/$path")"
            if git -C "$REPO_ROOT" cat-file blob "$blob" > "$material/$path" &&
                review_file_without_nul "$material/$path"; then
                continue
            fi
            context_gap canon "unreadable/non-text input $path at $rev"; rm -f "$material/$path"
        else context_gap canon "unsafe spec input $(printf '%q' "$path") at $rev"; fi
    done < "$CTX_TMP/spec-paths"
    while IFS= read -r path; do
        blob="$(context_object "$rev" "$path")"
        printf '%s\t%s\t%s\n' "$path" "$rev" "$blob" >> "$PACKAGE_DIR/$inputs"
    done < <(spec_files "$material")
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
    printf '%s\t%s\t%s\n' "$path" "$rev" "$blob" >> "$PACKAGE_DIR/$inputs"
}

context_review_child() { # record path, usable HEAD or historical record revision
    local path="$1" rev="$2" base_blob head_blob entry
    base_blob="$(context_object "$BASE_SHA" "$path")" || {
        entry="$(git -C "$REPO_ROOT" ls-tree "$BASE_SHA" -- ":(literal)$path")" || entry=unreadable
        if [ -n "$entry" ]; then context_gap child "unsafe/unreadable base child record $BASE_SHA:$path"; fi
    }
    if [ "$rev" = "$HEAD_SHA" ]; then
        head_blob="$(context_object "$HEAD_SHA" "$path")"
        if [ "$base_blob" = "$head_blob" ]; then
            context_span "$HEAD_SHA" "$path" 1 all child-shared "Child record"
            return
        fi
        if [ -n "$base_blob" ]; then context_span "$BASE_SHA" "$path" 1 all child-base "Child record"; fi
        context_span "$HEAD_SHA" "$path" 1 all child-proposed "Child record"
    else
        if [ -n "$base_blob" ]; then
            entry="$(git -C "$REPO_ROOT" ls-tree "$HEAD_SHA" -- ":(literal)$path")" || entry=unreadable
            if [ -z "$entry" ]; then
                context_span "$BASE_SHA" "$path" 1 all child-removed "Child record"
            else
                context_span "$BASE_SHA" "$path" 1 all child-base "Child record"
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
    sed -n "${bound_first},${bound_last}p" "$material/$bound_path" > "$CTX_TMP/bound-body" || return 2
}

context_compare_bound() {
    local id="$1" base_material="$2" base_items="$3" base_status=0 head_status=0 base_kind
    local bound_path bound_first bound_last base_path base_first base_last
    context_bound_body "$base_material" "$base_items" "$id" || base_status=$?
    if [ "$base_status" -eq 0 ]; then
        base_path="$bound_path"; base_first="$bound_first"; base_last="$bound_last"
        mv "$CTX_TMP/bound-body" "$CTX_TMP/base-body"
    elif [ "$base_status" -eq 2 ]; then context_gap "$id" "ambiguous/unreadable bound body at BASE $BASE_SHA"; fi
    context_bound_body "$CTX_TMP/material" "$CTX_TMP/items" "$id" || head_status=$?
    if [ "$head_status" -eq 2 ]; then context_gap "$id" "ambiguous/unreadable bound body at HEAD $HEAD_SHA"; fi
    # Compare the body, not its line numbers or parent headings. An ID can move
    # without changing a rule; the inventories still preserve both scope decisions.
    if [ "$base_status" -eq 0 ] && [ "$head_status" -eq 0 ] &&
        cmp -s "$CTX_TMP/base-body" "$CTX_TMP/bound-body"; then
        context_span "$HEAD_SHA" "$bound_path" "$bound_first" "$bound_last" bound-shared "$id"
    else
        if [ "$base_status" -eq 0 ]; then
            base_kind=bound-base
            [ "$head_status" -ne 1 ] || base_kind=bound-removed
            context_span "$BASE_SHA" "$base_path" "$base_first" "$base_last" "$base_kind" "$id"
        fi
        if [ "$head_status" -eq 0 ]; then
            context_span "$HEAD_SHA" "$bound_path" "$bound_first" "$bound_last" bound-proposed "$id"
        fi
    fi
    if [ "$head_status" -eq 0 ]; then
        context_select "$HEAD_SHA" "$bound_path" "" bound-context "$id (supporting headings)" "$bound_first"
    fi
}

context_review_bounds() { # record path and resolution at HEAD (possibly historical)
    local path="$1" rev="$2" base_material="$CTX_TMP/material" base_items="$CTX_TMP/items"
    local base_bounds="$PACKAGE_DIR/bounds.txt" base_scope="$CHANGE_ID" file id
    : > "$CTX_TMP/head-bound-ids"
    if [ -n "$rev" ] && (bounds_for_root "$CTX_TMP/material" "$CHANGE_ID") > "$PACKAGE_DIR/bounds.txt" 2> "$PACKAGE_DIR/bounds.stderr"; then
        awk '/^- [CNQ]-[0-9]/ { print $2 }' "$PACKAGE_DIR/bounds.txt" > "$CTX_TMP/head-bound-ids"
    else context_gap bounds "bounds unavailable; inspect bounds.stderr"; fi
    # Fast path: identical relevant spec tree and child. If the child did not yet exist at
    # BASE, err towards inclusion: scope all BASE bounds, never via the proposed record.
    if ! git -C "$REPO_ROOT" diff --quiet --no-ext-diff --no-textconv "$BASE_SHA" "$HEAD_SHA" -- specs ':!specs/changes' ||
        ! git -C "$REPO_ROOT" diff --quiet --no-ext-diff --no-textconv "$BASE_SHA" "$HEAD_SHA" -- "$path" ||
        [ "$rev" != "$HEAD_SHA" ]; then
        base_material="$CTX_TMP/base"; base_items="$CTX_TMP/base-items"; base_bounds="$PACKAGE_DIR/bounds-base.txt"
        printf 'path\tsource_rev\tsource_blob\n' > "$PACKAGE_DIR/bounds-base-inputs.tsv"
        context_collect_specs "$BASE_SHA" "$base_material" bounds-base-inputs.tsv
        if ! context_collect_record "$BASE_SHA" "$path" "$base_material" bounds-base-inputs.tsv; then
            if context_object "$BASE_SHA" "$path" >/dev/null; then
                context_gap child "unreadable base child record $BASE_SHA:$path"
            fi
            base_scope=--all
        fi
        if ! spec_items "$base_material" > "$base_items"; then
            context_gap bounds "BASE spec ID inventory incomplete at $BASE_SHA"
        fi
        if ! (bounds_for_root "$base_material" "$base_scope") > "$base_bounds" 2> "$PACKAGE_DIR/bounds-base.stderr"; then
            context_gap bounds "BASE bounds unavailable; inspect bounds-base.stderr"
        fi
        for file in bounds-base-inputs.tsv bounds-base.txt bounds-base.stderr; do
            inventory "$file" "BASE object-materialized inputs; installed bounds.sh"
        done
    fi
    # A HEAD scope edit, stage change or deletion must not hide a BASE bound.
    { cat "$CTX_TMP/head-bound-ids"; if [ -f "$base_bounds" ]; then awk '/^- [CNQ]-[0-9]/ { print $2 }' "$base_bounds"; fi; } |
        LC_ALL=C sort -u > "$CTX_TMP/review-bound-ids"
    while IFS= read -r id; do context_compare_bound "$id" "$base_material" "$base_items"; done < "$CTX_TMP/review-bound-ids"
    for file in bounds-inputs.tsv bounds.txt bounds.stderr; do
        [ ! -f "$PACKAGE_DIR/$file" ] || inventory "$file" "object-materialized inputs; installed bounds.sh"
    done
}

review_context_build() {
    local path blob rev record record_rev last parent parent_field header checkpoint row count a b id location reason target anchor line entry
    CTX_TMP="$PACKAGE_SCRATCH/context"; mkdir -p "$CTX_TMP/material/.prdkit"
    CTX_N=1
    printf 'artifact\tsource_rev\tsource_path\tsource_blob\tfirst_line\tlast_line\tobligation\treason\n' > "$PACKAGE_DIR/context-manifest.tsv"
    : > "$PACKAGE_DIR/context-gaps.txt"
    if ! git -C "$REPO_ROOT" diff --quiet "$HEAD_SHA" --; then
        context_gap worktree "working tree differs from bound HEAD; only committed objects are packaged, verify local evidence applicability"
    fi
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
    context_collect_specs "$HEAD_SHA" "$CTX_TMP/material" bounds-inputs.tsv
    if ! spec_items "$CTX_TMP/material" > "$CTX_TMP/items"; then
        context_gap canon "HEAD spec ID inventory incomplete at $HEAD_SHA"
    fi
    # Reuse the actual bounds computation, including all/later-stage/exception widening.
    source "$SCRIPT_DIR/bounds.sh"
    context_review_bounds "$record" "$record_rev"
    # Policy is frozen at the trusted default; proposed policy remains in the full diff.
    for path in .prdkit/memory/constitution.md .prdkit/memory/agents.md .prdkit/memory/config.md; do
        if [ -n "$POLICY_AT" ]; then context_span "$POLICY_AT" "$path" 1 all policy "trusted default-branch policy"
        else context_gap policy "no trusted policy binding for $path"; fi
    done
    for path in specs/product.md specs/architecture.md; do
        context_span "$HEAD_SHA" "$path" 1 all canon "protocol-required canon"
    done
    path=specs/design.md
    if [ -f "$CTX_TMP/material/$path" ]; then
        context_span "$HEAD_SHA" "$path" 1 all canon "optional L1 UI design"
    fi
    # Parts across interfaces cannot be inferred semantically from paths. Conservatively supply
    # the committed part canon rather than silently dropping a cross-interface obligation.
    while IFS= read -r path; do
        case "$path" in specs/parts/*) context_span "$HEAD_SHA" "$path" 1 all parts "part and cross-interface obligations" ;; esac
    done < <(spec_files "$CTX_TMP/material")
    if [ -n "$record_rev" ]; then
        header="$(awk "$SPEC_SKIP_AWK $SPEC_CHANGE_TAG_AWK"'
            { $0 = change_without_tags($0) }
            { if (spec_skip($0)) next } /^## / { exit } { print }' "$CTX_TMP/material/$record")"
        count="$(printf '%s\n' "$header" | awk '{ n+=gsub(/\*\*Parent\*\*:/,"&") } END { print n+0 }')"
        parent_field="$(printf '%s\n' "$header" | awk '/\*\*Parent\*\*:/ { sub(/^.*\*\*Parent\*\*:[[:space:]]*/, ""); sub(/·.*/, ""); sub(/[[:space:]]+$/, ""); print }')"
        parent="$(printf '%s\n' "$parent_field" | grep -Eo '[0-9]{3,}-[a-z0-9]+(-[a-z0-9]+)*' | LC_ALL=C sort -u || true)"
        if [ "$count" -gt 1 ] || [[ "$parent" == *$'\n'* ]]; then context_gap parent "ambiguous Parent field"
        elif [ -n "$parent" ]; then
            path="specs/changes/$parent.md"
            if blob="$(context_object "$HEAD_SHA" "$path")" &&
                git -C "$REPO_ROOT" cat-file blob "$blob" > "$CTX_TMP/parent"; then
                b="$(awk '/^## / { print NR-1; exit }' "$CTX_TMP/parent")"
                if [ -n "$b" ]; then context_span "$HEAD_SHA" "$path" 1 "$b" parent "parent header"
                else context_gap parent "unsupported parent structure without sections: $path"; fi
                checkpoint="$(awk "$SPEC_SKIP_AWK"'
                    { if (spec_skip($0)) next }
                    /^#+ / && tolower($0) ~ /outcome checkpoint/ { print NR }' "$CTX_TMP/parent")"
                if [ -z "$checkpoint" ] || [[ "$checkpoint" == *$'\n'* ]]; then context_gap parent "missing/ambiguous outcome checkpoint in $path"
                else context_select "$HEAD_SHA" "$path" "" checkpoint "required parent checkpoint" "$checkpoint"; fi
                row="$(awk -v id="$CHANGE_ID" "$SPEC_SKIP_AWK"'
                    { if (spec_skip($0)) next }
                    /^\|/ && $0 ~ ("(^|[^a-z0-9-])" id "([^a-z0-9-]|$)") { print NR }' "$CTX_TMP/parent")"
                if [ -z "$row" ] || [[ "$row" == *$'\n'* ]]; then context_gap parent "missing/ambiguous child row in $path"
                else context_select "$HEAD_SHA" "$path" "" child-row "actual child row" "$row"; fi
                while IFS= read -r line; do
                    context_select "$HEAD_SHA" "$path" "" parent-obligation "parent dependency/hold/limit/architecture/goal/lane" "$line"
                done < <(awk "$SPEC_SKIP_AWK"'
                    { if (spec_skip($0)) next }
                    /^#+ / && tolower($0) ~ /depend|hold|limit|architect|critical path|original goal|lane/ { print NR }' "$CTX_TMP/parent")
            else context_gap parent "missing/unsafe parent $path"; fi
        elif [ -n "$parent_field" ]; then
            printf '%s\n' "$parent_field" | grep -Eiq '^(none|—|n/a)$' ||
                context_gap parent "unsupported Parent field; supply explicit context"
        fi
        # Resolve all actual child citations, not just its declared Bounds.
        while IFS= read -r id; do context_id "$id" "child spec/acceptance/design/dependency citation"; done \
            < <(spec_citations "$CTX_TMP/material" "$record" | cut -d "$(printf '\037')" -f1 | LC_ALL=C sort -u)
        while IFS= read -r line; do context_gap reference "$line"; done < <(
            awk "$SPEC_SKIP_AWK"'
                { if (spec_skip($0)) next }
                /\]\(https?:/ { print "external child link at line " NR " requires captured context" }
                /-[0-9][0-9]+[[:space:]]*(to|through|–|—|\.\.)[[:space:]]*(P[0-9]+(\.[0-9]+)?\.[BI]|[JRQCDN])?-[0-9]/ {
                    print "ID range at child line " NR " requires explicit complete context"
                }' "$CTX_TMP/material/$record")
        # spec_links supplies safely normalized paths. Anchored links require a unique heading;
        # unsupported forms remain gaps, never a guessed section.
        while IFS=$'\037' read -r path line target; do
            [ -n "$target" ] || continue
            count="$(sed -n "${line}p" "$CTX_TMP/material/$record" | awk '{ n=gsub(/]\(/,"&"); print n }')"
            if [ "$count" != 1 ]; then context_gap link "multiple/unsupported links at child line $line; select explicit context"; continue; fi
            anchor="$(sed -n "${line}p" "$CTX_TMP/material/$record" | sed -n 's/.*](.*#\([^ )]*\)).*/\1/p')"
            if [ -n "$anchor" ]; then context_select "$HEAD_SHA" "$target" "$anchor" link "child design/dependency/spec link"
            else context_gap link "explicit section needed for $target (child line $line); --context can supply a whole file"; fi
        done < <(spec_links "$CTX_TMP/material" "$record")
    fi
    if [ -f "$CTX_TMP/parent-ids" ]; then
        while IFS= read -r id; do context_id "$id" "selected parent obligation citation"; done \
            < <(LC_ALL=C sort -u "$CTX_TMP/parent-ids")
    fi
    # Changed canon: include complete changed sections; additions without supported headings
    # stay visible as gaps as well as in the unabridged diff.
    if ! git -C "$REPO_ROOT" diff --ignore-submodules=none -z --name-only --no-renames "$BASE_SHA" "$HEAD_SHA" > "$CTX_TMP/changed-paths"; then
        context_gap changed-spec "cannot completely enumerate changed canon"
    fi
    while IFS= read -r -d '' path; do
        case "$path" in specs/changes/*) continue ;; specs/*) ;; *) continue ;; esac
        if blob="$(context_object "$HEAD_SHA" "$path")"; then
            context_span "$HEAD_SHA" "$path" 1 all changed-spec "changed canon, unabridged"
        else context_gap changed-spec "deleted/unsafe changed canon $(printf '%q' "$path"); inspect full diff"; fi
    done < "$CTX_TMP/changed-paths"
    for path in ${CONTEXT[@]+"${CONTEXT[@]}"}; do
        blob="$(context_object "$HEAD_SHA" "$path")"
        count="$(awk 'END { print NR }' "$PACKAGE_DIR/context/$path")"; a=1
        [ "$count" != 0 ] || a=0
        printf 'context/%s\t%s\t%s\t%s\t%s\t%s\twhole-file\texplicit --context\n' \
            "$path" "$HEAD_SHA" "$path" "$blob" "$a" "$count" >> "$PACKAGE_DIR/context-manifest.tsv"
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
            bound-base|child-base)
                heading="$reason — BASE, binding for this review" ;;
            bound-proposed|child-proposed)
                heading="$reason — Proposed by this change — not yet an obligation; the reviewer must reconcile" ;;
            bound-removed|child-removed)
                heading="$reason — BASE, removed by this change — the reviewer must judge" ;;
            child-historical)
                heading='Historical child record — scope evidence only, not a substitute for BASE' ;;
            bound-shared|child-shared)
                heading="$reason — unchanged from BASE" ;;
            changed-spec|bound-context) continue ;; # Supporting excerpts retained for fallback.
            policy) ;;
            *)
                if [ "$rev" = "$HEAD_SHA" ] && [ "$blob" != "$(context_object "$BASE_SHA" "$path")" ]; then
                    heading='Changed HEAD context — proposed source, not a binding rule'
                fi ;;
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
    awk -F '\t' 'NR>1 && $1!="-" && !seen[$1]++' "$PACKAGE_DIR/context-manifest.tsv" \
        > "$PACKAGE_SCRATCH/obligation-spans"
    : > "$obligation_draft"
    if review_obligation_capture; then
        cat "$obligation_draft"
    else
        status=$?
        case "$status" in
            2) printf '**Required full context:** The captured obligations exceed the %s-byte inline cap.\n\n' "$obligation_cap" ;;
            3) printf '**Required full context:** A captured artifact cannot be included as inline text.\n\n' ;;
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
    fi
}
