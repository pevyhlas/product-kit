#!/usr/bin/env bash
# Blocker-only 1.x history scan (design §4.1). Source after spec-lib.sh and
# review-fingerprint-lib.sh. No verdict from this library is a coverage edge.
# review_legacy_collect ROOT CHANGE BASE HEAD RIGOR WORK OUTPUT writes US-separated
# id/change/reviewer/reason rows, or fails without publishing a partial result.
# WORK is a caller-owned cache, shared by the current and clearance-head scans.
# All history/tree/blob reads are plumbing, with replacements and lazy fetch disabled.
# shellcheck disable=SC2034 # Cache outputs and normalized receipt fields cross interfaces.

_legacy_tree() { # commit -> LL_TREE (raw NUL-delimited ls-tree entries)
    LL_TREE="$ll_work/tree-$1"
    if [ ! -f "$LL_TREE" ]; then
        git -C "$ll_root" ls-tree -r -z "$1" > "$LL_TREE.next" || return 1
        mv "$LL_TREE.next" "$LL_TREE" || return 1
    fi
}
_legacy_record() { # ls-tree entry -> LL_PATH / LL_BLOB; accepts executable regular files too
    local meta="${1%%$'\t'*}"
    LL_PATH="${1#*$'\t'}"; LL_BLOB="${meta##* }"
    case "$meta" in '100644 blob '*|'100755 blob '*) ;; *) return 1 ;; esac
    case "$LL_PATH" in specs/changes/*.md) return 0 ;; *) return 1 ;; esac
}
_legacy_entry() { # tree-file path -> LL_ENTRY, empty for an absent path
    local entry
    LL_ENTRY=""
    while IFS= read -r -d '' entry; do
        if [ "${entry#*$'\t'}" = "$2" ]; then LL_ENTRY="$entry"; break; fi
    done < "$1"
}
_legacy_lines() { # blob -> LL_LINES: active line text, never raw-text matching across sections
    LL_LINES="$ll_work/lines-$1"
    if [ ! -f "$LL_LINES" ]; then
        git -C "$ll_root" cat-file blob "$1" > "$ll_work/blob" || return 1
        LC_ALL=C awk "$SPEC_SKIP_AWK"'
            { original=$0; gsub(/[\035-\037]/, " "); if (spec_skip($0)) next }
            /^## / { sec=$0; sub(/^##[[:space:]]+/, "", sec); next }
            sec=="State" && /^\*\*Review\*\*:/ { print original }
        ' "$ll_work/blob" > "$LL_LINES.next" || return 1
        mv "$LL_LINES.next" "$LL_LINES" || return 1
    fi
}
_legacy_emit() { # path lines-file -> append blockers; range/link/fingerprint fields are never read
    local change="${1##*/}" display_change number reviewer reason digest
    change="${change%.md}"
    LC_ALL=C awk -v rigor="$ll_rigor" '
        BEGIN { nul=sprintf("%c",0) }
        function trim(s) { gsub(/`/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        function count(s,k, v) { if (!match(s,"[0-9]+ " k)) return "?"; v=substr(s,RSTART,RLENGTH); sub(/ .*/,"",v); return v }
        { gsub(/[\035-\037]/, " "); sub(/^\*\*Review\*\*:[[:space:]]*/, ""); n=split($0,f," · ")
          r=n>=3 ? tolower(trim(f[3])) : ""; if (r=="" || (nul!="" && index(r,nul))) r="(unnamed)"
          verdict=toupper(trim(f[4])); c=count(f[5],"critical"); h=count(f[5],"high"); m=count(f[5],"medium"); l=count(f[5],"low")
          if (r=="owner") { if (verdict=="PASS") next; reason="owner legacy verdict is not a readable PASS" }
          else if (verdict=="FAIL") reason="legacy FAIL"
          else if (verdict!="PASS") reason="unreadable legacy verdict"
          else if (c=="?" || h=="?" || m=="?" || l=="?") reason="unreadable legacy counts"
          else if (c!="0" || h!="0" || (rigor!="light" && m!="0")) reason="legacy counts block under Rigor " rigor
          else next
          print NR "\037" r "\037" reason }
    ' "$2" > "$ll_work/classified" || return 1
    while IFS=$'\037' read -r number reviewer reason; do
        # Keep line bytes out of shell variables (which cannot hold NUL). Hash the
        # original active line, without its newline, even in a binary-marked blob.
        digest="$( { printf 'prdkit-legacy\000%s\000' "$change"
            LC_ALL=C awk -v number="$number" 'NR==number { printf "%s", $0; exit }' "$2"
        } | review_sha256)" || return 1
        # Presentation fields use the gate's row delimiter; identity always hashes the original bytes.
        display_change="$(printf '%s' "$change" | tr '\035-\037\n\r' ' ')" || return 1
        printf '%s\037%s\037%s\037%s\n' "${digest:0:32}" "$display_change" "$reviewer" "$reason" >> "$ll_rows" || return 1
    done < "$ll_work/classified"
}

review_legacy_collect() ( # subshell contains Git environment and scratch outputs
    local ll_root="$1" checked="$2" base="$3" head="$4" ll_rigor="$5" ll_work="$6" output="$7"
    local start entry record_path blob parent fork commit parents bases status start_tree head_tree tree parent_tree fork_tree
    local LL_TREE LL_ENTRY LL_PATH LL_BLOB LL_LINES ll_rows
    export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1
    set -o pipefail
    spec_objects_local "$ll_root" || return 1
    # A shallow boundary hides parents and their lines even if merge-base happens to succeed.
    [ "$(git -C "$ll_root" rev-parse --is-shallow-repository)" = false ] || return 1
    mkdir -p "$ll_work" || return 1
    ll_rows="$(mktemp "$ll_work/rows.XXXXXX")" || return 1
    start="$(review_merge_base "$ll_root" "$base" "$head")" || return 1
    _legacy_tree "$start" || return 1; start_tree="$LL_TREE"
    _legacy_tree "$head" || return 1; head_tree="$LL_TREE"
    # (1) Checked record, and (2) inherited records not kept identical by path/mode/blob.
    while IFS= read -r -d '' entry; do
        _legacy_record "$entry" || continue
        record_path="$LL_PATH"; blob="$LL_BLOB"
        _legacy_entry "$head_tree" "$record_path"
        if [ "$record_path" = "specs/changes/$checked.md" ] || [ "$entry" != "$LL_ENTRY" ]; then
            _legacy_lines "$blob" && _legacy_emit "$record_path" "$LL_LINES" || return 1
        fi
    done < "$start_tree"
    # (3) No pathspec: branch-side parents dropped by a merge resolution remain in the walk.
    git -C "$ll_root" rev-list "$start..$head" > "$ll_work/commits" || return 1
    while IFS= read -r commit; do
        parents="$(git -C "$ll_root" rev-list --parents -n 1 "$commit")" || return 1
        parents="${parents#"$commit"}"
        if bases="$(git -C "$ll_root" merge-base --all "$commit" "$start")"; then :
        else status=$?; [ "$status" -eq 1 ] && [ -z "$bases" ] || return 1; fi
        : > "$ll_work/fork-lines" || return 1
        for fork in $bases; do
            _legacy_tree "$fork" || return 1; fork_tree="$LL_TREE"
            while IFS= read -r -d '' entry; do
                _legacy_record "$entry" || continue
                _legacy_lines "$LL_BLOB" && cat "$LL_LINES" >> "$ll_work/fork-lines" || return 1
            done < "$fork_tree"
        done
        _legacy_tree "$commit" || return 1; tree="$LL_TREE"
        while IFS= read -r -d '' entry; do
            _legacy_record "$entry" || continue
            record_path="$LL_PATH"; blob="$LL_BLOB"
            cat "$ll_work/fork-lines" > "$ll_work/excluded" || return 1
            for parent in $parents; do
                _legacy_tree "$parent" || return 1; parent_tree="$LL_TREE"
                _legacy_entry "$parent_tree" "$record_path"
                if _legacy_record "$LL_ENTRY"; then
                    _legacy_lines "$LL_BLOB" && cat "$LL_LINES" >> "$ll_work/excluded" || return 1
                fi
            done
            _legacy_lines "$blob" || return 1
            LC_ALL=C awk 'FILENAME==ARGV[1] { seen[$0]=1; next } !($0 in seen)' \
                "$ll_work/excluded" "$LL_LINES" > "$ll_work/introduced" || return 1
            _legacy_emit "$record_path" "$ll_work/introduced" || return 1
        done < "$tree"
    done < "$ll_work/commits"
    LC_ALL=C awk -F '\037' '!seen[$1]++' "$ll_rows" > "$output.next" && mv "$output.next" "$output"
)

_legacy_evidence() { # root change base head rigor work -> LL_EVIDENCE (complete scan only)
    local key
    key="$(printf '%s\000%s\000%s' "$2" "$3" "$4" | review_sha256)" || return 1
    LL_EVIDENCE="$6/evidence-$key"
    [ ! -f "$LL_EVIDENCE.unavailable" ] || return 1
    if [ ! -f "$LL_EVIDENCE" ]; then
        if ! review_legacy_collect "$1" "$2" "$3" "$4" "$5" "$6/cache" "$LL_EVIDENCE" 2>/dev/null; then
            : > "$LL_EVIDENCE.unavailable"
            return 1
        fi
    fi
}

review_legacy_resolve() { # root checked base head rigor registry work scoped-receipts-or-empty pr
    local root="$1" checked="$2" base="$3" head="$4" rigor="$5" registry="$6" work="$7" receipts="$8" pr="$9"
    local identity change reviewer reason cleared current row evidence current_fp="" empty_ok
    local type seq origin review time receipt_id rchange rreviewer from to rhead since rbase base_at verdict c h m l report carried
    local LL_EVIDENCE OWNER_APPROVED_COMMIT="" owner_checked=false owner_valid=false
    LL_BLOCKERS=(); LL_PROBLEMS=(); LL_EMPTY_VALID=(); LL_EMPTY_ALLOWED=()
    mkdir -p "$work" || { LL_PROBLEMS+=('legacy scan: cannot allocate history evidence'); return 1; }
    current="$work/current"
    if ! review_legacy_collect "$root" "$checked" "$base" "$head" "$rigor" "$work/cache" "$current" 2>/dev/null; then
        LL_PROBLEMS+=('legacy scan: cannot read the complete local history, trees and record blobs; fetch the full history and objects before checking')
        return 1
    fi
    # Validate the empty full PASS exception at its own reviewed head. LL_EMPTY_VALID
    # retains those start-to-start verdicts for the ordinary latest-covered rule;
    # they add no coverage edge. LL_EMPTY_ALLOWED separately enables their legacy
    # clearance only while the currently checked change still has empty content.
    if [ -n "$receipts" ]; then
        while IFS=$'\037' read -r type seq origin review time receipt_id rchange rreviewer from to rhead since rbase base_at verdict c h m l report carried; do
            [ "$type" = R ] && [ "$origin" = "$pr" ] && [ "$to" = "$REVIEW_FP_EMPTY" ] || continue
            _receipts_blocking "$verdict" "$c" "$h" "$m" "$rigor" && continue
            empty_ok=false
            if [ "$from" = start ] && [ "$(review_eligibility "$registry" "$rreviewer")" = reviewer ]; then
                if _legacy_evidence "$root" "$rchange" "$base_at" "$rhead" "$rigor" "$work"; then
                    while IFS=$'\037' read -r identity change reviewer reason; do
                        if [ "$reviewer" = "$rreviewer" ] && { [ "$change" = "$rchange" ] || [ "$rchange" = "$checked" ]; }; then empty_ok=true; break; fi
                    done < "$LL_EVIDENCE"
                fi
            fi
            if $empty_ok; then
                LL_EMPTY_VALID+=("$seq")
                if [ -z "$current_fp" ]; then current_fp="$(review_fingerprint "$root" "$checked" "$base" "$head")" || current_fp=unavailable; fi
                [ "$current_fp" != "$REVIEW_FP_EMPTY" ] || LL_EMPTY_ALLOWED+=("$seq")
            else LL_PROBLEMS+=("receipt review $review: empty-content clearance requires a full PASS for this reviewer's legacy blocker, with available reviewed history at its empty head"); fi
        done < "$receipts"
    fi
    while IFS=$'\037' read -r identity change reviewer reason; do
        cleared=false
        if [ "$reviewer" = owner ] || [ "$reviewer" = '(unnamed)' ]; then
            if ! $owner_checked; then
                owner_checked=true
                if [ -n "$receipts" ] && owner_native_approval_valid "$root" "$checked" "$base" "$head" &&
                    [ -n "$OWNER_APPROVED_COMMIT" ]; then owner_valid=true; fi
            fi
            if $owner_valid && _legacy_evidence "$root" "$checked" "$base" "$OWNER_APPROVED_COMMIT" "$rigor" "$work" &&
                awk -F '\037' -v id="$identity" '$1==id { found=1 } END { exit !found }' "$LL_EVIDENCE"; then cleared=true; fi
        elif [ -n "$receipts" ] && [ "$(review_eligibility "$registry" "$reviewer")" = reviewer ]; then
            while IFS= read -r row; do
                IFS=$'\037' read -r type seq origin review time receipt_id rchange rreviewer from to rhead since rbase base_at verdict c h m l report carried <<< "$row"
                [ "$type" = R ] && [ "$origin" = "$pr" ] && [ "$rreviewer" = "$reviewer" ] && [ "$from" = start ] || continue
                { [ "$rchange" = "$change" ] || [ "$rchange" = "$checked" ]; } || continue
                _receipts_blocking "$verdict" "$c" "$h" "$m" "$rigor" && continue
                if [ "$to" = "$REVIEW_FP_EMPTY" ]; then
                    empty_ok=false
                    for evidence in ${LL_EMPTY_ALLOWED[@]+"${LL_EMPTY_ALLOWED[@]}"}; do [ "$seq" != "$evidence" ] || empty_ok=true; done
                    $empty_ok || continue
                fi
                # An authenticated token may cover after its head vanished, but it
                # cannot establish which legacy history that review included.
                if _legacy_evidence "$root" "$rchange" "$base_at" "$rhead" "$rigor" "$work" &&
                    awk -F '\037' -v id="$identity" '$1==id { found=1 } END { exit !found }' "$LL_EVIDENCE"; then cleared=true; break; fi
            done < "$receipts"
        fi
        LL_BLOCKERS+=("$identity"$'\037'"$change"$'\037'"$reviewer"$'\037'"$reason"$'\037'"$cleared")
        if ! $cleared; then
            if [ "$reviewer" = owner ] || [ "$reviewer" = '(unnamed)' ]; then
                LL_PROBLEMS+=("legacy blocker $identity ($change, $reviewer): $reason; stands until valid native owner approval whose reviewed history includes it")
            else
                LL_PROBLEMS+=("legacy blocker $identity ($change, $reviewer): $reason; stands until a clean native full PASS from $reviewer on this PR whose reviewed history includes it")
            fi
        fi
    done < "$current"
}

review_legacy_json() {
    local row identity change reviewer reason cleared sep=""
    printf '['
    for row in ${LL_BLOCKERS[@]+"${LL_BLOCKERS[@]}"}; do
        IFS=$'\037' read -r identity change reviewer reason cleared <<< "$row"
        printf '%s{"id":"%s","change":"%s","reviewer":"%s","reason":"%s","cleared":%s}' "$sep" \
            "$identity" "$(json_escape "$change")" "$(json_escape "$reviewer")" "$(json_escape "$reason")" "$cleared"
        sep=,
    done
    printf ']'
}
