#!/usr/bin/env bash
# Common functions for all scripts.

# Get repository root, with fallback for non-git repositories.
# Resolved from THIS FILE's location, not the caller's cwd: an installed
# script invoked from some other git repository must operate on the project
# it is installed in, never on whatever repo the shell happens to be in.
get_repo_root() {
    local script_dir
    script_dir="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if git -C "$script_dir" rev-parse --show-toplevel >/dev/null 2>&1; then
        git -C "$script_dir" rev-parse --show-toplevel
    else
        # Fall back to the install layout (.prdkit/scripts/bash -> repo root)
        (cd "$script_dir/../../.." && pwd)
    fi
}

# Stop a consumer-facing script run from the kit source (for example .product-kit/scripts/x.sh):
# it resolves its root from its own location, so it would check or write the kit checkout
# instead of the project. The installed copy lives in <project>/.prdkit/scripts/bash/.
require_consumer_root() { # root script-name
    [ -d "$1/.prdkit" ] && return 0
    echo "$2: resolved root $1 has no .prdkit/ (a kit-source run, or a project nested inside another Git repository); run the installed copy <project>/.prdkit/scripts/bash/$2 from a project whose Git root holds .prdkit/" >&2
    exit 2
}

# A change id is NNN-short-name: digits, a hyphen, then lowercase/digit words joined by
# single hyphens. It never contains a slash, a dot segment or whitespace, so it is safe
# to join into a path.
is_change_id() {
    [[ "$1" =~ ^[0-9]{3,}-[a-z0-9]+(-[a-z0-9]+)*$ ]]
}

# Escape a UTF-8 value for embedding inside a double-quoted JSON string. Bash
# strings cannot contain NUL; every other U+0001–U+001F control must be escaped.
json_escape() {
    local s="$1" code octal character escaped
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\t'/\\t}"
    # Keep the common path cheap; use Bash builtins (including on macOS 3.2),
    # not locale-sensitive byte slicing or a required external JSON runtime.
    if [[ "$s" == *[$'\001'-$'\037']* ]]; then
        for ((code=1; code<32; code++)); do
            printf -v octal '%03o' "$code"
            printf -v character '%b' "\\$octal"
            printf -v escaped '\\u%04x' "$code"
            s="${s//"$character"/$escaped}"
        done
    fi
    printf '%s' "$s"
}

# Print the arguments as a JSON array of strings.
json_array() {
    local value separator=""
    printf '['
    for value in "$@"; do
        printf '%s"%s"' "$separator" "$(json_escape "$value")"
        separator=,
    done
    printf ']'
}
