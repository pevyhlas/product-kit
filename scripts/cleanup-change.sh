#!/usr/bin/env bash
#
# Safely tear down the isolated worktrees that new-change.sh creates
# under .worktrees/<change-id>.
#
# Why this exists: removing a worktree with `rm -rf` (tempting, because
# .worktrees/ is gitignored and looks like disposable scratch) leaves a stale
# "prunable" registration behind in git's worktree list. A harness/agent
# session that was operating inside that directory then fails to re-enter it on
# resume ("can't enter the worktree at startup"). This helper removes a
# finished change's worktree the safe way (git worktree remove, non-forced)
# and prunes stale registrations so nothing dangles. With --closed it does so
# for every worktree whose change is closed on the trusted integration branch.
#
# Run it from the MAIN checkout, never from inside the worktree being removed.

set -e

# shellcheck source=/dev/null
SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/spec-lib.sh"

JSON_MODE=false
FORCE=false
PRUNE_ONLY=false
CLOSED_MODE=false
TARGET=""
USAGE="Usage: cleanup-change.sh [--json] [--force] (<change-id> | --prune)
       cleanup-change.sh [--json] --closed"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --json) JSON_MODE=true ;;
        --force) FORCE=true ;;
        --prune) PRUNE_ONLY=true ;;
        --closed) CLOSED_MODE=true ;;
        --help|-h)
            cat <<'EOF'
Usage: cleanup-change.sh [--json] [--force] (<change-id> | --prune)
       cleanup-change.sh [--json] --closed

Remove a finished change's isolated worktree, or clear stale registrations.

Options:
  --json        Output in JSON format
  --force       Remove even when the worktree has uncommitted or untracked
                changes (git worktree remove --force). Discards those changes.
  --prune       Only clear stale ("prunable") worktree registrations left behind
                when a worktree directory was deleted without this helper.
  --closed      Remove the worktree of every change that is closed on the trusted
                integration branch (origin/HEAD, plus any review-integration-branches
                in its committed config): its record specs/changes/<id>.md is gone
                and the log has its entry. A change id matches a worktree's branch
                name or directory name. Each worktree goes through the same safe
                removal as a single change id; a dirty, locked or otherwise refused
                worktree is reported and skipped, the run continues, and the exit
                status is 1 if any was refused. Never forces. Skips the main checkout
                and any worktree holding the current directory, and clears stale
                registrations. Refused when no trusted branch resolves (set
                origin/HEAD: git remote set-head origin --auto). Branches are never
                deleted; that stays your choice.
  --help, -h    Show this help message

Run from the MAIN checkout, not from inside the worktree being removed.
A worktree is removed non-forced by default: uncommitted or untracked changes
refuse the removal until they are committed, stashed or discarded. Committed
work is not checked for integration; it stays on the change's branch, which
is never deleted. Ignored files go with the worktree, except evidence,
retrospectives, usage-enrichment inputs and ledger events, which are first
copied to this checkout.

Git refuses to remove any worktree that contains submodules, even a clean one.
When the worktree is clean and that is the only reason, the removal is retried
with --force after re-checking that it is still clean, so nothing is discarded.
Any other git refusal, such as a locked worktree, is reported with git's reason.

Examples:
  cleanup-change.sh 007-user-auth      # remove that change's worktree
  cleanup-change.sh --closed           # remove every closed change's worktree
  cleanup-change.sh --prune            # clear stale registrations only
EOF
            exit 0
            ;;
        --*) echo "Error: unknown option: $1" >&2; exit 2 ;;
        *)
            if [ -n "$TARGET" ]; then
                echo "Error: only one change id may be given" >&2
                exit 2
            fi
            TARGET="$1"
            ;;
    esac
    shift
done

