#!/usr/bin/env bash
# review-coverage-lib.sh — check-review.sh's offline coverage engine. Source after common.sh,
# spec-lib.sh, review-policy-lib.sh and review-fingerprint-lib.sh; the caller supplies is_sha()
# and eligible() (which reads registry). Local Git and standard utilities only; no gh or jq.
#
# Interface (no arguments; all existing caller globals retain their scope):
# - review_coverage_evaluate: resolve content, build edges and evaluate each latest verdict.
# - review_coverage_require_start: enforce T1–T3 start coverage, after the caller's T0 checks.
# review_coverage_require_start requires a prior review_coverage_evaluate call, which defines
# the nested covered() and sets independent, owner and fp_ready.
# Inputs: verdict arrays v_rev, v_round, v_from, v_to, v_verdict, v_c, v_h, v_m and latest;
# context root, id, rigor, fp_base, head, start, record_only, tier, policy_at, base_ref,
# fp_cache, shallow_hint, registry, REVIEW_FP_EMPTY and REVIEW_L01_PATHSPECS. The caller also
# owns v_l, v_link, v_line and order; verdict arrays, rows and notes are not modified here.
# Outputs: append problems; set head_fp, head_l01, fp_ready, head_stream, head_l01_stream,
# independent and owner. content_of sets content_fp/content_stream/content_err and writes its
# fp_cache files; resolve_token sets tok_fp/tok_err/tok_commit. Fingerprint helpers also set
# REVIEW_FP_ERROR and REVIEW_MB. covered/leads_to use the global g_from/g_to edge arrays.
# Scratch globals, kept as in check-review.sh: l_idx, l_block, l_fromfp, l_tofp, l_fromc,
# l_toc, e_from, e_to, g_from, g_to, i, k, reviewer, x, block, what, resolved_by, m, j, n,
# where, from, to, verdict, label, kind, end, from_fp and later. Only the helpers' original
# local variables are local; coverage failures are appended to problems, not returned.
# shellcheck disable=SC2154 # Inputs are caller globals, documented above.

# The content a revision carries, as review-fingerprint-lib.sh computes it against fp_base: the
# whole change ("full") or its L0/L1 spec slice ("l01"). Cached per commit; sets content_fp and
# content_stream (a file), or content_err and returns 1.
content_of() { # commit full|l01
    local file="$fp_cache/$1.$2" digest
    content_fp=""; content_err=""; content_stream="$file.stream"
    if [ ! -f "$file.done" ]; then
        if [ "$2" = l01 ]; then
            review_delta_stream "$root" "$id" "$fp_base" "$1" "${REVIEW_L01_PATHSPECS[@]}" > "$file.stream" || content_err="$REVIEW_FP_ERROR"
        else
            review_delta_stream "$root" "$id" "$fp_base" "$1" > "$file.stream" || content_err="$REVIEW_FP_ERROR"
        fi
        if [ -z "$content_err" ]; then
            if digest="$(review_sha256 < "$file.stream")"; then printf 'fp1:%s\n' "$digest" > "$file.fp"
            else content_err="${REVIEW_FP_ERROR:-SHA-256 failed}"; fi
        fi
        printf '%s\n' "$content_err" > "$file.err"; : > "$file.done"
    fi
    content_err="$(cat "$file.err")"
    [ -z "$content_err" ] || return 1
    content_fp="$(cat "$file.fp")"
}
# A recorded range end: `start`, a content fingerprint, or (a line recorded before fingerprints)
# a commit hash present here, read as that commit's content, whether or not it is still in the
# head's history. Sets tok_fp, or tok_err and returns 1.
# With no content to compare (no trusted base, or the head cannot be fingerprinted) only the
# form and presence are checked, so the problems still name a missing commit (none = form only).
resolve_token() { # token full|l01|none
    tok_fp=""; tok_err=""; tok_commit=""
    if [ "$1" = start ]; then tok_fp="$REVIEW_FP_EMPTY"; return 0; fi
    if review_is_fp "$1"; then tok_fp="$1"; return 0; fi
    if ! is_sha "$1"; then
        tok_err="'$1' is not a content fingerprint (fp1:…) or a commit hash; record verdicts with record-review.sh, never a name that moves"; return 1
    fi
    if ! tok_commit="$(git -C "$root" rev-parse --verify --quiet "$1^{commit}")"; then
        tok_commit=""
        tok_err="commit $1 is not here: a range recorded before content fingerprints needs its commits; fetch them or record a new verdict with record-review.sh$shallow_hint"; return 1
    fi
    [ "$2" != none ] || return 0
    if ! content_of "$tok_commit" "$2"; then tok_err="the content of $1 cannot be read: $content_err"; return 1; fi
    tok_fp="$content_fp"
}
shown_fp() { # fingerprint -> its first 12 hex digits and an ellipsis
    local hex="${1#fp1:}"; printf '%s…' "${hex:0:12}"
}
# Whether the edges in g_from/g_to (parallel arrays of fingerprints) lead from $1 to $2.
leads_to() { # from to
    local reached used k grew=true r
    reached=("$1"); used=()
    [ "$1" != "$2" ] || return 0
    while $grew; do
        grew=false
        for k in ${g_from[@]+"${!g_from[@]}"}; do
            [ -z "${used[k]:-}" ] || continue
            for r in "${reached[@]}"; do
                if [ "${g_from[k]}" = "$r" ]; then
                    [ "${g_to[k]}" != "$2" ] || return 0
                    reached+=("${g_to[k]}"); used[k]=1; grew=true; break
                fi
            done
        done
    done
    return 1
}

