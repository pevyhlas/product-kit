#!/usr/bin/env bash
# Opt-in GitHub report consistency check. Core review checking remains offline Bash/Git.
# Matching report contents does not authenticate an independent reviewer session.
# shellcheck disable=SC2034 # RR_ERROR/RR_STATE are consumed by the caller
review_reports_context() { # PR URL exact local head; sets RR_REPO/RR_NUMBER/RR_ERROR/RR_STATE
    local url="$1" head="$2" response
    local pr_re='^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)$'
    RR_ERROR=""; RR_STATE=failed
    if ! [[ "$url" =~ $pr_re ]]; then RR_ERROR='--pr must be a github.com pull request URL'; return 1; fi
    RR_REPO="${BASH_REMATCH[1]}"; RR_NUMBER="${BASH_REMATCH[2]}"
    if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        RR_STATE=unavailable; RR_ERROR='report verification needs gh and jq; links remain unverified'; return 1
    fi
    if ! response="$(gh api --hostname github.com "repos/$RR_REPO/pulls/$RR_NUMBER" 2>/dev/null)"; then
        RR_STATE=unavailable; RR_ERROR='could not read the PR (offline, unauthorized or unavailable); links remain unverified'; return 1
    fi
    if ! jq -e --arg head "$head" '.head.sha == $head' >/dev/null 2>&1 <<< "$response"; then
        RR_ERROR='PR head does not match the exact head being checked'; return 1
    fi
    RR_STATE=matched
}

# The one prdkit-review receipt in the linked comment on this PR; sets RR_RECEIPT, or RR_ERROR/RR_STATE.
_review_report_receipt() { # link
    local link="$1"
    local link_re='^https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)/pull/([1-9][0-9]*)#issuecomment-([1-9][0-9]*)$'
    local repo number comment response body
    RR_ERROR=""; RR_STATE=failed; RR_RECEIPT=""
    if ! [[ "$link" =~ $link_re ]]; then RR_ERROR='report link must name an issuecomment on this GitHub PR'; return 1; fi
    repo="${BASH_REMATCH[1]}"; number="${BASH_REMATCH[2]}"; comment="${BASH_REMATCH[3]}"
    if [ "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" != "$(printf '%s' "$RR_REPO" | tr '[:upper:]' '[:lower:]')" ] || [ "$number" != "$RR_NUMBER" ]; then
        RR_ERROR='report link names a different repository or PR'; return 1
    fi
    if ! response="$(gh api --hostname github.com "repos/$RR_REPO/issues/comments/$comment" 2>/dev/null)"; then
        RR_STATE=unavailable; RR_ERROR='could not read the linked report; it remains unverified'; return 1
    fi
    if ! jq -e --arg issue "https://api.github.com/repos/$RR_REPO/issues/$RR_NUMBER" \
        '(.issue_url | ascii_downcase) == ($issue | ascii_downcase)' >/dev/null 2>&1 <<< "$response"; then
        RR_ERROR='linked comment does not belong to this PR'; return 1
    fi
    body="$(jq -er '.body | strings' <<< "$response" 2>/dev/null)" || { RR_ERROR='linked report has no readable body'; return 1; }
    RR_RECEIPT="$(printf '%s\n' "$body" | awk '
        /^<!-- prdkit-review$/ { n++; inside = 1; next }
        inside && /^-->$/ { inside = 0; closed++; next }
        inside { text = text $0 "\n" }
        END { if (n == 1 && closed == 1 && !inside) printf "%s", text }')"
}

# A line recorded before content fingerprints: a v1 receipt with both commits' full hashes.
review_report_match() { # link reviewer full-base full-head verdict critical high medium low
    local reviewer="$2" base="$3" head="$4" verdict="$5" critical="$6" high="$7" medium="$8" low="$9"
    _review_report_receipt "$1" || return 1
    if ! jq -se --arg reviewer "$reviewer" --arg base "$base" --arg head "$head" --arg verdict "$verdict" \
        --arg c "$critical" --arg h "$high" --arg m "$medium" --arg l "$low" '
        length == 1 and (.[0] | .schema == "prdkit.review.v1" and .reviewer == $reviewer and .base == $base and .head == $head and .verdict == $verdict
        and ($reviewer == "owner" or (.critical == ($c|tonumber) and .high == ($h|tonumber) and .medium == ($m|tonumber) and .low == ($l|tonumber))))
        ' >/dev/null 2>&1 <<< "$RR_RECEIPT"; then
        RR_ERROR='report receipt is absent, ambiguous or disagrees with the recorded reviewer, range, verdict or counts'; return 1
    fi
    RR_STATE=matched
}

# A fingerprint line: a v2 receipt (record-review.sh prints it) whose from and to are exactly the
# recorded ends; its head, if any, is provenance and not compared.
review_report_match_v2() { # link reviewer from to verdict critical high medium low
    local reviewer="$2" from="$3" to="$4" verdict="$5" critical="$6" high="$7" medium="$8" low="$9"
    _review_report_receipt "$1" || return 1
    if ! jq -se --arg reviewer "$reviewer" --arg from "$from" --arg to "$to" --arg verdict "$verdict" \
        --arg c "$critical" --arg h "$high" --arg m "$medium" --arg l "$low" '
        length == 1 and (.[0] | .schema == "prdkit.review.v2" and .reviewer == $reviewer and .from == $from and .to == $to and .verdict == $verdict
        and ($reviewer == "owner" or (.critical == ($c|tonumber) and .high == ($h|tonumber) and .medium == ($m|tonumber) and .low == ($l|tonumber))))
        ' >/dev/null 2>&1 <<< "$RR_RECEIPT"; then
        RR_ERROR='report receipt is absent, ambiguous or disagrees with the recorded reviewer, range, verdict or counts'; return 1
    fi
    RR_STATE=matched
}
