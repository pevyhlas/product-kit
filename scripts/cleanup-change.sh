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
# finished change's worktree by moving its checkout and registration to quarantine
# and leaves unrelated registrations alone. With --closed it does so
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
                changes. The checkout and its registration are quarantined.
  --prune       Only clear stale ("prunable") worktree registrations left behind
                when a worktree directory was deleted without this helper.
  --closed      Remove the worktree of every change that is closed on the trusted
                integration branch (origin/HEAD, plus any review-integration-branches
                in its committed config): its record specs/changes/<id>.md is gone
                and the log has its entry. Only a worktree laid out as new-change.sh
                creates it matches: the directory .worktrees/<id> of this checkout, on
                the branch <id>; a detached HEAD, another branch or another directory
                is left alone. Each worktree goes through the same safe
                removal as a single change id; a dirty, locked or otherwise refused
                worktree is reported and skipped, the run continues, and the exit
                status is 1 if any was refused. Never forces. Skips the main checkout
                and any worktree holding the current directory. Stale registrations
                are left for --prune. Refused when no trusted branch resolves (set
                origin/HEAD: git remote set-head origin --auto). Branches are never
                deleted; that stays your choice.
  --help, -h    Show this help message

Run from the MAIN checkout, not from inside the worktree being removed.
A worktree is removed non-forced by default: uncommitted or untracked changes
refuse the removal until they are committed, stashed or discarded. Committed
work is not checked for integration; the branch is never deleted. Ignored files
move with the checkout. Evidence, retrospectives and usage-enrichment inputs
are also copied to the main checkout. Archive and remove any legacy ledger
spool yourself before cleanup.

Cleanup moves the entire registration (including index, reflogs and submodule
stores) and any live checkout to the reported prdkit-retired directory. It
also retains shared Git objects there. Locked worktrees stay locked. Review
the slot and retain needed work before manually purging it.

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
REMOVED=(); SKIPPED_PATH=(); SKIPPED_WHY=()

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

# Inspect raw gitdir pointers before using older Git's newline-delimited
# porcelain. A literal newline in a registered path can resemble another field.
common_dir="$(git -C "$ROOT" rev-parse --git-common-dir)"
common_dir="$(CDPATH='' cd "$ROOT" && CDPATH='' cd "$common_dir" && pwd -P)"
legacy_listing_safe() (
    local dir target
    case "$ROOT$common_dir" in *[[:cntrl:]]*) return 1 ;; esac
    if [ ! -e "$common_dir/worktrees" ]; then return 0; fi
    [ -r "$common_dir/worktrees" ] && [ -x "$common_dir/worktrees" ] || return 1
    shopt -s nullglob dotglob
    for dir in "$common_dir/worktrees"/*; do
        [ ! -L "$dir" ] && [ -f "$dir/gitdir" ] && [ ! -L "$dir/gitdir" ] &&
            target="$(cat "$dir/gitdir")" || return 1
        case "$target" in *[[:cntrl:]]*) return 1 ;; */.git) ;; *) return 1 ;; esac
    done
)
registrations="$(mktemp)"; delimiter=''
if ! git -C "$ROOT" worktree list --porcelain -z > "$registrations" 2>/dev/null; then
    delimiter=$'\n'
    if ! legacy_listing_safe || ! git -C "$ROOT" worktree list --porcelain > "$registrations"; then
        rm -f "$registrations"
        echo "[prdkit] Cannot inspect worktree registrations unambiguously." >&2
        exit 1
    fi
fi
while IFS= read -r -d "$delimiter" line; do
    case "$line" in
        "worktree "*) flush_entry; cur_path="${line#worktree }" ;;
        "branch refs/heads/"*) cur_branch="${line#branch refs/heads/}" ;;
        "prunable"*) cur_prunable=true ;;
        "locked"*) cur_locked=true ;;
        "bare") cur_bare=true ;;
    esac
done < "$registrations"
rm -f "$registrations"
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

# Return the one registration pointing back to this checkout, including when
# its path no longer exists. Never derive an admin directory from the change ID.
registration() (
    local path="$1" dir target found=""
    [ -d "$common_dir/worktrees" ] && [ ! -L "$common_dir/worktrees" ] || return 1
    shopt -s nullglob dotglob
    for dir in "$common_dir/worktrees"/*; do
        [ -d "$dir" ] && [ ! -L "$dir" ] && [ -f "$dir/gitdir" ] &&
            [ ! -L "$dir/gitdir" ] && target="$(cat "$dir/gitdir")" || return 1
        case "$target" in
            /*) ;;
            */.git) target="$(git -C "$dir" --git-dir=. rev-parse --path-format=absolute --git-path "$target")" || return 1 ;;
            *) return 1 ;;
        esac
        [ "$target" = "$path/.git" ] || continue
        [ -z "$found" ] || return 1
        found="$dir"
    done
    [ -n "$found" ] && printf '%s\n' "$found"
)

