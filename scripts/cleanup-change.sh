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
                changes (git worktree remove --force). Discards those changes,
                never a submodule commit that exists only in the worktree.
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
work is not checked for integration; it stays on the change's branch, which
is never deleted. Ignored files go with the worktree, except evidence,
retrospectives and usage-enrichment inputs, which are first copied to this
checkout. Archive and remove any legacy ledger spool yourself before cleanup.

For worktrees with submodules, Git removal may require --force even when
clean. Cleanup rechecks cleanliness under its removal lock before using this
mode automatically. Locked worktrees stay locked.

A worktree keeps its own copy of each submodule repository. Before removal it
is moved to a reported prdkit-retired directory under the common Git directory.
Only the operator purges a retained copy, after checking its refs and reflogs.
Every removal, --force included, is refused while such a copy holds a
commit (HEAD, any ref or retained reflog entry, or a gitlink the worktree records)
that is not reachable from HEAD or a non-tracking ref in an independent main
checkout's submodule. Fetch it into a local branch or tag there, then rerun.

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
common_dir="$(cd "$ROOT" && cd "$common_dir" && pwd -P)"
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

stale_commits_retained() (
    local dir="$1" path log head roots oid refs orig=""
    set -o pipefail
    export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1
    # Only the ordinary files backend, HEAD and its log are supported. Refuse
    # per-worktree refs, pseudo-refs and other operation state rather than omit roots.
    shopt -s nullglob dotglob
    for path in "$dir"/*; do
        [ ! -L "$path" ] || return 1
        case "${path##*/}" in
            HEAD|gitdir|commondir|index|COMMIT_EDITMSG) [ -f "$path" ] || return 1 ;;
            ORIG_HEAD) [ -f "$path" ] && orig="$(git --git-dir="$dir" rev-parse --verify 'ORIG_HEAD^{commit}')" || return 1 ;;
            logs) [ -d "$path" ] && [ -r "$path" ] && [ -x "$path" ] || return 1
                  for log in "$path"/*; do
                      [ "$log" = "$dir/logs/HEAD" ] && [ ! -L "$log" ] && [ -f "$log" ] || return 1
                  done ;;
            refs) [ -d "$path" ] && roots="$(find "$path" ! -type d -print)" && [ -z "$roots" ] || return 1 ;;
            *) return 1 ;;
        esac
    done
    [ ! -e "$common_dir/info/grafts" ] && [ -z "${GIT_GRAFT_FILE:-}" ] || return 1
    head="$(git --git-dir="$dir" rev-parse --verify 'HEAD^{commit}')" || return 1
    roots="$head"
    if [ -e "$dir/logs/HEAD" ]; then
        # Include BOTH endpoints: Git's log walker can omit a log's oldest old OID.
        roots="$(LC_ALL=C awk -v len="${#head}" '
          length($1)!=len || length($2)!=len || $1$2 ~ /[^0-9a-f]/ {exit 1}
          {if ($1 !~ /^0+$/) print $1; if ($2 !~ /^0+$/) print $2}' "$dir/logs/HEAD")" || return 1
        roots="$head
$roots"
    fi
    roots="$(printf '%s\n' "$roots" "$orig" | LC_ALL=C sort -u)" || return 1
    while IFS= read -r oid; do
        [ -n "$oid" ] || continue
        refs="$(git -C "$ROOT" for-each-ref --contains="$oid" --format='%(refname)' refs/heads refs/tags)" &&
            [ -n "$refs" ] || return 1
    done <<< "$roots"
)
prunable_without_store() (
    local path="$1" admins="$common_dir/worktrees" dir target matches=0
    [ ! -e "$path" ] && [ ! -L "$path" ] || return 1
    [ -r "$admins" ] && [ -x "$admins" ] || return 1
    shopt -s nullglob dotglob
    for dir in "$admins"/*; do
        [ -d "$dir" ] && [ ! -L "$dir" ] && [ -r "$dir" ] && [ -x "$dir" ] &&
            [ -f "$dir/gitdir" ] && [ ! -L "$dir/gitdir" ] && target="$(cat "$dir/gitdir")" || return 1
        case "$target" in
            /*) ;;
            */.git) target="$(git -C "$dir" --git-dir=. rev-parse --path-format=absolute --git-path "$target")" || return 1 ;;
            *) return 1 ;;
        esac
        [ "$target" = "$path/.git" ] || continue
        [ ! -e "$dir/modules" ] && [ ! -L "$dir/modules" ] || return 1
        stale_commits_retained "$dir" || return 1
        matches=$((matches + 1))
    done
    [ "$matches" -eq 1 ]
)
prune_stale() {
    local p msg
    if [ "$#" -eq 0 ]; then
        if $JSON_MODE; then
            emit_json ok prune "No stale worktree registrations to prune."
        else
            echo "[prdkit] No stale worktree registrations to prune."
        fi
        return 0
    fi
    for p in "$@"; do
        if ! prunable_without_store "$p"; then
            msg="Refusing to prune $p: registration is ambiguous, has submodule data or cannot prove every local commit is retained. Recover its state and retain its commits on a shared branch or tag first."
            if $JSON_MODE; then emit_json refused prune "$msg"; else echo "[prdkit] $msg" >&2; fi
            return 1
        fi
    done
    for p in "$@"; do
        if ! prunable_without_store "$p" || ! git -C "$ROOT" worktree remove -- "$p"; then
            msg="Could not prune $p; inspect the current registrations before retrying."
            if $JSON_MODE; then emit_json refused prune "$msg"; else echo "[prdkit] $msg" >&2; fi
            return 1
        fi
    done
    msg="Pruned $# stale worktree registration(s) whose directories were already gone."
    if $JSON_MODE; then emit_json ok prune "$msg" "$@"; else echo "[prdkit] $msg"; printf '  %s\n' "$@"; fi
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

# Each linked worktree keeps its own copy of every submodule repository under its git directory
# (<git-dir>/modules/<name>), and removing the worktree deletes it. A commit made there, even one
# the superproject branch records as a gitlink, then exists nowhere unless something outside the
# worktree holds it. Every commit such a copy keeps (HEAD, every ref including tracking refs,
# every entry in their reflogs, such as an older stash) and each gitlink in the
# worktree's index and HEAD tree that it contains must be reachable in the surviving copy.
# submodule_commits_held sets UNSAFE_MODULE and UNSAFE_COMMIT and returns 1 for the first commit
# that is not, and returns 2 when git cannot say: an inspection that fails never passes.
UNSAFE_MODULE=""; UNSAFE_COMMIT=""
independent_store() { # conservative: only accept a self-contained main repository
    local module="$1" links rc
    [ -z "${GIT_OBJECT_DIRECTORY:-}${GIT_ALTERNATE_OBJECT_DIRECTORIES:-}${GIT_COMMON_DIR:-}" ] &&
        [ "$(CDPATH='' cd -P "$module" && pwd -P)" = "$module" ] &&
        [ -d "$module/objects" ] && [ ! -e "$module/commondir" ] &&
        [ ! -s "$module/objects/info/alternates" ] &&
        [ ! -e "$module/shallow" ] && [ ! -e "$module/info/grafts" ] &&
        [ -z "${GIT_SHALLOW_FILE:-}${GIT_GRAFT_FILE:-}" ] &&
        links="$(find "$module" \( -type l -o -name '*.promisor' \) -print)" && [ -z "$links" ] || return 1
    # The config can precede the first promisor pack. Read failures are not absence.
    rc=0
    git --git-dir="$module" config --get-regexp '^(extensions\.partialclone|remote\..*\.(promisor|partialclonefilter))$' >/dev/null || rc=$?
    [ "$rc" = 1 ] && [ "$(git --git-dir="$module" rev-parse --is-shallow-repository)" = false ] &&
        git --git-dir="$module" fsck --connectivity-only --no-reflogs >/dev/null 2>&1
}
held_outside() { # main checkout's module git dir, commit
    local refs
    [ -d "$1/objects" ] || return 1
    git --git-dir="$1" cat-file -e "$2^{commit}" 2>/dev/null || return 1
    git --git-dir="$1" merge-base --is-ancestor "$2" HEAD 2>/dev/null && return 0
    refs="$(git --git-dir="$1" for-each-ref --contains "$2" --format='%(refname)' 2>/dev/null)" &&
        printf '%s\n' "$refs" | awk 'NF && !/^refs\/remotes\// { found=1 } END { exit !found }'
}
# HEAD of a repository (git options in "$@"): prints it and returns 0; returns 1 when it is unborn
# (a symbolic ref to a branch with no commit yet) and 2 when git cannot say.
head_of() {
    local ref found
    git "$@" rev-parse --verify -q HEAD 2>/dev/null && return 0
    ref="$(git "$@" symbolic-ref -q HEAD 2>/dev/null)" || return 2
    found="$(git "$@" for-each-ref --format='%(refname)' "$ref" 2>/dev/null)" || return 2
    [ -z "$found" ] || return 2
    return 1
}
# HEAD, all refs and all their retained reflog entries, including tracking-only commits.
module_commits() { # module git dir
    local mod="$1" refs ref state=0
    refs="$(git --git-dir="$mod" for-each-ref --format='%(refname)' 2>/dev/null)" || return 1
    head_of --git-dir="$mod" >/dev/null || state=$?
    case "$state" in
        0) refs="HEAD
$refs" ;;
        1) ;;
        *) return 1 ;;
    esac
    while IFS= read -r ref; do
        [ -n "$ref" ] || continue
        git --git-dir="$mod" rev-parse --verify -q "$ref" 2>/dev/null || return 1
        # A ref without a reflog lists nothing and succeeds.
        git --git-dir="$mod" log -g --format=%H "$ref" -- 2>/dev/null || return 1
    done <<EOF
