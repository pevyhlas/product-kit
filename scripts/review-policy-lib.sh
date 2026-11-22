#!/usr/bin/env bash
# Review rigor from committed policy. Source spec-lib.sh first. No network/dependencies.
# shellcheck disable=SC2154 # root is supplied by the gate or the upgrade caller.
read_rigor() { # rev -> light|full|unknown; caller supplies root
    { git -C "$root" show "$1:.prdkit/memory/constitution.md" 2>/dev/null || true; } | read_rigor_text
}

# The 2.x registry maps concern names to reviewer identities. Capability rows are
# the legacy spelling. Only an unambiguous reviewer (never a maker) is eligible.
review_registry() {
    awk "$SPEC_SKIP_AWK"'
        function trim(s) { gsub(/^[[:space:]`]+|[[:space:]`]+$/, "", s); return tolower(s) }
        { if (spec_skip($0)) next }
        /^## / { section = $0; identity = role = 0; next }
        /^\|/ {
            split($0, c, "|")
            if (section == "## Review registry" && trim(c[2]) == "identity" && trim(c[3]) == "role") {
                identity = 2; role = 3; explicit = 1; next
            }
            if (trim(c[2]) == "role" && trim(c[3]) == "available agent or human") {
                identity = 3; role = 2; explicit = 0; next
            }
            if (!identity || c[2] ~ /^[[:space:]:-]+$/) next
            id = trim(c[identity]); kind = trim(c[role])
            if (id !~ /^[a-z0-9][a-z0-9_.-]*$/) next
            if (!explicit) {
                if (kind == "review" || kind == "independent review") kind = "reviewer"
                else if (kind == "implementation" || kind == "maker") kind = "maker"
                else next
            }
            count[id]++; roles[id]=kind
            next
        }
        /^[[:space:]]*$/ { next }
        { identity = role = 0 }
        END { for (id in count) if (count[id]==1 && roles[id]=="reviewer") print id }
    '
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
