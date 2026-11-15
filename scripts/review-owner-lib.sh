#!/usr/bin/env bash
# Native owner approval: GraphQL commit provenance plus an activity-log drift guard.
# Source after review-receipts-lib.sh. Online capture appends normalized O rows to RC_FILE;
# owner_native_approval_valid uses those rows and local Git only (also for snapshot previews).
# The caller owns the work directory and supplies RC_OWNERS / RC_PR_AUTHOR / RC_PR_HEAD.
# shellcheck disable=SC2034,SC2016 # Public outputs and literal jq variables.

review_owner_capture() { # receipt work directory; RC_FILE currently contains R/X rows
    local work="$1" repo ref review time state commit confirmed reason row
    # Owner identity is checked against the review author, never the installation viewer.
    if ! jq -r --arg owners "$RC_OWNERS" '.reviews | map(select(.author.__typename=="User" and
        (.state=="APPROVED" or .state=="CHANGES_REQUESTED" or .state=="DISMISSED"))) |
        map(. as $r | select(($owners|split("\n")|index("user:"+($r.author.databaseId|tostring))) != null)) |
        sort_by(.submittedAt,(.fullDatabaseId|tostring|length),(.fullDatabaseId|tostring))[] |
        [(.fullDatabaseId|tostring),.submittedAt,.state,(.commit.oid // "")]|join("\u001f")' \
        "$work/source-$RC_PR.json" > "$work/owners"; then RC_ERROR='could not read owner reviews'; return 1; fi
    if grep -q $'\037APPROVED\037' "$work/owners"; then
        if ! repo="$(jq -er '.head.repo.full_name' "$work/pr.json")" ||
            ! ref="$(jq -er '.head.ref | "refs/heads/"+. | @uri' "$work/pr.json")"; then
            RC_ERROR='missing head repository/ref for owner activity'; return 1
        fi
        if ! gh api --hostname github.com --paginate "repos/$repo/activity?ref=$ref&direction=asc" > "$work/activity-pages" 2>/dev/null ||
            ! jq -se 'length>0 and all(.[];type=="array" and all(.[];
                (.id|tostring|test("^[1-9][0-9]*$")) and (.timestamp|type)=="string" and
                (.timestamp|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
                (.activity_type|type)=="string" and (.before|test("^[0-9a-f]{40}$")) and (.after|test("^[0-9a-f]{40}$")))) and
                ([.[][]|.id|tostring] as $ids | ($ids|length)==($ids|unique|length))' "$work/activity-pages" >/dev/null 2>&1; then
            RC_ERROR='could not read the complete owner activity log'; return 1
        fi
        # Stable timestamp order preserves the API's ascending order for older same-second pushes.
        jq -s '[.[][]] | sort_by(.timestamp)' "$work/activity-pages" > "$work/activity.json" || return 1
    fi
    while IFS=$'\037' read -r review time state commit; do
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
        printf 'O\037%s\037%s\037%s\037%s\037%s\n' "$review" "$time" "$state" "$commit" "$confirmed" >> "$RC_FILE" || return 1
    done < "$work/owners"
}

owner_native_approval_valid() { # root checked-change trusted-base checked-head
    local root="$1" change="$2" base="$3" head="$4" row type review time state commit confirmed latest_time="" latest_id="" fp approved_fp entry
    OWNER_VALID=false; OWNER_APPROVED_COMMIT=""; OWNER_REVIEW=""; OWNER_STATE=""; OWNER_COMMIT=""; OWNER_HEAD_AT_SUBMISSION=""
    OWNER_ERROR="the owner has no decisive native review on this PR; approve natively on the PR"
    [ -n "${RC_FILE:-}" ] && [ -f "$RC_FILE" ] || return 1
    while IFS= read -r row; do
        IFS=$'\037' read -r type review time state commit confirmed <<< "$row"
        [ "$type" = O ] || continue
        if [ -z "$latest_time" ] || [[ "$time" > "$latest_time" ]] ||
            { [ "$time" = "$latest_time" ] && { [ "${#review}" -gt "${#latest_id}" ] || { [ "${#review}" -eq "${#latest_id}" ] && [[ "$review" > "$latest_id" ]]; }; }; }; then
            latest_time="$time"; latest_id="$review"
            OWNER_REVIEW="$review"; OWNER_STATE="$state"; OWNER_COMMIT="$commit"; OWNER_HEAD_AT_SUBMISSION="$confirmed"
        fi
    done < "$RC_FILE"
    [ -n "$OWNER_REVIEW" ] || return 1
    case "$OWNER_STATE" in
        CHANGES_REQUESTED) OWNER_ERROR='owner: changes requested, not PASS'; return 1 ;;
        DISMISSED) OWNER_ERROR='owner: the latest owner review was dismissed; approve again'; return 1 ;;
        APPROVED) ;; *) OWNER_ERROR='owner: unreadable native review state'; return 1 ;;
    esac
    while IFS= read -r entry; do
        if [ "$entry" = "user:${RC_PR_AUTHOR:-}" ]; then OWNER_ERROR='the owner authored this PR and cannot self-approve; T3 needs a PR opened by another account'; return 1; fi
    done <<< "${RC_OWNERS:-}"
    if ! [[ "$OWNER_HEAD_AT_SUBMISSION" =~ ^[0-9a-f]{40}$ ]] || [ "$OWNER_COMMIT" != "$OWNER_HEAD_AT_SUBMISSION" ]; then
        OWNER_ERROR="the owner's approval at ${OWNER_COMMIT:0:12} cannot be confirmed as the PR head at $latest_time; push a commit (a record-only commit is enough) and approve again"; return 1
    fi
    if ! spec_objects_local "$root" || ! GIT_NO_LAZY_FETCH=1 git -C "$root" cat-file -e "$OWNER_COMMIT^{commit}" 2>/dev/null; then
        OWNER_ERROR="the owner approved $OWNER_COMMIT, which is not here; git fetch origin $OWNER_COMMIT"; return 1
    fi
    if ! approved_fp="$(review_fingerprint "$root" "$change" "$base" "$OWNER_COMMIT" "${REVIEW_L01_PATHSPECS[@]}")" ||
        ! fp="$(review_fingerprint "$root" "$change" "$base" "$head" "${REVIEW_L01_PATHSPECS[@]}")"; then
        OWNER_ERROR="the owner's L0/L1 approval slice cannot be fingerprinted"; return 1
    fi
    [ "$approved_fp" = "$fp" ] || { OWNER_ERROR="the L0/L1 spec changed since the owner's native approval at ${OWNER_COMMIT:0:12}; approve again"; return 1; }
    OWNER_APPROVED_COMMIT="$OWNER_COMMIT"; OWNER_VALID=true; OWNER_ERROR=""
}

review_owner_json() {
    local field value sep=""
    printf '{'
    for field in review state commit head_at_submission; do
        case "$field" in review) value="${OWNER_REVIEW:-}" ;; state) value="${OWNER_STATE:-}" ;; commit) value="${OWNER_COMMIT:-}" ;; head_at_submission) value="${OWNER_HEAD_AT_SUBMISSION:-}" ;; esac
        printf '%s"%s":' "$sep" "$field"
        if [ -n "$value" ]; then printf '"%s"' "$(json_escape "$value")"; else printf null; fi
        sep=,
    done
    printf '}'
}
