#!/usr/bin/env bash
# check-review.sh — Before merging a change, check that its recorded independent review covers
# the head being merged. Reads committed state only: the change record's tier and its State
# `**Review**:` lines, and the policy (Rigor, reviewer registry, T0 paths) at the tip of the
# trusted default branch, never the head's own copy, with local git. Needs no network and no model
# credentials, so the merging agent and CI can both run it. It checks recorded verdicts; it does
# not review, and it never grants merge authority.
#
# A record line, one per verdict, written by record-review.sh and appended in order; a later line
# supersedes the same reviewer's earlier one whatever its round number:
#   **Review**: round <n> · <from>..<to> · <reviewer> · PASS|FAIL · <c> critical, <h> high, <m> medium, <l> low · <link>
# Each end is `start` (no change) or fp1:<sha256>, the change's content: its delta from where it
# leaves --base to a revision, outside the record and the log (review-fingerprint-lib.sh). A line
# recorded before fingerprints names commit hashes, read as those commits' content while they are
# here. The owner's line (reviewer `owner`, T3) binds the L0/L1 spec's content only; it needs PASS,
# may omit the counts, which are not read, and its link is the last field. The record is read at
# the head, or, when the closing commit deleted it, from the last commit that still had it.
#
# Coverage is by content, never ancestry. Every non-blocking PASS links its two contents. A
# blocking line (a FAIL, or counts that block for the Rigor or cannot be read) stands until a later
# clean PASS from the same reviewer over a non-empty range starts at `start` or at content
# reachable from the failed content through that reviewer's own later lines; only then (the
# latter) does it link. A blocking line recorded before fingerprints is also resolved by the old
# rule: a later clean PASS over a commit range whose head descends from the blocking head.
# A content is covered when links lead from it to the head's content: so a
# verdict survives record-only commits, reverts, rebases, squashes and base merges that leave the
# reviewed hunks and their 3 context lines alone. Each reviewer's latest content must be covered,
# and for T1-T3 so must `start`. A merge carrying only the record and the log from a trusted start
# (a change closed after its code merged) skips coverage. T1-T3 need one independent verdict, T3
# the owner's too, whose L0/L1 content must equal the head's.
# The tier is the record's one **Tier** field and never lower than any tier the record named on
# the trusted branches, at the change's start or at a commit of the branch, nor below T3 for an L0
# edit; T0 holds only when every changed path outside the record and the log is a regular file
# under the trusted config's review-t0-paths.
# A pass whose record is still at the head, with no child or outcome checkpoint, adds a note:
# if the PR completes the change, close it before merge (close-change.sh). It never fails.
# --verify-reports --pr <url> compares each linked report with its line; an unavailable or
# mismatching report fails the check.
#
# Usage: check-review.sh [--json] [--head <rev>] [--base <rev>] [--repo <dir>] [<change-id>]
#   <change-id> defaults to the current branch name; --base to origin/HEAD, and any --base must
#   be origin/HEAD's target or a review-integration-branches entry in its committed config.
#   Exit 0 pass, 1 fail, 2 usage.
set -euo pipefail
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/spec-lib.sh"
source "$SCRIPT_DIR/review-policy-lib.sh"
source "$SCRIPT_DIR/review-fingerprint-lib.sh"
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
# Policy comes from the trusted default branch, never from the change or the caller. The policy
# snapshot is origin/HEAD's current tip: Rigor, the reviewer registry and the T0 paths are read
# there, whatever --base says, so neither a branch nor the choice of base changes the rules, and a
# revoked privilege is not kept by an old merge base. --base only says where the change starts: it
# must be origin/HEAD's target or one of the review-integration-branches its committed config
# lists; any other --base is refused.
if [ -n "$base_ref" ]; then
    git -C "$root" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null || { echo "Not a commit here: $base_ref" >&2; exit 2; }
elif git -C "$root" rev-parse --verify --quiet "origin/HEAD^{commit}" >/dev/null; then
    base_ref=origin/HEAD
