#!/usr/bin/env bash
# record-review.sh — Record one review verdict: append its **Review** line to the State section of
# the working-tree record specs/changes/<change-id>.md, bound to content fingerprints the script
# computes (review-fingerprint-lib.sh), and print the line and the v2 receipt for the PR report
# comment. The only writer of Review lines; nobody types a fingerprint. It does not commit.
#
# The range runs from `start` (the whole change), or with --since from the content of an earlier
# reviewed head (any commit with that content, also one a rebase or squash left behind), to the
# content of --head, both against --base. The owner (reviewer `owner`) approves the L0/L1 spec:
# their line binds that slice's fingerprint, always from `start`, and needs no counts.
#
# Usage: record-review.sh <change-id> --reviewer <identity> --verdict PASS|FAIL --link <url>
#          --head <rev> [--since <rev>] [--counts <critical>,<high>,<medium>,<low>]
#          [--round <n>] [--base <ref>] [--repo <dir>]
#   --base defaults to origin/HEAD and must be a trusted integration branch, as check-review.sh
#   decides (origin/HEAD's target or a review-integration-branches entry in its committed config).
#   --round defaults to 1 + the reviewer's Review lines already in State.
#   Exit 0 recorded, 1 refused, 2 usage.
set -euo pipefail
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/spec-lib.sh"
source "$SCRIPT_DIR/review-fingerprint-lib.sh"
usage='Usage: record-review.sh <change-id> --reviewer <identity> --verdict PASS|FAIL --link <url> --head <rev> [--since <rev>] [--counts <critical>,<high>,<medium>,<low>] [--round <n>] [--base <ref>] [--repo <dir>]'
id=""; reviewer=""; verdict=""; link=""; head_ref=""; since_ref=""; counts=""; round=""; base_ref=""; repo=.
while [ "$#" -gt 0 ]; do
    case "$1" in
        --reviewer|--verdict|--link|--head|--since|--counts|--round|--base|--repo)
            [ "$#" -ge 2 ] || { echo "$usage" >&2; exit 2; }
            case "$1" in
                --reviewer) reviewer="$2" ;; --verdict) verdict="$2" ;; --link) link="$2" ;;
                --head) head_ref="$2" ;; --since) since_ref="$2" ;; --counts) counts="$2" ;;
                --round) round="$2" ;; --base) base_ref="$2" ;; --repo) repo="$2" ;;
            esac
            shift ;;
        --help|-h) echo "$usage"; exit 0 ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *) [ -z "$id" ] || { echo "$usage" >&2; exit 2; }; id="$1" ;;
    esac
    shift
done
[ -n "$id" ] && [ -n "$reviewer" ] && [ -n "$verdict" ] && [ -n "$head_ref" ] || { echo "$usage" >&2; exit 2; }
refuse() { echo "record-review.sh: $*" >&2; exit 1; }
is_change_id "$id" || refuse "expected a change id such as 004-export-csv (got: $id)"
[[ "$reviewer" =~ ^[a-z0-9][a-z0-9_.-]*$ ]] || refuse "reviewer '$reviewer' is not a registry identity (lowercase letters, digits, _ . -)"
verdict="$(printf '%s' "$verdict" | tr '[:lower:]' '[:upper:]')"
case "$verdict" in PASS|FAIL) ;; *) refuse "the verdict is PASS or FAIL (got: $verdict)" ;; esac
case "$link" in
    "") refuse "--link names the report (the PR comment that carries it)" ;;
    *" · "*|*$'\n'*|*$'\r'*) refuse "the link must be one field: no ' · ' and no line break" ;;
