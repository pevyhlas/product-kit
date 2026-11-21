#!/usr/bin/env bash
# close-change.sh — Close a reviewed change in its own PR with one commit: refuse unless
# check-review.sh passes at HEAD, then write the change's log entry and delete its record.
# Run it once the required receipts are published and before the final push, so required checks
# run once on the closed head. It commits in the current checkout only; it never pushes, merges
# or removes a worktree (cleanup-change.sh does that after merge, or --closed for every closed change).
#
# Usage: close-change.sh --pr <url> [--base <rev>] [--date YYYY-MM-DD] [-m <message>] <change-id> "<log text>"
#   <log text> follows "- <date> <id>: " on the entry: "<intent> — <IDs> — <disposition> — <PR>",
#   at most 300 characters. The entry is its own file, specs/log/<id>.md, so two branches that
#   each close a change never conflict; compaction folds entries into specs/log.md (compact.md).
#   Exit 0 closed and check-review.sh passes at the new head, 1 refused or failing, 2 usage.
set -euo pipefail
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
source "$SCRIPT_DIR/spec-lib.sh"
usage='Usage: close-change.sh --pr <url> [--base <rev>] [--date YYYY-MM-DD] [-m <message>] <change-id> "<intent> — <IDs> — <disposition> — <PR>" (at most 300 characters)'
base_args=(); pr=""; day=""; message=""; id=""; text=""; options=true
while [ "$#" -gt 0 ]; do
    if $options; then
        case "$1" in
            --pr|--base|--date|-m|--message)
                [ "$#" -gt 1 ] || { echo "$usage" >&2; exit 2; }
                case "$1" in --pr) pr="$2" ;; --base) base_args=(--base "$2") ;; --date) day="$2" ;; *) message="$2" ;; esac
                shift 2; continue ;;
            --help|-h) echo "$usage"; echo 'Publishing the entry requires hard-link support in specs/log/.'; exit 0 ;;
            --) options=false; shift; continue ;;
            -*) echo "Unknown option: $1" >&2; exit 2 ;;
        esac
    fi
    if [ -z "$id" ]; then id="$1"; elif [ -z "$text" ]; then text="$1"; else echo "$usage" >&2; exit 2; fi
    shift
done
is_change_id "$id" && [ -n "$text" ] && [ -n "$pr" ] || { echo "$usage" >&2; exit 2; }
[ -n "$day" ] || day="$(spec_today)"
spec_is_date "$day" || { echo "--date takes YYYY-MM-DD (got: $day)" >&2; exit 2; }
refuse() { echo "close-change.sh: $*" >&2; exit 1; }
case "$text" in *$'\n'*|*$'\r'*) refuse "the log text is one line" ;; esac
# Characters, not bytes: UTF-8 continuation bytes do not count, whatever the locale.
max=300; length="$(printf '%s' "$text" | LC_ALL=C tr -d '\200-\277' | wc -c | tr -d ' ')"
[ "$length" -le "$max" ] || refuse "the log text is $length characters, over $max: keep \"<intent> — <IDs> — <disposition> — <PR>\"; carried findings and follow-ups go to the parent's row or the spec, and evidence stays in the PR"

root="$(git rev-parse --show-toplevel 2>/dev/null)" || refuse "not inside a Git checkout"
path="specs/changes/$id.md"; log="specs/log.md"; entry="specs/log/$id.md"
check_paths() {
    local component
    for component in specs specs/changes "$path" specs/log "$entry" "$log"; do
        [ ! -L "$root/$component" ] || refuse "symlinked close path: $component"
    done
}
check_paths
git -C "$root" cat-file -e "HEAD:$path" 2>/dev/null || refuse "no record $path at HEAD"
git -C "$root" diff --quiet HEAD -- "$path" ||
    refuse "$path has uncommitted edits: commit the record edits first; the check reads committed state"