review_coverage_evaluate() {
    # Content: the head's fingerprint against the trusted base (the check's --base, or for
    # diagnostics only, when that base is refused, the trusted default branch). Every recorded
    # range end resolves to a fingerprint; verdicts link fingerprints, never commits.
    head_fp=""; head_l01=""; fp_ready=false
    if ! $record_only && [ -n "$fp_base" ] && [ -n "$start" ]; then
        if content_of "$head" full; then
            head_fp="$content_fp"; head_stream="$content_stream"; fp_ready=true
        else
            problems+=("This head's content cannot be fingerprinted against ${fp_base#refs/remotes/}: $content_err; nothing can be covered")
        fi
    fi
    # Every non-owner PASS or FAIL line, in record order, with its ends resolved. A blocking line
    # (a FAIL, or counts that block for the Rigor or cannot be read) by reviewer R at content X
    # stands until a later clean PASS from R over a non-empty range whose start is `start` (a full
    # re-review) or is reachable from X through R's own lines recorded after the blocking one.
    # Only a line resolved through that reachability links: a full re-review of other content
    # clears the FAIL but never vouches for the step it failed. A standing line is a problem in
    # any tier and links nothing. Standing lines are evaluated in every mode, record-only
    # included: that mode exempts coverage, never an unresolved FAIL.
    l_idx=(); l_block=(); l_fromfp=(); l_tofp=(); l_fromc=(); l_toc=(); e_from=(); e_to=()
    if [ -n "$fp_base" ]; then
        for i in ${v_rev[@]+"${!v_rev[@]}"}; do
            [ "${v_rev[i]}" != owner ] || continue
            case "${v_verdict[i]}" in PASS|FAIL) ;; *) continue ;; esac
            block=false
            [ "${v_verdict[i]}" = PASS ] && [ "${v_c[i]}" = 0 ] && [ "${v_h[i]}" = 0 ] && { [ "$rigor" = light ] || [ "${v_m[i]}" = 0 ]; } || block=true
            l_idx+=("$i"); l_block+=("$block")
            if resolve_token "${v_from[i]}" full; then l_fromfp+=("$tok_fp"); else l_fromfp+=(""); fi
            l_fromc+=("$tok_commit")
            if resolve_token "${v_to[i]}" full; then l_tofp+=("$tok_fp"); else l_tofp+=(""); fi
            l_toc+=("$tok_commit")
        done
    fi
    for k in ${l_idx[@]+"${!l_idx[@]}"}; do
        i="${l_idx[k]}"; reviewer="${v_rev[i]}"; x="${l_tofp[k]}"
        if ${l_block[k]}; then
            what="its ${v_verdict[i]}"; [ "${v_verdict[i]}" = FAIL ] || what="its PASS with blocking findings"
            resolved_by=""; m=$((k + 1))
            while [ "$m" -lt "${#l_idx[@]}" ] && [ -z "$resolved_by" ]; do
                j="${l_idx[m]}"
                if [ "${v_rev[j]}" = "$reviewer" ] && ! ${l_block[m]} && [ -n "${l_fromfp[m]}" ] && [ -n "${l_tofp[m]}" ] &&
                    [ "${l_fromfp[m]}" != "${l_tofp[m]}" ] && eligible "$reviewer"; then
                    if [ -n "$x" ]; then
                        # R's own steps after the blocking line, any verdict: R inspected them.
                        g_from=(); g_to=(); n=$((k + 1))
                        while [ "$n" -lt "${#l_idx[@]}" ]; do
                            if [ "$n" != "$m" ] && [ "${v_rev[${l_idx[n]}]}" = "$reviewer" ] && [ -n "${l_fromfp[n]}" ] &&
                                [ -n "${l_tofp[n]}" ] && [ "${l_fromfp[n]}" != "${l_tofp[n]}" ]; then
                                g_from+=("${l_fromfp[n]}"); g_to+=("${l_tofp[n]}")
                            fi
                            n=$((n + 1))
                        done
                        if leads_to "$x" "${l_fromfp[m]}"; then resolved_by=reach
                        elif [ "${l_fromfp[m]}" = "$REVIEW_FP_EMPTY" ]; then resolved_by=start; fi
                    elif [ "${l_fromfp[m]}" = "$REVIEW_FP_EMPTY" ]; then
                        resolved_by=start
                    fi
                fi
                m=$((m + 1))
            done
            # A line recorded before fingerprints is also resolved by the rule it was written
            # under: a later clean PASS from the same eligible reviewer over a non-empty commit
            # range whose head descends from (or is) the blocking head. Once the branch is in the
            # base its commits all read as no change, so content alone could not resolve it. It
            # clears the line, never links it.
            if [ -z "$resolved_by" ] && [ -n "${l_toc[k]}" ] && eligible "$reviewer"; then
                m=$((k + 1))
                while [ "$m" -lt "${#l_idx[@]}" ] && [ -z "$resolved_by" ]; do
                    j="${l_idx[m]}"
                    if [ "${v_rev[j]}" = "$reviewer" ] && ! ${l_block[m]} && [ -n "${l_fromc[m]}" ] && [ -n "${l_toc[m]}" ] &&
                        [ "${l_fromc[m]}" != "${l_toc[m]}" ] && git -C "$root" merge-base --is-ancestor "${l_toc[k]}" "${l_toc[m]}"; then
                        resolved_by=legacy
                    fi
                    m=$((m + 1))
                done
            fi
            if [ -z "$resolved_by" ]; then
                if [ -n "$x" ]; then
                    where="${v_to[i]}"; review_is_fp "$where" && where="$(shown_fp "$where")"; is_sha "$where" && where="${where:0:12}"
                    problems+=("$reviewer (${v_round[i]}): $what at $where stands: no later clean PASS from $reviewer reaches that content")
                else
                    problems+=("$reviewer (${v_round[i]}): $what at '${v_to[i]}' stands: that names no content here, and no later clean PASS from $reviewer reviews the change from start")
                fi
                continue
            fi
            [ "$resolved_by" = reach ] || continue
        fi
        [ -n "${l_fromfp[k]}" ] && [ -n "$x" ] && [ "${l_fromfp[k]}" != "$x" ] || continue
        eligible "$reviewer" || continue
        e_from+=("${l_fromfp[k]}"); e_to+=("$x")
    done
    covered() { # fingerprint: edges lead from it to this head's content
        g_from=(${e_from[@]+"${e_from[@]}"}); g_to=(${e_to[@]+"${e_to[@]}"})
        leads_to "$1" "$head_fp"
    }

    # Verdicts and blocking counts, every tier; then each reviewer's content must be covered.
    independent=0; owner=false
    for i in ${latest[@]+"${latest[@]}"}; do
        reviewer="${v_rev[i]}"; from="${v_from[i]}"; to="${v_to[i]}"; verdict="${v_verdict[i]}"
        label="$reviewer (${v_round[i]})"
        [ "$verdict" = PASS ] || problems+=("$label: verdict ${verdict:-missing}, not PASS")
        if [ "$reviewer" = owner ]; then
            owner=true; ! $record_only || continue
            if ! $fp_ready; then resolve_token "$to" none || problems+=("$label: $tok_err"); continue; fi
            # The owner approves the L0/L1 spec: their verdict holds while that slice is unchanged.
            if [ -z "$head_l01" ]; then
                if content_of "$head" l01; then head_l01="$content_fp"; head_l01_stream="$content_stream"
                else problems+=("$label: this head's L0/L1 spec cannot be fingerprinted: $content_err"); continue; fi
            fi
            if ! resolve_token "$to" l01; then problems+=("$label: $tok_err"); continue; fi
            [ "$tok_fp" != "$head_l01" ] || continue
            if [ -n "$tok_commit" ]; then
                later="$(review_stream_paths "$fp_cache/$tok_commit.l01.stream" "$head_l01_stream" | tr '\n' ' ' | sed 's/ $//')"
                problems+=("$label: the L0/L1 spec changed since the owner's head $to: ${later:-its content differs}")
            else
                problems+=("$label: the L0/L1 spec changed since the owner's approval ($(shown_fp "$tok_fp"))")
            fi
            continue
        fi
        if eligible "$reviewer"; then independent=$((independent + 1)); fi
        for kind in critical high medium; do
            case "$kind" in critical) n="${v_c[i]}" ;; high) n="${v_h[i]}" ;; medium) n="${v_m[i]}" ;; esac
            [ "$kind" != medium ] || [ "$rigor" != light ] || continue
            [ "$n" = 0 ] && continue
            if [ "$rigor" = unknown ]; then
                problems+=("$label: $n $kind finding(s) block: the trusted base's constitution names no single Rigor (light or full), so medium blocks")
            else
                problems+=("$label: $n $kind finding(s) block under Rigor: $rigor")
            fi
        done
        ! $record_only || continue
        if ! $fp_ready; then
            for end in "$from" "$to"; do resolve_token "$end" none || problems+=("$label: $tok_err"); done
            continue
        fi
        from_fp=""
        if resolve_token "$from" full; then from_fp="$tok_fp"; else problems+=("$label: $tok_err"); fi
        if ! resolve_token "$to" full; then problems+=("$label: $tok_err"); continue; fi
        if [ "$from_fp" = "$tok_fp" ]; then problems+=("$label: the range $from..$to is empty"); continue; fi
        covered "$tok_fp" && continue
        if [ -n "$tok_commit" ]; then
            later="$(review_stream_paths "$fp_cache/$tok_commit.full.stream" "$head_stream" | tr '\n' ' ' | sed 's/ $//')"
            problems+=("$label: changed since the reviewed head $to: ${later:-its content differs}")
        else
            problems+=("$label: changed since the reviewed content $(shown_fp "$tok_fp"): no recorded verdict carries it to this head's content ($(shown_fp "$head_fp"))")
        fi
    done
}

review_coverage_require_start() {
    if [ -n "$tier" ] && [ "$tier" != T0 ] && ! $record_only; then
        [ "$independent" -gt 0 ] || problems+=("$tier needs a recorded independent review; none found in State")
        # Coverage closes each reviewer's end; the change's start must be covered the same way.
        if [ -z "$start" ]; then
            [ -z "$policy_at" ] || problems+=("$tier: $head shares no history with $base_ref, so the change's start cannot be found; fetch the branch history")
        elif [ "$start" = "$head" ]; then
            problems+=("$tier: $head is already in $base_ref; pass --base <the branch it merges into>")
        elif [ "$independent" -gt 0 ] && $fp_ready && ! covered "$REVIEW_FP_EMPTY"; then
            problems+=("$tier: the recorded ranges do not chain from the change's start ${start:0:12} (where it leaves $base_ref) to this head's content; review the whole change")
        fi
        [ "$tier" != T3 ] || $owner || problems+=("T3 needs the owner's verdict too (a **Review** line with reviewer owner)")
    fi
}
