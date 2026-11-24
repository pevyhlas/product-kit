#!/usr/bin/env bash
# check-review.sh — Host receipts are the independent verdict authority. Trusted policy, tier,
# fingerprints and structure still come from committed Git state. The coverage engine is unchanged.
# Online --pr enumerates this PR and closed-source blockers in every tier. --receipts revalidates
# an untrusted snapshot without gh/jq. With no source, only structure and coverage needs are known.
# Exit 0 host pass, 1 fail, 2 usage, 3 preview pass. The owner approves natively, never by text.
#
# Invariants:
# Use committed policy from the trusted default branch, even for other PR targets.
# Exit 0 requires host authority; a would-pass offline preview exits 3.
# A checked online head must be the PR head or a local descendant with equal gated content.
# PR-authored record text does not grant approval. Coverage exemptions do not bypass
# standing owner barriers; only later valid native approval by that actor clears its barrier.
#
# Threat model:
# Include candidate-controlled content and review text, unavailable or partial host reads,
# and revisions moving between runs. Trust the executing code and local Git context;
# this script does not authenticate its own invocation or exclude a hostile checkout writer.
# shellcheck disable=SC2034,SC2153 # Coverage inputs and normalized rows cross sourced interfaces.
set -euo pipefail
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/spec-lib.sh"
source "$SCRIPT_DIR/review-policy-lib.sh"
source "$SCRIPT_DIR/review-fingerprint-lib.sh"
# shellcheck source=scripts/review-coverage-lib.sh
source "$SCRIPT_DIR/review-coverage-lib.sh"
# shellcheck source=scripts/review-receipts-lib.sh
source "$SCRIPT_DIR/review-receipts-lib.sh"
# shellcheck source=scripts/review-owner-lib.sh
source "$SCRIPT_DIR/review-owner-lib.sh"
json=false; diagnostics=false; head_ref=HEAD; base_ref=""; repo=.; id=""
pr_url=""; receipts_file=""; save_receipts=""
usage='Usage: check-review.sh [--json [--diagnostics]] [--head <rev>] [--base <rev>] [--repo <dir>] [--pr <url> [--save-receipts <file>] | --receipts <file>] [<change-id>]'
while [ "$#" -gt 0 ]; do
    case "$1" in
        --json) json=true ;;
        --diagnostics) diagnostics=true ;;
        --pr) shift; [ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }; pr_url="$1" ;;
        --receipts) shift; [ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }; receipts_file="$1" ;;
        --save-receipts) shift; [ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }; save_receipts="$1" ;;
        --head) shift; [ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }; head_ref="$1" ;;
        --base) shift; [ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }; base_ref="$1" ;;
        --repo) shift; [ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }; repo="$1" ;;
        --help|-h) echo "$usage"; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *) [ -z "$id" ] || { echo "$usage" >&2; exit 2; }; id="$1" ;;
    esac
    shift
done
if { [ -n "$pr_url" ] && [ -n "$receipts_file" ]; } || { [ -n "$save_receipts" ] && [ -z "$pr_url" ]; }; then echo "$usage" >&2; exit 2; fi
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
if [ "${PRDKIT_CLOSE_CHECK_HISTORY:-}" = 1 ] && $base_trusted; then
    spec_require_history_tips "$root" "$import_base" || exit 1
fi
trusted_default="$(printf '%s\n' "$approved_refs" | sed -n 1p)"
policy_at=""
[ -z "$trusted_default" ] || policy_at="$(git -C "$root" rev-parse --verify --quiet "$trusted_default^{commit}" || true)"
$base_trusted || import_base=""

problems=(); rows=(); tier=""; rigor=""; record_at=""; record_only=false; start=""; notes=()
d_classes=(); d_cursor=0
diagnostic_capture() {
    $diagnostics || return 0
    while [ "$d_cursor" -lt "${#problems[@]}" ]; do
        d_classes+=("$1"); d_cursor=$((d_cursor+1))
    done
}
sep37="$(printf '\037')"; head_fp=""; fp_ready=false
v_line=(); v_rev=(); v_round=(); v_from=(); v_to=(); v_verdict=(); v_c=(); v_h=(); v_m=(); v_l=(); v_link=()
v_receipt=(); v_receipt_head=()
authority=none; pr_head=""; head_is_pr_head=false; publisher_isolation=""
host_content_bound=false
[ -z "$receipts_file" ] || authority=snapshot
RC_PR=""; RC_PR_HEAD=""; RC_FETCHED=""; RC_IGNORED=0; RC_INVALID=0; RC_CARRIED=0; RC_RECEIPTS=0
receipt_ready=false
RC_SCOPE_BLOCKERS=(); RC_REFERENCES=(); RC_CURRENT_REVIEWERS=(); coverage_standing=(); coverage_clean=(); coverage_end=(); coverage_eligible=()
e_from=(); e_to=(); latest=()
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
    problems+=("No trusted integration base: origin/HEAD does not resolve here, so there is no policy to check against; establish it (git remote set-head origin --auto) with its history fetched$shallow_hint")