selected=0
[ "$PRUNE_ONLY" = true ] && selected=$((selected + 1))
[ "$CLOSED_MODE" = true ] && selected=$((selected + 1))
[ -z "$TARGET" ] || selected=$((selected + 1))
if [ "$selected" -gt 1 ]; then
    echo "Error: pass one of a change id, --prune or --closed" >&2
    exit 2
fi
if [ "$selected" -eq 0 ]; then
    echo "$USAGE" >&2
    exit 2
fi
if [ "$CLOSED_MODE" = true ] && [ "$FORCE" = true ]; then
    echo "Error: --closed never forces; remove a dirty worktree by id with --force" >&2
    exit 2
fi

if ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "[prdkit] Error: worktrees are a Git feature and no Git repository was detected." >&2
    exit 1
fi

ROOT="$(get_repo_root)"

# Physical path of the checkout this invocation is standing in. Compared against
# the removal target so we never pull the ground out from under ourselves.
CURRENT_TOP=""
if top="$(git rev-parse --show-toplevel 2>/dev/null)"; then
    CURRENT_TOP="$(CDPATH="" cd "$top" 2>/dev/null && pwd -P)" || CURRENT_TOP=""
fi
CWD_PHYS="$(pwd -P 2>/dev/null)" || CWD_PHYS=""

# Collect worktree registrations. For each we keep the path, the branch (if
# any), whether git considers it prunable (its directory is gone) and whether
# it is locked. The first registration is the main checkout.
STALE_PATHS=()
ENT_PATH=(); ENT_BRANCH=(); ENT_PRUNABLE=(); ENT_LOCKED=(); ENT_BARE=()
MATCH_PATH=""
MATCH_PRUNABLE=false
MATCH_LOCKED=false
KNOWN=()
REMOVED=(); SKIPPED_PATH=(); SKIPPED_WHY=(); PRUNED=()

cur_path=""; cur_branch=""; cur_prunable=false; cur_locked=false; cur_bare=false
flush_entry() {
    [ -n "$cur_path" ] || return 0
    KNOWN+=("$cur_path")
    ENT_PATH+=("$cur_path"); ENT_BRANCH+=("$cur_branch"); ENT_PRUNABLE+=("$cur_prunable")
    ENT_LOCKED+=("$cur_locked"); ENT_BARE+=("$cur_bare")
    if [ "$cur_prunable" = true ]; then
        STALE_PATHS+=("$cur_path")
    fi
    if [ -n "$TARGET" ]; then
        base="${cur_path##*/}"
        if [ "$cur_branch" = "$TARGET" ] || [ "$base" = "$TARGET" ]; then
            MATCH_PATH="$cur_path"
            MATCH_PRUNABLE="$cur_prunable"
            MATCH_LOCKED="$cur_locked"
        fi
    fi
    cur_path=""; cur_branch=""; cur_prunable=false; cur_locked=false; cur_bare=false
}

while IFS= read -r line; do
    case "$line" in
        "worktree "*) flush_entry; cur_path="${line#worktree }" ;;
        "branch refs/heads/"*) cur_branch="${line#branch refs/heads/}" ;;
        "prunable"*) cur_prunable=true ;;
        "locked"*) cur_locked=true ;;
        "bare") cur_bare=true ;;
    esac
done < <(git -C "$ROOT" worktree list --porcelain 2>/dev/null || true)
flush_entry

emit_json() {
    # $1 result, $2 action, $3 message, then any number of path operands that
    # were removed/pruned.
    local result="$1" action="$2" message="$3"; shift 3
    local items="" p first=true
    for p in "$@"; do
        if [ "$first" = true ]; then first=false; else items="$items,"; fi
        items="$items\"$(json_escape "$p")\""
    done
    printf '{"result":"%s","action":"%s","message":"%s","paths":[%s]}\n' \
        "$result" "$action" "$(json_escape "$message")" "$items"
}