$refs
EOF
}
# Checks every submodule copy whose HEAD file is listed, NUL-separated, in $2 (found under $1).
scan_modules() { # modules dir, list file
    local mods="$1" common head mod rel links own present c t state=0
    common="$(git -C "$ROOT" rev-parse --git-common-dir 2>/dev/null)" || return 2
    common="$(CDPATH="" cd "$ROOT" && CDPATH="" cd "$common" && pwd -P)" || return 2
    links="$(git -C "$WT" ls-files -s 2>/dev/null)" || return 2
    links="$(printf '%s\n' "$links" | awk '$1 == "160000" { print $2 }')"
    head_of -C "$WT" >/dev/null || state=$?
    case "$state" in
        0) own="$(git -C "$WT" ls-tree -r HEAD 2>/dev/null)" || return 2
           links="$links
$(printf '%s\n' "$own" | awk '$2 == "commit" { print $3 }')" ;;
        1) ;;
        *) return 2 ;;
    esac
    links="$(printf '%s\n' "$links" | awk 'NF' | sort -u)"
    # A submodule copy is a directory under modules/ with its own HEAD and objects; nested
    # submodules sit under its own modules/ and are found the same way.
    while IFS= read -r -d '' head; do
        mod="${head%/HEAD}"
        [ -d "$mod/objects" ] || continue
        rel="${mod#"$mods"/}"
        if [ -e "$mod/worktrees" ] || [ -L "$mod/worktrees" ]; then
            UNSAFE_MODULE="$rel administers linked worktrees"; return 4
        fi
        if ! independent_store "$common/modules/$rel"; then
            UNSAFE_MODULE="$rel"; return 3
        fi
        own="$(module_commits "$mod")" || return 2
        while IFS= read -r c; do
            [ -n "$c" ] || continue
            c="$(git --git-dir="$mod" rev-parse --verify -q "$c^{}" 2>/dev/null)" || return 2
            t="$(git --git-dir="$mod" cat-file -t "$c" 2>/dev/null)" || return 2
            [ "$t" = commit ] || continue   # a tag of a tree or blob holds no commit
            held_outside "$common/modules/$rel" "$c" && continue
            UNSAFE_MODULE="$rel"; UNSAFE_COMMIT="$c"
            return 1
        done <<EOF