# Validate relocation dependencies only. Never use reachability to authorize
# deletion. Inspect each repository's own metadata, not names inside its refs.
supported_layout() (
    local admin="$1" path="$2" list file repo
    list="$(mktemp)" || return 1
    trap 'rm -f "$list"' EXIT
    if [ -d "$path" ]; then
        [ ! -L "$path" ] && [ -f "$path/.git" ] && [ ! -L "$path/.git" ] &&
            [ "$(git -C "$path" rev-parse --absolute-git-dir)" = "$admin" ] || return 1
        find "$path" -iname .git -prune -print0 > "$list" || return 1
        while IFS= read -r -d '' file; do
            [ "$file" != "$path/.git" ] || continue
            [ -f "$file" ] && [ ! -L "$file" ] &&
                repo="$(git rev-parse --resolve-git-dir "$file")" &&
                repo="$(CDPATH='' cd -P "$repo" && pwd -P)" || return 1
            case "$repo" in "$admin/modules/"*) ;; *) return 1 ;; esac
            [ -d "$repo/objects" ] && [ -f "$repo/HEAD" ] || return 1
        done < "$list"
    fi
    [ ! -L "$admin/modules" ] || return 1
    [ -e "$admin/modules" ] || return 0
    [ -d "$admin/modules" ] &&
        find "$admin/modules" \( -type l -o -name HEAD \) -print0 > "$list" || return 1
    while IFS= read -r -d '' file; do
        [ ! -L "$file" ] || return 1
        repo="${file%/HEAD}"
        [ -d "$repo/objects" ] || [ -f "$repo/commondir" ] || continue
        [ ! -e "$repo/commondir" ] && [ ! -e "$repo/objects/info/alternates" ] || return 1
        if [ -e "$repo/worktrees" ]; then
            echo "[prdkit] $repo administers linked worktrees" >&2
            return 1
        fi
    done < "$list"
)