elif [ -z "$base_ref" ]; then
    problems+=("No base to find the change's start; pass --base <a trusted integration branch>")
elif ! $base_trusted; then
    problems+=("--base $base_ref is not a trusted integration branch (origin/HEAD's target, or one named by review-integration-branches in its committed config); pass the branch this change merges into")
fi
# Registration must precede use: a change cannot qualify its own maker or invented identity.
registry_at="$policy_at"; registry=""
if [ -n "$registry_at" ]; then
    if ! registry="$( { git -C "$root" show "$registry_at:.prdkit/memory/agents.md" 2>/dev/null || true; } | review_text_stream | review_registry)"; then
        problems+=("Unreadable trusted reviewer policy: expected a ## Review registry table with Identity and Role (reviewer or maker)")
    fi
fi
[ -n "$registry_at" ] || problems+=("No trusted integration-baseline registry: establish origin/HEAD and fetch its shared history before checking reviewer eligibility")
# Rigor: exactly one Rigor line, an empty one included, whose value is light or full followed by
# nothing or a space; anything else (none, two, light/full, light1) is unknown, which fails.
rigor=unknown
if [ -n "$policy_at" ]; then
    rigor="$(read_rigor "$policy_at")"
    [ "$rigor" != unknown ] ||
        problems+=("The trusted base's constitution must name exactly one Rigor, light or full (- **Rigor**: light); fix .prdkit/memory/constitution.md on the integration branch")
fi
# Enumerate blockers even when structural checks fail, at T0, and for record-only changes.
diagnostic_capture structure
if [ -z "$pr_url" ] && [ -z "$receipts_file" ] && [ -n "$policy_at" ]; then
    if review_receipts_policy "$root" "$policy_at"; then publisher_isolation="$RC_ISOLATION"
    else problems+=("$RC_ERROR"); fi
fi
if [ -n "$pr_url" ] || [ -n "$receipts_file" ]; then
    RC_RIGOR="$rigor"
    if ! review_receipts_policy "$root" "$policy_at"; then
        problems+=("$RC_ERROR"); [ -z "$pr_url" ] || authority=unavailable
    else
        publisher_isolation="$RC_ISOLATION"
        if [ -n "$pr_url" ]; then
            authority=unavailable
            if review_receipts_fetch "$pr_url" "$root" "$fp_cache/receipts-work" && review_owner_capture "$fp_cache/receipts-work"; then
                authority=host; receipt_ready=true
            else problems+=("${RC_ERROR:-could not read receipts and owner activity completely}"); fi
        else
            authority=snapshot
            if review_receipts_read "$receipts_file" "$fp_cache/receipts-work"; then receipt_ready=true
            else problems+=("${RC_ERROR:-malformed receipt snapshot}"); fi
        fi
        if $receipt_ready; then
            [ "$authority" != host ] || host_content_bound=true
            pr_head="$RC_PR_HEAD"
            if [ "$authority" = host ] && { ! spec_objects_local "$root" ||
                ! GIT_NO_LAZY_FETCH=1 git -C "$root" merge-base --is-ancestor "$pr_head" "$head" 2>/dev/null; }; then
                problems+=("PR head $pr_head is not a local ancestor of --head $head; fetch the PR head and check it or a metadata-only descendant")
                authority=unavailable; receipt_ready=false
            fi
        fi
        if $receipt_ready; then
            [ "$pr_head" != "$head" ] || head_is_pr_head=true
            if [ "$RC_BASE" != "${base_canonical#refs/remotes/origin/}" ]; then
                host_content_bound=false
                problems+=("the PR merges into $RC_BASE, not --base ${base_canonical#refs/remotes/origin/}")
            fi
            if ! $head_is_pr_head; then
                if ! checked_fp="$(review_fingerprint "$root" "$id" "$fp_base" "$head")" ||
                    ! pr_fp="$(review_fingerprint "$root" "$id" "$fp_base" "$pr_head")" || [ "$checked_fp" != "$pr_fp" ]; then
                    problems+=("PR head does not match the content of --head; use --head <PR head>")
                    host_content_bound=false
                fi
            fi
            if review_receipts_scope "$id" "$rigor" "$registry" "$fp_cache/receipts-work" "$root"; then
                problems+=(${RC_PROBLEMS[@]+"${RC_PROBLEMS[@]}"})
                notes+=(${RC_NOTES[@]+"${RC_NOTES[@]}"})
                if [ -n "$save_receipts" ] && ! review_receipts_write "$save_receipts"; then problems+=("$RC_ERROR"); fi
            else
                problems+=("${RC_ERROR:-could not resolve receipt scope}")
                [ "$authority" != host ] || authority=unavailable
                receipt_ready=false
            fi
        fi
    fi
