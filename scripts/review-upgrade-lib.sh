#!/usr/bin/env bash
# Read-only 2.0 installer preflight. Sourced by init.sh; no host writes.
# shellcheck disable=SC2034 # Installer and report outputs are shared across sourced files.
upgrade_source_2() {
    upgrade_version_2 "$PK_VERSION"
}

upgrade_version_2() {
    local major="${1%%.*}"
    case "$major" in ''|*[!0-9]*) return 1 ;; esac
    [ "$major" -ge 2 ]
}

upgrade_policy_context() {
    UP_REFS="$(spec_trusted_refs "$TARGET")"
    UP_DEFAULT="$(printf '%s\n' "$UP_REFS" | sed -n 1p)"
    UP_POLICY_AT=""
    if [ -n "$UP_DEFAULT" ]; then
        UP_POLICY_AT="$(git -C "$TARGET" rev-parse --verify "$UP_DEFAULT^{commit}")" || return 1
    fi
}

upgrade_rigor_diagnosis() {
    local root="$TARGET" lines entry
    UP_RIGOR=unknown
    if [ -n "$UP_POLICY_AT" ]; then UP_RIGOR="$(read_rigor "$UP_POLICY_AT")"; fi
    [ "$UP_RIGOR" = unknown ] || return 0
    lines='(none)'
    if [ -n "$UP_POLICY_AT" ]; then
        entry="$(git -C "$TARGET" ls-tree "$UP_POLICY_AT" -- .prdkit/memory/constitution.md)" || return 1
        if [ -n "$entry" ]; then
            lines="$(git -C "$TARGET" show "$UP_POLICY_AT:.prdkit/memory/constitution.md" | tr -d '\r' |
                awk '{ line=$0; if (sub(/^[-*[:space:]]*[Rr]igor\**:\**[[:space:]]*/, "", line)) print NR ": " $0 }')" || return 1
            [ -n "$lines" ] || lines='(none)'
        fi
    fi
    cat >&2 <<EOF
The default branch's constitution must hold exactly one Rigor line whose value is light or
full, followed by a space or the end of the line. Found:
$lines
(a colon after the value is not accepted). Write it as "- **Rigor**: full — medium blocks" and
merge that in its own PR first, then rerun.
EOF
    return 1
}

# Active State lines only, using the gate's parser, including its byte-safety check.
upgrade_record_lines() { # root rev output work
    local ll_root="$1" at="$2" output="$3" ll_work="$4" entry
    local LL_TREE LL_PATH LL_BLOB LL_LINES ll_awk_nul=false ll_error="$3.error"
    mkdir -p "$ll_work" || return 1
    if review_legacy_awk_preserves_nul "$ll_work"; then ll_awk_nul=true; fi
    _legacy_tree "$at" || return 1
    : > "$output" || return 1
    while IFS= read -r -d '' entry; do
        _legacy_record "$entry" || continue
        _legacy_lines "$LL_BLOB" "$LL_PATH" || return 1
        [ ! -s "$LL_LINES" ] || printf '%s\n' "$LL_PATH" >> "$output" || return 1
    done < "$LL_TREE"
}

upgrade_plain_guard() (
    local work
    work="$(mktemp -d)" || return 1
    trap 'rm -rf "$work"' EXIT
    [ -n "$UP_POLICY_AT" ] || { echo 'No trusted integration base: establish origin/HEAD with its history fetched.' >&2; return 1; }
    upgrade_record_lines "$TARGET" "$UP_POLICY_AT" "$work/trusted" "$work/a" || return 1
    # Include uncommitted checkout records as well as HEAD. P1 already requires them clean,
    # so HEAD is an exact, raw-object representation, not a diff-driver-dependent text read.
    upgrade_record_lines "$TARGET" HEAD "$work/checkout" "$work/b" || return 1
    if [ -s "$work/trusted" ] || [ -s "$work/checkout" ]; then
        cat "$work/trusted" "$work/checkout" | LC_ALL=C sort -u >&2
        echo '2.0 stops counting 1.x PASS verdicts and enforces 1.x FAILs through the gate; rerun with --migrate-reviews to see the report and upgrade' >&2
        return 1
    fi
)

