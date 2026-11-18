#!/usr/bin/env bash
# Native owner approval: GraphQL commit provenance plus an activity-log drift guard.
# Source after review-receipts-lib.sh. Online capture appends normalized O rows to RC_FILE;
# owner_native_approval_valid evaluates per-actor barriers and positive approval using those rows
# and local Git only (also for snapshot previews). Barriers are independent of coverage/tier.
# The caller owns the work directory and supplies RC_OWNERS / RC_PR_AUTHOR / RC_PR_HEAD.
# shellcheck disable=SC2034,SC2016 # Public outputs and literal jq variables.

review_owner_capture() { # receipt work directory; RC_FILE currently contains R/X rows
    local work="$1" repo ref encoded_ref review time state commit confirmed actor
    # An unattributable/unknown event or duplicate id is unavailable authority, not no owner event.
    if ! jq -e '
        all(.reviews[];
            (.author|type)=="object" and (.author.__typename=="User" or .author.__typename=="Bot") and
            (.author.databaseId|type)=="number" and .author.databaseId>0 and
            (.author.databaseId|floor)==.author.databaseId and
            (.state=="APPROVED" or .state=="CHANGES_REQUESTED" or .state=="DISMISSED" or
             .state=="COMMENTED" or .state=="PENDING") and
            (.commit.oid==null or (.commit.oid|type=="string" and test("^[0-9a-f]{40}$")))) and
        ([.reviews[].fullDatabaseId|tostring] as $ids | ($ids|length)==($ids|unique|length))
        ' "$work/source-$RC_PR.json" >/dev/null 2>&1; then
        RC_ERROR='incomplete or ambiguous owner review authority'; return 1
    fi
    # Owner identity is checked against the review author, never the installation viewer.
    if ! jq -r --arg owners "$RC_OWNERS" '.reviews | map(select(.author.__typename=="User" and
        (.state=="APPROVED" or .state=="CHANGES_REQUESTED" or .state=="DISMISSED"))) |
        map(. as $r | select(($owners|split("\n")|index("user:"+($r.author.databaseId|tostring))) != null)) |
        sort_by(.submittedAt,(.fullDatabaseId|tostring|length),(.fullDatabaseId|tostring))[] |
        [(.fullDatabaseId|tostring),.submittedAt,.state,(.commit.oid // ""),
         ("user:"+(.author.databaseId|tostring))]|join("\u001f")' \
        "$work/source-$RC_PR.json" > "$work/owners"; then RC_ERROR='could not read owner reviews'; return 1; fi
    if grep -q $'\037APPROVED\037' "$work/owners"; then
        if ! repo="$(jq -er '.head.repo.full_name' "$work/pr.json")" ||
            ! ref="$(jq -er '.head.ref | "refs/heads/"+.' "$work/pr.json")"; then
            RC_ERROR='missing head repository/ref for owner activity'; return 1
        fi
        encoded_ref="$(printf '%s' "$ref" | jq -sRr @uri)" || return 1
        if ! gh api --hostname github.com --paginate "repos/$repo/activity?ref=$encoded_ref&direction=asc" > "$work/activity-pages" 2>/dev/null ||
            ! jq -se 'length>0 and all(.[];type=="array" and all(.[];
                (.id|tostring|test("^[1-9][0-9]*$")) and (.timestamp|type)=="string" and
                (.timestamp|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
                (.activity_type|type)=="string" and (.before|test("^[0-9a-f]{40}$")) and (.after|test("^[0-9a-f]{40}$")))) and
                ([.[][]|.id|tostring] as $ids | ($ids|length)==($ids|unique|length))' "$work/activity-pages" >/dev/null 2>&1; then
            RC_ERROR='could not read the complete owner activity log'; return 1
        fi
        # Stable timestamp order preserves the API's ascending order for older same-second pushes.
        jq -s --arg ref "$ref" '[.[][] | select(.ref==$ref)] | sort_by(.timestamp)' "$work/activity-pages" > "$work/activity.json" || return 1
    fi
    while IFS=$'\037' read -r review time state commit actor; do
        [ -n "$review" ] || continue
        confirmed='unconfirmed:not-approved'
        if [ "$state" = APPROVED ]; then
            confirmed="$(jq -r --arg time "$time" --arg head "$RC_PR_HEAD" '
                if any(.[];.timestamp==$time) then "unconfirmed:same-second"
                else ([.[]|select(.timestamp<$time)]|last) as $before |
                     ([.[]|select(.timestamp>$time)]|first) as $after |
                     if $before==null then "unconfirmed:no-earlier-entry"
                     elif (["push","force_push","branch_creation","pr_merge","merge_queue_merge"]|index($before.activity_type))==null then "unconfirmed:deleted-or-unknown"
                     elif $before.after=="0000000000000000000000000000000000000000" then "unconfirmed:deleted-head"
                     elif $after!=null and $after.before!=$before.after then "unconfirmed:continuity"
                     elif $after==null and $head!=$before.after then "unconfirmed:current-head-continuity"
                     else $before.after end end' "$work/activity.json")" || return 1
        fi
        printf 'O\037%s\037%s\037%s\037%s\037%s\037%s\n' "$review" "$time" "$state" "$commit" "$confirmed" "$actor" >> "$RC_FILE" || return 1
    done < "$work/owners"
}