# Move whole directories instead of asking Git to recursively delete them.
# A private slot and a link across the two directories rule out mv's cross-
# device copy-and-delete fallback. Only our scratch probe/lock are unlinked.
same_mount() (
    local probe
    probe="$(mktemp "$1/.prdkit-device.XXXXXXXX")" || return 1
    trap 'rm -f "$probe"' EXIT
    ln "$probe" "$2/device" && rm "$2/device"
)
retire() (
    local path="$1" mode="$2" admin root="$common_dir/prdkit-retired" slot state=0 lock config_rc=0
    admin="$(registration "$path")" || { echo "ambiguous worktree registration: $path"; return 1; }
    lock="$admin/prdkit-cleanup.lock"
    mkdir "$lock" 2>/dev/null || { echo "another cleanup-change.sh run holds $lock"; return 1; }
    trap 'rmdir "$lock" 2>/dev/null || :' EXIT
    if [ -e "$admin/locked" ]; then echo "cannot remove a locked working tree: $(cat "$admin/locked")"; return 1; fi
    [ ! -L "$path" ] || return 1
    case "$mode" in
        stale) [ ! -e "$path" ] || { echo "checkout is no longer missing"; return 1; } ;;
        *) [ -d "$path" ] || return 1
           if [ "$FORCE" = false ]; then
               wt_dirty || state=$?
               [ "$state" -eq 1 ] || { echo "cannot confirm worktree is still clean"; return 1; }
           fi ;;
    esac
    supported_layout "$admin" "$path" || { echo "unsupported submodule layout: $path"; return 1; }
    # Refuse rather than make a backup that borrows objects from an external store.
    [ -z "${GIT_OBJECT_DIRECTORY:-}${GIT_ALTERNATE_OBJECT_DIRECTORIES:-}${GIT_COMMON_DIR:-}${GIT_SHALLOW_FILE:-}" ] &&
        [ "$(git -C "$ROOT" rev-parse --is-shallow-repository)" = false ] &&
        [ ! -e "$common_dir/objects/info/alternates" ] && [ ! -L "$common_dir/objects/info/alternates" ] ||
        { echo "unsupported shared object store"; return 1; }
    git -C "$ROOT" config --get-regexp '^(extensions\.partialclone|remote\..*\.(promisor|partialclonefilter))$' >/dev/null || config_rc=$?
    [ "$config_rc" = 1 ] || { echo "cannot verify complete local object storage"; return 1; }
    case "$root/" in "$path"/*) return 1 ;; esac
    [ ! -L "$root" ] && mkdir -p "$root" &&
        slot="$(mktemp -d "$root/${admin##*/}.$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")" || return 1
    printf '[prdkit] Quarantine: %s\n' "$slot" >&2
    if ! same_mount "$admin" "$slot" || { [ "$mode" != stale ] && ! same_mount "$path" "$slot"; }; then
        echo "cannot guarantee a same-filesystem move to $slot"; return 1
    fi
    # Keep native Git from pruning the registration while the checkout is
    # absent. An interrupted partial retirement stays locked for recovery.
    printf 'Product-Kit retirement: %s\n' "$slot" > "$slot/lock-reason" &&
        ln "$slot/lock-reason" "$admin/locked" && [ ! -L "$admin/locked" ] &&
        [ "$admin/locked" -ef "$slot/lock-reason" ] || { echo "cannot lock registration"; return 1; }
    if [ "$mode" != stale ]; then
        mv "$path" "$slot/checkout" || { echo "checkout move failed; inspect locked registration $admin and $slot"; return 1; }
    fi
    # The registration still roots detached HEAD, index and reflog objects
    # during backup. Local clone retains their objects even without shared refs.
    git -c gc.auto=0 clone -q --local --mirror "$common_dir" "$slot/common.git" ||
        { echo "shared object backup failed; inspect locked registration $admin and $slot"; return 1; }
    # Renaming the entire admin unregisters it in one step. No later removal
    # touches its former name, even if a concurrent writer recreates it.
    mv "$admin" "$slot/admin" || { echo "registration move failed: $slot"; return 1; }
    lock="$slot/admin/prdkit-cleanup.lock"
    printf '%s\n' "$slot"
)
prune_stale() {
    local path slot msg slots=""
    for path in "$@"; do
        if ! slot="$(retire "$path" stale)"; then
            msg="Could not quarantine stale registration $path: $slot"
            if $JSON_MODE; then emit_json refused prune "$msg"; else echo "[prdkit] $msg" >&2; fi
            return 1
        fi
        slots="$slots $slot"
    done
    msg="Pruned $# stale worktree registration(s) whose directories were already gone.${slots:+ Quarantine:$slots}"
    if $JSON_MODE; then emit_json ok prune "$msg" "$@"; else echo "[prdkit] $msg"; fi
}

if [ "$PRUNE_ONLY" = true ]; then
    prune_stale "${STALE_PATHS[@]}"
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

# Review packages, check outputs, retrospectives and usage-enrichment inputs live
# in the worktree's gitignored .prdkit/cache/ and .prdkit/retrospective/, which
# `git worktree remove` deletes without counting them as dirty. Copy every evidence, retrospective
# and enrichment file into this checkout's .prdkit/ and verify it first; a copy that fails or
# would overwrite a different file refuses the removal.
PRESERVED=0; CONFLICT=""
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

remove_worktree() { # path label locked
    local label="$2" locked="$3" state admin slot
    WT="$1"; PRESERVED=0; CONFLICT=""
    admin="$(registration "$WT")" || { refuse_git "cannot resolve worktree registration"; return 1; }
    if [ -d "$admin/prdkit-cleanup.lock" ]; then refuse_git "another cleanup-change.sh run holds $admin/prdkit-cleanup.lock"; return 1; fi
    if [ "$locked" = true ]; then
        refuse_git "cannot remove a locked working tree, lock reason: $(cat "$admin/locked")"; return 1
    fi
    # Refuse before copying anything, so a refused removal leaves this checkout's cache untouched.
    if [ "$FORCE" = false ]; then
        state=0; wt_dirty || state=$?
        case "$state" in
            0) refuse_dirty; return 1 ;;
            2) refuse_git "git status failed in the worktree"; return 1 ;;
        esac
    fi

    if [ -L "$WT/.prdkit" ] || [ -L "$WT/.prdkit/ledger" ] ||
        [ -L "$WT/.prdkit/ledger/events.jsonl" ] || [ -e "$WT/.prdkit/ledger/events.jsonl" ]; then
        refuse_with "legacy ledger spool or linked ledger path" \
            "Refusing to remove $WT: archive the legacy ledger spool if needed, then remove it or the linked ledger path before retrying."
        return 1
    fi
    if ! preserve cache/evidence || ! preserve cache/retrospectives || ! preserve retrospective; then
        refuse_with "could not preserve its evidence at $CONFLICT" \
            "Refusing to remove $WT: could not preserve its evidence at $CONFLICT (a different file is already there, or the copy failed). Resolve it, then rerun."
        return 1
    fi

    if ! slot="$(retire "$WT" live)"; then
        refuse_with "retirement incomplete: $slot" "Worktree retirement did not complete for $WT: $slot"
        return 1
    fi
    RESULT_REASON="removed"
    RESULT_MSG="Removed worktree for '$label': $WT; quarantine: $slot"
    [ "$PRESERVED" -eq 0 ] || RESULT_MSG="$RESULT_MSG; preserved $PRESERVED evidence file(s) in $ROOT/.prdkit/"
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

