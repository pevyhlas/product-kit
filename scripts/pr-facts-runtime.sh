#!/usr/bin/env bash
# Python is optional and only used by the PR evidence helpers.
pr_facts_exec() {
    local dir
    dir="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 2
    if ! python3 -I -B -c 'import sys; sys.exit(sys.version_info < (3, 11))' 2>/dev/null; then
        printf '%s.sh: install Python 3.11 or newer\n' "$1" >&2
        exit 2
    fi
    exec python3 -I -B -X utf8 "$dir/pr-facts.py" "$@"
}
