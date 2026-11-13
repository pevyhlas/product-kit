#!/usr/bin/env bash
# check-review.sh — Before merging a change, check that its recorded independent review covers
# the head being merged. Reads committed state only: the change record's tier and its State
# `**Review**:` lines, and the policy (Rigor, reviewer registry, T0 paths) at the tip of the
# trusted default branch, never the head's own copy, with local git. Needs no network and no model
# credentials, so the merging agent and CI can both run it. It checks recorded verdicts; it does
# not review, and it never grants merge authority.
#
# A record line, one per verdict, appended in order; a later line supersedes the same reviewer's
# earlier one whatever its round number. Both ends of the range are commit hashes:
#   **Review**: round <n> · <base sha>..<head sha> · <reviewer> · PASS|FAIL · <c> critical, <h> high, <m> medium, <l> low · <link>
# The owner's line (reviewer `owner`, T3) needs PASS and the head the owner approved; it may omit
# the counts, which are not read. The link is always the last field. The record is read at the
# head, or, when the closing commit deleted it, from the last commit that still had it.
#
# Every reviewer's latest verdict, in any tier, must be PASS with nothing blocking for the Rigor.
# A blocking line (a FAIL, or counts that block for the Rigor or cannot be read) stands until a
# later non-blocking PASS from the same reviewer, over a non-empty range, reaches its head; only
# then does its range link. A blocking head that is not a commit hash always stands; one gone
# from the history (rebased or squashed away) is ignored. Every non-blocking PASS range,
# superseded rounds included, links. A point is covered when links chain from it (each starting
# at or before a head already reached) to a head after which only the record and the log (specs/log.md,
# specs/log/<id>.md) changed, or through verified imports from the trusted base that preserve the exact branch
# delta (modes, blob IDs and paths). Overlapping source edits/resolutions remain uncovered.
# Each reviewer's head must be covered, and for
# T1-T3 so must the change's start (its merge base with --base). A merge carrying only the record
# and the log from a trusted start (a change closed after its code merged) skips coverage. T1-T3
# need one independent verdict, T3 the owner's too, and no L0/L1 spec edit since the owner's head.
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

problems=(); rows=(); links=(); all_reviews=(); tier=""; rigor=""; record_at=""; record_only=false; start=""; notes=()
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
# Exact tree-entry deltas, without rename heuristics, external diff drivers, textconv or
# whitespace normalization. Git quotes control characters in paths; no NUL data enters Bash.
delta_signature() { # from to pathspec...
    local from="$1" to="$2"; shift 2
    git -C "$root" -c core.quotepath=true diff --no-ext-diff --no-textconv --no-renames \
        --ignore-submodules=none --raw --no-abbrev "$from" "$to" -- "$@"
}
unchanged_since() { # sha [pathspec...] -> covered without another review of this delta
    local sha="$1" delta merges cursor parents first second extra common before after
    shift
    [ "$#" -gt 0 ] || set -- . ":(exclude)$path" ":(exclude)specs/log.md" ":(exclude)specs/log/$id.md"
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
            # The link is the last field: after the counts, or after the verdict on an owner line.
            link = (n > (reviewer == "owner" ? 4 : 5)) ? trim(f[n]) : ""
            print "\035" NR "\037" reviewer "\037" from "\037" to "\037" verdict "\037" count(f[5], "critical") "\037" count(f[5], "high") "\037" count(f[5], "medium") "\037" count(f[5], "low") "\037" link
            if (reviewer != "owner" && (verdict == "PASS" || verdict == "FAIL")) print "\036" reviewer "\037" trim(f[1]) "\037" verdict "\037" from "\037" to "\037" count(f[5], "critical") "\037" count(f[5], "high") "\037" count(f[5], "medium")
            if (!(reviewer in row)) order[++k] = reviewer
            row[reviewer] = reviewer "\037" trim(f[1]) "\037" from "\037" to "\037" verdict "\037" count(f[5], "critical") "\037" count(f[5], "high") "\037" count(f[5], "medium") "\037" count(f[5], "low")
        }
        END { for (i = 1; i <= k; i++) print row[order[i]] }')
    case "$claims" in *$'\n'*) ;; *) [ -n "$tier" ] || problems+=("The record names no review tier (**Tier**: T0–T3)") ;; esac
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
                problems+=("$label: $n $kind finding(s) block: the trusted base's constitution names no single Rigor (light or full), so medium blocks")
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
# Advisory: a reviewed PR-scoped record still at this head would merge open (review.md, Closing).
record_open=false
if [ "$result" = pass ] && [ "$record_at" = "$head" ]; then
    case $'\n'"$(spec_unclosed_changes "$root" "$head")"$'\n' in *$'\n'"$id"$'\n'*) record_open=true ;; esac
fi
if $json; then
    printf '{"result":"%s","change":"%s","head":"%s","base":"%s","base_trusted":%s,"policy_at":"%s","record_only":%s,"record_open":%s,"tier":"%s","rigor":"%s","record_at":"%s","reviews":[' \
        "$result" "$id" "$head" "$(json_escape "$base_ref")" "$base_trusted" "$policy_at" "$record_only" "$record_open" "$tier" "$rigor" "$(json_escape "$record_at")"
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
