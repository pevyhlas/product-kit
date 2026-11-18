#!/usr/bin/env bash
# Blocker-only 1.x history scan (design §4.1). Source after spec-lib.sh and
# review-fingerprint-lib.sh. No verdict from this library is a coverage edge.
# review_legacy_collect ROOT CHANGE BASE HEAD RIGOR WORK OUTPUT writes US-separated
# id/change/reviewer/reason rows plus OUTPUT.paths (id/path presentation metadata),
# or fails without publishing a partial result. Optional argument 8 selects a full
# checked-record path for inventory callers; gate callers retain the change-id API.
# WORK is a caller-owned cache, shared by the current and clearance-head scans.
# All history/tree/blob reads are plumbing, with replacements and lazy fetch disabled.
# shellcheck disable=SC2034,SC2030,SC2031 # Shared outputs; each public scan intentionally confines its Git environment.

review_legacy_awk_preserves_nul() { # caller-owned work directory; one probe per collect
    local expected actual
    printf 'left\000right' > "$1/awk-nul-input" || return 1
    LC_ALL=C awk 'BEGIN { printf "%d", length(sprintf("%c",0)) }' > "$1/awk-nul-length" || return 1
    LC_ALL=C awk '{ printf "%s", $0 }' "$1/awk-nul-input" > "$1/awk-nul-output" || return 1
    [ "$(cat "$1/awk-nul-length")" = 1 ] || return 1
    # Compare the complete byte streams through the same byte-preserving SHA-256 tool
    # used for identities; neither NUL-bearing stream enters a shell variable.
    expected="$(review_sha256 < "$1/awk-nul-input")" || return 1
    actual="$(review_sha256 < "$1/awk-nul-output")" || return 1
    [ "$expected" = "$actual" ]
}