fi
diagnostic_capture host
if [ "$publisher_isolation" = shared ] && [ "$authority" != host ]; then
    notes+=("Publisher isolation is shared: authentication does not establish the reviewer's independence.")
fi
OWNER_VALID=false; OWNER_REVIEW=""; OWNER_STATE=""; OWNER_COMMIT=""; OWNER_HEAD_AT_SUBMISSION=""; OWNER_ERROR='the owner has no decisive native review on this PR'
OWNER_ACTOR=""; OWNER_APPROVED_COMMIT=""; OWNER_BARRIERS=(); OWNER_PROBLEMS=()
if $receipt_ready; then
    owner_native_approval_valid "$root" "$id" "$fp_base" "$head" || true
    if ! $OWNER_AVAILABLE; then problems+=("$OWNER_ERROR"); authority=unavailable; fi
    problems+=(${OWNER_PROBLEMS[@]+"${OWNER_PROBLEMS[@]}"})
fi
diagnostic_capture owner
if [ -n "$fp_base" ]; then
    if ! record_problem="$(review_record_history "$root" "$id" "$fp_base" "$head" "$fp_cache")"; then
        problems+=("Cannot validate the change record format: fetch the complete local history, trees and record blobs")
    elif [ -n "$record_problem" ]; then problems+=("$record_problem"); fi