prune_stale() {
    # Clear registrations whose directories are gone. Reports the paths git drops.
    git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
    if [ "${#STALE_PATHS[@]}" -eq 0 ]; then
        if $JSON_MODE; then
            emit_json ok prune "No stale worktree registrations to prune."
        else
            echo "[prdkit] No stale worktree registrations to prune."
        fi
        return 0
    fi
    if $JSON_MODE; then
        emit_json ok prune "Pruned ${#STALE_PATHS[@]} stale worktree registration(s)." "${STALE_PATHS[@]}"
    else
        echo "[prdkit] Pruned ${#STALE_PATHS[@]} stale worktree registration(s):"
        for p in "${STALE_PATHS[@]}"; do echo "  $p"; done
    fi
}

if [ "$PRUNE_ONLY" = true ]; then
    prune_stale
    exit 0
fi

ROOT_TOP="$(CDPATH="" cd "$ROOT" 2>/dev/null && pwd -P)" || ROOT_TOP="$ROOT"

# --- Remove one worktree, safely ---------------------------------------------
# remove_worktree <path> <label> <locked> sets RESULT_REASON (short) and RESULT_MSG (full) and
# returns 0 when the worktree was removed, 1 when it was refused. It never exits and prints nothing.

# Cleanliness: 0 has changes, 1 clean, 2 git could not say.
WT=""
wt_dirty() {
    local out
    out="$(git -C "$WT" status --porcelain --untracked-files=all 2>/dev/null)" || return 2
    [ -n "$out" ]
}

# Review packages, check outputs, retrospectives, usage-enrichment inputs and the ledger spool live
# in the worktree's gitignored .prdkit/cache/, .prdkit/retrospective/ and .prdkit/ledger/, which
# `git worktree remove` deletes without counting them as dirty. Copy every evidence, retrospective
# and enrichment file into this checkout's .prdkit/ and verify it first; a copy that fails or
# would overwrite a different file refuses the removal.
# The worktree's ledger events are appended to this checkout's spool, skipping lines it has.
PRESERVED=0; EVENTS=0; CONFLICT=""
preserve() { # path relative to .prdkit/ (a directory or a file)
    local src="$WT/.prdkit/$1" dest="$ROOT/.prdkit/$1" file rel
    [ -e "$src" ] || return 0
    while IFS= read -r -d '' file; do
        rel="${file#"$src"}"
        if [ -e "$dest$rel" ]; then
            cmp -s "$file" "$dest$rel" || { CONFLICT="$dest$rel"; return 1; }
        else
            if ! { mkdir -p "$(dirname "$dest$rel")" && cp -p "$file" "$dest$rel" && cmp -s "$file" "$dest$rel"; }; then
                CONFLICT="$dest$rel"; return 1
            fi
            PRESERVED=$((PRESERVED + 1))
        fi
    done < <(find "$src" -type f -print0)
}
merge_events() {
    local src="$WT/.prdkit/ledger/events.jsonl" dest="$ROOT/.prdkit/ledger/events.jsonl" new
    [ -s "$src" ] || return 0
    CONFLICT="$dest"
    mkdir -p "$(dirname "$dest")" && touch "$dest" || return 1
    # FILENAME, not NR == FNR: with an empty spool here, NR == FNR would hold through the worktree's.
    new="$(awk 'FILENAME == ARGV[1] { seen[$0] = 1; next } !seen[$0]++' "$dest" "$src")" || return 1
    [ -n "$new" ] || return 0
    printf '%s\n' "$new" >> "$dest" || return 1
    EVENTS="$(printf '%s\n' "$new" | wc -l | tr -d ' ')"
}

# git refuses `worktree remove` for any worktree that contains submodules, clean or not. True when
# a refusal was that one: git's message (C locale, but other versions word it differently) or the
# worktree's index holding a gitlink (mode 160000) entry, which is what makes git refuse.
submodule_refusal() { # git's error
    case "$1" in *submodules*) return 0 ;; esac
    git -C "$WT" ls-files -s 2>/dev/null | awk '$1 == "160000" { found = 1 } END { exit !found }'
}

