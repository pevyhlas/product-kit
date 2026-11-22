#!/usr/bin/env bash
# Review rigor from committed policy. Source spec-lib.sh first. No network/dependencies.
# shellcheck disable=SC2154 # root is supplied by the gate or the upgrade caller.
read_rigor() { # rev -> light|full|unknown; caller supplies root
    { git -C "$root" show "$1:.prdkit/memory/constitution.md" 2>/dev/null || true; } | read_rigor_text
}

read_rigor_text() { # validated constitution bytes on stdin; the same strict grammar
    tr -d '\r' | awk '
        { line = $0 }
        sub(/^[-*[:space:]]*[Rr]igor\**:\**[[:space:]]*/, "", line) { n++; value = tolower(line) }
        END {
            if (n == 1 && value ~ /^(light|full)([[:space:]]|$)/) { sub(/[[:space:]].*/, "", value); print value }
            else print "unknown"
        }'
}
