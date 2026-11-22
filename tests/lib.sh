#!/usr/bin/env bash
# Tiny dependency-free test harness for Product-Kit.
# Source this from a test_*.sh file. It provides assertions, counters, and
# helpers to build a throwaway initialized project. No bats/npm required.

# Resolve the Product-Kit repo root (parent of the tests/ dir).
TESTS_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PK_ROOT="$(CDPATH="" cd "$TESTS_DIR/.." && pwd)"

# Fail before any fixture Git command if temporary storage is unavailable. Several suites
# intentionally aggregate assertions without errexit; an empty fixture path would run Git
# in the caller's real checkout. Probe allocation, not just directory existence/permissions.
if ! _TMP_PROBE="$(mktemp -d)" || [ -z "$_TMP_PROBE" ] || [ ! -d "$_TMP_PROBE" ]; then
    echo 'Cannot allocate test fixture storage; check TMPDIR. No tests were started.' >&2
    exit 1
fi
# Allocation can also fail later (a full or cleaned TMPDIR), leaving a fixture path empty, and
# `git -C ""` or a helper's repo-root fallback then acts on the current directory. Run every suite
# from this empty scratch directory and stop Git discovery at its parent, so such a fall-through
# meets "not a git repository" instead of the caller's checkout.
GIT_CEILING_DIRECTORIES="$(dirname "$_TMP_PROBE")"; export GIT_CEILING_DIRECTORIES
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_COMMON_DIR GIT_NAMESPACE GIT_IMPLICIT_WORK_TREE GIT_GRAFT_FILE GIT_REPLACE_REF_BASE \
    GIT_NO_REPLACE_OBJECTS GIT_SHALLOW_FILE GIT_PREFIX GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS \
    GIT_QUARANTINE_PATH GIT_TEMPLATE_DIR
cd "$_TMP_PROBE" || exit 1
_SCRATCH_CWD="$_TMP_PROBE"
unset _TMP_PROBE

VERBOSE="${VERBOSE:-false}"
[ "${1:-}" = "-v" ] && VERBOSE=true

_PASS=0
_FAIL=0
_CURRENT="(none)"

# Colors only when stdout is a terminal.
if [ -t 1 ]; then _G=$'\033[32m'; _R=$'\033[31m'; _Y=$'\033[33m'; _0=$'\033[0m'; else _G=; _R=; _Y=; _0=; fi

it() { _CURRENT="$1"; }   # name the current assertion group

_ok()  { _PASS=$((_PASS+1)); $VERBOSE && echo "  ${_G}ok${_0}   $1"; return 0; }
_no()  { _FAIL=$((_FAIL+1)); echo "  ${_R}FAIL${_0} $1"; [ -n "${2:-}" ] && echo "       $2"; return 1; }

assert_eq() { # expected actual [msg]
    if [ "$1" = "$2" ]; then _ok "${3:-$_CURRENT}"; else
        _no "${3:-$_CURRENT}" "expected: [$1]  actual: [$2]"; fi
}
assert_contains() { # haystack needle [msg]
    case "$1" in *"$2"*) _ok "${3:-$_CURRENT}";; *) _no "${3:-$_CURRENT}" "[$1] does not contain [$2]";; esac
}
assert_not_contains() { # haystack needle [msg]
    case "$1" in *"$2"*) _no "${3:-$_CURRENT}" "[$1] unexpectedly contains [$2]";; *) _ok "${3:-$_CURRENT}";; esac
}
assert_file() { # path [msg]
    if [ -f "$1" ]; then _ok "${2:-file exists: $1}"; else _no "${2:-file exists: $1}" "missing: $1"; fi
}
assert_symlink() { # path [msg]
    if [ -L "$1" ]; then _ok "${2:-symlink: $1}"; else _no "${2:-symlink: $1}" "not a symlink: $1"; fi
}
# Run a command, capture combined output into $OUTPUT and status into $STATUS.
# shellcheck disable=SC2034 # OUTPUT and STATUS are consumed by the test files that source this lib
run() {
    if OUTPUT="$("$@" 2>&1)"; then STATUS=0; else STATUS=$?; fi
    return 0
}