# One line from git's own words: no "fatal:" prefix, no line breaks.
flatten_git_error() {
    local e="${1#fatal: }"
    e="$(printf '%s' "$e" | tr '\n' ' ')"
    printf '%s' "${e:-unknown git error}"
}

refuse_with() { # short reason, full message
    RESULT_REASON="$1"; RESULT_MSG="$2"   # callers return 1 after it
}
refuse_dirty() {
    refuse_with "uncommitted or untracked changes" \
        "Refusing to remove $WT: it has uncommitted or untracked changes. Commit, stash or discard them first, or pass --force to discard them."
}
refuse_git() { # git's reason
    local why; why="$(flatten_git_error "$1")"
    refuse_with "git refused the removal: $why" \
        "Refusing to remove $WT: git refused the removal, and the worktree itself is clean. Git's reason: $why"
}

RESULT_REASON=""; RESULT_MSG=""; RETRIED=false
remove_worktree() { # path label locked
    local label="$2" locked="$3" rm_err state
    WT="$1"; PRESERVED=0; EVENTS=0; CONFLICT=""; RETRIED=false
    # Refuse before copying anything, so a refused removal leaves this checkout's cache untouched.
    if [ "$FORCE" = false ]; then
        state=0; wt_dirty || state=$?
        case "$state" in
            0) refuse_dirty; return 1 ;;
            2) refuse_git "git status failed in the worktree"; return 1 ;;
        esac
    fi

    if ! preserve cache/evidence || ! preserve cache/retrospectives || ! preserve retrospective ||
        ! merge_events; then
        refuse_with "could not preserve its evidence at $CONFLICT" \
            "Refusing to remove $WT: could not preserve its evidence at $CONFLICT (a different file is already there, or the copy failed). Resolve it, then rerun."
        return 1
    fi

    if [ "$FORCE" = true ]; then
        rm_err="$(LC_ALL=C git -C "$ROOT" worktree remove --force "$WT" 2>&1 >/dev/null)" || { refuse_git "$rm_err"; return 1; }
    elif ! rm_err="$(LC_ALL=C git -C "$ROOT" worktree remove "$WT" 2>&1 >/dev/null)"; then
        # Cleanliness was proven above, but a worktree with submodules is refused regardless.
        # Re-check, then retry forced: with nothing uncommitted, --force discards nothing. A locked
        # worktree stays refused, with git's reason.
        if [ "$locked" = true ] || ! submodule_refusal "$rm_err"; then
            refuse_git "$rm_err"; return 1
        fi
        state=0; wt_dirty || state=$?
        case "$state" in
            0) refuse_dirty; return 1 ;;
            2) refuse_git "git status failed in the worktree"; return 1 ;;
        esac
        RETRIED=true
        rm_err="$(LC_ALL=C git -C "$ROOT" worktree remove --force "$WT" 2>&1 >/dev/null)" || { refuse_git "$rm_err"; return 1; }
    fi
    git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
    RESULT_REASON="removed"
    RESULT_MSG="Removed worktree for '$label': $WT"
    [ "$PRESERVED" -eq 0 ] || RESULT_MSG="$RESULT_MSG; preserved $PRESERVED evidence file(s) in $ROOT/.prdkit/"
    [ "$EVENTS" -eq 0 ] || RESULT_MSG="$RESULT_MSG; appended $EVENTS ledger event(s) to $ROOT/.prdkit/ledger/events.jsonl"
    [ "$RETRIED" = false ] || RESULT_MSG="$RESULT_MSG; the worktree contains submodules, which git refuses to remove without --force, so it was removed with --force after confirming it had no uncommitted or untracked changes"
    return 0
}

# --- Remove every closed change's worktree ---------------------------------

