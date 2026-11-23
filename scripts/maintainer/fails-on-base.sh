#!/usr/bin/env bash
# Kit-only PR check. Run from a clone containing both refs and their common history.
# Workers can outlive their launchers and answer another snapshot's health check.
# Require verified cleanup of inherited run tags before accepting regression evidence.
# A worker that deliberately clears its inherited environment is outside the threat model.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/replay-workers.sh"

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
reap_limit=5
# Reserve time for both the tree stop and the independent token scan.
pair_seconds=$((2 * (suite_limit + 2 * (grace + reap_limit) + 1)))
deadline=$((SECONDS + budget))

scratch="$(mktemp -d)"
platform=$(uname -s)
run_tag=''
suite_pid='' timer_pid='' interrupted=0 changing_jobs=false owned_pids=''
supervisor_pid=$$
stop_group() {
    [ -n "$1" ] || return 0
    kill -KILL -- "-$1" 2>/dev/null || :
    wait "$1" 2>/dev/null || :
}
suite_tree() {
    # Seed by PID and follow PPIDs across job-control groups. A known group leader's
    # group also identifies members reparented since a previous snapshot.
    # BSD awk rejects literal newlines in -v assignments; read the PID list as data.
    LC_ALL=C ps -A -o pid=,ppid=,pgid=,stat= | LC_ALL=C REPLAY_ROOTS="$*" awk '
        BEGIN {
            n = split(ENVIRON["REPLAY_ROOTS"], root, /[[:space:]]+/)
            for (i = 1; i <= n; i++) if (root[i] != "") owned[root[i]] = 1
        }
        { parent[$1] = $2; group[$1] = $3; state[$1] = $4 }
        END {
            do {
                added = 0
                for (pid in parent)
                    if (!(pid in owned) && ((parent[pid] in owned) || (group[pid] in owned))) {
                        owned[pid] = 1
                        added = 1
                    }
            } while (added)
            for (pid in owned)
                if (pid in state && state[pid] !~ /^Z/) print pid
        }'
}
signal_pids() {
    local signal="$1" pid
    while IFS= read -r pid; do
        [ -n "$pid" ] || continue
        kill "-$signal" -- "$pid" 2>/dev/null || :
    done <<< "$2"
}
stop_suite() {
    local living stop_at
    [ -n "$suite_pid" ] || return 0
    # Discover before TERM can kill the leader and orphan a job-controlled worker.
    living="$(suite_tree "$suite_pid" "$owned_pids")" || return 1
    if [ -n "$living" ]; then
        owned_pids="$owned_pids $living"
        signal_pids TERM "$living"
        sleep "$grace" || return 1
    fi
    stop_at=$((SECONDS + reap_limit))
    while :; do
        # Retain known PIDs even after they exit: they may still name a process group.
        living="$(suite_tree "$suite_pid" "$owned_pids")" || return 1
        if [ -z "$living" ]; then break; fi
        signal_pids KILL "$living"
        owned_pids="$owned_pids $living"
        if [ "$SECONDS" -ge "$stop_at" ]; then return 1; fi
        sleep 1 || return 1
    done
    wait "$suite_pid" 2>/dev/null || :
    suite_pid='' owned_pids=''
}
cleanup() {
    trap '' INT TERM HUP
    stop_group "$timer_pid"
    if ! stop_suite; then
        printf 'Could not stop the suite process tree.\n' >&2
    fi
    if ! stop_tagged_workers; then printf 'INCONCLUSIVE: run isolation unverified.\n' >&2; fi
    rm -rf "$scratch"
}
interrupt() {
    interrupted="$1"
    if [ "$changing_jobs" = false ]; then exit "$interrupted"; fi
}
trap cleanup EXIT
# Defer cancellation while transferring ownership of the background jobs.
trap 'interrupt 130' INT
trap 'interrupt 143' TERM
trap 'interrupt 129' HUP
trap ':' USR1 # wake wait on expiry; the parent owns all suite teardown
set -m # Bash 3.2+: give each async job its own process group, including its descendants.
scratch="$(cd "$scratch" && pwd -P)"

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
    local root="$1" path="$2" log="$3" limit="$4" status=0 tmp
    : > "$log"
    if [ ! -f "$root/$path" ] || [ -L "$root/$path" ]; then
        printf 'Cannot run %q: not a regular test file.\n' "$path" > "$log"
        result='FAIL (exit 1)'
        return 0
    fi
    tmp="$(mktemp -d "$scratch/run.XXXXXX")"
    # A unique variable name preserves the outer run's tag in nested replays.
    local nonce
    nonce=$(openssl rand -hex 24)
    [[ $nonce =~ ^[0-9a-f]{48}$ ]] || exit 2
    run_tag="PRDKIT_REPLAY_${nonce}=1"
    rm -f "$scratch/timed-out"
    changing_jobs=true
    (
        exec 3>&-
        cd "$root"
        unset GITHUB_STEP_SUMMARY
        export TMPDIR="$tmp" TMP="$tmp" TEMP="$tmp"
        export "${run_tag?}"
        exec bash "$path"
    ) </dev/null >"$log" 2>&1 &
    suite_pid=$!
    (
        exec 3>&-
        sleep "$limit"
        if kill -0 "$suite_pid" 2>/dev/null; then
            : > "$scratch/timed-out"
            # Repeat until stopped in case the first signal arrived just before wait.
            while kill -USR1 "$supervisor_pid" 2>/dev/null; do sleep 1; done
        fi
    ) </dev/null >/dev/null 2>&1 &
    timer_pid=$!
    changing_jobs=false
    if [ "$interrupted" -ne 0 ]; then exit "$interrupted"; fi
    wait "$suite_pid" 2>/dev/null || status=$?
    changing_jobs=true
    stop_group "$timer_pid"; timer_pid=''
    if ! stop_suite; then
        printf '\nINCONCLUSIVE: could not stop the process tree for PID %s.\n' "$suite_pid" >&3
        exit 2
    fi
    if [ -f "$scratch/timed-out" ]; then
        result="FAIL (timed out after ${limit}s)"
    else
        if [ "$status" -ne 0 ]; then result="FAIL (exit $status)"; else result=PASS; fi
    fi
    # This also gates the transition from base to head after a normal base exit.
    if ! stop_tagged_workers 2>"$scratch/isolation-error"; then
        printf -- '- <code>%s</code> — INCONCLUSIVE (%s isolation); comparison stopped, not counted.\n' \
            "$label" "${root##*/}" >&3
        cat "$scratch/isolation-error" >&3
        exit 2
    fi
    changing_jobs=false
    if [ "$interrupted" -ne 0 ]; then exit "$interrupted"; fi
    rm -rf "$tmp"
}

count=0
reproduced=0
skipped=0
if [ -s "$scratch/changed" ]; then
    case "$platform" in Linux|Darwin) ;; *) echo 'INCONCLUSIVE: unsupported process inventory.' >&3; exit 2 ;; esac
    replay_census "$scratch/preexisting" || { echo 'INCONCLUSIVE: process census unavailable.' >&3; exit 2; }
    # lstart has one-second resolution. No process born after this barrier can
    # share a pre-token identity, even if the kernel reuses its PID.
    sleep 1
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