fi
approved_refs="$(spec_trusted_refs "$root")"
import_base=""
base_trusted=false
base_canonical=""
[ -z "$base_ref" ] || base_canonical="$(git -C "$root" rev-parse --symbolic-full-name "$base_ref" 2>/dev/null || true)"
if [ -n "$base_canonical" ] && printf '%s\n' "$approved_refs" | grep -qxF -- "$base_canonical"; then
    import_base="$(git -C "$root" rev-parse "$base_ref^{commit}")"; base_trusted=true
fi
trusted_default="$(printf '%s\n' "$approved_refs" | sed -n 1p)"
policy_at=""
[ -z "$trusted_default" ] || policy_at="$(git -C "$root" rev-parse --verify --quiet "$trusted_default^{commit}" || true)"
$base_trusted || import_base=""

problems=(); rows=(); tier=""; rigor=""; record_at=""; record_only=false; start=""; notes=()
sep37="$(printf '\037')"; head_fp=""; fp_ready=false
v_line=(); v_rev=(); v_round=(); v_from=(); v_to=(); v_verdict=(); v_c=(); v_h=(); v_m=(); v_l=(); v_link=()
# Fingerprints are computed against the trusted base: --base, or, only to word the problems of a
# refused --base, the trusted default branch.
fp_base=""
if $base_trusted; then fp_base="$base_canonical"
elif [ -n "$policy_at" ]; then fp_base="$trusted_default"; fi
shallow_hint=""
[ "$(git -C "$root" rev-parse --is-shallow-repository 2>/dev/null)" != true ] || shallow_hint=" (a shallow clone needs the branch history: fetch-depth 0)"
fp_cache="$(mktemp -d)" || { echo "check-review.sh: no temporary directory for content fingerprints" >&2; exit 2; }
trap 'rm -rf "$fp_cache"' EXIT
if [ -z "$policy_at" ]; then
    problems+=("No trusted integration base: origin/HEAD does not resolve here, so there is no policy to check against; establish it (git remote set-head origin --auto) with its history fetched")
elif [ -z "$base_ref" ]; then
    problems+=("No base to find the change's start; pass --base <a trusted integration branch>")
elif ! $base_trusted; then
    problems+=("--base $base_ref is not a trusted integration branch (origin/HEAD's target, or one named by review-integration-branches in its committed config); pass the branch this change merges into")
fi
# Registration must precede use: a change cannot qualify its own maker or invented identity.
registry_at="$policy_at"; registry=""
if [ -n "$registry_at" ]; then
    registry="$( { git -C "$root" show "$registry_at:.prdkit/memory/agents.md" 2>/dev/null || true; } | review_registry)"
fi
# Rigor: exactly one Rigor line, an empty one included, whose value is light or full followed by
# nothing or a space; anything else (none, two, light/full, light1) is unknown, which fails.
read_rigor() { # rev -> light|full|unknown
    { git -C "$root" show "$1:.prdkit/memory/constitution.md" 2>/dev/null || true; } | tr -d '\r' | awk '
        { line = $0 }
        sub(/^[-*[:space:]]*[Rr]igor\**:\**[[:space:]]*/, "", line) { n++; value = tolower(line) }
        END {
            if (n == 1 && value ~ /^(light|full)([[:space:]]|$)/) { sub(/[[:space:]].*/, "", value); print value }
            else print "unknown"
        }'
}
rigor=unknown
if [ -n "$policy_at" ]; then
    rigor="$(read_rigor "$policy_at")"
    [ "$rigor" != unknown ] ||
        problems+=("The trusted base's constitution must name exactly one Rigor, light or full (- **Rigor**: light); fix .prdkit/memory/constitution.md on the integration branch")
