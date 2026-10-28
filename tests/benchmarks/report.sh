#!/usr/bin/env bash
# Optional local research tooling, never installed in consumers. jq is a test dependency.
# Validate the entire normalized study before emitting anything; no provider calls or pricing guesses.
set -euo pipefail
HERE="$(CDPATH='' cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
    echo 'Usage: bash tests/benchmarks/report.sh study.json' >&2; exit 2
fi
command -v jq >/dev/null 2>&1 || { echo 'Benchmark reports require jq 1.6+ (test tooling only).' >&2; exit 2; }
jq -e -s 'if length == 1 then .[0] else error("expected exactly one study object") end' "$1" |
    jq -e -f "$HERE/report.jq"
