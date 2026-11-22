#!/usr/bin/env bash
# Only an online, complete review collection can pass. Policy is read from origin/HEAD.
#
# Invariants:
# Use committed policy from the trusted default branch, even for other PR targets.
# Exit 0 requires host authority; a would-pass offline preview exits 3.
# Require the exact PR head, its effective tier's approvals and no eligible open objection.
# PR-authored record text does not grant approval.
#
# Threat model:
# Include candidate-controlled content and review text, unavailable or partial host reads,
# and revisions moving between runs. Trust the executing code and local Git context;
# this script does not authenticate its own invocation or exclude a hostile checkout writer.
set -euo pipefail
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/spec-lib.sh"
source "$SCRIPT_DIR/review-policy-lib.sh"
source "$SCRIPT_DIR/github-reviews-lib.sh"
json=false; diagnostics=false; head_ref=HEAD; base_ref=""; repo=.; id=""
pr_url=""; online=false
usage='Usage: check-review.sh [--json [--diagnostics]] [--head <rev>] [--base <rev>] [--repo <dir>] [--pr <url>] [<change-id>]'
while [ "$#" -gt 0 ]; do
    case "$1" in
        --json) json=true ;;
        --diagnostics) diagnostics=true ;;
        --pr) shift; [ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }; pr_url="$1"; online=true ;;
        --head) shift; [ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }; head_ref="$1" ;;
        --base) shift; [ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }; base_ref="$1" ;;
        --repo) shift; [ "$#" -gt 0 ] || { echo "$usage" >&2; exit 2; }; repo="$1" ;;
        --help|-h) echo "$usage"; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *) [ -z "$id" ] || { echo "$usage" >&2; exit 2; }; id="$1" ;;
    esac
    shift
done
root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || { echo "Not inside a Git checkout: $repo" >&2; exit 2; }
[ -n "$id" ] || id="$(git -C "$root" symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
is_change_id "$id" || { echo "Expected a change id such as 004-export-csv (got: ${id:-none}); pass it explicitly" >&2; exit 2; }
head="$(git -C "$root" rev-parse --verify --quiet "$head_ref^{commit}")" || { echo "Not a commit here: $head_ref" >&2; exit 2; }
# Policy comes from the trusted default branch, never from the change or the caller. The policy
# snapshot is origin/HEAD's current tip: Rigor, eligible GitHub accounts and the T0 paths are read
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

problems=(); tier=""; record_at=""; record_only=false; start=""
authority=none; pr_head=""; approvals='[]'; blocking='[]'; head_is_pr_head=false
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
if [ -z "$policy_at" ]; then
    problems+=("No trusted integration base: origin/HEAD does not resolve here, so there is no policy to check against; establish it (git remote set-head origin --auto) with its history fetched")
elif [ -z "$base_ref" ]; then
    problems+=("No base to find the change's start; pass --base <a trusted integration branch>")
elif ! $base_trusted; then
    problems+=("--base $base_ref is not a trusted integration branch (origin/HEAD's target, or one named by review-integration-branches in its committed config); pass the branch this change merges into")
fi
# Rigor: exactly one Rigor line, an empty one included, whose value is light or full followed by
# nothing or a space; anything else (none, two, light/full, light1) is unknown, which fails.
rigor=unknown
if [ -n "$policy_at" ]; then
    rigor="$(read_rigor "$policy_at")"
    [ "$rigor" != unknown ] ||
        problems+=("The trusted base's constitution must name exactly one Rigor, light or full (- **Rigor**: light); fix .prdkit/memory/constitution.md on the integration branch")
fi
if $online; then authority=unavailable; fi
if ! github_review_policy "$root" "$policy_at"; then problems+=("$RC_ERROR")
elif $online; then
    if github_review_fetch "$pr_url" "$work" "$head" "${base_canonical#refs/remotes/origin/}"; then
        authority=host; head_is_pr_head=true
    else problems+=("$RC_ERROR"); fi
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
    for file in "$path" specs/log.md "specs/log/$id.md"; do
        entry="$(GIT_NO_REPLACE_OBJECTS=1 git -C "$root" ls-tree "$1" -- "$file")" || return 1
        case "$entry" in ""|"100644 blob "*) ;; *) printf '%s\n' "$file" ;; esac
    done
}
_review_blob_text() { # root blob file
    local size kept
    GIT_NO_REPLACE_OBJECTS=1 git -C "$1" cat-file blob "$2" > "$3" 2>/dev/null || return 2
    size="$(set -o pipefail; wc -c < "$3" | tr -d ' ')" || return 2
    kept="$(set -o pipefail; tr -d '\000' < "$3" | wc -c | tr -d ' ')" || return 2
    [ -n "$size" ] && [ -n "$kept" ] || return 2
    [ "$size" = "$kept" ]
}

