#!/usr/bin/env bash
# Kit-only PR check. Run from a clone containing both refs and their common history.
set -euo pipefail

if [ "$#" -ne 3 ]; then
    echo "Usage: bash scripts/maintainer/fails-on-base.sh <base-ref> <head-ref> <pr-title>" >&2
    exit 2
fi
repo="$(git rev-parse --show-toplevel)"
base_tip="$(git rev-parse --verify --end-of-options "$1^{commit}")"
head="$(git rev-parse --verify --end-of-options "$2^{commit}")"
base="$(git merge-base "$base_tip" "$head")"
fix_title='^fix(\([^)]+\))?!?:'
mode=advisory
if [[ $3 =~ $fix_title ]]; then mode=required; fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Match tests/run.sh's entry points. Renamed files are new at their destination; deleted
# tests, helpers, and fixtures are not entry points. Keep pathname bytes intact.
git diff --name-only -z --diff-filter=AMT --no-renames "$base" "$head" \
    -- ':(top,glob)tests/test_*.sh' > "$scratch/changed"

snapshot() {
    # Separate Git directories so neither suite can accidentally change the other's refs
    # (or the source checkout's). Sharing immutable objects keeps the local clones cheap.
    git clone -q --shared --no-checkout "$repo" "$scratch/$1"
    git -C "$scratch/$1" checkout -q --detach "$2"
}

escape_html() { sed 's/\&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g'; }

diagnostic() {
    local side="$1" log="$2"
    printf '\n<details><summary>%s failure output (last 12 lines)</summary><pre>\n' "$side"
    if [ -s "$log" ]; then
        tail -n 12 "$log" | LC_ALL=C tr -d '\000-\010\013-\037\177' | cut -c 1-500 | escape_html
    else
        printf 'The test produced no output.\n'
    fi
    printf '\n</pre></details>\n\n'
}

run_test() {
    local root="$1" path="$2"
    if [ ! -f "$root/$path" ] || [ -L "$root/$path" ]; then
        printf 'Cannot run %q: not a regular test file.\n' "$path" >&2
        return 1
    fi
    (cd "$root" && unset GITHUB_STEP_SUMMARY && bash "$path")
}

count=0
reproduced=0
report="$scratch/summary"
{
    printf '### Fails before the fix (%s)\n\n' "$mode"
    printf 'Base (merge base): %s · Head: %s\n\n' "\`$base\`" "\`$head\`"
    if [ -s "$scratch/changed" ]; then
        snapshot base "$base"
        snapshot head "$head"
        # Replace, rather than merge, tests/ so removed or renamed test fixtures cannot leak in.
        if [ -e "$scratch/base/tests" ] || [ -L "$scratch/base/tests" ]; then
            mv "$scratch/base/tests" "$scratch/base-tests"
        fi
        cp -RP "$scratch/head/tests" "$scratch/base/tests"
    fi

    while IFS= read -r -d '' test_path; do
        count=$((count + 1))
        base_status=0 head_status=0
        run_test "$scratch/base" "$test_path" </dev/null >"$scratch/base.log" 2>&1 || base_status=$?
        run_test "$scratch/head" "$test_path" </dev/null >"$scratch/head.log" 2>&1 || head_status=$?
        base_result=PASS head_result=PASS
        if [ "$base_status" -ne 0 ]; then base_result="FAIL (exit $base_status)"; fi
        if [ "$head_status" -ne 0 ]; then head_result="FAIL (exit $head_status)"; fi
        printf -- '- <code>%s</code> — Base: %s; Head: %s.\n' \
            "$(LC_ALL=C printf '%q' "$test_path" | escape_html)" "$base_result" "$head_result"
        if [ "$base_status" -ne 0 ] && [ "$head_status" -eq 0 ]; then
            reproduced=$((reproduced + 1))
        fi
        if [ "$base_status" -ne 0 ]; then diagnostic Base "$scratch/base.log"; fi
        if [ "$head_status" -ne 0 ]; then diagnostic Head "$scratch/head.log"; fi
    done < "$scratch/changed"

    if [ "$count" -eq 0 ]; then printf 'No added or changed test suites.\n'; fi
    printf '\n%d of %d changed test suite(s) fail on base and pass on head.\n' "$reproduced" "$count"
    if [ "$mode" = required ] && [ "$reproduced" -eq 0 ]; then
        printf '\nA fix PR must have at least one changed test suite fail on base and pass on head.\n'
    fi
} > "$report"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    cat "$report" >> "$GITHUB_STEP_SUMMARY"
else
    cat "$report"
fi
if [ "$mode" = required ] && [ "$reproduced" -eq 0 ]; then exit 1; fi
