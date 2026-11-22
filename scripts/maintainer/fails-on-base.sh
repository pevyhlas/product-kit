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

# Overrides can shorten the limits for local reproductions and fixtures.
limit_seconds() {
    if [[ ! $1 =~ ^[1-9][0-9]{0,3}$ ]] || [ "$1" -gt "$2" ]; then
        printf '%s must be an integer from 1 to %s seconds.\n' "$3" "$2" >&2
        return 2
    fi
    printf '%s\n' "$1"
}
suite_limit="$(limit_seconds "${PRDKIT_REPLAY_SUITE_SECONDS:-300}" 300 PRDKIT_REPLAY_SUITE_SECONDS)"
budget="$(limit_seconds "${PRDKIT_REPLAY_BUDGET_SECONDS:-2400}" 2400 PRDKIT_REPLAY_BUDGET_SECONDS)"
grace=2
pair_seconds=$((2 * (suite_limit + grace + 1)))
deadline=$((SECONDS + budget))

scratch="$(mktemp -d)"
suite_pid='' timer_pid='' interrupted=0 launching=false
stop_group() {
    [ -n "$1" ] || return 0
    kill -KILL -- "-$1" 2>/dev/null || :
    wait "$1" 2>/dev/null || :
}
cleanup() {
    trap '' INT TERM HUP
    stop_group "$timer_pid"
    stop_group "$suite_pid"
    rm -rf "$scratch"
}
interrupt() {
    interrupted="$1"
    if [ "$launching" = false ]; then exit "$interrupted"; fi
}
trap cleanup EXIT
# Defer processing until both background launch PIDs have been saved.
trap 'interrupt 130' INT
trap 'interrupt 143' TERM
trap 'interrupt 129' HUP
set -m # Bash 3.2+: give each async job its own process group, including its descendants.

exec 3>&1
if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then exec 3>> "$GITHUB_STEP_SUMMARY"; fi
printf '### Fails before the fix (%s)\n\n' "$mode" >&3
printf 'Base (merge base): %s · Head: %s\n\n' "\`$base\`" "\`$head\`" >&3

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
    local root="$1" path="$2" log="$3" limit="$4" status=0
    : > "$log"
    if [ ! -f "$root/$path" ] || [ -L "$root/$path" ]; then
        printf 'Cannot run %q: not a regular test file.\n' "$path" > "$log"
        result='FAIL (exit 1)'
        return 0
    fi
    rm -f "$scratch/timed-out"
    launching=true
    (
        cd "$root"
        unset GITHUB_STEP_SUMMARY
        exec bash "$path"
    ) 3>&- </dev/null >"$log" 2>&1 &
    suite_pid=$!
    (
        sleep "$limit"
        if kill -0 "$suite_pid" 2>/dev/null; then
            : > "$scratch/timed-out"
            kill -TERM -- "-$suite_pid" 2>/dev/null || :
            sleep "$grace"
            kill -KILL -- "-$suite_pid" 2>/dev/null || :
        fi
    ) 3>&- </dev/null >/dev/null 2>&1 &
    timer_pid=$!
    launching=false
    if [ "$interrupted" -ne 0 ]; then exit "$interrupted"; fi
    wait "$suite_pid" 2>/dev/null || status=$?
    stop_group "$timer_pid"; timer_pid=''
    # Kill any descendants that outlived the suite leader, then retire the group.
    stop_group "$suite_pid"; suite_pid=''
    if [ -f "$scratch/timed-out" ]; then
        result="FAIL (timed out after ${limit}s)"
    elif [ "$status" -ne 0 ]; then
        result="FAIL (exit $status)"
    else
        result=PASS
    fi
}

count=0
reproduced=0
skipped=0
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
    label="$(LC_ALL=C printf '%q' "$test_path" | escape_html)"
    # Admit a pair only with enough time for both full deadlines and cleanup.
    # A reduced base timeout could falsely count an ordinary slow test as evidence.
    if [ "$((deadline - SECONDS))" -lt "$pair_seconds" ]; then
        skipped=$((skipped + 1))
        printf -- '- <code>%s</code> — Not run on base or head (comparison budget exhausted).\n' "$label" >&3
        continue
    fi
    run_test "$scratch/base" "$test_path" "$scratch/base.log" "$suite_limit"
    base_result="$result"
    run_test "$scratch/head" "$test_path" "$scratch/head.log" "$suite_limit"
    head_result="$result"
    printf -- '- <code>%s</code> — Base: %s; Head: %s.\n' "$label" "$base_result" "$head_result" >&3
    if [ "$base_result" != PASS ] && [ "$head_result" = PASS ]; then
        reproduced=$((reproduced + 1))
    fi
    if [ "$base_result" != PASS ]; then diagnostic Base "$scratch/base.log" >&3; fi
    if [ "$head_result" != PASS ]; then diagnostic Head "$scratch/head.log" >&3; fi
done < "$scratch/changed"

if [ "$count" -eq 0 ]; then printf 'No added or changed test suites.\n' >&3; fi
if [ "$skipped" -gt 0 ]; then printf '\n%d suite(s) not run; skipped suites are not evidence.\n' "$skipped" >&3; fi
printf '\n%d of %d changed test suite(s) fail on base and pass on head.\n' "$reproduced" "$count" >&3
if [ "$mode" = required ] && [ "$reproduced" -eq 0 ]; then
    printf '\nA fix PR must have at least one changed test suite fail on base and pass on head.\n' >&3
    exit 1
fi
