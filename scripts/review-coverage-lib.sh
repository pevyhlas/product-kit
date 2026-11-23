#!/usr/bin/env bash
# review-coverage-lib.sh — check-review.sh's offline coverage engine. Source after common.sh,
# spec-lib.sh, review-policy-lib.sh and review-fingerprint-lib.sh; the caller supplies
# eligible() (which reads registry). Local Git and standard utilities only; no gh or jq.
#
# Interface (no arguments; all existing caller globals retain their scope):
# - review_coverage_evaluate: resolve content, build edges and evaluate each latest verdict.
# - review_coverage_require_start: enforce T1–T3 start coverage, after the caller's T0 checks.
# review_coverage_require_start requires a prior review_coverage_evaluate call, which defines
# the nested covered() and sets independent, owner and fp_ready.
# Inputs: verdict arrays v_rev, v_round, v_from, v_to, v_verdict, v_c, v_h, v_m and latest;
# context root, id, rigor, fp_base, head, start, record_only, tier, policy_at, base_ref,
# fp_cache, registry and REVIEW_FP_EMPTY. The caller also
# owns v_l, v_link, v_line and order; verdict arrays, rows and notes are not modified here.
# Outputs: append problems; set head_fp, fp_ready, head_stream,
# independent and owner. content_of sets content_fp/content_stream/content_err and writes its
# fp_cache files; resolve_token sets tok_fp/tok_err. Fingerprint helpers also set
# REVIEW_FP_ERROR and REVIEW_MB. covered/leads_to use the global g_from/g_to edge arrays.
# Scratch globals, kept as in check-review.sh: l_idx, l_block, l_fromfp, l_tofp,
# e_from, e_to, g_from, g_to, i, k, reviewer, x, block, what, resolved_by, m, j, n,
# where, from, to, verdict, label, kind, end and from_fp. Only the helpers' original
# local variables are local; coverage failures are appended to problems, not returned.
# shellcheck disable=SC2154,SC2034 # Inputs and additive diagnostic outputs cross sourced interfaces.

# The content a revision carries, as review-fingerprint-lib.sh computes it against fp_base: the
# whole change ("full"). Cached per commit; sets content_fp and
# content_stream (a file), or content_err and returns 1.
content_of() { # commit full
    local file="$fp_cache/$1.$2" digest
    content_fp=""; content_err=""; content_stream="$file.stream"
    if [ ! -f "$file.done" ]; then
        review_delta_stream "$root" "$id" "$fp_base" "$1" > "$file.stream" || content_err="$REVIEW_FP_ERROR"
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
# Receipt ends are authenticated content tokens, never commit-range verdicts.
resolve_token() { # token
    tok_fp=""; tok_err=""
    if [ "$1" = start ]; then tok_fp="$REVIEW_FP_EMPTY"; return 0; fi
    if review_is_fp "$1"; then tok_fp="$1"; return 0; fi
    tok_err="'$1' names no coverage content; receipt ends are start or fp1:<64 hex>"
    return 1
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
    head_fp=""; fp_ready=false
    if ! $record_only && [ -n "$fp_base" ] && [ -n "$start" ]; then
        if content_of "$head" full; then
            head_fp="$content_fp"
            # shellcheck disable=SC2034 # Caller uses the stream for path diagnostics.
            head_stream="$content_stream"; fp_ready=true
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
    l_idx=(); l_block=(); l_fromfp=(); l_tofp=(); e_from=(); e_to=()
    # Additive facts for package planning. These never participate in a gate decision.
    coverage_standing=(); coverage_clean=(); coverage_end=(); coverage_eligible=()
    if [ -n "$fp_base" ]; then
        for i in ${v_rev[@]+"${!v_rev[@]}"}; do
            [ "${v_rev[i]}" != owner ] || continue
            [ "${v_provenance[i]}" = verified ] || continue
            case "${v_verdict[i]}" in PASS|FAIL) ;; *) continue ;; esac
            block=false
            [ "${v_verdict[i]}" = PASS ] && [ "${v_c[i]}" = 0 ] && [ "${v_h[i]}" = 0 ] && { [ "$rigor" = light ] || [ "${v_m[i]}" = 0 ]; } || block=true
            l_idx+=("$i"); l_block+=("$block")
            if resolve_token "${v_from[i]}"; then l_fromfp+=("$tok_fp"); else l_fromfp+=(""); fi
            if resolve_token "${v_to[i]}"; then l_tofp+=("$tok_fp"); else l_tofp+=(""); fi
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
            if [ -z "$resolved_by" ]; then
                coverage_standing+=("$i")
                if [ -n "$x" ]; then
                    where="${v_to[i]}"; review_is_fp "$where" && where="$(shown_fp "$where")"
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
        coverage_clean[i]=false; coverage_end[i]=false; coverage_eligible[i]=false
        if [ "${v_provenance[i]}" != verified ]; then
            $record_only || problems+=("$label: latest receipt provenance is ${v_provenance[i]}; publish a corrected full PASS")
            continue
        fi
        for k in ${l_idx[@]+"${!l_idx[@]}"}; do
            if [ "${l_idx[k]}" = "$i" ] && ! ${l_block[k]}; then coverage_clean[i]=true; fi
        done
        [ "$verdict" = PASS ] || problems+=("$label: verdict ${verdict:-missing}, not PASS")
        if eligible "$reviewer"; then independent=$((independent + 1)); coverage_eligible[i]=true; fi
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
            for end in "$from" "$to"; do resolve_token "$end" || problems+=("$label: $tok_err"); done
            continue
        fi
        from_fp=""
        if resolve_token "$from"; then from_fp="$tok_fp"; else problems+=("$label: $tok_err"); fi
        if ! resolve_token "$to"; then problems+=("$label: $tok_err"); continue; fi
        if [ "$from_fp" = "$tok_fp" ]; then
            problems+=("$label: the range $from..$to is empty"); continue
        fi
        if covered "$tok_fp"; then coverage_end[i]=true; continue; fi
        problems+=("$label: changed since the reviewed content $(shown_fp "$tok_fp"): no recorded verdict carries it to this head's content ($(shown_fp "$head_fp"))")
    done
}

review_coverage_require_start() {
    if [ -n "$tier" ] && [ "$tier" != T0 ] && ! $record_only; then
        [ "$independent" -gt 0 ] || problems+=("$tier needs a recorded independent review; publish a receipt on this PR")
        # Coverage closes each reviewer's end; the change's start must be covered the same way.
        if [ -z "$start" ]; then
            [ -z "$policy_at" ] || problems+=("$tier: $head shares no history with $base_ref, so the change's start cannot be found; fetch the branch history")
        elif [ "$start" = "$head" ]; then
            problems+=("$tier: $head is already in $base_ref; pass --base <the branch it merges into>")
        elif [ "$independent" -gt 0 ] && $fp_ready && ! covered "$REVIEW_FP_EMPTY"; then
            problems+=("$tier: the recorded ranges do not chain from the change's start ${start:0:12} (where it leaves $base_ref) to this head's content; review the whole change")
        fi
        [ "$tier" != T3 ] || $owner || problems+=("T3 needs the owner's native approval too")
    fi
}