$(printf '%s\n' "$own" | sort -u)
EOF
        [ -n "$links" ] || continue
        # "<id> commit <size>" for a gitlink this copy holds, "<id> missing" for another one's.
        present="$(printf '%s\n' "$links" | git --git-dir="$mod" cat-file --batch-check 2>/dev/null)" || return 2
        while IFS= read -r c; do
            [ -n "$c" ] || continue
            held_outside "$common/modules/$rel" "$c" && continue
            UNSAFE_MODULE="$rel"; UNSAFE_COMMIT="$c"
            return 1
        done <<EOF
$(printf '%s\n' "$present" | awk '$2 == "commit" { print $1 }')
EOF
    done < "$2"
    return 0
}
# Git reads around a file it cannot open: `log -g` lists nothing and `cat-file --batch-check` says
# "missing", both with exit 0. So before git looks, every path under the submodule copies must be
# a directory this run can read and search or a regular file it can open for reading. Sets
# UNREADABLE to the first path that is not and returns 2; a traversal that fails returns 2 too.
UNREADABLE=""
modules_readable() { # modules dir
    local list p state=0
    list="$(mktemp 2>/dev/null)" || return 2
    # A failed traversal refuses whatever it listed; what it listed still names the culprit.
    find -L "$1" -print0 > "$list" 2>/dev/null || state=2
    while IFS= read -r -d '' p; do
        if [ -d "$p" ]; then
            [ -r "$p" ] && [ -x "$p" ] && continue
        elif [ -f "$p" ]; then
            [ -r "$p" ] && true 2>/dev/null < "$p" && continue
        fi
        UNREADABLE="$p"; state=2
        break
    done < "$list"
    rm -f "$list"
    return "$state"
}
# Every populated checkout, including nested ones, must use a gitfile pointing
# into the administrative tree scanned below. An embedded store is not scanned.
supported_gitfiles() {
    local admin="$1" file mod
    while IFS= read -r -d '' file; do
        [ "$file" != "$WT/.git" ] || continue
        UNSAFE_MODULE="${file#"$WT"/}"
        [ -f "$file" ] && [ ! -L "$file" ] || return 4
        mod="$(git rev-parse --resolve-git-dir "$file")" && mod="$(cd -P "$mod" && pwd -P)" || return 4
        case "$mod" in "$admin/modules/"*) ;; *) return 4 ;; esac
        [ -d "$mod/objects" ] && [ -f "$mod/HEAD" ] && [ ! -L "$mod/HEAD" ] || return 4
    done < "$2"
}
submodule_commits_held() {
    local admin list state=0
    local GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1
    export GIT_NO_REPLACE_OBJECTS GIT_NO_LAZY_FETCH
    UNSAFE_MODULE=""; UNSAFE_COMMIT=""; UNREADABLE=""
    admin="$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)" || return 2
    list="$(mktemp)" || return 2
    if find "$WT" -iname .git -prune -print0 > "$list"; then
        supported_gitfiles "$admin" "$list" || state=$?
    else
        state=2
    fi
    rm -f "$list"
    [ "$state" -eq 0 ] || return "$state"
    # A modules entry this run cannot see, or one that is not a directory, is not an absent one.
    { [ -r "$admin" ] && [ -x "$admin" ]; } || { UNREADABLE="$admin"; return 2; }
    if [ ! -e "$admin/modules" ]; then
        [ -L "$admin/modules" ] && { UNREADABLE="$admin/modules"; return 2; }
        return 0
    fi
    [ -d "$admin/modules" ] && [ ! -L "$admin/modules" ] || { UNREADABLE="$admin/modules"; return 2; }
    modules_readable "$admin/modules" || return 2
    list="$(mktemp 2>/dev/null)" || return 2
    if find "$admin/modules" -type f -name HEAD -print0 > "$list" 2>/dev/null; then
        scan_modules "$admin/modules" "$list" || state=$?
    else
        state=2
    fi
    rm -f "$list"
    return "$state"
}
# Refuses (and returns 1) unless every submodule commit is held outside the worktree.
check_submodule_commits() {
    local state=0
    submodule_commits_held || state=$?
    case "$state" in
        0) return 0 ;;
        1) refuse_with "unpushed submodule commit $UNSAFE_COMMIT in $UNSAFE_MODULE" \
            "Refusing to remove $WT: its copy of submodule $UNSAFE_MODULE holds commit $UNSAFE_COMMIT, which is not proven reachable in the main checkout's submodule. Fetch it into a local branch or tag in that copy before retrying." ;;
        3) refuse_with "independent store not verified for $UNSAFE_MODULE" \
            "Refusing to remove $WT: cannot verify an independent object store for submodule $UNSAFE_MODULE. Use a self-contained main-checkout copy without links or alternates before retrying." ;;
        4) refuse_with "unsupported submodule layout: $UNSAFE_MODULE" \
            "Refusing to remove $WT: unsupported submodule layout: $UNSAFE_MODULE. Preserve its commits and relocate dependent checkouts before retrying." ;;
        *) if [ -n "$UNREADABLE" ]; then
               refuse_with "cannot read $UNREADABLE" \
                   "Refusing to remove $WT: this run cannot read $UNREADABLE, so it cannot tell whether the worktree's copy of a submodule holds commits that exist nowhere else, and git would not say. Restore read access (and search access for a directory), then rerun."
           else
               refuse_git "git could not list the commits in the worktree's submodules"
           fi ;;
    esac
    return 1
}

