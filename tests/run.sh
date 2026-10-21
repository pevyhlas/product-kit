#!/usr/bin/env bash
# Product-Kit test runner. Discovers and runs every tests/test_*.sh file in its
# own process, aggregates results. Bash + coreutils + git; enrichment tests use jq.
#
# Usage: bash tests/run.sh [-v]

set -u
TESTS_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VFLAG=""
[ "${1:-}" = "-v" ] && VFLAG="-v"

if [ -t 1 ]; then G=$'\033[32m'; R=$'\033[31m'; B=$'\033[1m'; Z=$'\033[0m'; else G=; R=; B=; Z=; fi

total_files=0; failed_files=0
echo "${B}Product-Kit test suite${Z}"
echo

for f in "$TESTS_DIR"/test_*.sh; do
    [ -e "$f" ] || continue
    total_files=$((total_files+1))
    name="$(basename "$f")"
    echo "${B}▶ $name${Z}"
    if bash "$f" $VFLAG; then
        :
    else
        failed_files=$((failed_files+1))
    fi
    echo
done

echo "────────────────────────────────────────"
if [ "$failed_files" -eq 0 ]; then
    echo "${G}ALL GREEN${Z} — $total_files test file(s) passed"
    exit 0
else
    echo "${R}$failed_files of $total_files test file(s) FAILED${Z}"
    exit 1
fi