# Whether <id> is closed on a trusted ref: its record specs/changes/<id>.md is gone there and
# the log has its entry, specs/log/<id>.md as close-change.sh writes it or a line in specs/log.md
# ("- <date> <id>: ..."). Both facts are read from the trusted ref, never from the worktree's own
# branch.
CLOSED_REFS=""
closed_on_trusted() { # id
    local id="$1" ref
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        GIT_NO_LAZY_FETCH=1 git -C "$ROOT" rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || continue
        if GIT_NO_LAZY_FETCH=1 git -C "$ROOT" cat-file -e "$ref:specs/changes/$id.md" 2>/dev/null; then continue; fi
        if spec_log_entries_at "$ROOT" "$ref" |
            sed -n 's/^- [0-9-]* \([^ :]*\):.*/\1/p' | grep -Fqx -- "$id"; then
            return 0
        fi
    done <<EOF
$CLOSED_REFS
EOF
    return 1
}

# A worktree matches when it names a change id (its branch, its directory name) and every id it
# names is closed.
worktree_closed() { # branch basename
    local name found=false
    for name in "$1" "$2"; do
        is_change_id "$name" || continue
        found=true
        closed_on_trusted "$name" || return 1
    done
    [ "$found" = true ]
}

run_closed() {
    local i path branch locked top msg result removed_n=0 skipped_n=0 open_n=0 failed=0 p
    REMOVED=(); SKIPPED_PATH=(); SKIPPED_WHY=(); PRUNED=()
    CLOSED_REFS="$(spec_trusted_refs "$ROOT")"
    if [ -z "$CLOSED_REFS" ]; then
        msg="Refusing --closed: no trusted integration branch resolves, so no change can be called closed. Set origin/HEAD (git remote set-head origin --auto) and fetch, then rerun."
        if $JSON_MODE; then emit_json refused closed "$msg"; else >&2 echo "[prdkit] $msg"; fi
        exit 1
    fi

    # Entry 0 is the main checkout.
    for ((i = 1; i < ${#ENT_PATH[@]}; i++)); do
        path="${ENT_PATH[$i]}"; branch="${ENT_BRANCH[$i]}"; locked="${ENT_LOCKED[$i]}"
        # A bare repository, or a registration whose directory is gone (pruned below), is no candidate.
        if [ "${ENT_BARE[$i]}" = true ] || [ "${ENT_PRUNABLE[$i]}" = true ]; then continue; fi
        top="$(CDPATH="" cd "$path" 2>/dev/null && pwd -P)" || top="$path"
        [ "$top" != "$ROOT_TOP" ] || continue
        if ! worktree_closed "$branch" "${path##*/}"; then
            open_n=$((open_n + 1)); continue
        fi
        case "$CWD_PHYS/" in
            "$top"/*)
                skipped_n=$((skipped_n + 1)); SKIPPED_PATH+=("$path"); SKIPPED_WHY+=("it holds the current directory; run this from the main checkout")
                continue ;;
        esac
        if remove_worktree "$path" "${branch:-${path##*/}}" "$locked"; then
            removed_n=$((removed_n + 1)); REMOVED+=("$path")
            $JSON_MODE || echo "[prdkit] $RESULT_MSG"
        else
            failed=1; skipped_n=$((skipped_n + 1)); SKIPPED_PATH+=("$path"); SKIPPED_WHY+=("$RESULT_REASON")
        fi
    done

    git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
    if [ "${#STALE_PATHS[@]}" -gt 0 ]; then
        result="$(git -C "$ROOT" worktree list --porcelain 2>/dev/null || true)"
        for p in "${STALE_PATHS[@]}"; do
            printf '%s\n' "$result" | grep -Fqx -- "worktree $p" || PRUNED+=("$p")
        done
    fi

    msg="Removed $removed_n closed change worktree(s), skipped $skipped_n, left $open_n for open or unrelated work, pruned ${#PRUNED[@]} stale registration(s)."
    if $JSON_MODE; then
        local skipped_json="" sep=""
        i=0
        while [ "$i" -lt "${#SKIPPED_PATH[@]}" ]; do
            skipped_json="$skipped_json$sep{\"path\":\"$(json_escape "${SKIPPED_PATH[$i]}")\",\"reason\":\"$(json_escape "${SKIPPED_WHY[$i]}")\"}"
            sep=","; i=$((i + 1))
        done
        result=ok; [ "$failed" -eq 0 ] || result=refused
        printf '{"result":"%s","action":"closed","message":"%s","paths":%s,"skipped":[%s],"pruned":%s}\n' \
            "$result" "$(json_escape "$msg")" "$(json_array ${REMOVED[@]+"${REMOVED[@]}"})" "$skipped_json" \
            "$(json_array ${PRUNED[@]+"${PRUNED[@]}"})"
    else
        echo "[prdkit] $msg"
        if [ "${#PRUNED[@]}" -gt 0 ]; then
            echo "[prdkit] Pruned:"
            for p in "${PRUNED[@]}"; do echo "  $p"; done
        fi
        if [ "${#SKIPPED_PATH[@]}" -gt 0 ]; then
            >&2 echo "[prdkit] Skipped:"
            i=0
            while [ "$i" -lt "${#SKIPPED_PATH[@]}" ]; do
                >&2 echo "  ${SKIPPED_PATH[$i]}: ${SKIPPED_WHY[$i]}"; i=$((i + 1))
            done
        fi
    fi
    exit "$failed"
}

if [ "$CLOSED_MODE" = true ]; then
    run_closed
fi

# --- Remove a specific change's worktree ------------------------------------

if [ -z "$MATCH_PATH" ]; then
    msg="No worktree found for '$TARGET'."
    if $JSON_MODE; then
        emit_json error remove "$msg"
    else
        >&2 echo "[prdkit] $msg"
        if [ "${#KNOWN[@]}" -gt 1 ]; then
            >&2 echo "[prdkit] Known worktrees:"
            for p in "${KNOWN[@]}"; do >&2 echo "  $p"; done
        fi
    fi
    exit 1
fi

# A prunable match means the directory is already gone; just drop the registration.
if [ "$MATCH_PRUNABLE" = true ]; then
    git -C "$ROOT" worktree prune >/dev/null 2>&1 || true
    msg="Worktree for '$TARGET' was already gone; pruned its stale registration."
    if $JSON_MODE; then emit_json ok prune "$msg" "$MATCH_PATH"; else echo "[prdkit] $msg"; fi
    exit 0
fi

MATCH_TOP="$(CDPATH="" cd "$MATCH_PATH" 2>/dev/null && pwd -P)" || MATCH_TOP="$MATCH_PATH"
if [ -n "$CURRENT_TOP" ] && [ "$CURRENT_TOP" = "$MATCH_TOP" ]; then
    msg="Refusing to remove the worktree you are currently inside ($MATCH_PATH). Run this from the main checkout."
    if $JSON_MODE; then emit_json refused remove "$msg"; else >&2 echo "[prdkit] $msg"; fi
    exit 1
fi

if [ "$ROOT_TOP" = "$MATCH_TOP" ]; then
    msg="Refusing to remove $MATCH_PATH with its own copy of this script: run the main checkout's .prdkit/scripts/bash/cleanup-change.sh, which keeps the worktree's evidence."
    if $JSON_MODE; then emit_json refused remove "$msg"; else >&2 echo "[prdkit] $msg"; fi
    exit 1
fi

if remove_worktree "$MATCH_PATH" "$TARGET" "$MATCH_LOCKED"; then
    if $JSON_MODE; then emit_json ok remove "$RESULT_MSG" "$MATCH_PATH"; else echo "[prdkit] $RESULT_MSG"; fi
    exit 0
fi
if $JSON_MODE; then emit_json refused remove "$RESULT_MSG"; else >&2 echo "[prdkit] $RESULT_MSG"; fi
exit 1