fi
# Every **Tier** field in a record on stdin, one per line: T0-T3, or ? when its whole value (up to
# the next · or the end of the line, in optional backticks) is not exactly one tier: T1/T3, T1-T3,
# T1x, "T1, T3" and "T1 T3" are not tiers.
record_tiers() {
    awk '{ s = $0; sub(/\r$/, "", s)
        while ((i = index(s, "**Tier**:")) > 0) {
            s = substr(s, i + 9); v = s; j = index(v, "·"); if (j) v = substr(v, 1, j - 1)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
            if (v ~ /^`T[0-3]`$/) gsub(/`/, "", v)
            if (v ~ /^T[0-3]$/) print v; else print "?"
        } }'
}
# For a floor, every T0-T3 named in any **Tier** field value (up to the next ·), so that a
# malformed earlier value such as T1/T3 still counts at its highest.
floor_tiers() {
    awk '{ s = $0
        while ((i = index(s, "**Tier**:")) > 0) {
            s = substr(s, i + 9); v = s; j = index(v, "·"); if (j) v = substr(v, 1, j - 1)
            while (match(v, /T[0-3]/)) { print substr(v, RSTART, 2); v = substr(v, RSTART + 2) }
        } }'
}
highest_tier() { grep -x 'T[0-3]' | sort | tail -n 1; } # tiers on stdin -> the highest
tier_floor_of() { # rev -> the highest tier the record names there, if any
    { git -C "$root" show "$1:$path" 2>/dev/null || true; } | floor_tiers | highest_tier || true
}
# T0 is docs only: every changed path outside the record and the log must be a regular,
# non-executable file under a path the trusted config lists in review-t0-paths (literal paths;
# a trailing / names a directory), and never the kit's policy, another change record or the L0/L1
# spec. Prints the paths that do not qualify; fails when the diff cannot be read.
t0_paths() { # rev -> configured entries, one per line
    { git -C "$root" show "$1:.prdkit/memory/config.md" 2>/dev/null || true; } | awk "$SPEC_SKIP_AWK"'
        { if (spec_skip($0)) next }
        /^## / { section = $0; next }
        section == "## Configuration" && /^- review-t0-paths:/ {
            n++; value = $0; sub(/^- review-t0-paths:[[:space:]]*/, "", value)
        }
        END { if (n == 1) { gsub(/,/, " ", value); print value } }' | tr -s ' \t\r' '\n' |
        grep -v -e '^$' -e '^/' -e '[][*?\\"]' -e '^\.\./' -e '/\.\./' -e '/\.\.$' -e '^\.\.$' || true
}
metadata_mode_problems() { # rev -> the record or log path when it is there but not a regular file
    local file entry
    for file in "$path" specs/log.md "specs/log/$id.md"; do
        entry="$(GIT_NO_REPLACE_OBJECTS=1 git -C "$root" ls-tree "$1" -- "$file")" || return 1
        case "$entry" in ""|"100644 blob "*) ;; *) printf '%s\n' "$file" ;; esac
    done
}
t0_violations() { # from to
    local allowed raw meta file old new entry ok
    allowed="$(t0_paths "$policy_at")"
    raw="$(LC_ALL=C GIT_NO_REPLACE_OBJECTS=1 git -C "$root" -c core.quotepath=true diff --raw --no-abbrev \
        --no-renames --no-ext-diff --no-textconv --no-color --no-relative --ignore-submodules=none "$1" "$2" -- . \
        ":(top,literal,exclude)$path" ":(top,literal,exclude)specs/log.md" \
        ":(top,literal,exclude)specs/log/$id.md")" || return 1
    while IFS="$(printf '\t')" read -r meta file; do
        [ -n "$meta" ] || continue
        old="${meta%% *}"; old="${old#:}"; new="${meta#* }"; new="${new%% *}"
        ok=false
        case "$old:$new" in 000000:100644|100644:100644|100644:000000) ok=true ;; esac
        case "$file" in .prdkit|.prdkit/*|.product-kit|.product-kit/*|specs/changes/*|\"*) ok=false ;; esac
        for entry in "${spec_l01[@]}"; do
            case "$file" in "$entry"|"$entry"/*) ok=false ;; esac
        done
        if $ok; then
            ok=false
            while IFS= read -r entry; do
                [ -n "$entry" ] || continue
                case "$entry" in
                    */) case "$file" in "$entry"*) ok=true ;; esac ;;
                    *) [ "$file" != "$entry" ] || ok=true ;;
                esac
            done <<< "$allowed"
        fi
        $ok || printf '%s\n' "$file"
    done <<< "$raw"
}
eligible() { [ "$(review_eligibility "$registry" "$1")" = reviewer ]; }
path="specs/changes/$id.md"
spec_l01=(specs/product.md specs/product specs/architecture.md specs/architecture specs/SPEC.md specs/decisions)
changed_since() { # sha [pathspec...] -> paths changed from sha to head, outside the record and the log
    local sha="$1"; shift
    [ "$#" -gt 0 ] || set -- . ":(exclude)$path" ":(exclude)specs/log.md" ":(exclude)specs/log/$id.md"
    git -C "$root" diff --name-only --no-renames --ignore-submodules=none "$sha" "$head" -- "$@" | tr '\n' ' ' | sed 's/ $//'
}
is_sha() { case "$1" in ""|*[!0-9a-f]*) return 1 ;; esac; [ "${#1}" -ge 7 ] && [ "${#1}" -le 40 ]; }
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
    # Closing a change deletes its record; the same history must add its log entry.
    if [ "$record_at" = "$head" ]; then :
    elif ! log="$(spec_log_entries_at "$root" "$head")"; then
        problems+=("$id is closed (its record is deleted), but the log at $head cannot be read without fetching from the promisor remote (a partial clone with Git older than 2.45): fetch the branch's blobs or use Git 2.45+")
    elif ! grep -q "^- [0-9-]* $id:" <<< "$log"; then
        problems+=("$id is closed (its record is deleted) but the log at $head has no '- <date> $id: <what changed>' entry (specs/log/$id.md, as close-change.sh writes it, or a line in specs/log.md)")
    fi
    # The log paths leave review coverage, so each must be a plain file at the head: a pathspec
    # also excludes whatever lies under a directory of that name. The entry is its own one line.
    while read -r log_mode log_type log_sha log_path; do
        case "$log_mode $log_type" in
            "100644 blob"|"100755 blob")
                [ "$log_path" != specs/log.md ] || continue
                if ! spec_objects_local "$root"; then
                    problems+=("$log_path at $head cannot be checked without fetching from the promisor remote (a partial clone with Git older than 2.45): fetch the branch's blobs or use Git 2.45+")
                    continue
                fi
                # Read to a sentinel, so trailing blank lines count; a missing object reads as empty.
                entry_text="$(GIT_NO_LAZY_FETCH=1 git -C "$root" cat-file blob "$log_sha" 2>/dev/null; echo .)"
                entry_text="${entry_text%.}"
                if [ "$(printf '%s' "$entry_text" | awk 'END { print NR }')" != 1 ] ||
                    ! grep -q "^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] $id: ." <<< "$entry_text"; then
                    problems+=("$log_path at $head must hold one line, '- <date> $id: <what changed>'")
                fi ;;
            *) problems+=("$log_path at $head is not a regular file; the log and the change's entry are plain files") ;;
        esac
    done < <(GIT_NO_LAZY_FETCH=1 git -C "$root" ls-tree "$head" -- specs/log.md "specs/log/$id.md" 2>/dev/null)
    record="$(git -C "$root" show "$record_at:$path")"
    # The tier is the record's single **Tier** field; a second one, even in a comment, is refused.
    claims="$(printf '%s\n' "$record" | record_tiers)"
    case "$claims" in
        T[0-3]) tier="$claims" ;;
        *$'\n'*) problems+=("The record names more than one review tier ($(printf '%s' "$claims" | tr '\n' ' ')); keep exactly one **Tier** field") ;;
    esac
    # The branch's own constitution never sets its Rigor; say so when it differs.
    head_rigor="$(read_rigor "$head")"
    if [ -n "$policy_at" ] && [ "$head_rigor" != "$rigor" ]; then
        notes+=("Note: this head's constitution says Rigor $head_rigor; the check uses the trusted base's ($rigor) until that change merges.")
    fi
    # The change starts where it leaves the base. Carrying only the record and the log from there
    # skips coverage, but only from a trusted start: a base inside the change's own history would
    # hide its code.
    [ -z "$base_ref" ] || start="$(git -C "$root" merge-base "$base_ref" "$head" 2>/dev/null)" || start=""
    # A branch may raise its tier, never lower it. The floor is the highest tier the record names
    # on the trusted default branch, on the base, where the change left the base, or at any commit
    # of the branch since; an L0 edit (specs/product.md, specs/product/) is T3 (protocol.md).
    floor=""; floor_at=""
    raise_floor() { # tier where
        if [ -n "$1" ] && { [ -z "$floor" ] || [[ "$1" > "$floor" ]]; }; then floor="$1"; floor_at="$2"; fi
    }
    trusted_floor() { # rev where: a record there must name exactly one tier, or the minimum is unknown
        local named
        git -C "$root" cat-file -e "$1:$path" 2>/dev/null || return 0
        named="$( { git -C "$root" show "$1:$path" 2>/dev/null || true; } | record_tiers)"
        case "$named" in
            T[0-3]) raise_floor "$named" "$2" ;;
            *) problems+=("The record at $2 names no readable tier, so the trusted minimum is unknown; fix it there first") ;;
        esac
    }
    [ -z "$policy_at" ] || trusted_floor "$policy_at" "the trusted base (${trusted_default#refs/remotes/})"
    [ -z "$import_base" ] || trusted_floor "$import_base" "the base ($base_ref)"
    if [ -n "$start" ]; then
        trusted_floor "$start" "the change's start ${start:0:12}"
        while IFS= read -r commit; do
            [ -n "$commit" ] || continue
            raise_floor "$(tier_floor_of "$commit")" "commit ${commit:0:12}"
        done < <(git -C "$root" rev-list --full-history "$start..$head" -- "$path" 2>/dev/null || true)
        if [ "$start" != "$head" ] && [ -n "$(changed_since "$start" specs/product.md specs/product)" ]; then
            raise_floor T3 "its L0 edit ($(changed_since "$start" specs/product.md specs/product))"
        fi
    fi
    if [ -n "$tier" ] && [ -n "$floor" ] && [[ "$tier" < "$floor" ]]; then
        problems+=("The record claims $tier, but its floor is $floor, from $floor_at: a branch may raise its tier, never lower it; claim **Tier**: $floor")
        tier="$floor"
    fi
    # The record and the log are exempt from coverage only as regular, non-executable files, where
    # the change starts and at its head: a directory there would exempt everything inside it, and
    # converting or deleting an unsafe entry would hide that transition.
    metadata_ends=("$head"); [ -z "$start" ] || [ "$start" = "$head" ] || metadata_ends=("$start" "$head")
    for at in "${metadata_ends[@]}"; do
        where="$head"; [ "$at" = "$head" ] || where="the change's start ${start:0:12}"
        if ! odd="$(metadata_mode_problems "$at")"; then
            problems+=("The tree at $where cannot be read to check the record and the log")
        elif [ -n "$odd" ] && [ "$at" = "$head" ]; then
            problems+=("$(printf '%s' "$odd" | tr '\n' ' ' | sed 's/ $//') must stay a regular, non-executable file")
        elif [ -n "$odd" ]; then
            problems+=("$(printf '%s' "$odd" | tr '\n' ' ' | sed 's/ $//') is not a regular, non-executable file at $where, so changing it cannot be exempt from review; fix it on the base first")
        fi
    done
    if $base_trusted && [ -n "$start" ] && [ "$start" != "$head" ] && [ -z "$(changed_since "$start")" ]; then
        record_only=true
    fi
    # The verdict list, parsed once from State in record order: line, reviewer, round, from, to,
    # verdict, critical, high, medium, low, link. Coverage consumes only this list.
    v_line=(); v_rev=(); v_round=(); v_from=(); v_to=(); v_verdict=(); v_c=(); v_h=(); v_m=(); v_l=(); v_link=()
    while IFS="$(printf '\037')" read -r line reviewer round from to verdict critical high medium low link; do
        [ -n "$line" ] || continue
        v_line+=("$line"); v_rev+=("$reviewer"); v_round+=("$round"); v_from+=("$from"); v_to+=("$to")
        v_verdict+=("$verdict"); v_c+=("$critical"); v_h+=("$high"); v_m+=("$medium"); v_l+=("$low"); v_link+=("$link")
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
            # The link is the last field: after the counts, or after the verdict on an owner line.
            link = (n > (reviewer == "owner" ? 4 : 5)) ? trim(f[n]) : ""
            print NR "\037" reviewer "\037" trim(f[1]) "\037" from "\037" to "\037" verdict "\037" count(f[5], "critical") "\037" count(f[5], "high") "\037" count(f[5], "medium") "\037" count(f[5], "low") "\037" link
        }')
    # Each reviewer's latest line, in order of first appearance.
    order=(); latest=()
    for i in ${v_rev[@]+"${!v_rev[@]}"}; do
        found=""
        for k in ${order[@]+"${!order[@]}"}; do [ "${order[k]}" != "${v_rev[i]}" ] || found="$k"; done
        if [ -z "$found" ]; then order+=("${v_rev[i]}"); latest+=("$i"); else latest[found]="$i"; fi
    done
    for i in ${latest[@]+"${latest[@]}"}; do
        rows+=("${v_rev[i]}$sep37${v_round[i]}$sep37${v_from[i]}$sep37${v_to[i]}$sep37${v_verdict[i]}$sep37${v_c[i]}$sep37${v_h[i]}$sep37${v_m[i]}$sep37${v_l[i]}")
    done
    case "$claims" in *$'\n'*) ;; *) [ -n "$tier" ] || problems+=("The record names no review tier (**Tier**: T0–T3)") ;; esac
    for i in ${v_rev[@]+"${!v_rev[@]}"}; do
        [ "${v_rev[i]}" != owner ] || continue
        if [ -z "$registry_at" ]; then
            problems+=("$path:${v_line[i]}: No trusted integration-baseline registry: establish origin/HEAD and fetch its shared history before checking reviewer eligibility")
        fi
        eligibility="$(review_eligibility "$registry" "${v_rev[i]}")"
        [ "$eligibility" = reviewer ] || problems+=("$path:${v_line[i]}: reviewer '${v_rev[i]}' is $eligibility in the integration-baseline registry; register an eligible identity in agents.md before using it")
    done

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
    if [ "$tier" = T0 ] && ! $record_only && [ -n "$policy_at" ]; then
        # The tier is checked, not taken as the record's claim.
        if [ -z "$start" ]; then
            problems+=("T0: $head shares no history with $base_ref, so the change cannot be shown to be docs only; fetch the branch history")
        elif ! t0_bad="$(t0_violations "$start" "$head")"; then
            problems+=("T0: the change's diff from ${start:0:12} cannot be read, so it cannot be shown to be docs only")
        elif [ -n "$t0_bad" ]; then
            n_bad="$(printf '%s\n' "$t0_bad" | wc -l | tr -d ' ')"
            shown="$(printf '%s\n' "$t0_bad" | head -n 10 | tr '\n' ' ' | sed 's/ $//')"
            [ "$n_bad" -le 10 ] || shown="$shown and $((n_bad - 10)) more"
            if [ -z "$(t0_paths "$policy_at")" ]; then
                problems+=("T0 is docs only, and the trusted base's .prdkit/memory/config.md lists no review-t0-paths, so T0 covers only the record and the log; this change also touches: $shown. Claim T1 or higher")
            else
                problems+=("T0 is docs only: these changed paths are not regular files under the trusted base's review-t0-paths (or are policy, another change record or the L0/L1 spec): $shown. Claim T1 or higher")
            fi
        fi
    fi
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
fi

if $verify_reports; then
    report_verification=not-run
    if [ "${#problems[@]}" -eq 0 ]; then
        source "$SCRIPT_DIR/review-reports-lib.sh"
        if review_reports_context "$pr_url" "$head"; then
            report_verification=matched
            for i in ${v_rev[@]+"${!v_rev[@]}"}; do
                from="${v_from[i]}"; to="${v_to[i]}"; at="$path:${v_line[i]}"
                # A fingerprint line matches a v2 receipt with exactly the recorded ends; a line
                # recorded before fingerprints, a v1 receipt with both commits' full hashes.
                if { [ "$from" = start ] || review_is_fp "$from"; } && review_is_fp "$to"; then
                    review_report_match_v2 "${v_link[i]}" "${v_rev[i]}" "$from" "$to" "${v_verdict[i]}" "${v_c[i]}" "${v_h[i]}" "${v_m[i]}" "${v_l[i]}" ||
                        { problems+=("$at: $RR_ERROR"); report_verification="$RR_STATE"; }
                    continue
                fi
                from="$( { is_sha "$from" && git -C "$root" rev-parse --verify --quiet "$from^{commit}"; } || true)"
                to="$( { is_sha "$to" && git -C "$root" rev-parse --verify --quiet "$to^{commit}"; } || true)"
                # Superseded verdicts whose commits are unavailable still cannot be authenticated.
                if [ -z "$from" ] || [ -z "$to" ]; then
                    problems+=("$at: report range is unavailable for verification"); report_verification=failed; continue
                fi
                if ! review_report_match "${v_link[i]}" "${v_rev[i]}" "$from" "$to" "${v_verdict[i]}" "${v_c[i]}" "${v_h[i]}" "${v_m[i]}" "${v_l[i]}"; then
                    problems+=("$at: $RR_ERROR"); report_verification="$RR_STATE"
                fi
            done
        else
            problems+=("$RR_ERROR"); report_verification="$RR_STATE"
        fi
    fi
fi
result=pass; [ "${#problems[@]}" -eq 0 ] || result=fail
# Advisory: a reviewed PR-scoped record still at this head would merge open (review.md, Closing).
record_open=false
if [ "$result" = pass ] && [ "$record_at" = "$head" ]; then
    case $'\n'"$(spec_unclosed_changes "$root" "$head")"$'\n' in *$'\n'"$id"$'\n'*) record_open=true ;; esac
fi
if $json; then
    printf '{"result":"%s","change":"%s","head":"%s","fingerprint":"%s","base":"%s","base_trusted":%s,"policy_at":"%s","record_only":%s,"record_open":%s,"tier":"%s","rigor":"%s","record_at":"%s","reviews":[' \
        "$result" "$id" "$head" "$head_fp" "$(json_escape "$base_ref")" "$base_trusted" "$policy_at" "$record_only" "$record_open" "$tier" "$rigor" "$(json_escape "$record_at")"
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
        printf 'PASS %s at %s: tier T0 needs no independent review (every changed path is docs only under the trusted review-t0-paths).\n' "$id" "$head"
    else
        printf 'PASS %s at %s: %s, Rigor %s; %s recorded verdict(s) cover this head.\n' "$id" "$head" "$tier" "$rigor" "${#rows[@]}"
    fi
    for note in ${notes[@]+"${notes[@]}"}; do printf '%s\n' "$note"; done
    ! $record_open || printf 'Note: %s is still at this head; if this PR completes the change, close it before merge: .prdkit/scripts/bash/close-change.sh %s "<log line>" (review.md, Closing).\n' "$path" "$id"
else
    printf 'FAIL %s at %s:\n' "$id" "$head"
    for problem in "${problems[@]}"; do printf '  %s\n' "$problem"; done
    for note in ${notes[@]+"${notes[@]}"}; do printf '%s\n' "$note"; done
fi
if ! $json && [ "${#rows[@]}" -gt 0 ]; then
    if [ "$report_verification" = not-requested ]; then
        printf 'Report links unverified (offline default); use --verify-reports --pr <url> for report consistency checks.\n'
    else printf 'Report verification: %s (matching metadata does not prove reviewer independence).\n' "$report_verification"; fi
fi
[ "$result" = pass ]
