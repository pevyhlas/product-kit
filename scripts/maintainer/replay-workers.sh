#!/usr/bin/env bash
# shellcheck disable=SC2154 # scratch, run_tag, platform and deadlines belong to the caller.
# Sourced by fails-on-base.sh. Only identities and scan results go to scratch;
# process environments may contain credentials and must never be logged.

replay_census() {
    local scanner
    LC_ALL=C TZ=UTC0 ps -A -o uid=,pid=,stat=,lstart= > "$scratch/ps" &
    scanner=$!
    wait "$scanner" || return 1
    # Keep PID and birth time together. Ignore zombies and this census's own ps.
    LC_ALL=C awk -v uid="$EUID" -v scanner="$scanner" -v self="$$" '
        NF != 8 || $1 !~ /^[0-9]+$/ || $2 !~ /^[1-9][0-9]*$/ { exit 1 }
        $1 == uid && $2 == self { seen = 1 }
        $1 == uid && $2 != scanner && $3 !~ /^Z/ {
            print $2, $4, $5, $6, $7, $8
        } END { if (!seen) exit 1 }' "$scratch/ps" > "$1"
}

replay_candidates() {
    replay_census "$scratch/census" || return 1
    LC_ALL=C awk 'FILENAME == ARGV[1] { old[$0]; next } !($0 in old)' \
        "$scratch/preexisting" "$scratch/census" > "$1"
}

# Status: 0 tagged, 1 definitely untagged, 2 unavailable. Never infer an empty
# environment from a failed read. Keep the proc root an argument for parser tests.
replay_membership() {
    local platform="$1" pid="$2" entry="$3" proc="$4" rc args full
    case "$platform" in
        Linux)
            # Linux /proc uses NUL boundaries, not newlines or shell words.
            LC_ALL=C grep -zxF -- "$entry" "$proc/$pid/environ" >/dev/null 2>&1 && return 0
            rc=$?
            [ "$rc" = 1 ] && return 1
            ;;
        Darwin)
            # Darwin ps appends the environment to argv with -E. Strip the
            # ordinary argv view first. No suffix (including ps's "(comm)"
            # fallback on read errors) means visibility was not established.
            # Spaces inside values are ambiguous. A false match can only block
            # evidence (Low); this information is never used to signal a PID.
            args=$(LC_ALL=C ps -ww -p "$pid" -o command= 2>/dev/null) || return 2
            full=$(LC_ALL=C ps -Eww -p "$pid" -o command= 2>/dev/null) || return 2
            [[ -n $args && $full == "$args "* ]] || return 2
            full=${full#"$args "}
            [[ " $full " == *" $entry "* ]] && return 0
            return 1
            ;;
    esac
    return 2
}

verify_no_workers() {
    local until=$((SECONDS + scan_limit)) row pid rc verified=0
    [ -n "$run_tag" ] || return 0
    while :; do
        replay_candidates "$scratch/live" || { echo 'Process census unavailable.' >&2; return 1; }
        : > "$scratch/unverified"
        while IFS= read -r row; do
            pid=${row%% *}
            rc=0
            replay_membership "$platform" "$pid" "$run_tag" /proc || rc=$?
            case "$rc" in
                1) : ;; # positively untagged
                0) printf 'Leftover tagged PID %s.\n' "$pid" >> "$scratch/unverified" ;;
                *) printf 'Cannot inspect PID %s.\n' "$pid" >> "$scratch/unverified" ;;
            esac
        done < "$scratch/live"
        # Never credit a census with a missing lookup, even if that PID has
        # since exited. Its successor must be inspected in a fresh census.
        if [ ! -s "$scratch/unverified" ]; then
            verified=$((verified + 1))
            if [ "$verified" = 2 ]; then return 0; fi
        else
            verified=0
        fi
        if [ "$SECONDS" -ge "$until" ]; then
            cat "$scratch/unverified" >&2
            echo 'Two consecutive complete clean scans were not verified.' >&2
            return 1
        fi
        if [ "$verified" = 0 ]; then sleep 0.2 || return 1; fi
    done
}