git -C "$root" diff --cached --quiet || refuse "other changes are staged; commit or unstage them, so this commit holds only the record and its log entry"
if [ -e "$root/$entry" ] || git -C "$root" cat-file -e "HEAD:$entry" 2>/dev/null ||
    { [ -f "$root/$log" ] && grep -q "^- [0-9-]* $id:" "$root/$log"; }; then
    refuse "the log already has an entry for $id"
fi
default="$(spec_default_branch "$root")"
if [ -n "$default" ] && git -C "$root" cat-file -e "$default:$path" 2>/dev/null; then
    refuse "$path is already on $default: a change merged with its record closes inside the next relevant PR, before that PR's final review (review.md, Closing)"
fi

check() { bash "$SCRIPT_DIR/check-review.sh" --pr "$pr" --repo "$root" --head HEAD ${base_args[@]+"${base_args[@]}"} "$id" 2>&1; }
if ! out="$(check)"; then
    printf '%s\n' "$out" >&2
    refuse "check-review.sh does not pass at HEAD; publish the remaining verdicts first"
fi

check_paths
# The process cwd pins a directory just like a directory descriptor. Verify
# its physical identity *after* entering it, before any relative write.
(
    cd -P "$root/specs" && [ "$(pwd -P)" = "$root/specs" ] || exit 1
    created_log=false
    if [ ! -d ./log ]; then mkdir ./log || exit 1; created_log=true; fi
    [ ! -L ./log ] && cd -P ./log && [ "$(pwd -P)" = "$root/specs/log" ] || exit 1
    if $created_log; then
        # Restore an initially absent log on refusal. rmdir preserves concurrent entries.
        trap 'if [ "$?" -ne 0 ] && [[ . -ef "$root/specs/log" ]]; then rmdir "$root/specs/log" 2>/dev/null || :; fi' EXIT
    fi
    stage="$(mktemp -d .close-XXXXXXXX)" || exit 1
    (
        cd -P "./$stage" && [ "$(pwd -P)" = "$root/specs/log/$stage" ] || exit 1
        # Keep cleanup in the private cwd even if that directory gets moved.
        # shellcheck disable=SC2329 # called by the EXIT trap
        cleanup_stage() {
            rm -f "./$id.md"
            if [[ . -ef "$root/specs/log/$stage" ]]; then rmdir "$root/specs/log/$stage"; fi
        }
        trap cleanup_stage EXIT
        set -C
        cat <<< "- $day $id: $text" > "./$id.md" || exit 1
        # Pin the publishing cwd separately. A moved stage can make its source
        # disappear, but can never redirect the destination to its new parent.
        (
            cd -P "$root/specs/log" && [ "$(pwd -P)" = "$root/specs/log" ] || exit 1
            if ! ln "./$stage/$id.md" .; then
                if [ -e "./$id.md" ] || [ -L "./$id.md" ]; then exit 3; fi
                exit 4
            fi
        ) || exit "$?"
        [[ ! -L "$root/$entry" && "./$id.md" -ef "$root/$entry" ]]
    )
) || {
    case $? in
        3) refuse "the log already has an entry for $id; nothing was deleted or committed" ;;
        4) refuse "could not create the hard link for $entry; nothing was deleted or committed. Closing requires hard-link support in specs/log/" ;;
        *) refuse "could not write $entry; nothing was deleted or committed" ;;
    esac
}
check_paths
git -C "$root" add -- "$entry"
git -C "$root" rm -q -- "$path"
git -C "$root" commit -q -m "${message:-$id: close (log entry, record deleted)}" ||
    refuse "the commit failed; the record deletion and the log entry are staged"

head="$(git -C "$root" rev-parse --short HEAD)"
if out="$(check)"; then
    printf 'Closed %s in %s.\n%s\n' "$id" "$head" "$out"
else
    printf '%s\n' "$out" >&2
    refuse "closed $id in $head, but check-review.sh fails there"
fi