# Build a fresh git project with an initial commit. Echoes the project dir.
make_project() {
    local d; d="$(mktemp -d)" || return 1
    [ -n "$d" ] && [ -d "$d" ] || return 1
    git -C "$d" init -q
    git -C "$d" config user.email t@example.com
    git -C "$d" config user.name test
    # Product-Kit must be reachable as if it were the .product-kit submodule.
    mkdir -p "$d/.product-kit"
    cp -r "$PK_ROOT/commands" "$PK_ROOT/workflows" "$PK_ROOT/scripts" "$PK_ROOT/templates" "$d/.product-kit/"
    [ -f "$PK_ROOT/VERSION" ] && cp "$PK_ROOT/VERSION" "$d/.product-kit/"
    : > "$d/.gitkeep"
    git -C "$d" add -A >/dev/null 2>&1
    git -C "$d" commit -q -m "init" >/dev/null 2>&1
    echo "$d"
}

# Build a project AND run init.sh into it. Echoes the project dir.
make_inited_project() {
    local d; d="$(make_project)" || return 1
    ( cd "$d" && bash .product-kit/scripts/init.sh "$@" ) >/dev/null 2>&1
    echo "$d"
}

# A 2.0 upgrade reads a committed install and local trusted default history.
# Only for disposable fixtures: stage the prepared state and point origin/HEAD at it.
snapshot_upgrade_fixture() {
    local project="${1:-}"
    [ -n "$project" ] && [ -d "$project/.git" ] || return 1
    git -C "$project" add -A &&
        git -C "$project" commit -q --allow-empty -m 'prepare upgrade fixture' &&
        git -C "$project" update-ref refs/remotes/origin/main HEAD &&
        git -C "$project" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
}

# Commit stdin as <path> on top of a trusted remote-tracking ref and move the ref there, as a
# policy change landing on the integration branch would, without touching the checkout or branch.
trusted_edit() { # ref path < content
    local idx blob tree commit
    idx="$(mktemp)" || return 1; rm -f "$idx"
    GIT_INDEX_FILE="$idx" git read-tree "$1" &&
        blob="$(git hash-object -w --stdin)" &&
        GIT_INDEX_FILE="$idx" git update-index --add --cacheinfo "100644,$blob,$2" &&
        tree="$(GIT_INDEX_FILE="$idx" git write-tree)" &&
        commit="$(git commit-tree "$tree" -p "$1" -m "trusted policy: $2")" &&
        git update-ref "$1" "$commit"
    local status=$?; rm -f "$idx"; return "$status"
}

# Per-test host fixtures. The executable is always this repository's stub, never a real gh.
use_gh_stub() { # [fixture directory]
    GH_STUB_DIR="${1:-$(mktemp -d)}"; export GH_STUB_DIR
    [ -n "$GH_STUB_DIR" ] || return 1
    mkdir -p "$GH_STUB_DIR/bin" "$GH_STUB_DIR/pulls" "$GH_STUB_DIR/reviews" \
        "$GH_STUB_DIR/routes" "$GH_STUB_DIR/users" "$GH_STUB_DIR/issues/comments"
    cp "$TESTS_DIR/gh-stub.sh" "$GH_STUB_DIR/bin/gh"
    chmod +x "$GH_STUB_DIR/bin/gh"
    : > "$GH_STUB_DIR/requests"
    printf '%s\n' '{"__typename":"Bot","login":"publisher[bot]","databaseId":1001}' > "$GH_STUB_DIR/publisher.json"
    printf '%s\n' '[]' > "$GH_STUB_DIR/activity.json"
    export PATH="$GH_STUB_DIR/bin:$PATH"
    track_tmp "$GH_STUB_DIR"
}