# A forced removal runs under a mutex: the directory prdkit-cleanup.lock in the worktree's git
# directory, created atomically with mkdir, so two runs cannot remove the same worktree at once.
# The checks are repeated under it. A successful removal deletes it with the git directory; a
# refused or failed one, or an interrupted run, removes it again. A run killed outright leaves it,
# and later runs refuse until it is removed.
MUTEX=""
release_mutex() {
    if [ -n "$MUTEX" ]; then
        if [ -f "$MUTEX/modules" ]; then
            if [ ! -L "${MUTEX%/*}/modules" ] && [ "${MUTEX%/*}/modules" -ef "$MUTEX/modules" ]; then
                rm -f "${MUTEX%/*}/modules"
            fi
            rm -f "$MUTEX/modules"
        fi
        rmdir "$MUTEX" 2>/dev/null || true
    fi
    MUTEX=""
}
trap release_mutex EXIT
trap 'release_mutex; exit 130' INT
trap 'release_mutex; exit 143' TERM
RETIRED=""
retire_modules() { # admin: preserve the directory itself, including late Git writes
    local admin="$1" src="$1/modules" root="$common_dir/prdkit-retired" probe hazards
    [ -e "$src" ] || { [ ! -L "$src" ]; return; }
    case "$root/" in "$WT"/*) return 1 ;; esac
    [ ! -L "$src" ] && [ -d "$src" ] && [ ! -L "$root" ] && mkdir -p "$root" || return 1
    # Relative dependencies would not necessarily resolve after relocation.
    hazards="$(find "$src" \( -type l -o -name commondir -o -path '*/objects/info/alternates' \) -print)" &&
        [ -z "$hazards" ] || return 1
    RETIRED="$(mktemp -d "$root/${admin##*/}.XXXXXXXX")" || return 1
    # A cross-device mv can silently copy then delete, missing concurrent writes.
    # Require the same filesystem before moving, including when modules is mounted.
    probe="$(mktemp "$src/.prdkit-device.XXXXXXXX")" || return 1
    if ! ln "$probe" "$RETIRED/device"; then rm -f "$probe"; return 1; fi
    rm "$probe" "$RETIRED/device" || return 1
    echo "[prdkit] Retiring submodule stores to $RETIRED/modules" >&2
    mv "$src" "$RETIRED/modules"
}
refuse_mutex() {
    refuse_with "another cleanup-change.sh run is removing it" \
        "Refusing to remove $WT: another cleanup-change.sh run holds $1/prdkit-cleanup.lock and is removing it. If no run is active, inspect its retained stores before removing the lock and retrying."
}
forced_remove() { # recheck_clean (true for the submodule retry)
    local admin err state
    admin="$(git -C "$WT" rev-parse --absolute-git-dir 2>/dev/null)" || { refuse_git "git could not resolve the worktree's git directory"; return 1; }
    if ! mkdir "$admin/prdkit-cleanup.lock" 2>/dev/null; then
        refuse_mutex "$admin"
        return 1
    fi
    MUTEX="$admin/prdkit-cleanup.lock"
    if [ "$1" = true ]; then
        state=0; wt_dirty || state=$?
        case "$state" in
            0) release_mutex; refuse_dirty; return 1 ;;
            2) release_mutex; refuse_git "git status failed in the worktree"; return 1 ;;
        esac
    fi
    check_submodule_commits || { release_mutex; return 1; }
    # Reserve the modules name even if it was absent at inspection. Refuse if
    # a writer already created another directory. Git removes only our guard.
    if ! retire_modules "$admin" || ! { : > "$MUTEX/modules" && ln "$MUTEX/modules" "$admin" &&
        [ ! -L "$admin/modules" ] && [ "$admin/modules" -ef "$MUTEX/modules" ]; }; then
        release_mutex; refuse_with "could not retire submodule stores${RETIRED:+ at $RETIRED}" \
            "Refusing to remove $WT: could not retire submodule stores safely. Inspect $admin/modules${RETIRED:+ and $RETIRED} before retrying."; return 1
    fi
    err="$(LC_ALL=C git -C "$ROOT" worktree remove --force "$WT" 2>&1 >/dev/null)" || {
        release_mutex; refuse_git "$err${RETIRED:+; recover submodule stores from $RETIRED/modules}"; return 1;
    }
    MUTEX=""   # removed with the worktree's git directory
}

