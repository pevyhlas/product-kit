#!/usr/bin/env bash
# close-change.sh — Close a reviewed change in its own PR with one commit: refuse unless
# check-review.sh passes at HEAD, then write the change's log entry and delete its record.
# Run it once the final Review line is committed and before the final push, so required checks
# run once on the closed head. It commits in the current checkout only; it never pushes, merges
# or removes a worktree (cleanup-change.sh does that after merge, or --closed for every closed change).
#
# Usage: close-change.sh [--base <rev>] [--date YYYY-MM-DD] [-m <message>] <change-id> "<log text>"
#   <log text> follows "- <date> <id>: " on the entry: "<intent> — <IDs> — <disposition> — <PR>",
#   at most 300 characters. The entry is its own file, specs/log/<id>.md, so two branches that
#   each close a change never conflict; compaction folds entries into specs/log.md (compact.md).
#   Exit 0 closed and check-review.sh passes at the new head, 1 refused or failing, 2 usage.
set -euo pipefail
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/spec-lib.sh"
usage='Usage: close-change.sh [--base <rev>] [--date YYYY-MM-DD] [-m <message>] <change-id> "<intent> — <IDs> — <disposition> — <PR>" (at most 300 characters)'
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
# Characters, not bytes: UTF-8 continuation bytes do not count, whatever the locale.
max=300; length="$(printf '%s' "$text" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')"
[ "$length" -le "$max" ] || refuse "the log text is $length characters, over $max: keep \"<intent> — <IDs> — <disposition> — <PR>\"; carried findings and follow-ups go to the parent's row or the spec, and evidence stays in the PR"

root="$(git rev-parse --show-toplevel 2>/dev/null)" || refuse "not inside a Git checkout"
path="specs/changes/$id.md"; log="specs/log.md"; entry="specs/log/$id.md"
git -C "$root" cat-file -e "HEAD:$path" 2>/dev/null || refuse "no record $path at HEAD"
git -C "$root" diff --quiet HEAD -- "$path" ||
    refuse "$path has uncommitted edits: commit the final Review line first; the check reads committed state"
git -C "$root" diff --cached --quiet || refuse "other changes are staged; commit or unstage them, so this commit holds only the record and its log entry"
if [ -e "$root/$entry" ] || git -C "$root" cat-file -e "HEAD:$entry" 2>/dev/null ||
    { [ -f "$root/$log" ] && grep -q "^- [0-9-]* $id:" "$root/$log"; }; then
    refuse "the log already has an entry for $id"
fi
default="$(spec_default_branch "$root")"
if [ -n "$default" ] && git -C "$root" cat-file -e "$default:$path" 2>/dev/null; then
    refuse "$path is already on $default: a change merged with its record closes inside the next relevant PR, before that PR's final review (review.md, Closing)"
fi

check() { bash "$SCRIPT_DIR/check-review.sh" --repo "$root" --head HEAD ${base_args[@]+"${base_args[@]}"} "$id" 2>&1; }
if ! out="$(check)"; then
    printf '%s\n' "$out" >&2
    refuse "check-review.sh does not pass at HEAD; commit the final passing Review line first"
fi

if ! { mkdir -p "$root/specs/log" && printf -- '- %s %s: %s\n' "$day" "$id" "$text" > "$root/$entry"; } 2>/dev/null; then
    rm -f "$root/$entry" 2>/dev/null || true
    refuse "could not write $entry; nothing was deleted or committed"
fi
git -C "$root" rm -q -- "$path"
git -C "$root" add -- "$entry"
git -C "$root" commit -q -m "${message:-$id: close (log entry, record deleted)}" ||
    refuse "the commit failed; the record deletion and the log entry are staged"

head="$(git -C "$root" rev-parse --short HEAD)"
if out="$(check)"; then
    printf 'Closed %s in %s.\n%s\n' "$id" "$head" "$out"
else
    printf '%s\n' "$out" >&2
    refuse "closed $id in $head, but check-review.sh fails there"
fi
