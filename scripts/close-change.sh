#!/usr/bin/env bash
# close-change.sh — Close a reviewed change in its own PR with one commit: refuse unless
# check-review.sh passes at HEAD, then add the change's specs/log.md line and delete its record.
# Run it once the final Review line is committed and before the final push, so required checks
# run once on the closed head. It commits in the current checkout only; it never pushes, merges
# or removes a worktree (cleanup-change.sh does that after merge).
#
# Usage: close-change.sh [--base <rev>] [--date YYYY-MM-DD] [-m <message>] <change-id> "<log text>"
#   <log text> follows "- <date> <id>: " on the log line: "<intent> — <IDs> — <disposition> — <PR>".
#   The line is appended, or put first when the log lists the newest change first.
#   Exit 0 closed and check-review.sh passes at the new head, 1 refused or failing, 2 usage.
set -euo pipefail
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/spec-lib.sh"
usage='Usage: close-change.sh [--base <rev>] [--date YYYY-MM-DD] [-m <message>] <change-id> "<intent> — <IDs> — <disposition> — <PR>"'
base_args=(); day=""; message=""; id=""; text=""; options=true
while [ "$#" -gt 0 ]; do
    if $options; then
        case "$1" in
            --base|--date|-m|--message)
                [ "$#" -gt 1 ] || { echo "$usage" >&2; exit 2; }
                case "$1" in --base) base_args=(--base "$2") ;; --date) day="$2" ;; *) message="$2" ;; esac
                shift 2; continue ;;
            --help|-h) echo "$usage"; exit 0 ;;
            --) options=false; shift; continue ;;
            -*) echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    fi
    if [ -z "$id" ]; then id="$1"; elif [ -z "$text" ]; then text="$1"; else echo "$usage" >&2; exit 2; fi
    shift
done
is_change_id "$id" && [ -n "$text" ] || { echo "$usage" >&2; exit 2; }
[ -n "$day" ] || day="$(spec_today)"
spec_is_date "$day" || { echo "--date takes YYYY-MM-DD (got: $day)" >&2; exit 2; }
refuse() { echo "close-change.sh: $*" >&2; exit 1; }
case "$text" in *$'\n'*|*$'\r'*) refuse "the log text is one line" ;; esac

root="$(git rev-parse --show-toplevel 2>/dev/null)" || refuse "not inside a Git checkout"
path="specs/changes/$id.md"; log="specs/log.md"
git -C "$root" cat-file -e "HEAD:$path" 2>/dev/null || refuse "no record $path at HEAD"
git -C "$root" diff --quiet HEAD -- "$path" ||
    refuse "$path has uncommitted edits: commit the final Review line first; the check reads committed state"
git -C "$root" diff --cached --quiet || refuse "other changes are staged; commit or unstage them, so this commit holds only the record and the log"
if [ -e "$root/$log" ]; then
    if ! git -C "$root" ls-files --error-unmatch -- "$log" >/dev/null 2>&1 || ! git -C "$root" diff --quiet HEAD -- "$log"; then
        refuse "$log has uncommitted edits; commit or discard them first"
    fi
    ! grep -q "^- [0-9-]* $id:" "$root/$log" || refuse "$log already has a line for $id"
fi

check() { bash "$SCRIPT_DIR/check-review.sh" --repo "$root" --head HEAD ${base_args[@]+"${base_args[@]}"} "$id" 2>&1; }
if ! out="$(check)"; then
    printf '%s\n' "$out" >&2
    default="$(spec_default_branch "$root")"
    if [ -n "$default" ] && git -C "$root" cat-file -e "$default:$path" 2>/dev/null; then
        refuse "$path is already on $default: a change merged with its record closes inside the next relevant PR, before that PR's final review (change.md, Closing)"
    fi
    refuse "check-review.sh does not pass at HEAD; commit the final passing Review line first"
fi

line="- $day $id: $text"
if [ -s "$root/$log" ]; then
    tmp="$root/$log.close-change.$$"
    # Dates are compared, never matched: the line itself reaches awk only through ENVIRON.
    CLOSE_LINE="$line" awk '
        { lines[NR] = $0 }
        /^- [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] / { d = substr($0, 3, 10); if (!first) { first = NR; newest = d }; oldest = d }
        END {
            top = first && newest > oldest
            for (i = 1; i <= NR; i++) { if (top && i == first) print ENVIRON["CLOSE_LINE"]; print lines[i] }
            if (!top) print ENVIRON["CLOSE_LINE"]
        }' "$root/$log" > "$tmp" && mv "$tmp" "$root/$log"
else
    mkdir -p "$root/specs"; printf '%s\n' "$line" > "$root/$log"
fi
git -C "$root" rm -q -- "$path"
git -C "$root" add -- "$log"
git -C "$root" commit -q -m "${message:-$id: close (log line, record deleted)}" ||
    refuse "the commit failed; the record deletion and the log line are staged"

head="$(git -C "$root" rev-parse --short HEAD)"
if out="$(check)"; then
    printf 'Closed %s in %s.\n%s\n' "$id" "$head" "$out"
else
    printf '%s\n' "$out" >&2
    refuse "closed $id in $head, but check-review.sh fails there"
fi