# A legacy shared-log close is metadata only if the selected record was deleted in this
# range, there is no per-change entry, and exactly one well-formed line was added for it.
# Return the blob ID of the log without that line, or fail to keep the original log delta.
_review_shared_log_without_close() { # root id start rev old-mode old-id new-id oldtext newtext deletion-text
    local root="$1" id="$2" start="$3" rev="$4" oldmode="$5" last entry lines deletion_lines
    local record="specs/changes/$id.md" own="specs/log/$id.md"
    is_change_id "$id" && spec_objects_local "$root" || return 1
    [ "$(git -C "$root" ls-tree "$rev" -- "$record" "$own" || echo unreadable)" = "" ] &&
        [ "$(git -C "$root" ls-tree "$start" -- "$own" || echo unreadable)" = "" ] || return 1
    last="$(git -C "$root" log -1 --format=%H "$start..$rev" -- "$record")" && [ -n "$last" ] || return 1
    entry="$(git -C "$root" ls-tree "$last^" -- "$record")" || return 1
    case "$entry" in "100644 blob "*) ;; *) return 1 ;; esac
    entry="$(git -C "$root" ls-tree "$last" -- specs/log.md)" || return 1
    case "$entry" in "100644 blob "*) ;; *) return 1 ;; esac
    _review_blob_text "$root" "$last:specs/log.md" "${10}" || return 1
    deletion_lines="$(wc -l < "${10}")" || return 1

    if [ "$oldmode" = 000000 ]; then : > "$8" || return 1
    else _review_blob_text "$root" "$6" "$8" || return 1; fi
    _review_blob_text "$root" "$7" "$9" || return 1
    lines="$(wc -l < "$9")" || return 1
    # Preserve every other byte, including a missing final newline on a retained line.
    ( set -o pipefail
      LC_ALL=C awk -v id="$id" -v lines="$lines" -v deletion_lines="$deletion_lines" '
        BEGIN { key = "^- [0-9-]+ " id ":" }
        FILENAME == ARGV[1] { if ($0 ~ key) old++; next }
        FILENAME == ARGV[2] {
            if ($0 ~ key) { at_close++; original=$0; terminated=(FNR <= deletion_lines) }
            next
        }
        $0 ~ key {
            n++
            if ($0 != original || terminated != (FNR <= lines)) next
            text=$0
            if (FNR <= lines) sub(/\r$/, "", text)
            if (text !~ /\r/ && text ~ ("^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] " id ": .*[^[:space:]]")) valid++
            next
        }
        { printf "%s%s", $0, (FNR <= lines ? "\n" : "") }
        END { exit (old || at_close != 1 || n != 1 || valid != 1) }
      ' "$8" "${10}" "$9" | git -C "$root" hash-object --no-filters --stdin )
}

t0_violations() { # from to
    local allowed raw meta file old new entry ok
    allowed="$(t0_paths "$policy_at")"
    raw="$(LC_ALL=C GIT_NO_REPLACE_OBJECTS=1 git -C "$root" -c core.quotepath=true diff --raw --no-abbrev \
        --no-renames --no-ext-diff --no-textconv --no-color --no-relative --ignore-submodules=none "$1" "$2" -- . \
        ":(top,literal,exclude)$path" ":(top,literal,exclude)specs/log/$id.md")" || return 1
    while IFS="$(printf '\t')" read -r meta file; do
        [ -n "$meta" ] || continue
        if [ "$file" = specs/log.md ] && [ -z "$shared_log_delta" ]; then continue; fi
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
path="specs/changes/$id.md"
spec_l01=(specs/product.md specs/product specs/architecture.md specs/architecture specs/SPEC.md specs/decisions)
changed_since() { # sha [pathspec...] -> paths changed from sha to head; check the shared log separately
    local sha="$1"; shift
    [ "$#" -gt 0 ] || set -- . ":(exclude)$path" ":(exclude)specs/log.md" ":(exclude)specs/log/$id.md"
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
    # Each log path must be a plain file. The per-change entry is exactly one line.
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
    record="$(git -C "$root" show "$record_at:$path" | review_text_stream)" || { echo "Unreadable change record: $path" >&2; exit 1; }
    # The tier is the record's single **Tier** field; a second one, even in a comment, is refused.
    claims="$(printf '%s\n' "$record" | record_tiers)"
    case "$claims" in
        T[0-3]) tier="$claims" ;;
        *$'\n'*) problems+=("The record names more than one review tier ($(printf '%s' "$claims" | tr '\n' ' ')); keep exactly one **Tier** field") ;;
        *) problems+=("The record names no review tier (**Tier**: T0–T3)") ;;
    esac
    # The merge base bounds the effective tier and docs-only path checks.
    if [ -n "$base_ref" ] && bases="$(git -C "$root" merge-base --all "$base_ref" "$head" 2>/dev/null)"; then
        if [[ "$bases" == *$'\n'* ]]; then
            problems+=("$base_ref and $head have multiple merge bases; merge the target into the branch to establish one change start")
        elif [[ "$bases" =~ ^([0-9a-f]{40}|[0-9a-f]{64})$ ]]; then
            start="$bases"
        fi
    fi
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
    # The record and the log are valid only as regular, non-executable files, where
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
    if [ -n "$start" ]; then
        if ! shared_log_delta="$(git -C "$root" diff --raw --no-abbrev --no-renames "$start" "$head" -- specs/log.md)"; then
            shared_log_delta=unreadable
            problems+=("The shared log's diff from ${start:0:12} to $head cannot be checked")
        elif [ -n "$shared_log_delta" ]; then
            read -r old new oid nid _ <<< "${shared_log_delta#:}"
            case "$old:$new" in 000000:100644|100644:100644)
                if normalized="$(_review_shared_log_without_close "$root" "$id" "$start" "$head" "$old" "$oid" "$nid" "$work/old" "$work/new" "$work/deletion")"; then
                    if [ "$old" = 000000 ]; then oid="$(git -C "$root" hash-object --stdin < /dev/null)"; fi
                    [ "$normalized" != "$oid" ] || shared_log_delta=""
                fi ;;
            esac
        fi
    fi
    if $base_trusted && [ -n "$start" ] && [ "$start" != "$head" ] &&
        [ -z "$shared_log_delta" ] && [ -z "$(changed_since "$start")" ]; then
        record_only=true
    fi
    if [ "$tier" = T0 ] && ! $record_only && [ -n "$policy_at" ] && [ -n "$start" ]; then
        # The tier is checked, not taken as the record's claim.
        if ! t0_bad="$(t0_violations "$start" "$head")"; then
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
    if [ -z "$start" ] || [ "$start" = "$head" ]; then
        problems+=("No change range from $base_ref to $head")
    fi
