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
    ( cd "$d" && bash .product-kit/scripts/init.sh ) >/dev/null 2>&1
    echo "$d"
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