fi
diagnostic_capture record-format
# Every **Tier** field in a record on stdin, one per line: T0-T3, or ? when its whole value (up to
# the next · or the end of the line, in optional backticks) is not exactly one tier: T1/T3, T1-T3,
# T1x, "T1, T3" and "T1 T3" are not tiers.
record_tiers() {
    awk "$SPEC_CHANGE_TAG_AWK"'{ s = change_without_tags($0); sub(/\r$/, "", s)
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
    awk "$SPEC_CHANGE_TAG_AWK"'{ s = change_without_tags($0)
        while ((i = index(s, "**Tier**:")) > 0) {
            s = substr(s, i + 9); v = s; j = index(v, "·"); if (j) v = substr(v, 1, j - 1)
            while (match(v, /T[0-3]/)) { print substr(v, RSTART, 2); v = substr(v, RSTART + 2) }
        } }'
}
highest_tier() { grep -x 'T[0-3]' | sort | tail -n 1; } # tiers on stdin -> the highest
tier_floor_of() { # rev -> the highest tier the record names there, if any
    { git -C "$root" show "$1:$path" 2>/dev/null || true; } | floor_tiers | highest_tier || true
}
# T0 is docs only: every changed path outside the record and closing metadata must be a regular,
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
    for file in "$path" .prdkit/history/log.md ".prdkit/history/log/$id.md"; do
        entry="$(GIT_NO_REPLACE_OBJECTS=1 git -C "$root" ls-tree "$1" -- "$file")" || return 1
        case "$entry" in ""|"100644 blob "*) ;; *) printf '%s\n' "$file" ;; esac
    done
}
t0_violations() { # from to
    local allowed raw meta file old new entry ok
    allowed="$(t0_paths "$policy_at")"
    raw="$(LC_ALL=C GIT_NO_REPLACE_OBJECTS=1 git -C "$root" -c core.quotepath=true diff --raw --no-abbrev \
        --no-renames --no-ext-diff --no-textconv --no-color --no-relative --ignore-submodules=none "$1" "$2" -- . \
        ":(top,literal,exclude)$path" ":(top,literal,exclude).prdkit/history/log/$id.md")" || return 1
    while IFS="$(printf '\t')" read -r meta file; do
        [ -n "$meta" ] || continue
        if [ "$file" = .prdkit/history/log.md ] && [ -z "$shared_log_delta" ]; then continue; fi
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
changed_since() { # sha [pathspec...] -> paths changed from sha to head; check the shared log separately
    local sha="$1"; shift
    [ "$#" -gt 0 ] || set -- . ":(exclude)$path" ":(exclude).prdkit/history/log.md" ":(exclude).prdkit/history/log/$id.md"
    git -C "$root" diff --name-only --no-renames --ignore-submodules=none "$sha" "$head" -- "$@" | tr '\n' ' ' | sed 's/ $//'
}

if git -C "$root" cat-file -e "$head:$path" 2>/dev/null; then
    record_at="$head"
elif last="$(git -C "$root" log -1 --format=%H "$head" -- "$path" 2>/dev/null)" && [ -n "$last" ] &&
    git -C "$root" cat-file -e "$last^:$path" 2>/dev/null; then
    record_at="$last^"
fi
if [ -z "$record_at" ]; then
    hint=" (a shallow clone needs the branch history)"
    problems+=("No change record $path at $head or in its history$hint")
elif ! GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 git -C "$root" cat-file blob "$record_at:$path" > "$fp_cache/selected-record" ||
    ! verify_lf_file "$fp_cache/selected-record"; then
    problems+=("$path at $record_at must be readable LF-terminated Markdown")
else
    # Closing a change deletes its record; the same history must add its log entry.
    if [ "$record_at" = "$head" ]; then :
    elif ! log="$(spec_log_entries_at "$root" "$head")"; then
        problems+=("$id is closed (its record is deleted), but the log at $head cannot be read without fetching from the promisor remote (a partial clone with Git older than 2.45): fetch the branch's blobs or use Git 2.45+")
    elif ! grep -q "^- [0-9-]* $id:" <<< "$log"; then
        problems+=("$id is closed (its record is deleted) but the log at $head has no '- <date> $id: <what changed>' entry (.prdkit/history/log/$id.md, as close-change.sh writes it, or its compacted line in .prdkit/history/log.md)")
    elif ! log_mode="$(GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 git -C "$root" ls-tree "$last" -- ".prdkit/history/log/$id.md")" ||
        [[ "$log_mode" != '100644 blob '* ]] ||
        ! GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 git -C "$root" cat-file blob "$last:.prdkit/history/log/$id.md" > "$fp_cache/close-entry" ||
        ! spec_log_entry_valid "$fp_cache/close-entry" "$id"; then
        problems+=("$id was closed without .prdkit/history/log/$id.md at the closing commit; use the current per-change entry format from close-change.sh, not a direct edit to .prdkit/history/log.md")
    fi
    # Closing metadata must be plain files. The per-change entry is its own one line.
    while read -r log_mode log_type log_sha log_path; do
        case "$log_mode $log_type" in
            "100644 blob"|"100755 blob")
                [ "$log_path" != .prdkit/history/log.md ] || continue
                if ! spec_objects_local "$root"; then
                    problems+=("$log_path at $head cannot be checked without fetching from the promisor remote (a partial clone with Git older than 2.45): fetch the branch's blobs or use Git 2.45+")
                    continue
                fi
                if ! GIT_NO_LAZY_FETCH=1 git -C "$root" cat-file blob "$log_sha" > "$fp_cache/head-close-entry" 2>/dev/null ||
                    ! spec_log_entry_valid "$fp_cache/head-close-entry" "$id"; then
                    problems+=("$log_path at $head must hold one line, '- <date> $id: <what changed>', ending in LF")
                fi ;;
            *) problems+=("$log_path at $head is not a regular file; the log and the change's entry are plain files") ;;
        esac
    done < <(GIT_NO_LAZY_FETCH=1 git -C "$root" ls-tree "$head" -- .prdkit/history/log.md ".prdkit/history/log/$id.md" 2>/dev/null)
    record="$(cat "$fp_cache/selected-record")"
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
    # The record and closing metadata are exempt only as regular, non-executable files, where
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
    shared_log_delta=""
    if [ -n "$start" ] &&
        ! shared_log_delta="$(review_delta_stream "$root" "$id" "$start" "$head" ':(top,literal).prdkit/history/log.md')"; then
        shared_log_delta=unreadable
        problems+=("The shared log's diff from ${start:0:12} to $head cannot be checked")
    fi
    if $base_trusted && [ -n "$start" ] && [ "$start" != "$head" ] &&
        [ -z "$shared_log_delta" ] && [ -z "$(changed_since "$start")" ]; then
        record_only=true
    fi
    # All verdicts come from the validated host/snapshot list, in host order.
    v_line=(); v_rev=(); v_round=(); v_from=(); v_to=(); v_verdict=(); v_c=(); v_h=(); v_m=(); v_l=(); v_link=(); v_provenance=()
    if $receipt_ready; then
        while IFS="$sep37" read -r kind seq origin review submitted receipt_id change reviewer from to receipt_head since receipt_base base_at verdict critical high medium low link carried provenance; do
            [ "$kind" = R ] || continue
            ordinal=1
            for prior in ${v_rev[@]+"${v_rev[@]}"}; do [ "$prior" != "$reviewer" ] || ordinal=$((ordinal+1)); done
            v_line+=("$seq"); v_rev+=("$reviewer"); v_round+=("round $ordinal"); v_from+=("$from"); v_to+=("$to")
            v_verdict+=("$verdict"); v_c+=("$critical"); v_h+=("$high"); v_m+=("$medium"); v_l+=("$low"); v_link+=("$link")
            v_receipt+=("https://github.com/$RC_REPO/pull/$origin#pullrequestreview-$review")
            v_receipt_head+=("$receipt_head")
            v_provenance+=("$provenance")
        done < "$RC_COVERAGE"
    fi
    # Each reviewer's latest line, in order of first appearance.
    order=(); latest=()
    for i in ${v_rev[@]+"${!v_rev[@]}"}; do
        found=""
        for k in ${order[@]+"${!order[@]}"}; do [ "${order[k]}" != "${v_rev[i]}" ] || found="$k"; done
        if [ -z "$found" ]; then order+=("${v_rev[i]}"); latest+=("$i"); else latest[found]="$i"; fi
    done
    for i in ${latest[@]+"${latest[@]}"}; do
        rows+=("${v_rev[i]}$sep37${v_round[i]}$sep37${v_from[i]}$sep37${v_to[i]}$sep37${v_verdict[i]}$sep37${v_c[i]}$sep37${v_h[i]}$sep37${v_m[i]}$sep37${v_l[i]}$sep37${v_receipt[i]}")
    done
    case "$claims" in *$'\n'*) ;; *) [ -n "$tier" ] || problems+=("The record names no review tier (**Tier**: T0–T3)") ;; esac
    for i in ${v_rev[@]+"${!v_rev[@]}"}; do
        [ "${v_rev[i]}" != owner ] || continue
        if [ -z "$registry_at" ]; then
            problems+=("${v_receipt[i]}: No trusted integration-baseline registry: establish origin/HEAD and fetch its shared history before checking reviewer eligibility")
        fi
        eligibility="$(review_eligibility "$registry" "${v_rev[i]}")"
        [ "$eligibility" = reviewer ] || problems+=("${v_receipt[i]}: reviewer '${v_rev[i]}' is $eligibility in the integration-baseline registry; use an eligible identity from the ## Review registry table (Identity and Role) in agents.md")
    done

    coverage_record_only="$record_only"
    diagnostic_capture structure
    [ "$tier" != T0 ] || record_only=true
    review_coverage_evaluate
    diagnostic_capture coverage
    owner="$OWNER_VALID"
    record_only="$coverage_record_only"
    if [ "$tier" = T3 ] && ! $record_only && ! $owner && [ "${#OWNER_PROBLEMS[@]}" -eq 0 ]; then problems+=("$OWNER_ERROR"); fi
    diagnostic_capture owner
    # Keep actionable path diagnostics when the publisher's provenance commit is still local.
    # These are diagnostics only; authenticated tokens, never the commits, decide coverage.
    if $fp_ready; then
        for i in ${latest[@]+"${latest[@]}"}; do
            if [ "${v_rev[i]}" = owner ] || [ -z "${v_receipt_head[i]}" ] || ! review_is_fp "${v_to[i]}"; then continue; fi
            if ! covered "${v_to[i]}" && content_of "${v_receipt_head[i]}" full; then
                # shellcheck disable=SC2154 # Stream paths are outputs of the coverage library.
                affected="$(review_stream_paths "$content_stream" "$head_stream" | tr '\n' ' ' | sed 's/ $//')"
                [ -z "$affected" ] || problems+=("${v_rev[i]}: reviewed content differs at: $affected")
            fi
        done
    fi
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
                problems+=("T0 is docs only, and the trusted base's .prdkit/memory/config.md lists no review-t0-paths, so T0 covers only the record and its validated closing metadata; this change also touches: $shown. Claim T1 or higher")
            else
                problems+=("T0 is docs only: these changed paths are not regular files under the trusted base's review-t0-paths (or are policy, another change record or the L0/L1 spec): $shown. Claim T1 or higher")
            fi
        fi
    fi
    diagnostic_capture structure
    review_coverage_require_start
    diagnostic_capture coverage