fi
# Apply the minimum to the effective tier, after trusted floor and path validation.
if [ "$authority" = host ]; then
    if [ "$blocking" != '[]' ]; then
        problems+=("Outstanding CHANGES_REQUESTED: $(jq -r 'map("\(.role) \(.reviewer) (review \(.review) on \(.commit))") | join(", ")' <<< "$blocking")")
    fi
    case "$tier" in T1|T2|T3)
        jq -e 'any(.[]; .role=="publisher")' <<< "$approvals" >/dev/null ||
            problems+=("$tier requires an independent review-publishers APPROVED review on the exact PR head $head")
        if [ "$tier" = T3 ]; then
            jq -e 'any(.[]; .role=="owner")' <<< "$approvals" >/dev/null ||
                problems+=("T3 also requires a review-owner APPROVED review on the exact PR head $head")
        fi ;;
    esac
fi
result=pass; [ "${#problems[@]}" -eq 0 ] || result=fail
# Advisory: a reviewed PR-scoped record still at this head would merge open (review.md, Closing).
record_open=false
if [ "$result" = pass ] && [ "$record_at" = "$head" ]; then
    case $'\n'"$(spec_unclosed_changes "$root" "$head")"$'\n' in *$'\n'"$id"$'\n'*) record_open=true ;; esac
fi
if $json; then
    json_result="$result"; [ "$authority" = host ] || json_result=preview
    printf '{"result":"%s","change":"%s","head":"%s","base":"%s","base_trusted":%s,"policy_at":"%s","record_only":%s,"record_open":%s,"tier":"%s","rigor":"%s","record_at":"%s","reviews":%s,' \
        "$json_result" "$id" "$head" "$(json_escape "$base_ref")" "$base_trusted" "$policy_at" "$record_only" "$record_open" "$tier" "$rigor" "$(json_escape "$record_at")" "$approvals"
    printf '"blocking":%s,"authority":"%s","pr":"%s","pr_head":"%s","head_is_pr_head":%s,"problems":%s' \
        "$blocking" "$authority" "$(json_escape "$pr_url")" "$pr_head" "$head_is_pr_head" "$(json_array ${problems[@]+"${problems[@]}"})"
    if $diagnostics; then
        printf ',"diagnostics":{"base_ref":"%s","base_at":"%s","policy_at":"%s","head":"%s"}' \
            "$(json_escape "$base_canonical")" "$import_base" "$policy_at" "$head"
    fi
    printf '}\n'
elif [ "$result" = pass ]; then
    if $online; then printf 'PASS %s: %s review minimum met on %s.\n' "$id" "$tier" "$head"
    else printf 'PREVIEW %s: local structure checked; use --pr for approval.\n' "$id"; fi
    ! $record_open || printf 'Note: %s is still at this head.\n' "$path"
else
    printf 'FAIL %s at %s:\n' "$id" "$head"
    printf '  %s\n' "${problems[@]}"
fi
[ "$result" = pass ] || exit 1
[ "$authority" = host ] || exit 3