_legacy_nul_error() { # collect output basename; propagate a subshell's specific failure
    [ -f "$1.error" ] || return 0
    LL_NUL_UNAVAILABLE=true
    LL_NUL_ERROR="$(cat "$1.error")"
}

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
_legacy_entry() { # commit literal-path -> LL_ENTRY, empty for an absent path
    LL_ENTRY=""
    git -C "$ll_root" ls-tree -z "$1" -- ":(top,literal)$2" > "$ll_work/entry" || return 1
    IFS= read -r -d '' LL_ENTRY < "$ll_work/entry" || true
}
_legacy_lines() { # blob path -> LL_LINES: active line text, never truncated NUL-bearing records
    local status
    LL_LINES="$ll_work/lines-$1"
    if [ ! -f "$LL_LINES" ] || { ! $ll_awk_nul && [ ! -f "$ll_work/nul-free-$1" ]; }; then
        git -C "$ll_root" cat-file blob "$1" > "$ll_work/blob" || return 1
        if ! $ll_awk_nul; then
            if review_file_without_nul "$ll_work/blob"; then : > "$ll_work/nul-free-$1" || return 1
            else
                status=$?; [ "$status" -eq 1 ] || return 1
                printf 'legacy scan unavailable: %s: awk cannot read NUL bytes; run the gate with an awk that preserves them (for example gawk)\n' "$2" > "$ll_error" || return 1
                cat "$ll_error" >&2
                return 1
            fi
        fi
        if [ ! -f "$LL_LINES" ]; then
            LC_ALL=C awk -v numbers="$LL_LINES.numbers.next" "$SPEC_SKIP_AWK"'
            { original=$0; gsub(/[\035-\037]/, " "); if (spec_skip($0)) next }
            /^## / { sec=$0; sub(/^##[[:space:]]+/, "", sec); next }
            sec=="State" && /^\*\*Review\*\*:/ { print original; print NR > numbers }
            ' "$ll_work/blob" > "$LL_LINES.next" || return 1
            # An empty record has no number rows, but still gets a complete sidecar.
            [ -f "$LL_LINES.numbers.next" ] || : > "$LL_LINES.numbers.next"
            mv "$LL_LINES.numbers.next" "$LL_LINES.numbers" || return 1
            mv "$LL_LINES.next" "$LL_LINES" || return 1
        fi
    fi
}
review_legacy_classify() { # active-lines-file rigor -> active index / reviewer / verdict / reason
    LC_ALL=C awk -v rigor="$2" '
        BEGIN { nul=sprintf("%c",0) }
        function trim(s) { gsub(/`/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        function count(s,k, v) { if (!match(s,"[0-9]+ " k)) return "?"; v=substr(s,RSTART,RLENGTH); sub(/ .*/,"",v); return v }
        { gsub(/[\035-\037]/, " "); sub(/^\*\*Review\*\*:[[:space:]]*/, ""); n=split($0,f," · ")
          r=n>=3 ? tolower(trim(f[3])) : ""; if (r=="" || (nul!="" && index(r,nul))) r="(unnamed)"
          verdict=toupper(trim(f[4])); c=count(f[5],"critical"); h=count(f[5],"high"); m=count(f[5],"medium"); l=count(f[5],"low")
           reason=""
           if (r=="owner") { if (verdict!="PASS") reason="owner legacy verdict is not a readable PASS" }
          else if (verdict=="FAIL") reason="legacy FAIL"
          else if (verdict!="PASS") reason="unreadable legacy verdict"
          else if (c=="?" || h=="?" || m=="?" || l=="?") reason="unreadable legacy counts"
          else if (c!="0" || h!="0" || (rigor!="light" && m!="0")) reason="legacy counts block under Rigor " rigor
           print NR "\037" r "\037" verdict "\037" reason }
    ' "$1"
}

_legacy_identity() { # change lines-file active-index -> full digest, byte preserving
    { printf 'prdkit-legacy\000%s\000' "$1"
        LC_ALL=C awk -v number="$3" 'NR==number { printf "%s", $0; exit }' "$2"
    } | review_sha256
}

_legacy_emit() { # path lines-file -> append blockers; range/link/fingerprint fields are never read
    local change="${1##*/}" display_change display_path number reviewer verdict reason digest
    change="${change%.md}"
    review_legacy_classify "$2" "$ll_rigor" > "$ll_work/classified" || return 1
    while IFS=$'\037' read -r number reviewer verdict reason; do
        [ -n "$reason" ] || continue
        digest="$(_legacy_identity "$change" "$2" "$number")" || return 1
        # Presentation fields use the gate's row delimiter; identity always hashes the original bytes.
        display_change="$(printf '%s' "$change" | tr '\035-\037\n\r' ' ')" || return 1
        display_path="$(printf '%s' "$1" | tr '\035-\037\n\r' ' ')" || return 1
        printf '%s\037%s\037%s\037%s\n' "${digest:0:32}" "$display_change" "$reviewer" "$reason" >> "$ll_rows" || return 1
        printf '%s\037%s\n' "${digest:0:32}" "$display_path" >> "$ll_locations" || return 1
    done < "$ll_work/classified"
}

# Presentation adapter for the installer and diagnostics. The gate's same parser,
# classifier and identity function supply raw-blob line numbers and ignored PASS metadata.
# This grants no verdict; review_legacy_collect remains the blocker authority.
review_legacy_inventory() ( # root at rigor work output
    local ll_root="$1" at="$2" rigor="$3" ll_work="$4" output="$5" entry number reviewer verdict reason digest change line
    local LL_TREE LL_PATH LL_BLOB LL_LINES ll_awk_nul=false ll_error="$5.error"
    export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1
    set -o pipefail
    spec_objects_local "$ll_root" || return 1
    mkdir -p "$ll_work" || return 1
    if review_legacy_awk_preserves_nul "$ll_work"; then ll_awk_nul=true; fi
    _legacy_tree "$at" || return 1
    : > "$output.next" || return 1
    while IFS= read -r -d '' entry; do
        _legacy_record "$entry" || continue
        _legacy_lines "$LL_BLOB" "$LL_PATH" || return 1
        review_legacy_classify "$LL_LINES" "$rigor" > "$ll_work/inventory-classified" || return 1
        change="${LL_PATH##*/}"; change="${change%.md}"
        while IFS=$'\037' read -r number reviewer verdict reason; do
            digest="$(_legacy_identity "$change" "$LL_LINES" "$number")" || return 1
            line="$(awk -v n="$number" 'NR==n { print; exit }' "$LL_LINES.numbers")" || return 1
            printf '%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n' \
                "${digest:0:32}" "$change" "$LL_PATH" "$line" "$reviewer" "$verdict" "$reason" "$number" >> "$output.next" || return 1
        done < "$ll_work/inventory-classified"
    done < "$LL_TREE"
    mv "$output.next" "$output"
)

review_legacy_collect() ( # subshell contains Git environment and scratch outputs
    local ll_root="$1" checked="$2" base="$3" head="$4" ll_rigor="$5" ll_work="$6" output="$7"
    local checked_path="${8:-specs/changes/$2.md}"
    local start entry record_path blob parent fork commit parents bases status start_tree tree fork_tree unchanged
    local parent_blobs=()
    local LL_TREE LL_ENTRY LL_PATH LL_BLOB LL_LINES ll_rows ll_locations
    local ll_awk_nul=false ll_error="$output.error"
    export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1
    set -o pipefail
    spec_objects_local "$ll_root" || return 1
    # A shallow boundary hides parents and their lines even if merge-base happens to succeed.
    [ "$(git -C "$ll_root" rev-parse --is-shallow-repository)" = false ] || return 1
    mkdir -p "$ll_work" || return 1
    rm -f "$ll_error" || return 1
    if review_legacy_awk_preserves_nul "$ll_work"; then ll_awk_nul=true; fi
    ll_rows="$(mktemp "$ll_work/rows.XXXXXX")" || return 1
    ll_locations="$ll_rows.paths"; : > "$ll_locations" || return 1
    start="$(review_merge_base "$ll_root" "$base" "$head")" || return 1
    _legacy_tree "$start" || return 1; start_tree="$LL_TREE"
    # (1) Checked record, and (2) inherited records not kept identical by path/mode/blob.
    while IFS= read -r -d '' entry; do
        _legacy_record "$entry" || continue
        record_path="$LL_PATH"; blob="$LL_BLOB"
        _legacy_entry "$head" "$record_path" || return 1
        if [ "$record_path" = "$checked_path" ] || [ "$entry" != "$LL_ENTRY" ]; then
            _legacy_lines "$blob" "$record_path" && _legacy_emit "$record_path" "$LL_LINES" || return 1
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
                _legacy_lines "$LL_BLOB" "$LL_PATH" && cat "$LL_LINES" >> "$ll_work/fork-lines" || return 1
            done < "$fork_tree"
        done
        _legacy_tree "$commit" || return 1; tree="$LL_TREE"
        while IFS= read -r -d '' entry; do
            _legacy_record "$entry" || continue
            record_path="$LL_PATH"; blob="$LL_BLOB"
            parent_blobs=(); unchanged=false
            for parent in $parents; do
                _legacy_entry "$parent" "$record_path" || return 1
                if _legacy_record "$LL_ENTRY"; then
                    if [ "$LL_BLOB" = "$blob" ]; then unchanged=true; break; fi
                    parent_blobs+=("$LL_BLOB")
                fi
            done
            # An identical eligible record in any parent contains every parsed line already.
            $unchanged && continue
            cat "$ll_work/fork-lines" > "$ll_work/excluded" || return 1
            for parent in ${parent_blobs[@]+"${parent_blobs[@]}"}; do
                _legacy_lines "$parent" "$record_path" && cat "$LL_LINES" >> "$ll_work/excluded" || return 1
            done
            _legacy_lines "$blob" "$record_path" || return 1
            LC_ALL=C awk 'FILENAME==ARGV[1] { seen[$0]=1; next } !($0 in seen)' \
                "$ll_work/excluded" "$LL_LINES" > "$ll_work/introduced" || return 1
            _legacy_emit "$record_path" "$ll_work/introduced" || return 1
        done < "$tree"
    done < "$ll_work/commits"
    LC_ALL=C awk '!seen[$0]++' "$ll_locations" > "$output.paths.next" &&
        LC_ALL=C awk -F '\037' '!seen[$1]++' "$ll_rows" > "$output.next" &&
        mv "$output.paths.next" "$output.paths" && mv "$output.next" "$output"
)

_legacy_evidence() { # root change base head rigor work -> LL_EVIDENCE (complete scan only)
    local key
    key="$(printf '%s\000%s\000%s' "$2" "$3" "$4" | review_sha256)" || return 1
    LL_EVIDENCE="$6/evidence-$key"
    if [ -f "$LL_EVIDENCE.unavailable" ]; then _legacy_nul_error "$LL_EVIDENCE"; return 1; fi
    if [ ! -f "$LL_EVIDENCE" ]; then
        if ! review_legacy_collect "$1" "$2" "$3" "$4" "$5" "$6/cache" "$LL_EVIDENCE" 2>/dev/null; then
            _legacy_nul_error "$LL_EVIDENCE"
            : > "$LL_EVIDENCE.unavailable"
            return 1
        fi
    fi
}

review_legacy_resolve() { # root checked base head rigor registry work scoped-receipts-or-empty pr
    local root="$1" checked="$2" base="$3" head="$4" rigor="$5" registry="$6" work="$7" receipts="$8" pr="$9"
    local identity change reviewer reason cleared current row evidence current_fp="" empty_ok
    local type seq origin review time receipt_id rchange rreviewer from to rhead since rbase base_at verdict c h m l report carried
    local LL_EVIDENCE owner_valid=false
    LL_BLOCKERS=(); LL_PROBLEMS=(); LL_EMPTY_VALID=(); LL_EMPTY_ALLOWED=()
    LL_NUL_UNAVAILABLE=false; LL_NUL_ERROR=""
    mkdir -p "$work" || { LL_PROBLEMS+=('legacy scan: cannot allocate history evidence'); return 1; }
    current="$work/current"
    if ! review_legacy_collect "$root" "$checked" "$base" "$head" "$rigor" "$work/cache" "$current" 2>/dev/null; then
        _legacy_nul_error "$current"
        if $LL_NUL_UNAVAILABLE; then LL_PROBLEMS+=("$LL_NUL_ERROR")
        else LL_PROBLEMS+=('legacy scan: cannot read the complete local history, trees and record blobs; fetch the full history and objects before checking'); fi
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
            # The caller evaluated native owner state once, before any exemption. Legacy
            # clearance additionally proves historical inclusion; it is not barrier clearance.
            if [ -n "$receipts" ] && ${OWNER_VALID:-false} &&
                [ -n "${OWNER_APPROVED_COMMIT:-}" ]; then owner_valid=true; fi
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
    if $LL_NUL_UNAVAILABLE; then LL_PROBLEMS=("$LL_NUL_ERROR"); return 1; fi
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

# Read-only diagnostics for remaining 1.x debt. Both the checkout commit and the
# trusted default tip are inspected; no host access or jq is required.
review_legacy_record_findings() (
    local root="$1" work at refs default rigor=unknown change record_path identity reviewer reason ignored policy
    export GIT_NO_LAZY_FETCH=1 GIT_NO_REPLACE_OBJECTS=1
    if ! spec_objects_local "$root"; then
        echo 'Legacy 1.x scan unavailable: this Git cannot refuse missing-object fetches in a partial clone'; return 1
    fi
    work="$(mktemp -d)" || { echo 'Legacy 1.x scan unavailable: cannot allocate scratch storage'; return 1; }
    trap 'rm -rf "$work"' EXIT
    set -o pipefail
    refs="$(spec_trusted_refs "$root")" || return 1
    default="$(printf '%s\n' "$refs" | sed -n 1p)"
    if [ -n "$default" ]; then
        for policy in config.md constitution.md; do
            if ! git -C "$root" show "$default:.prdkit/memory/$policy" > "$work/policy" 2>/dev/null; then
                echo "Legacy 1.x scan unavailable: trusted .prdkit/memory/$policy is not completely available locally"; return 1
            fi
        done
        rigor="$(read_rigor "$default")"
    fi
    { git -C "$root" rev-parse --verify HEAD; [ -z "$default" ] || git -C "$root" rev-parse --verify "$default"; } > "$work/refs" || return 1
    LC_ALL=C sort -u "$work/refs" > "$work/tips" || return 1
    : > "$work/findings" || return 1
    while IFS= read -r at; do
        if ! review_legacy_inventory "$root" "$at" "$rigor" "$work/cache" "$work/inventory"; then
            echo 'Legacy 1.x scan unavailable: fetch the complete local history and record blobs before checking'; return 1
        fi
        awk -F '\037' 'NF { print $3 }' "$work/inventory" | LC_ALL=C sort -u > "$work/paths" || return 1
        while IFS= read -r record_path; do
            change="${record_path##*/}"; change="${change%.md}"
            if ! review_legacy_collect "$root" "$change" "$at" "$at" "$rigor" "$work/cache" "$work/blockers" "$record_path"; then
                echo 'Legacy 1.x scan unavailable: fetch the complete local history and record blobs before checking'; return 1
            fi
            while IFS=$'\037' read -r identity ignored reviewer reason; do
                printf 'Legacy 1.x blocking lines: %s (%s: %s)\n' "$record_path" "$reviewer" "$reason" >> "$work/findings" || return 1
            done < "$work/blockers"
        done < "$work/paths"
    done < "$work/tips"
    LC_ALL=C sort -u "$work/findings"
)