upgrade_preflight() {
    local version entry
    version="$(install_manifest_value "$MANIFEST" version)" || { echo 'P1: target must hold a 1.x or 2.0 manifest; nothing was written.' >&2; return 1; }
    case "$version" in 1.*|2.0|2.0.*) ;; *) echo 'P1: target must hold a 1.x or 2.0 manifest; nothing was written.' >&2; return 1 ;; esac
    spec_objects_local "$TARGET" || return 1
    [ -n "$UP_POLICY_AT" ] || { echo 'No trusted integration base: establish origin/HEAD with its history fetched.' >&2; return 1; }
    upgrade_checkout_clean || return 1
    if $MIGRATE_REVIEWS; then
        if ! review_receipts_policy "$TARGET" "$UP_POLICY_AT"; then
            echo "P3: $RC_ERROR" >&2
            entry="$(git -C "$TARGET" ls-tree "$UP_POLICY_AT" -- .prdkit/memory/config.md)" || return 1
            if [ -n "$entry" ]; then
                git -C "$TARGET" show "$UP_POLICY_AT:.prdkit/memory/config.md" |
                    awk '/^- review-(host|publishers|owner|publisher-isolation):/ { print NR ": " $0 }' >&2 || return 1
            fi
            echo 'Merge all four well-formed receipt policy keys in their own PR first, then rerun.' >&2
            return 1
        fi
        if ! git -C "$TARGET" diff --quiet "$UP_POLICY_AT" HEAD -- specs/changes/; then
            echo 'P4: specs/changes/ must equal the trusted default branch tip; merge record changes separately first. Nothing was written.' >&2
            return 1
        fi
    fi
}

# Snapshot a HEAD entry without filters or git-show absence masking.
upgrade_head_file() { # relative path destination
    local entry mode blob
    entry="$(git -C "$TARGET" ls-tree HEAD -- ":(top,literal)$1")" || return 1
    [ -n "$entry" ] || return 0
    mode="${entry%% *}"; blob="${entry#* }"; blob="${blob%%$'\t'*}"; blob="${blob#* }"
    mkdir -p "$(dirname "$2")" || return 1
    case "$mode" in
        100644|100755)
            git -C "$TARGET" cat-file blob "$blob" > "$2" || return 1
            if [ "$mode" = 100755 ]; then chmod 755 "$2"; else chmod 644 "$2"; fi ;;
        120000) ln -s "$(git -C "$TARGET" cat-file blob "$blob")" "$2" || return 1 ;;
        *) return 1 ;;
    esac
}

upgrade_same_file() {
    if [ -L "$1" ] || [ -L "$2" ]; then
        [ -L "$1" ] && [ -L "$2" ] && [ "$(readlink "$1")" = "$(readlink "$2")" ]
    elif [ -f "$1" ] && [ -f "$2" ]; then
        { { [ -x "$1" ] && [ -x "$2" ]; } || { [ ! -x "$1" ] && [ ! -x "$2" ]; }; } && cmp -s "$1" "$2"
    else [ ! -e "$1" ] && [ ! -e "$2" ]; fi
}