RESULT_REASON=""; RESULT_MSG=""; RETRIED=false
remove_worktree() { # path label locked
    local label="$2" locked="$3" rm_err state admin
    WT="$1"; PRESERVED=0; CONFLICT=""; RETRIED=false; RETIRED=""
    admin="$(git -C "$WT" rev-parse --absolute-git-dir)" || { refuse_git "cannot resolve worktree administration"; return 1; }
    if [ -e "$admin/prdkit-cleanup.lock" ]; then refuse_mutex "$admin"; return 1; fi
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
    # --force discards uncommitted changes only, never a commit that exists nowhere else.
    check_submodule_commits || return 1

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

    if [ "$FORCE" = true ]; then
        forced_remove false || return 1
    elif [ -e "$admin/modules" ]; then
        # Even a deinitialized submodule may still have a store. Git needn't
        # refuse ordinary removal in that case, so retire it before either path.
        RETRIED=true
        forced_remove true || return 1
    elif ! rm_err="$(LC_ALL=C git -C "$ROOT" worktree remove "$WT" 2>&1 >/dev/null)"; then
        # Cleanliness was proven above, but a worktree with submodules is refused regardless.
        # Retry forced under the mutex, after re-checking cleanliness and the submodule commits: with
        # nothing uncommitted, --force discards nothing. A locked worktree stays refused, with
        # git's reason.
        if [ "$locked" = true ] || ! submodule_refusal "$rm_err"; then
            refuse_git "$rm_err"; return 1
        fi
        RETRIED=true
        forced_remove true || return 1
    fi
    RESULT_REASON="removed"
    RESULT_MSG="Removed worktree for '$label': $WT"
    [ -z "$RETIRED" ] || RESULT_MSG="$RESULT_MSG; retained submodule stores at $RETIRED/modules"
    [ "$PRESERVED" -eq 0 ] || RESULT_MSG="$RESULT_MSG; preserved $PRESERVED evidence file(s) in $ROOT/.prdkit/"
    [ "$RETRIED" = false ] || RESULT_MSG="$RESULT_MSG; the worktree contains submodules, which git refuses to remove without --force, so it was removed with --force after confirming it had no uncommitted or untracked changes and no submodule commit kept only there"
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