fi
diagnostic_capture structure

result=pass; [ "${#problems[@]}" -eq 0 ] || result=fail
# Advisory: a reviewed PR-scoped record still at this head would merge open (review.md, Closing).
record_open=false
if [ "$result" = pass ] && [ "$record_at" = "$head" ]; then
    case $'\n'"$(spec_unclosed_changes "$root" "$head")"$'\n' in *$'\n'"$id"$'\n'*) record_open=true ;; esac
fi
if $json; then
    json_result="$result"; [ "$authority" = host ] || json_result=preview
    printf '{"result":"%s","change":"%s","head":"%s","fingerprint":"%s","base":"%s","base_trusted":%s,"policy_at":"%s","record_only":%s,"record_open":%s,"tier":"%s","rigor":"%s","record_at":"%s","reviews":[' \
        "$json_result" "$id" "$head" "$head_fp" "$(json_escape "$base_ref")" "$base_trusted" "$policy_at" "$record_only" "$record_open" "$tier" "$rigor" "$(json_escape "$record_at")"
    sep=""
    for row in ${rows[@]+"${rows[@]}"}; do
        IFS="$(printf '\037')" read -r reviewer round from to verdict critical high medium low receipt_url <<< "$row"
        printf '%s{"reviewer":"%s","round":"%s","range":"%s","verdict":"%s","critical":"%s","high":"%s","medium":"%s","low":"%s","receipt":"%s"}' "$sep" \
            "$(json_escape "$reviewer")" "$(json_escape "$round")" "$(json_escape "$from..$to")" "$(json_escape "$verdict")" \
            "$(json_escape "$critical")" "$(json_escape "$high")" "$(json_escape "$medium")" "$(json_escape "$low")" "$(json_escape "$receipt_url")"
        sep=,
    done
    printf '],"registry_at":"%s","authority":"%s","pr":"%s","pr_head":"%s","head_is_pr_head":%s,"publisher_isolation":"%s","receipts":%s,"ignored_receipts":%s,"invalid_receipts":%s,"carried_blockers":%s,"owner":%s,"problems":%s' \
        "$registry_at" "$authority" "$(json_escape "${pr_url:-${RC_PR:+https://github.com/$RC_REPO/pull/$RC_PR}}")" "$pr_head" "$head_is_pr_head" "$publisher_isolation" \
        "$RC_RECEIPTS" "$RC_IGNORED" "$RC_INVALID" "$RC_CARRIED" "$(review_owner_json)" "$(json_array ${problems[@]+"${problems[@]}"})"
    if $diagnostics; then
        printf ',"diagnostics":{"base_ref":"%s","base_at":"%s","policy_at":"%s","head":"%s","host_content_bound":%s,"fetched":"%s","receipt_ready":%s,"start_covered":' \
            "$(json_escape "$base_canonical")" "$import_base" "$policy_at" "$head" "$host_content_bound" "$RC_FETCHED" "$receipt_ready"
        if $fp_ready; then covered "$REVIEW_FP_EMPTY" && printf true || printf false; else printf null; fi
        printf ',"registry":['; sep=""
        while IFS="$sep37" read -r identity role line; do
            [ -n "$identity" ] || continue
            printf '%s{"reviewer":"%s","eligibility":"%s"}' "$sep" "$(json_escape "$identity")" "$(review_eligibility "$registry" "$identity")"; sep=,
        done <<< "$registry"
        printf '],"edges":['
        sep=""
        for k in ${e_from[@]+"${!e_from[@]}"}; do
            printf '%s{"from":"%s","to":"%s"}' "$sep" "${e_from[k]}" "${e_to[k]}"; sep=,
        done
        printf '],"latest":['; sep=""
        for i in ${latest[@]+"${latest[@]}"}; do
            standing=false
            for k in ${coverage_standing[@]+"${coverage_standing[@]}"}; do [ "${v_rev[k]}" != "${v_rev[i]}" ] || standing=true; done
            printf '%s{"reviewer":"%s","eligibility":"%s","receipt":"%s","from":"%s","to":"%s","clean":%s,"end_covered":%s,"standing":%s,"provenance":"%s"}' \
                "$sep" "$(json_escape "${v_rev[i]}")" "$(review_eligibility "$registry" "${v_rev[i]}")" "$(json_escape "${v_receipt[i]}")" \
                "${v_from[i]}" "${v_to[i]}" "${coverage_clean[i]:-false}" "${coverage_end[i]:-false}" "$standing" "${v_provenance[i]}"
            sep=,
        done
        printf '],"standing":['; sep=""
        for i in ${coverage_standing[@]+"${coverage_standing[@]}"}; do
            printf '%s{"reviewer":"%s","to":"%s","receipt":"%s"}' "$sep" "$(json_escape "${v_rev[i]}")" "${v_to[i]}" "$(json_escape "${v_receipt[i]}")"; sep=,
        done
        printf '],"scope_blockers":['; sep=""
        for k in ${RC_SCOPE_BLOCKERS[@]+"${!RC_SCOPE_BLOCKERS[@]}"}; do
            row="${RC_SCOPE_BLOCKERS[k]}"
            IFS="$sep37" read -r kind seq origin review submitted receipt_id change reviewer from to rest <<< "$row"
            printf '%s{"reviewer":"%s","change":"%s","origin_pr":"%s","to":"%s","receipt":"%s","full_required":%s}' "$sep" \
                "$(json_escape "$reviewer")" "$change" "$origin" "$to" "https://github.com/$RC_REPO/pull/$origin#pullrequestreview-$review" "${RC_FULL_REQUIRED[k]}"; sep=,
        done
        printf '],"references":%s,"current_reviewers":%s,"current_pr":"%s","problem_classes":%s}' \
            "$(json_array ${RC_REFERENCES[@]+"${RC_REFERENCES[@]}"})" \
            "$(json_array ${RC_CURRENT_REVIEWERS[@]+"${RC_CURRENT_REVIEWERS[@]}"})" "$RC_PR" "$(json_array ${d_classes[@]+"${d_classes[@]}"})"
    fi
    printf '}\n'
elif [ "$result" = pass ]; then
    if $record_only; then
        printf 'PASS %s at %s: since %s it carries only the record and the log; %s recorded verdict(s), none blocking; no covering receipt needed on this PR.\n' "$id" "$head" "$base_ref" "${#rows[@]}"
    elif [ "$tier" = T0 ]; then
        printf 'PASS %s at %s: tier T0 needs no independent review. All changes outside the change record and validated closing metadata passed the trusted T0 path check (review-t0-paths). %s recorded verdict(s), none blocking. Review coverage was not required.\n' "$id" "$head" "${#rows[@]}"
    else
        printf 'PASS %s at %s: %s, Rigor %s; %s recorded verdict(s) cover this head.\n' "$id" "$head" "$tier" "$rigor" "${#rows[@]}"
    fi
    for note in ${notes[@]+"${notes[@]}"}; do printf '%s\n' "$note"; done
    ! $record_open || printf 'Note: %s is still at this head; if this PR completes the change, close it before merge: .prdkit/scripts/bash/close-change.sh --pr <url> %s "<log line>" (review.md, Closing).\n' "$path" "$id"
else
    printf 'FAIL %s at %s:\n' "$id" "$head"
    for problem in "${problems[@]}"; do printf '  %s\n' "$problem"; done
    for note in ${notes[@]+"${notes[@]}"}; do printf '%s\n' "$note"; done
fi
if ! $json && [ "$authority" != host ]; then printf 'PREVIEW: authority=%s fetched=%s; only an online check can certify that no blocker stands.\n' "$authority" "${RC_FETCHED:-none}"; fi
[ "$result" = pass ] || exit 1
[ "$authority" = host ] || exit 3
