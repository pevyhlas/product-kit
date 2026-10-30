#!/usr/bin/env bash
# Reviewer eligibility from committed policy. Source spec-lib.sh first. No network/dependencies.
review_registry() { # agents.md on stdin -> identity, role, policy line
    awk "$SPEC_SKIP_AWK"'
        function trim(s) { gsub(/^[[:space:]`]+|[[:space:]`]+$/, "", s); return tolower(s) }
        { if (spec_skip($0)) next }
        /^## / { section = $0; identity = role = 0; next }
        /^\|/ {
            n = split($0, c, "|")
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
            if (kind != "reviewer" && kind != "maker") kind = "invalid"
            print id "\037" kind "\037" NR
            next
        }
        /^[[:space:]]*$/ { next }
        { identity = role = 0 }
    '
}

review_eligibility() { # registry identity -> reviewer|maker|ambiguous|unregistered
    printf '%s\n' "$1" | awk -F '\037' -v id="$2" '
        $1 == id { n++; if ($2 == "maker") maker = 1; if ($2 != "reviewer") invalid = 1 }
        END {
            if (maker) print "maker"
            else if (n > 1 || invalid) print "ambiguous"
            else if (n == 1) print "reviewer"
            else print "unregistered"
        }'
}
