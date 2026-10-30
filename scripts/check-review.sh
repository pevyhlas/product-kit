#!/usr/bin/env bash
# check-review.sh — Before merging a change, check that its recorded independent review covers
# the head being merged. Reads committed state only: the change record's tier and its State
# `**Review**:` lines, the constitution's Rigor and local git. Needs no network and no model
# credentials, so the merging agent and CI can both run it. It checks recorded verdicts; it does
# not review, and it never grants merge authority.
#
# A record line, one per verdict, appended in order; a later line supersedes the same reviewer's
# earlier one whatever its round number. Both ends of the range are commit hashes:
#   **Review**: round <n> · <base sha>..<head sha> · <reviewer> · PASS|FAIL · <c> critical, <h> high, <m> medium, <l> low · <link>
# The owner's line (reviewer `owner`, T3) needs PASS and the head the owner approved; its counts
# are not read. The record is read at the head, or, when the closing commit deleted it, from the
# last commit that still had it.
#
# Every reviewer's latest verdict, in any tier, must be PASS with nothing blocking for the Rigor.
# A blocking line (a FAIL, or counts that block for the Rigor or cannot be read) stands until a
# later non-blocking PASS from the same reviewer, over a non-empty range, reaches its head; only
# then does its range link. A blocking head that is not a commit hash always stands; one gone
# from the history (rebased or squashed away) is ignored. Every non-blocking PASS range,
# superseded rounds included, links. A point is covered when links chain from it (each starting
# at or before a head already reached) to a head after which only the record and specs/log.md
# changed, or through verified imports from the trusted base that preserve the exact branch
# delta (modes, blob IDs and paths). Overlapping source edits/resolutions remain uncovered.
# Each reviewer's head must be covered, and for
# T1-T3 so must the change's start (its merge base with --base). A merge carrying only the record
# and the log from a trusted start (a change closed after its code merged) skips coverage. T1-T3
# need one independent verdict, T3 the owner's too, and no L0/L1 spec edit since the owner's head.
#
# Usage: check-review.sh [--json] [--head <rev>] [--base <rev>] [--repo <dir>] [<change-id>]
#   <change-id> defaults to the current branch name; --base to the first of origin/HEAD,
#   origin/main, origin/master, main and master that exists.
#   Exit 0 pass, 1 fail, 2 usage.
set -euo pipefail
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/spec-lib.sh"
source "$SCRIPT_DIR/review-policy-lib.sh"
json=false; head_ref=HEAD; base_ref=""; repo=.; id=""
verify_reports=false; pr_url=""; report_verification=not-requested
usage='Usage: check-review.sh [--json] [--head <rev>] [--base <rev>] [--repo <dir>] [--verify-reports --pr <url>] [<change-id>]'
while [ "$#" -gt 0 ]; do
    case "$1" in
        --json) json=true ;;
        --verify-reports) verify_reports=true ;;
        --pr) shift; [ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }; pr_url="$1" ;;
        --head) shift; [ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }; head_ref="$1" ;;
        --base) shift; [ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }; base_ref="$1" ;;
        --repo) shift; [ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }; repo="$1" ;;
        --help|-h) echo "$usage"; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *) [ -z "$id" ] || { echo "$usage" >&2; exit 2; }; id="$1" ;;
    esac
    shift
done
if { $verify_reports && [ -z "$pr_url" ]; } || { ! $verify_reports && [ -n "$pr_url" ]; }; then echo "$usage" >&2; exit 2; fi
root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || { echo "Not inside a Git checkout: $repo" >&2; exit 2; }
[ -n "$id" ] || id="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
is_change_id "$id" || { echo "Expected a change id such as 004-export-csv (got: ${id:-none}); pass it explicitly" >&2; exit 2; }
head="$(git -C "$root" rev-parse --verify --quiet "$head_ref^{commit}")" || { echo "Not a commit here: $head_ref" >&2; exit 2; }
default_ref=""
for candidate in origin/HEAD origin/main origin/master main master; do
    if git -C "$root" rev-parse --verify --quiet "$candidate^{commit}" >/dev/null; then default_ref="$candidate"; break; fi