_owner_approval_check() { # root change base head actor time commit confirmed -> OWNER_ROW_ERROR
    local root="$1" change="$2" base="$3" head="$4" actor="$5" time="$6" commit="$7" confirmed="$8" fp approved_fp
    OWNER_ROW_ERROR=""
    if [ "$actor" = "user:${RC_PR_AUTHOR:-}" ]; then
        OWNER_ROW_ERROR='the owner authored this PR and cannot self-approve; T3 needs a PR opened by another account'; return 1
    fi
    if ! [[ "$confirmed" =~ ^[0-9a-f]{40}$ ]] || [ "$commit" != "$confirmed" ]; then
        OWNER_ROW_ERROR="the owner's approval at ${commit:0:12} cannot be confirmed as the PR head at $time; push a commit (a record-only commit is enough) and approve again"; return 1
    fi
    if ! spec_objects_local "$root" || ! GIT_NO_LAZY_FETCH=1 git -C "$root" cat-file -e "$commit^{commit}" 2>/dev/null; then
        OWNER_ROW_ERROR="the owner approved $commit, which is not here; git fetch origin $commit"; return 1
    fi
    if ! approved_fp="$(review_fingerprint "$root" "$change" "$base" "$commit" "${REVIEW_L01_PATHSPECS[@]}")" ||
        ! fp="$(review_fingerprint "$root" "$change" "$base" "$head" "${REVIEW_L01_PATHSPECS[@]}")"; then
        OWNER_ROW_ERROR="the owner's L0/L1 approval slice cannot be fingerprinted"; return 1
    fi
    [ "$approved_fp" = "$fp" ] || { OWNER_ROW_ERROR="the L0/L1 spec changed since the owner's native approval at ${commit:0:12}; approve again"; return 1; }
}