upgrade_render_expected() { # caller-owned work directory -> head/, rendered/, paths (NUL)
    local work="$1" src rel entry rec cur kit ignore hash line dest trailing action
    mkdir -p "$work/head/.prdkit" "$work/rendered" || return 1
    upgrade_head_file .prdkit/.manifest "$work/head/.prdkit/.manifest" || return 1
    # The last committed manifest, never a dirty intermediate, is the ownership baseline.
    local MANIFEST="$work/head/.prdkit/.manifest"
    list_kit_files > "$work/files" || return 1
    : > "$work/paths" || return 1
    while IFS=$'\t' read -r src rel; do
        printf '%s\0' "$rel" >> "$work/paths" || return 1
        upgrade_head_file "$rel" "$work/head/$rel" || return 1
        dest="$work/rendered/$rel"
        mkdir -p "$(dirname "$dest")" || return 1
        case "$rel" in
            .claude/commands/*|.opencode/commands/*)
                if ! $MODE_COPY; then
                    case "$src" in "$TARGET"/*) entry="../../${src#"$TARGET"/}" ;; *) entry="$src" ;; esac
                    ln -s "$entry" "$dest" || return 1
                    continue
                fi ;;
            .prdkit/templates/*|.prdkit/memory/*)
                if [ -L "$work/head/$rel" ]; then cp -P "$work/head/$rel" "$dest"; continue; fi
                if [ -f "$work/head/$rel" ] && ! $FORCE; then
                    cur="$(hash_file "$work/head/$rel")"; rec="$(recorded_hash "$rel")"
                    kit="$(hash_file "$src")"
                    if [ "$cur" != "$rec" ] && [ "$cur" != "$kit" ]; then cp -p "$work/head/$rel" "$dest"; continue; fi
                fi ;;
        esac
        if [ -f "$work/head/$rel" ] && { [[ "$rel" = .prdkit/templates/* ]] || [[ "$rel" = .prdkit/memory/* ]]; }; then
            cp -p "$work/head/$rel" "$dest" || return 1
        fi
        cp "$src" "$dest" || return 1
        case "$rel" in .prdkit/scripts/bash/*) chmod +x "$dest" || return 1 ;; esac
    done < "$work/files"
    # Every retired recorded path is part of the planned deletion set, even after a retry
    # already deleted it. Project-owned customized retired conffiles remain untouched.
    if [ -f "$MANIFEST" ]; then
        while IFS= read -r line; do
            rel="${line#*  }"
            [[ "$rel" =~ $KIT_FILE_RE || "$rel" =~ $INSTALLED_RE ]] || continue
            awk -F '\t' -v p="$rel" '$2==p { found=1 } END { exit !found }' "$work/files" && continue
            case "$rel" in .prdkit/memory/*) case " $RETIRED_MEMORY " in *" ${rel##*/} "*) ;; *) continue ;; esac ;; esac
            upgrade_head_file "$rel" "$work/head/$rel" || return 1
            case "$rel" in .prdkit/templates/*|.prdkit/memory/*)
                if [ -L "$work/head/$rel" ] || { [ -f "$work/head/$rel" ] && [ "$(hash_file "$work/head/$rel")" != "${line%%  *}" ]; }; then continue; fi ;;
            esac
            printf '%s\0' "$rel" >> "$work/paths" || return 1
        done < "$MANIFEST"
    fi
    while IFS=$'\t' read -r rel action; do
        [ "$action" = remove ] || continue
        printf '%s\0' "$rel" >> "$work/paths" || return 1
        if [ ! -e "$work/head/$rel" ] && [ ! -L "$work/head/$rel" ]; then
            upgrade_head_file "$rel" "$work/head/$rel" || return 1
        fi
    done < <(list_retired_commands; list_retired_kit_files)
    for rel in AGENTS.md .gitignore; do
        [ "$rel" != AGENTS.md ] || has_harness agents || continue
        if dest="$(root_file_path "$rel")"; then dest="${dest#"$TARGET"/}"; else continue; fi
        printf '%s\0' "$dest" >> "$work/paths" || return 1
        upgrade_head_file "$dest" "$work/head/$dest" || return 1
        mkdir -p "$(dirname "$work/rendered/$dest")" || return 1
        if [ -f "$work/head/$dest" ]; then cp -p "$work/head/$dest" "$work/rendered/$dest"; else : > "$work/rendered/$dest"; fi
        if [ "$rel" = AGENTS.md ]; then
            render_agents_section > "$work/section" || return 1
            if grep -qF "$AGENTS_BEGIN" "$work/rendered/$dest"; then
                managed_agents_section "$work/rendered/$dest" >/dev/null || return 1
                awk -v b="$AGENTS_BEGIN" -v e="$AGENTS_END" -v f="$work/section" '
                    $0==b { while((getline l < f)>0) print l; skip=1; next }
                    $0==e { skip=0; next } !skip { print }' "$work/rendered/$dest" > "$work/next" || return 1
                cat "$work/next" > "$work/rendered/$dest" || return 1
            elif [ -f "$work/head/$dest" ]; then
                trailing="$(tail -c 1 "$work/rendered/$dest")"
                { [ -z "$trailing" ] || echo; echo; cat "$work/section"; } >> "$work/rendered/$dest" || return 1
            else cat "$work/section" > "$work/rendered/$dest" || return 1; fi
        else
            for ignore in $IGNORE_ENTRIES; do
                if ! grep -qxF "$ignore" "$work/rendered/$dest"; then
                    trailing="$(tail -c 1 "$work/rendered/$dest")"
                    { [ -z "$trailing" ] || echo; echo "$ignore"; } >> "$work/rendered/$dest" || return 1
                fi
            done
        fi
    done
    printf '.prdkit/.manifest\0' >> "$work/paths" || return 1
    {
        printf 'version: %s\nharnesses: %s\nmode: %s\noptions: %s\n' "$PK_VERSION" "$HARNESSES" "$($MODE_COPY && echo copy || echo symlink)" "${OPTIONS:-none}"
        if has_harness agents; then printf 'agents-section: %s\n' "$(render_agents_section | install_hash_stream)"; fi
        while IFS=$'\t' read -r src rel; do
            dest="$work/rendered/$rel"
            [ -e "$dest" ] || continue
            cur="$(hash_file "$dest")"; kit="$(hash_file "$src")"
            hash="$kit"
            if [ "$cur" != "$kit" ]; then rec="$(recorded_hash "$rel")"; hash="${rec:-$kit}"; fi
            printf '%s  %s\n' "$hash" "$rel"
        done < "$work/files"
    } > "$work/rendered/.prdkit/.manifest"
    printf '.prdkit/.manifest.tmp\0' >> "$work/paths" || return 1
    upgrade_head_file .prdkit/.manifest.tmp "$work/head/.prdkit/.manifest.tmp" || return 1
    cp "$work/rendered/.prdkit/.manifest" "$work/rendered/.prdkit/.manifest.tmp"
}

upgrade_checkout_clean() (
    local status version work rel allowed
    status="$(git -C "$TARGET" status --porcelain --untracked-files=all)" || return 1
    [ -n "$status" ] || return 0
    version="$(install_manifest_value "$PRDKIT_DIR/.install-state" source-version 2>/dev/null)" || version=""
    if [ "$version" != "$PK_VERSION" ] || ! git -C "$TARGET" diff --cached --quiet HEAD --; then
        echo 'P1: checkout must be clean (staged, unstaged and untracked files included); nothing was written.' >&2; return 1
    fi
    work="$(mktemp -d)" || return 1
    trap 'rm -rf "$work"' EXIT
    upgrade_render_expected "$work" || return 1
    git -C "$TARGET" ls-files --modified --deleted --others --exclude-standard -z > "$work/dirty" || return 1
    while IFS= read -r -d '' rel; do
        case "$rel" in specs/changes/*) allowed=false ;; *) allowed=true ;; esac
        $allowed || { echo "P1: records must always be clean: $rel" >&2; return 1; }
        allowed=false
        while IFS= read -r -d '' version; do [ "$rel" != "$version" ] || allowed=true; done < "$work/paths"
        if ! $allowed; then
            echo "P1: not a validated installer-owned intermediate state: $rel; nothing was written." >&2; return 1
        fi
        if ! upgrade_same_file "$TARGET/$rel" "$work/head/$rel" && ! upgrade_same_file "$TARGET/$rel" "$work/rendered/$rel"; then
            echo "P1: not a validated intermediate state (bytes, type or mode): $rel; nothing was written." >&2; return 1
        fi
    done < "$work/dirty"
)

# Inspect the entire planned overwrite/delete set, including ignored files. Git cleanliness
# alone is not ownership: a committed customization is still the project's work.
upgrade_no_overwrite() (
    local work rel src dest rec cur section expected problem=false
    work="$(mktemp -d)" || return 1
    trap 'rm -rf "$work"' EXIT
    upgrade_render_expected "$work" || return 1
    while IFS= read -r -d '' rel; do
        dest="$TARGET/$rel"
        { [ -e "$dest" ] || [ -L "$dest" ]; } || continue
        src="$(awk -F '\t' -v p="$rel" '$2==p { print $1 }' "$work/files")"
        case "$rel" in .prdkit/.manifest) continue ;; esac
        if [ -z "$src" ] && { [ "$dest" = "$(root_file_path AGENTS.md 2>/dev/null)" ] || [ "$dest" = "$(root_file_path .gitignore 2>/dev/null)" ]; }; then
            # Root files are edited in place, not replaced as kit-owned documents. Only
            # the managed block is overwritten; the ignore operation only appends entries.
            if has_harness agents && [ "$dest" = "$(root_file_path AGENTS.md 2>/dev/null)" ] && grep -qF "$AGENTS_BEGIN" "$dest"; then
                section="$(managed_agents_section "$dest")" || { echo "Customized managed section: $rel" >&2; problem=true; continue; }
                cur="$(printf '%s\n' "$section" | install_hash_stream)"
                rec="$(install_manifest_value "$MANIFEST" agents-section 2>/dev/null)" || rec=""
                expected="$(render_agents_section | install_hash_stream)"
                if [ "$cur" != "$rec" ] && [ "$cur" != "$expected" ]; then
                    echo "Customized managed section: $rel" >&2; problem=true
                fi
            fi
            continue
        fi
        if upgrade_same_file "$dest" "$work/rendered/$rel"; then continue; fi
        case "$rel" in .prdkit/templates/*|.prdkit/memory/*)
            # Non-forced conffiles with custom bytes are preserved by install_conffile.
            if ! $FORCE && [ -n "$src" ]; then continue; fi ;;
        esac
        rec="$(recorded_hash "$rel")"
        if [ -L "$dest" ]; then
            case "$rel" in .claude/commands/*|.opencode/commands/*)
                if is_kit_command_link "$dest"; then continue; fi ;;
            esac
        elif [ -f "$dest" ] && [ -n "$rec" ]; then
            cur="$(hash_file "$dest")" || return 1
            if [ "$cur" = "$rec" ]; then
                if [ -z "$src" ] || { { [ -x "$dest" ] && [ -x "$work/rendered/$rel" ]; } ||
                    { [ ! -x "$dest" ] && [ ! -x "$work/rendered/$rel" ]; }; }; then continue; fi
            fi
        fi
        echo "Customized overwrite/delete destination: $rel" >&2
        problem=true
    done < "$work/paths"
    if $problem; then
        echo 'Refusing to overwrite or delete customized content; nothing was written. Reconcile these files before upgrading.' >&2
        return 1
    fi
)

upgrade_inventory_json() { # inventory rows -> JSON array, presentation only
    jq -Rn '[inputs | split("\u001f") | {id:.[0],change:.[1],path:.[2],line:(.[3]|tonumber),reviewer:.[4],verdict:.[5],reason:.[6]}]' < "$1"
}

upgrade_blockers_json() { # collect rows inventory-json -> JSON with optional raw line location
    jq -Rn --slurpfile inventory "$2" '[inputs | split("\u001f") |
        {id:.[0],change:.[1],reviewer:.[2],reason:.[3]} |
        . as $b | ([$inventory[0][] | select(.id==$b.id)][0] // {}) as $location |
        . + {path:($location.path // ("specs/changes/"+.change+".md")),line:($location.line // null)}]' < "$1"
}

upgrade_host_repo() {
    local url
    url="$(git -C "$TARGET" config --get remote.origin.url)" || return 1
    case "$url" in
        https://github.com/*) url="${url#https://github.com/}" ;;
        git@github.com:*) url="${url#git@github.com:}" ;;
        ssh://git@github.com/*) url="${url#ssh://git@github.com/}" ;;
        *) return 1 ;;
    esac
    url="${url%.git}"
    [[ "$url" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || return 1
    printf '%s\n' "$url"
}

upgrade_transition_report() (
    local work change path repo pr head base checked ref canonical available note
    command -v jq >/dev/null 2>&1 || { echo 'The 2.0 transition report requires jq; nothing was written.' >&2; return 1; }
    work="$(mktemp -d)" || return 1
    trap 'rm -rf "$work"' EXIT
    review_legacy_inventory "$TARGET" "$UP_POLICY_AT" "$UP_RIGOR" "$work/cache" "$work/inventory" || return 1
    upgrade_inventory_json "$work/inventory" > "$work/inventory.json" || return 1
    : > "$work/records.jsonl"; : > "$work/prs.jsonl"; : > "$work/notes.jsonl"
    jq -r '.[].change' "$work/inventory.json" | LC_ALL=C sort -u > "$work/changes" || return 1
    while IFS= read -r change; do
        path="specs/changes/$change.md"
        review_legacy_collect "$TARGET" "$change" "$UP_POLICY_AT" "$UP_POLICY_AT" "$UP_RIGOR" "$work/cache" "$work/blockers" || return 1
        upgrade_blockers_json "$work/blockers" "$work/inventory.json" > "$work/blockers.json" || return 1
        jq -cn --arg change "$change" --arg path "$path" --slurpfile blockers "$work/blockers.json" --slurpfile inventory "$work/inventory.json" '
            {change:$change,path:$path,legacy_blockers:$blockers[0],
             pass_lines:([$inventory[0][] | select(.change==$change and .verdict=="PASS")]|length)}' >> "$work/records.jsonl" || return 1
    done < "$work/changes"
    note=''
    if ! command -v gh >/dev/null 2>&1; then note='Could not list open PRs: gh is missing; default-branch report is complete.'
    elif ! repo="$(upgrade_host_repo)"; then note='Could not list open PRs: origin is not a GitHub repository URL.'
    elif ! gh api --method GET "repos/$repo/pulls?state=open&per_page=100" --paginate > "$work/open-pages" 2>/dev/null; then
        note='Could not list open PRs: the host API is unavailable; the upgrade can proceed.'
    elif ! jq -se 'length>0 and all(.[]; type=="array" and all(.[];
        (.number|type)=="number" and (.head.sha|type)=="string" and (.head.sha|test("^[0-9a-f]{40}$")) and
        (.head.ref|type)=="string" and (.base.ref|type)=="string"))' "$work/open-pages" >/dev/null; then
        note='Could not list open PRs: the host returned incomplete or malformed pages.'
    else
        jq -sc 'add | unique_by(.number)[]' "$work/open-pages" > "$work/open.jsonl" || return 1
        while IFS= read -r pr; do
            head="$(printf '%s' "$pr" | jq -r .head.sha)"; base="$(printf '%s' "$pr" | jq -r .base.ref)"
            canonical=''
            while IFS= read -r ref; do
                checked="${ref#refs/remotes/}"; checked="${checked#*/}"
                if [ "$checked" = "$base" ]; then canonical="$ref"; break; fi
            done <<< "$UP_REFS"
            [ -n "$canonical" ] || continue
            checked="$(printf '%s' "$pr" | jq -r .head.ref)"
            is_change_id "$checked" || checked=''
            available=true
            if ! review_legacy_inventory "$TARGET" "$head" "$UP_RIGOR" "$work/cache" "$work/pr-inventory" 2>/dev/null ||
                ! review_legacy_collect "$TARGET" "$checked" "$canonical" "$head" "$UP_RIGOR" "$work/cache" "$work/pr-blockers" 2>/dev/null; then available=false; fi
            if $available; then
                upgrade_inventory_json "$work/pr-inventory" > "$work/pr-inventory.json" || return 1
                upgrade_blockers_json "$work/pr-blockers" "$work/pr-inventory.json" > "$work/pr-blockers.json" || return 1
            else printf '[]\n' > "$work/pr-inventory.json"; printf '[]\n' > "$work/pr-blockers.json"; fi
            printf '%s' "$pr" | jq -c --argjson available "$available" --arg checked "$checked" \
                --slurpfile inventory "$work/pr-inventory.json" --slurpfile blockers "$work/pr-blockers.json" '
                {number,url:(.html_url // ""),head:.head.sha,base:.base.ref,checked_change:$checked,scan_available:$available,
                 legacy_blockers:$blockers[0],reviews_owed:([$inventory[0][]|select(.verdict=="PASS")|.reviewer] + [$blockers[0][].reviewer] | unique),
                 note:(if $available then "" else "Legacy scan unavailable: fetch this PR head and its complete history locally, then rerun; no network fetch was attempted." end)}' \
                >> "$work/prs.jsonl" || return 1
        done < "$work/open.jsonl"
    fi
    [ -z "$note" ] || jq -cn --arg note "$note" '$note' >> "$work/notes.jsonl"
    jq -n --arg policy_at "$UP_POLICY_AT" --slurpfile records "$work/records.jsonl" \
        --slurpfile prs "$work/prs.jsonl" --slurpfile notes "$work/notes.jsonl" '
        {schema:"prdkit.review-transition.v1",policy_at:$policy_at,records:$records,open_prs:$prs,notes:$notes,
         totals:{records_with_blockers:([$records[]|select(.legacy_blockers|length>0)]|length),
                 blockers_per_reviewer:([$records[].legacy_blockers[]]|group_by(.reviewer)|map({key:.[0].reviewer,value:length})|from_entries),
                 open_prs:($prs|length),reviews_owed:([$prs[].reviews_owed[]]|length)}}' > "$work/report.json" || return 1
    if $JSON; then cat "$work/report.json"
    else
        jq -r '"2.0 review transition (trusted tip " + .policy_at + ")",
          "1.x PASS verdicts stop counting; no verdict is converted or published.",
          (.records[] | "Record " + .path + ": " + (.pass_lines|tostring) + " PASS line(s) stop counting",
            (.legacy_blockers[] | "  " + .reviewer + " at line " + (.line|tostring) + ": " + .reason)),
          (.open_prs[] | ("Open PR #" + (.number|tostring) + ": " + (.reviews_owed|join(", ")) + " need fresh 2.0 reviews"),
            (.legacy_blockers[] | "  " + .change + ": " + .reviewer + ": " + .reason), (if .note!="" then .note else empty end)),
          (.notes[]),
          ("Totals: " + (.totals.records_with_blockers|tostring) + " records with blockers; " +
            (.totals.open_prs|tostring) + " open PRs; " + (.totals.reviews_owed|tostring) + " reviews owed"),
          (.totals.blockers_per_reviewer | to_entries[] | "  " + .key + ": " + (.value|tostring) + " default-branch blocker(s)")' "$work/report.json"
    fi
)