done
if [ -n "$base_ref" ]; then
    git -C "$root" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null || { echo "Not a commit here: $base_ref" >&2; exit 2; }
else
    base_ref="$default_ref"
fi
# Only origin/HEAD establishes the default integration branch. Other bases may locate a
# comparison, but do not grant exemptions. Additional integration refs must be configured in
# the default branch's committed config, never in the change/worktree being checked.
trusted_default="$(git -C "$root" symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null || true)"
case "$trusted_default" in refs/remotes/*) ;; *) trusted_default="" ;; esac
trusted_default_sha=""
if [ -n "$trusted_default" ]; then
    trusted_default_sha="$(git -C "$root" rev-parse --verify --quiet "$trusted_default^{commit}" || true)"
fi
approved_refs=""
if [ -n "$trusted_default_sha" ]; then
    approved_refs="$trusted_default"
    policy="$(git -C "$root" show "$trusted_default_sha:.prdkit/memory/config.md" 2>/dev/null || true)"
    configured="$(printf '%s\n' "$policy" | awk "$SPEC_SKIP_AWK"'
        { if (spec_skip($0)) next }
        /^## / { section = $0; next }
        section == "## Configuration" && /^- review-integration-branches:/ {
            n++; value = $0; sub(/^- review-integration-branches:[[:space:]]*/, "", value)
        }
        END { if (n == 1) { gsub(/,/, " ", value); print value } }')"
    # Disable glob expansion: configuration is a list of literal refs, never patterns.
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        case "$candidate" in refs/remotes/*) ;; *) candidate="refs/remotes/$candidate" ;; esac
        git check-ref-format "$candidate" >/dev/null 2>&1 || continue
        approved_refs="$approved_refs"$'\n'"$candidate"
    done < <(printf '%s\n' "$configured" | tr ' \t\r' '\n')
fi
import_base=""
base_trusted=false
base_canonical="$(git -C "$root" rev-parse --symbolic-full-name "$base_ref" 2>/dev/null || true)"
if [ -n "$base_canonical" ] && printf '%s\n' "$approved_refs" | grep -qxF -- "$base_canonical"; then
    import_base="$(git -C "$root" rev-parse "$base_ref^{commit}")"; base_trusted=true
fi

problems=(); rows=(); links=(); all_reviews=(); tier=""; rigor=""; record_at=""; record_only=false; start=""
# Registration must precede use: a change cannot qualify its own maker or invented identity.
registry_base="$trusted_default_sha"; registry_at=""; registry=""
if [ -n "$registry_base" ]; then
    registry_at="$(git -C "$root" merge-base "$registry_base" "$head" 2>/dev/null || true)"
    if [ -n "$registry_at" ]; then
        registry="$( { git -C "$root" show "$registry_at:.prdkit/memory/agents.md" 2>/dev/null || true; } | review_registry)"
    fi
fi
eligible() { [ "$(review_eligibility "$registry" "$1")" = reviewer ]; }
path="specs/changes/$id.md"
spec_l01=(specs/product.md specs/product specs/architecture.md specs/architecture specs/SPEC.md specs/decisions)
changed_since() { # sha [pathspec...] -> paths changed from sha to head, outside the record and the log
    local sha="$1"; shift
    [ "$#" -gt 0 ] || set -- . ":(exclude)$path" ":(exclude)specs/log.md"
    git -C "$root" diff --name-only "$sha" "$head" -- "$@" | tr '\n' ' ' | sed 's/ $//'
}
# Exact tree-entry deltas, without rename heuristics, external diff drivers, textconv or
# whitespace normalization. Git quotes control characters in paths; no NUL data enters Bash.
delta_signature() { # from to pathspec...
    local from="$1" to="$2"; shift 2
    git -C "$root" -c core.quotepath=true diff --no-ext-diff --no-textconv --no-renames \
        --raw --no-abbrev "$from" "$to" -- "$@"
}
unchanged_since() { # sha [pathspec...] -> covered without another review of this delta
    local sha="$1" delta merges cursor parents first second extra common before after
    shift
    [ "$#" -gt 0 ] || set -- . ":(exclude)$path" ":(exclude)specs/log.md"
    delta="$(delta_signature "$sha" "$head" "$@")" || return 1
    merges="$(git -C "$root" rev-list --first-parent --min-parents=2 "$sha..$head")" || return 1
    # Inspect merges even if the resulting tree equals the reviewed tree: resolving an
    # upstream conflict by choosing the reviewed version is still a new integration decision.
    [ -n "$delta" ] || [ -n "$merges" ] || return 0
    [ -n "$import_base" ] || return 1
    cursor="$head"
    while [ "$cursor" != "$sha" ]; do
        parents="$(git -C "$root" rev-list --parents -n 1 "$cursor")" || return 1
        read -r _ first second extra <<< "$parents"
        [ -n "$first" ] && [ -z "$extra" ] || return 1
        git -C "$root" merge-base --is-ancestor "$sha" "$first" || return 1
        if [ -z "$second" ]; then
            delta="$(delta_signature "$first" "$cursor" "$@")" || return 1
            [ -z "$delta" ] || return 1
        else
            git -C "$root" merge-base --is-ancestor "$second" "$import_base" || return 1
            common="$(git -C "$root" merge-base --all "$first" "$second")" || return 1
            case "$common" in ''|*$'\n'*) return 1 ;; esac
            before="$(delta_signature "$common" "$first" "$@")" || return 1
            after="$(delta_signature "$second" "$cursor" "$@")" || return 1
            [ "$before" = "$after" ] || return 1
        fi
        cursor="$first"
    done
    return 0
}
is_sha() { case "$1" in ""|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -ge 7 ] && [ "${#1}" -le 40 ]; }
here() { # end -> its full hash when it is a commit hash in the head's history; no problem recorded
    local sha
    is_sha "$1" && sha="$(git -C "$root" rev-parse --verify --quiet "$1^{commit}")" &&
        git -C "$root" merge-base --is-ancestor "$sha" "$head" && printf '%s\n' "$sha"
}
# A recorded end must be a commit hash present here and in the head's history; sets resolved to
# its full hash, or records the problem and returns 1.
resolve_end() { # label end
    resolved=""
    if ! is_sha "$2"; then
        problems+=("$1: '${2:-}' is not a commit hash; record the resolved hashes build-review-package.sh prints"); return 1
    fi
    if ! resolved="$(git -C "$root" rev-parse --verify --quiet "$2^{commit}")"; then
        problems+=("$1: commit $2 is not here (a shallow clone needs the branch history: fetch-depth 0)"); return 1
    fi
    if ! git -C "$root" merge-base --is-ancestor "$resolved" "$head"; then
        problems+=("$1: commit $2 is not in the history of $head"); resolved=""; return 1
    fi
}

if git -C "$root" cat-file -e "$head:$path" 2>/dev/null; then
    record_at="$head"
elif last="$(git -C "$root" log -1 --format=%H "$head" -- "$path" 2>/dev/null)" && [ -n "$last" ] &&
    git -C "$root" cat-file -e "$last^:$path" 2>/dev/null; then
    record_at="$last^"
fi
if [ -z "$record_at" ]; then
    hint=" (a shallow clone needs the branch history)"
    ! git -C "$root" cat-file -e "$head:specs/features/$id" 2>/dev/null ||
        hint=" (a 0.x feature the owner keeps open becomes a change record at the cutover or restructure; see .prdkit/workflows/compact.md)"
    problems+=("No change record $path at $head or in its history$hint")
else
    # Closing a change deletes its record; the same history must add its log line.
    log="$(git -C "$root" show "$head:specs/log.md" 2>/dev/null)" || log=""
    if [ "$record_at" != "$head" ] && ! grep -q "^- [0-9-]* $id:" <<< "$log"; then
        problems+=("$id is closed (its record is deleted) but specs/log.md at $head has no '- <date> $id: <what changed>' line")
    fi
    record="$(git -C "$root" show "$record_at:$path")"
    tier="$(printf '%s\n' "$record" | sed -n 's/.*\*\*Tier\*\*:[[:space:]]*\(T[0-3]\)\([^0-9].*\)\{0,1\}$/\1/p' | head -n 1)"
    rigor="$(git -C "$root" show "$head:.prdkit/memory/constitution.md" 2>/dev/null |
        sed -n 's/^[-*[:space:]]*[Rr]igor\**:\**[[:space:]]*\([A-Za-z]*\).*/\1/p' | head -n 1 | tr '[:upper:]' '[:lower:]')" || true
    case "$rigor" in light|full) ;; *) rigor=unknown ;; esac
    # The change starts where it leaves the base. Carrying only the record and the log from there
    # skips coverage, but only from a trusted start: a base inside the change's own history would
    # hide its code.
    [ -z "$base_ref" ] || start="$(git -C "$root" merge-base "$base_ref" "$head" 2>/dev/null)" || start=""
    if $base_trusted && [ -n "$start" ] && [ "$start" != "$head" ] && [ -z "$(changed_since "$start")" ]; then
        record_only=true
    fi
    # Latest verdict per reviewer from State: reviewer, round, range base, range head, verdict,
    # critical, high, medium, low. Every independent PASS or FAIL line, superseded ones included,
    # is also a link (marked \036): the range it reviewed, which coverage chains through.
    sep36="$(printf '\036')"
    sep35="$(printf '\035')"
    while IFS= read -r row; do
        case "$row" in
            "") ;;
            "$sep35"*) all_reviews+=("${row#"$sep35"}") ;;
            "$sep36"*) links+=("${row#"$sep36"}") ;;
            *) rows+=("$row") ;;
        esac
    done < <(printf '%s\n' "$record" | awk "$SPEC_SKIP_AWK"'
        { gsub(/[\035-\037]/, " "); if (spec_skip($0)) next }
        function trim(s) { gsub(/`/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        function count(s, kind,   v) { v = s; if (!match(v, "[0-9]+ " kind)) return "?"; v = substr(v, RSTART, RLENGTH); sub(/ .*/, "", v); return v }
        /^## / { sec = $0; sub(/^##[[:space:]]+/, "", sec); next }
        sec == "State" && /^\*\*Review\*\*:/ {
            line = $0; sub(/^\*\*Review\*\*:[[:space:]]*/, "", line)
            n = split(line, f, " · ")
            reviewer = n >= 3 ? tolower(trim(f[3])) : ""
            if (reviewer == "") reviewer = "(unnamed)"
            range = trim(f[2]); cut = index(range, "..."); width = 3
            if (!cut) { cut = index(range, ".."); width = 2 }
            from = cut ? substr(range, 1, cut - 1) : ""; to = cut ? substr(range, cut + width) : ""
            verdict = toupper(trim(f[4]))
            print "\035" NR "\037" reviewer "\037" from "\037" to "\037" verdict "\037" count(f[5], "critical") "\037" count(f[5], "high") "\037" count(f[5], "medium") "\037" count(f[5], "low") "\037" trim(f[reviewer == "owner" ? 5 : 6])
            if (reviewer != "owner" && (verdict == "PASS" || verdict == "FAIL")) print "\036" reviewer "\037" trim(f[1]) "\037" verdict "\037" from "\037" to "\037" count(f[5], "critical") "\037" count(f[5], "high") "\037" count(f[5], "medium")
            if (!(reviewer in row)) order[++k] = reviewer
            row[reviewer] = reviewer "\037" trim(f[1]) "\037" from "\037" to "\037" verdict "\037" count(f[5], "critical") "\037" count(f[5], "high") "\037" count(f[5], "medium") "\037" count(f[5], "low")
        }
        END { for (i = 1; i <= k; i++) print row[order[i]] }')
    [ -n "$tier" ] || problems+=("The record names no review tier (**Tier**: T0–T3)")
    for review in ${all_reviews[@]+"${all_reviews[@]}"}; do
        IFS="$(printf '\037')" read -r line reviewer _ <<< "$review"
        [ "$reviewer" != owner ] || continue
        if [ -z "$registry_at" ]; then
            problems+=("$path:$line: No trusted integration-baseline registry: establish origin/HEAD and fetch its shared history before checking reviewer eligibility")
        fi
        eligibility="$(review_eligibility "$registry" "$reviewer")"
        [ "$eligibility" = reviewer ] || problems+=("$path:$line: reviewer '$reviewer' is $eligibility in the integration-baseline registry; register an eligible identity in agents.md before using it")
    done

    # Every PASS or FAIL line, in record order, with its ends resolved where they are hashes in the
    # head's history. A blocking line (a FAIL, or counts that block for the Rigor or cannot be
    # read) stands until a later non-blocking PASS from the same reviewer, over a non-empty range,
    # reaches its head. A standing line is a problem in any tier and links nothing; one whose head
    # is a well-formed hash gone from this history (rebased or squashed away) is ignored.
    l_rev=(); l_round=(); l_block=(); l_text=(); l_verdict=(); l_from=(); l_to=(); link_from=(); link_to=()
    for link in ${links[@]+"${links[@]}"}; do
        IFS="$(printf '\037')" read -r reviewer round verdict from to critical high medium <<< "$link"
        block=false
        [ "$verdict" = PASS ] && [ "$critical" = 0 ] && [ "$high" = 0 ] && { [ "$rigor" = light ] || [ "$medium" = 0 ]; } || block=true
        l_rev+=("$reviewer"); l_round+=("$round"); l_verdict+=("$verdict"); l_block+=("$block"); l_text+=("$to")
        l_from+=("$(here "$from" || true)"); l_to+=("$(here "$to" || true)")
    done
    for k in ${l_rev[@]+"${!l_rev[@]}"}; do
        what="its ${l_verdict[k]}"; [ "${l_verdict[k]}" = FAIL ] || what="its PASS with blocking findings"
        if ${l_block[k]}; then
            if [ -z "${l_to[k]}" ]; then
                is_sha "${l_text[k]}" || problems+=("${l_rev[k]} (${l_round[k]}): $what at '${l_text[k]}' stands: that is not a commit hash")
                continue
            fi
            resolved_block=false; m=$((k + 1))
            while [ "$m" -lt "${#l_rev[@]}" ]; do
                if [ "${l_rev[m]}" = "${l_rev[k]}" ] && ! ${l_block[m]} && [ -n "${l_to[m]}" ] && [ -n "${l_from[m]}" ] &&
                    [ "${l_from[m]}" != "${l_to[m]}" ] && git -C "$root" merge-base --is-ancestor "${l_to[k]}" "${l_to[m]}"; then
                    if eligible "${l_rev[m]}"; then resolved_block=true; break; fi
                fi
                m=$((m + 1))
            done
            if ! $resolved_block; then
                problems+=("${l_rev[k]} (${l_round[k]}): $what at ${l_to[k]:0:12} stands: no later clean PASS from ${l_rev[k]} reaches that head")
                continue
            fi
        fi
        [ -n "${l_to[k]}" ] && [ -n "${l_from[k]}" ] && [ "${l_from[k]}" != "${l_to[k]}" ] || continue
        eligible "${l_rev[k]}" || continue
        link_from+=("${l_from[k]}"); link_to+=("${l_to[k]}")
    done
    # A point is covered when recorded ranges chain from it to a head after which only the record
    # and the log changed: each range must start at or before a head already reached.
    covered() { # sha
        local reached used grew r k n=0
        reached=("$1"); used=(); grew=true
        while $grew; do
            grew=false
            while [ "$n" -lt "${#reached[@]}" ]; do
                unchanged_since "${reached[n]}" && return 0
                n=$((n + 1))
            done
            for k in ${link_from[@]+"${!link_from[@]}"}; do
                [ -z "${used[k]:-}" ] || continue
                for r in "${reached[@]}"; do
                    if git -C "$root" merge-base --is-ancestor "${link_from[k]}" "$r"; then
                        reached+=("${link_to[k]}"); used[k]=1; grew=true; break
                    fi
                done
            done
        done
        return 1
    }

    # Verdicts and blocking counts, every tier; then each reviewer's head must be covered.
    independent=0; owner=false
    for row in ${rows[@]+"${rows[@]}"}; do
        IFS="$(printf '\037')" read -r reviewer round from to verdict critical high medium low <<< "$row"
        label="$reviewer ($round)"
        [ "$verdict" = PASS ] || problems+=("$label: verdict ${verdict:-missing}, not PASS")
        if [ "$reviewer" = owner ]; then
            owner=true; $record_only && continue
            resolve_end "$label" "$to" || continue
            if ! unchanged_since "$resolved" "${spec_l01[@]}"; then
                later="$(changed_since "$resolved" "${spec_l01[@]}")"
                problems+=("$label: the L0/L1 spec changed since the owner's head $to: ${later:-merge integration is not covered}")
            fi
            continue
        fi
        if eligible "$reviewer"; then independent=$((independent + 1)); fi
        for kind in critical high medium; do
            case "$kind" in critical) n="$critical" ;; high) n="$high" ;; medium) n="$medium" ;; esac
            [ "$kind" != medium ] || [ "$rigor" != light ] || continue
            [ "$n" = 0 ] && continue
            if [ "$rigor" = unknown ]; then
                problems+=("$label: $n $kind finding(s) block: the constitution names no Rigor (light or full), so medium blocks")
            else
                problems+=("$label: $n $kind finding(s) block under Rigor: $rigor")
            fi
        done
        $record_only && continue
        resolve_end "$label" "$from" || true
        from_resolved="$resolved"
        resolve_end "$label" "$to" || continue
        if [ "$from_resolved" = "$resolved" ]; then problems+=("$label: the range $from..$to is empty"); continue; fi
        if ! covered "$resolved"; then
            later="$(changed_since "$resolved")"
            problems+=("$label: changed since the reviewed head $to: ${later:-merge integration is not covered}")
        fi
    done
    if [ -n "$tier" ] && [ "$tier" != T0 ] && ! $record_only; then
        [ "$independent" -gt 0 ] || problems+=("$tier needs a recorded independent review; none found in State")
        # Coverage closes each reviewer's end; the change's start must be covered the same way.
        if [ -z "$start" ]; then
            problems+=("$tier: no base to find the change's start (none of origin/HEAD, origin/main, origin/master, main, master); pass --base <the branch it merges into>")
        elif [ "$start" = "$head" ]; then
            problems+=("$tier: $head is already in $base_ref; pass --base <the branch it merges into>")
        elif [ "$independent" -gt 0 ] && ! covered "$start"; then
            problems+=("$tier: the recorded ranges do not chain from the change's start ${start:0:12} (where it leaves $base_ref) to this head; review the whole change")
        fi
        [ "$tier" != T3 ] || $owner || problems+=("T3 needs the owner's verdict too (a **Review** line with reviewer owner)")
    fi
fi

if $verify_reports; then
    report_verification=not-run
    if [ "${#problems[@]}" -eq 0 ]; then
        source "$SCRIPT_DIR/review-reports-lib.sh"
        if review_reports_context "$pr_url" "$head"; then
            report_verification=matched
            for review in ${all_reviews[@]+"${all_reviews[@]}"}; do
                IFS="$(printf '\037')" read -r line reviewer from to verdict critical high medium low link <<< "$review"
                from="$(here "$from" || true)"; to="$(here "$to" || true)"
                # Superseded verdicts whose history is unavailable still cannot be authenticated.
                if [ -z "$from" ] || [ -z "$to" ]; then
                    problems+=("$path:$line: report range is unavailable for verification"); report_verification=failed; continue
                fi
                if ! review_report_match "$link" "$reviewer" "$from" "$to" "$verdict" "$critical" "$high" "$medium" "$low"; then
                    problems+=("$path:$line: $RR_ERROR"); report_verification="$RR_STATE"
                fi
            done
        else
            problems+=("$RR_ERROR"); report_verification="$RR_STATE"
        fi
    fi
fi
result=pass; [ "${#problems[@]}" -eq 0 ] || result=fail
if $json; then
    printf '{"result":"%s","change":"%s","head":"%s","base":"%s","base_trusted":%s,"record_only":%s,"tier":"%s","rigor":"%s","record_at":"%s","reviews":[' \
        "$result" "$id" "$head" "$(json_escape "$base_ref")" "$base_trusted" "$record_only" "$tier" "$rigor" "$(json_escape "$record_at")"
    sep=""
    for row in ${rows[@]+"${rows[@]}"}; do
        IFS="$(printf '\037')" read -r reviewer round from to verdict critical high medium low <<< "$row"
        printf '%s{"reviewer":"%s","round":"%s","range":"%s","verdict":"%s","critical":"%s","high":"%s","medium":"%s","low":"%s"}' "$sep" \
            "$(json_escape "$reviewer")" "$(json_escape "$round")" "$(json_escape "$from..$to")" "$(json_escape "$verdict")" \
            "$(json_escape "$critical")" "$(json_escape "$high")" "$(json_escape "$medium")" "$(json_escape "$low")"
        sep=,
    done
    printf '],"registry_at":"%s","report_verification":"%s","problems":%s}\n' "$registry_at" "$report_verification" "$(json_array ${problems[@]+"${problems[@]}"})"
elif [ "$result" = pass ]; then
    if $record_only; then
        note=""
        [ "${#rows[@]}" -gt 0 ] || [ "$tier" = T0 ] || note=" Note: a $tier record with no verdict, so its code merged unreviewed."
        printf 'PASS %s at %s: since %s it carries only the record and the log; %s recorded verdict(s), none blocking.%s\n' "$id" "$head" "$base_ref" "${#rows[@]}" "$note"
    elif [ "${#rows[@]}" -eq 0 ]; then
        printf 'PASS %s at %s: tier T0 needs no independent review (the tier is the record'"'"'s claim).\n' "$id" "$head"
    else
        printf 'PASS %s at %s: %s, Rigor %s; %s recorded verdict(s) cover this head.\n' "$id" "$head" "$tier" "$rigor" "${#rows[@]}"
    fi
else
    printf 'FAIL %s at %s:\n' "$id" "$head"
    $base_trusted || printf '  Base is not trusted for coverage exemptions: establish origin/HEAD or configure review-integration-branches in its committed config.\n'
    for problem in "${problems[@]}"; do printf '  %s\n' "$problem"; done
fi
if ! $json && [ "${#rows[@]}" -gt 0 ]; then
    if [ "$report_verification" = not-requested ]; then
        printf 'Report links unverified (offline default); use --verify-reports --pr <url> for report consistency checks.\n'
    else printf 'Report verification: %s (matching metadata does not prove reviewer independence).\n' "$report_verification"; fi
fi
[ "$result" = pass ]