esac
owner=false; [ "$reviewer" != owner ] || owner=true
critical=""; high=""; medium=""; low=""
if [ -n "$counts" ]; then
    [[ "$counts" =~ ^[0-9]+,[0-9]+,[0-9]+,[0-9]+$ ]] || refuse "--counts is <critical>,<high>,<medium>,<low>, four non-negative integers (got: $counts)"
    IFS=, read -r critical high medium low <<< "$counts"
    critical=$((10#$critical)); high=$((10#$high)); medium=$((10#$medium)); low=$((10#$low))
elif ! $owner; then
    refuse "--counts is required: the reviewer's <critical>,<high>,<medium>,<low> findings"
fi
if [ -n "$round" ]; then [[ "$round" =~ ^[1-9][0-9]*$ ]] || refuse "--round is a positive integer (got: $round)"; fi
! $owner || [ -z "$since_ref" ] || refuse "the owner approves the L0/L1 spec as a whole; --since is for a reviewer's narrow re-review"

root="$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null)" || refuse "not inside a Git checkout: $repo"
head="$(git -C "$root" rev-parse --verify --quiet "$head_ref^{commit}")" || refuse "not a commit here: $head_ref"
since=""
[ -z "$since_ref" ] || since="$(git -C "$root" rev-parse --verify --quiet "$since_ref^{commit}")" || refuse "not a commit here: $since_ref"
# The same trust decision as check-review.sh: only origin/HEAD's target or a configured
# integration branch, by its canonical full name, is a base.
[ -n "$base_ref" ] || base_ref=origin/HEAD
git -C "$root" rev-parse --verify --quiet "$base_ref^{commit}" >/dev/null || refuse "not a commit here: $base_ref (establish origin/HEAD: git remote set-head origin --auto)"
canonical="$(git -C "$root" rev-parse --symbolic-full-name "$base_ref" 2>/dev/null || true)"
if [ -z "$canonical" ] || ! spec_trusted_refs "$root" | grep -qxF -- "$canonical"; then
    refuse "--base $base_ref is not a trusted integration branch (origin/HEAD's target, or one named by review-integration-branches in its committed config); pass the branch this change merges into"
fi

record="$root/specs/changes/$id.md"
[ -f "$record" ] && [ ! -L "$record" ] || refuse "no change record specs/changes/$id.md in this checkout (a regular file)"
sections="$(awk "$SPEC_SKIP_AWK"'{ if (spec_skip($0)) next } /^## / { s = $0; sub(/^##[[:space:]]+/, "", s); if (s == "State") n++ } END { print n + 0 }' "$record")"
[ "$sections" = 1 ] || refuse "specs/changes/$id.md needs exactly one '## State' section to record into (found $sections)"

fingerprint() { # rev -> sets fp, or refuses
    if $owner; then review_fingerprint "$root" "$id" "$canonical" "$1" "${REVIEW_L01_PATHSPECS[@]}" >/dev/null || refuse "$REVIEW_FP_ERROR"
    else review_fingerprint "$root" "$id" "$canonical" "$1" >/dev/null || refuse "$REVIEW_FP_ERROR"; fi
    fp="$REVIEW_FP"
}
fingerprint "$head"; to="$fp"
from=start
if [ -n "$since" ]; then fingerprint "$since"; [ "$fp" = "$REVIEW_FP_EMPTY" ] || from="$fp"; fi
from_fp="$from"; [ "$from" != start ] || from_fp="$REVIEW_FP_EMPTY"
if ! $owner && [ "$from_fp" = "$to" ]; then
    if [ -n "$since" ]; then refuse "nothing changed since --since $since_ref; no round needed"
    else refuse "the change has no content at $head_ref against $base_ref; nothing to review"; fi
fi

if [ -z "$round" ]; then
    previous="$(RR_WHO="$reviewer" awk "$SPEC_SKIP_AWK"'
        function trim(s) { gsub(/`/, "", s); gsub(/^[[:space:]]+|[[:space:]]+$/, "", s); return s }
        { if (spec_skip($0)) next }
        /^## / { sec = $0; sub(/^##[[:space:]]+/, "", sec); next }
        sec == "State" && /^\*\*Review\*\*:/ {
            line = $0; sub(/^\*\*Review\*\*:[[:space:]]*/, "", line)
            if (split(line, f, " · ") >= 3 && tolower(trim(f[3])) == ENVIRON["RR_WHO"]) n++
        }
        END { print n + 0 }' "$record")"
    round=$((previous + 1))
fi
fields="$verdict"
[ -z "$critical" ] || fields="$fields · $critical critical, $high high, $medium medium, $low low"
line="**Review**: round $round · $from..$to · $reviewer · $fields · $link"

# Append after the State section's last line outside a comment or fence.
tmp="$(mktemp "$record.XXXXXX")" || refuse "cannot write next to specs/changes/$id.md"
if ! RR_ENTRY="$line" awk "$SPEC_SKIP_AWK"'
    { text[NR] = $0; if (spec_skip($0)) next }
    /^## / { s = $0; sub(/^##[[:space:]]+/, "", s)
        if (inside) inside = 0
        if (s == "State") { inside = 1; at = NR }
        next }
    inside && $0 !~ /^[[:space:]]*$/ { at = NR }
    END {
        for (i = 1; i <= NR; i++) {
            print text[i]
            if (i == at) { if (text[at] ~ /^## /) print ""; print ENVIRON["RR_ENTRY"] }
        }
    }' "$record" > "$tmp"; then
    rm -f "$tmp"; refuse "could not rewrite specs/changes/$id.md"
fi
if ! chmod 644 "$tmp" || ! mv "$tmp" "$record"; then rm -f "$tmp"; refuse "could not replace specs/changes/$id.md"; fi

printf '%s\n' "$line"
printf '<!-- prdkit-review\n{"schema":"prdkit.review.v2","reviewer":"%s","from":"%s","to":"%s","head":"%s","verdict":"%s"' \
    "$reviewer" "$from" "$to" "$head" "$verdict"
$owner || printf ',"critical":%s,"high":%s,"medium":%s,"low":%s' "$critical" "$high" "$medium" "$low"
printf '}\n-->\n'
