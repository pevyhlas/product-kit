#!/usr/bin/env bash
# Product-Kit test runner. Runs each selected suite in its own Bash process.
# The default selection is every tests/test_*.sh file.
#
# Usage: bash tests/run.sh [-v] [--native] [--shard K/N] [--list]
# --native uses the macOS allowlist and weights; --list prints the plan without running it.

set -uo pipefail
TESTS_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || exit 1
VFLAG=""
native=false; list=false; shard=""; shards=""
usage() {
    echo 'Usage: bash tests/run.sh [-v] [--native] [--shard K/N] [--list]' >&2
    exit 2
}
# Limit each number to nine digits so arithmetic is exact on every supported Bash.
shard_format='^([1-9][0-9]{0,8})/([1-9][0-9]{0,8})$'
while [ "$#" -gt 0 ]; do
    case "$1" in
        -v) VFLAG="-v" ;;
        --native) native=true ;;
        --list) list=true ;;
        --shard)
            [ -z "$shard" ] && [[ "${2:-}" =~ $shard_format ]] || usage
            shard="${BASH_REMATCH[1]}"; shards="${BASH_REMATCH[2]}"
            [ "$shard" -le "$shards" ] || usage
            shift
            ;;
        *) usage ;;
    esac
    shift
done

suite_list() {
    local f name seen=$'\n'
    if ! "$native"; then
        for f in "$TESTS_DIR"/test_*.sh; do
            [ -e "$f" ] || continue
            printf '%s\n' "${f##*/}"
        done
        return 0
    fi
    while IFS= read -r name || [ -n "$name" ]; do
        case "$name" in
            ''|\#*) continue ;;
            */*|*[!a-zA-Z0-9_.-]*) echo "Invalid native suite: $name" >&2; return 1 ;;
            test_*.sh) ;;
            *) echo "Invalid native suite: $name" >&2; return 1 ;;
        esac
        case "$seen" in
            *$'\n'"$name"$'\n'*) echo "Duplicate native suite: $name" >&2; return 1 ;;
        esac
        if [ ! -f "$TESTS_DIR/$name" ]; then
            echo "Missing native suite: $name" >&2
            return 1
        fi
        seen="$seen$name"$'\n'
        printf '%s\n' "$name"
    done < "$TESTS_DIR/native-suites.txt"
    [ "$seen" != $'\n' ] || { echo 'No native suites listed' >&2; return 1; }
}

shard_plan() {
    local column=2 default_weight=30 LC_ALL=C
    export LC_ALL
    if "$native"; then column=3; default_weight=60; fi
    # Sort by descending weight and C-locale suite name. Assign to the lowest-index
    # lightest bin; unvisited bins are empty, so only the first of them can win a tie.
    awk -v column="$column" -v fallback="$default_weight" '
        FILENAME != "-" {
            if (NF && $1 !~ /^#/ && $column ~ /^[0-9]+$/) weight[$1] = $column
            next
        }
        NF { printf "%d\t%s\n", ($0 in weight ? weight[$0] : fallback), $0 }
    ' "$TESTS_DIR/suite-weights.txt" - |
        sort -k1,1nr -k2 |
        awk -v wanted="$shard" -v bins="$shards" '
            {
                best = 1
                for (i = 2; i <= bins && i <= used + 1; i++)
                    if (load[i] < load[best]) best = i
                if (best > used) used = best
                load[best] += $1
                if (best == wanted) print substr($0, index($0, "\t") + 1)
            }
        '
}

suites="$(suite_list)" || exit 1
if [ -n "$shard" ]; then
    suites="$(printf '%s\n' "$suites" | shard_plan)" || exit 1
fi
if "$list"; then
    [ -z "$suites" ] || printf '%s\n' "$suites"
    exit 0
fi

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; Z=$'\033[0m'; else G=; R=; B=; Z=; fi

suite_bash=bash
if "$native"; then suite_bash="$BASH"; fi
planned_files="$(printf '%s\n' "$suites" | awk 'length($0) { count++ } END { print count+0 }')" || exit 1
total_files=0; failed_files=0
echo "${B}Product-Kit test suite${shard:+ — shard $shard/$shards}${Z}"
echo

while IFS= read -r name; do
    [ -n "$name" ] || continue
    total_files=$((total_files+1))
    echo "${B}▶ $name${Z}"
    started=$SECONDS
    # The loop's stdin is the suite plan, not input for suites or their children.
    if "$suite_bash" "$TESTS_DIR/$name" ${VFLAG:+"$VFLAG"} </dev/null; then
        :
    else
        failed_files=$((failed_files+1))
    fi
    echo "Elapsed: $name $((SECONDS - started))s"
    echo
done <<< "$suites"

echo "────────────────────────────────────────"
if [ "$total_files" -ne "$planned_files" ]; then
    echo "Suite count mismatch: ran $total_files of $planned_files planned test files" >&2
    exit 1
fi
if [ "$failed_files" -eq 0 ]; then
    echo "${G}ALL GREEN${Z} — $total_files test file(s) passed"
    exit 0
else
    echo "${R}$failed_files of $total_files test file(s) FAILED${Z}"
    exit 1
fi