# A worktree matches only as new-change.sh lays it out: the directory .worktrees/<id> of this
# checkout, on the branch <id>, and <id> is closed. Anything else is left alone: a detached HEAD
# (it can hold commits no ref reaches, which removing the worktree would lose), another branch, or
# a directory that merely carries a closed id's name somewhere else.
WORKTREES_TOP=""
worktree_closed() { # branch path
    local branch="$1" path="$2" parent
    [ -n "$WORKTREES_TOP" ] && [ -n "$branch" ] || return 1
    is_change_id "$branch" || return 1
    [ "${path##*/}" = "$branch" ] || return 1
    parent="$(CDPATH="" cd "${path%/*}" 2>/dev/null && pwd -P)" || return 1
    [ "$parent" = "$WORKTREES_TOP" ] || return 1
    closed_on_trusted "$branch"
}

run_closed() {
    local i path branch locked top msg result removed_n=0 skipped_n=0 open_n=0 failed=0
    REMOVED=(); SKIPPED_PATH=(); SKIPPED_WHY=()
    CLOSED_REFS="$(spec_trusted_refs "$ROOT")"
    if [ -z "$CLOSED_REFS" ]; then
        msg="Refusing --closed: no trusted integration branch resolves, so no change can be called closed. Set origin/HEAD (git remote set-head origin --auto) and fetch, then rerun."
        if $JSON_MODE; then emit_json refused closed "$msg"; else >&2 echo "[prdkit] $msg"; fi
        exit 1
    fi
    WORKTREES_TOP="$(CDPATH="" cd "$ROOT/.worktrees" 2>/dev/null && pwd -P)" || WORKTREES_TOP=""

    # Entry 0 is the main checkout.
    for ((i = 1; i < ${#ENT_PATH[@]}; i++)); do
        path="${ENT_PATH[$i]}"; branch="${ENT_BRANCH[$i]}"; locked="${ENT_LOCKED[$i]}"
        # A bare repository or a registration whose directory is gone is no candidate.
        if [ "${ENT_BARE[$i]}" = true ] || [ "${ENT_PRUNABLE[$i]}" = true ]; then continue; fi
        top="$(CDPATH="" cd "$path" 2>/dev/null && pwd -P)" || top="$path"
        [ "$top" != "$ROOT_TOP" ] || continue
        if ! worktree_closed "$branch" "$path"; then
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

    msg="Removed $removed_n closed change worktree(s), skipped $skipped_n, left $open_n for open or unrelated work."
    if $JSON_MODE; then
        local skipped_json="" sep=""
        i=0
        while [ "$i" -lt "${#SKIPPED_PATH[@]}" ]; do
            skipped_json="$skipped_json$sep{\"path\":\"$(json_escape "${SKIPPED_PATH[$i]}")\",\"reason\":\"$(json_escape "${SKIPPED_WHY[$i]}")\"}"
            sep=","; i=$((i + 1))
        done
        result=ok; [ "$failed" -eq 0 ] || result=refused
        printf '{"result":"%s","action":"closed","message":"%s","paths":%s,"skipped":[%s],"pruned":[]}\n' \
            "$result" "$(json_escape "$msg")" "$(json_array ${REMOVED[@]+"${REMOVED[@]}"})" "$skipped_json"
    else
        echo "[prdkit] $msg"
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
    prune_stale "$MATCH_PATH"
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