owner_native_approval_valid() { # root checked-change trusted-base checked-head; once before exemptions
    local root="$1" change="$2" base="$3" head="$4" ordered row type review time state commit confirmed actor
    local order_time order_length order_id entry known k slot reason latest_valid=false latest_error=""
    local actors=() barriers=() reasons=() failures=()
    OWNER_VALID=false; OWNER_AVAILABLE=true; OWNER_APPROVED_COMMIT=""
    OWNER_REVIEW=""; OWNER_STATE=""; OWNER_COMMIT=""; OWNER_HEAD_AT_SUBMISSION=""; OWNER_ACTOR=""
    OWNER_PROBLEMS=(); OWNER_BARRIERS=()
    OWNER_ERROR="the owner has no decisive native review on this PR; approve natively on the PR"
    if [ -z "${RC_FILE:-}" ] || [ ! -f "$RC_FILE" ]; then
        OWNER_AVAILABLE=false; OWNER_ERROR='owner review authority is unavailable'; return 1
    fi
    # Scope processing sorts mixed rows by id. Restore timestamp/numeric-id order without jq
    # or floating-point conversion of host ids, including ids larger than the shell integer range.
    if ! ordered="$(set -o pipefail; LC_ALL=C awk -F '\037' '$1=="O" {
        print $3 "\037" length($2) "\037" $2 "\037" $0
        }' "$RC_FILE" | LC_ALL=C sort -t $'\037' -k1,1 -k2,2n -k3,3)"; then
        OWNER_AVAILABLE=false; OWNER_ERROR='owner review order is unavailable'; return 1
    fi
    while IFS=$'\037' read -r order_time order_length order_id row; do
        [ -n "$row" ] || continue
        IFS=$'\037' read -r type review time state commit confirmed actor <<< "$row"
        known=false
        while IFS= read -r entry; do [ "$entry" != "$actor" ] || known=true; done <<< "${RC_OWNERS:-}"
        if ! $known; then
            OWNER_AVAILABLE=false; OWNER_ERROR="owner review $review has no configured actor identity"; return 1
        fi
        OWNER_REVIEW="$review"; OWNER_STATE="$state"; OWNER_COMMIT="$commit"
        OWNER_HEAD_AT_SUBMISSION="$confirmed"; OWNER_ACTOR="$actor"; latest_valid=false
        slot="${#actors[@]}"
        for k in ${actors[@]+"${!actors[@]}"}; do [ "${actors[k]}" != "$actor" ] || slot="$k"; done
        if [ "$slot" -eq "${#actors[@]}" ]; then
            actors+=("$actor"); barriers+=(""); reasons+=(""); failures+=("")
        fi
        case "$state" in
            CHANGES_REQUESTED|DISMISSED)
                reason='owner: changes requested, not PASS'
                [ "$state" != DISMISSED ] || reason='owner: the latest owner review was dismissed; approve again'
                barriers[slot]="$actor"$'\037'"$review"$'\037'"$state"
                reasons[slot]="owner $actor review $review ($state): $reason"
                failures[slot]=""; latest_error="${reasons[slot]}" ;;
            APPROVED)
                if _owner_approval_check "$root" "$change" "$base" "$head" "$actor" "$time" "$commit" "$confirmed"; then
                    barriers[slot]=""; reasons[slot]=""; failures[slot]=""; latest_valid=true; latest_error=""
                else
                    latest_error="$OWNER_ROW_ERROR"
                    [ -z "${barriers[slot]}" ] || failures[slot]="; later review $review (APPROVED) cannot clear it: $OWNER_ROW_ERROR"
                fi ;;
            *) OWNER_AVAILABLE=false; OWNER_ERROR="owner review $review has an unreadable native state"; return 1 ;;
        esac
    done <<< "$ordered"
    for k in ${barriers[@]+"${!barriers[@]}"}; do
        [ -n "${barriers[k]}" ] || continue
        reason="${reasons[k]}${failures[k]}"
        OWNER_PROBLEMS+=("$reason"); OWNER_BARRIERS+=("${barriers[k]}"$'\037'"$reason")
    done
    if [ "${#OWNER_PROBLEMS[@]}" -gt 0 ]; then OWNER_ERROR="${OWNER_PROBLEMS[0]}"; return 1; fi
    [ -n "$OWNER_REVIEW" ] || return 1
    if ! $latest_valid; then OWNER_ERROR="$latest_error"; return 1; fi
    OWNER_APPROVED_COMMIT="$OWNER_COMMIT"; OWNER_VALID=true; OWNER_ERROR=""
}

review_owner_json() {
    local field value sep="" row actor review state reason
    printf '{'
    for field in review state commit head_at_submission actor; do
        case "$field" in review) value="${OWNER_REVIEW:-}" ;; state) value="${OWNER_STATE:-}" ;; commit) value="${OWNER_COMMIT:-}" ;; head_at_submission) value="${OWNER_HEAD_AT_SUBMISSION:-}" ;; actor) value="${OWNER_ACTOR:-}" ;; esac
        printf '%s"%s":' "$sep" "$field"
        if [ -n "$value" ]; then printf '"%s"' "$(json_escape "$value")"; else printf null; fi
        sep=,
    done
    printf ',"barriers":['; sep=""
    for row in ${OWNER_BARRIERS[@]+"${OWNER_BARRIERS[@]}"}; do
        IFS=$'\037' read -r actor review state reason <<< "$row"
        printf '%s{"actor":"%s","review":"%s","state":"%s","reason":"%s"}' "$sep" \
            "$(json_escape "$actor")" "$review" "$state" "$(json_escape "$reason")"
        sep=,
    done
    printf ']}'
}