fx_pr() { # number head [JSON overrides, including head/base/author]
    local overrides="${3:-}"
    [ -n "$overrides" ] || overrides='{}'
    jq -n --argjson number "$1" --arg head "$2" --argjson overrides "$overrides" '
        {number:$number,html_url:("https://github.com/owner/repo/pull/"+($number|tostring)),
         state:"open",merged_at:null,created_at:"2026-01-01T00:00:00Z",
         author:{__typename:"User",login:"maker",databaseId:1002},user:{id:1002,login:"maker",type:"User"},
         head:{sha:$head,ref:"feature",label:"owner:feature",repo:{full_name:"owner/repo",owner:{login:"owner"}}},
         base:{ref:"main"}} * $overrides' > "$GH_STUB_DIR/pulls/$1.json"
    [ -f "$GH_STUB_DIR/reviews/$1.json" ] || printf '%s\n' '[]' > "$GH_STUB_DIR/reviews/$1.json"
}

fx_review() { # PR body [GraphQL review JSON overrides]
    local overrides="${3:-}" next next_id
    [ -n "$overrides" ] || overrides='{}'
    next="$GH_STUB_DIR/reviews/$1.next"
    next_id="$(jq -s '[.[][] | .fullDatabaseId | tonumber] | (max // 1000) + 1' "$GH_STUB_DIR"/reviews/*.json)" || return 1
    jq --arg body "$2" --argjson number "$1" --argjson overrides "$overrides" \
        --argjson id "$next_id" \
        --slurpfile pr "$GH_STUB_DIR/pulls/$1.json" --slurpfile author "$GH_STUB_DIR/publisher.json" '
        . + [({fullDatabaseId:($id|tostring),url:("https://github.com/owner/repo/pull/"+($number|tostring)+"#pullrequestreview-"+($id|tostring)),
               body:$body,state:"COMMENTED",submittedAt:"2026-01-02T00:00:00Z",lastEditedAt:null,editor:null,
               author:$author[0],commit:{oid:$pr[0].head.sha}} * $overrides)]' "$GH_STUB_DIR/reviews/$1.json" > "$next" &&
        mv "$next" "$GH_STUB_DIR/reviews/$1.json"
}

fx_owner_review() { # PR APPROVED|CHANGES_REQUESTED|DISMISSED commit [overrides]
    local overrides="${4:-}"
    [ -n "$overrides" ] || overrides='{}'
    overrides="$(jq -n --arg state "$2" --arg commit "$3" --argjson overrides "$overrides" '
        {state:$state,commit:{oid:$commit},author:{__typename:"User",login:"owner",databaseId:1003}} * $overrides')" || return 1
    fx_review "$1" 'Owner review.' "$overrides"
}

fx_activity() { # before after [activity JSON overrides]
    local overrides="${3:-}"
    [ -n "$overrides" ] || overrides='{}'
    jq --arg before "$1" --arg after "$2" --argjson overrides "$overrides" '
        . + [({id:(length+1001),activity_type:"push",ref:"refs/heads/feature",before:$before,after:$after,
               timestamp:"2026-01-01T12:00:00Z"} * $overrides)]' "$GH_STUB_DIR/activity.json" > "$GH_STUB_DIR/activity.next" &&
        mv "$GH_STUB_DIR/activity.next" "$GH_STUB_DIR/activity.json"
}

fx_closed_pr() { # number head [JSON overrides; merged_at non-null models a merge]
    local overrides="${3:-}"
    [ -n "$overrides" ] || overrides='{}'
    overrides="$(jq -n --argjson overrides "$overrides" '{state:"closed"} * $overrides')" || return 1
    fx_pr "$1" "$2" "$overrides"
}

# Register cleanup of temp dirs created during the run.
_TMPDIRS=()
track_tmp() { _TMPDIRS+=("$1"); }
_TMPDIRS+=("$_SCRATCH_CWD")
_cleanup() {
    local dir
    for dir in "${_TMPDIRS[@]:-}"; do
        if [ -n "$dir" ]; then rm -rf "$dir"; fi
    done
    return 0
}
trap _cleanup EXIT

finish() {
    echo
    if [ "$_FAIL" -eq 0 ]; then
        echo "${_G}PASS${_0}: $_PASS assertion(s)"
        exit 0
    else
        echo "${_R}FAIL${_0}: $_FAIL failed, $_PASS passed"
        exit 1
    fi
}
