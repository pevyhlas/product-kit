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

stop_tagged_workers() {
    local until=$((SECONDS + grace + reap_limit)) signal=TERM row pid rc found
    [ -n "$run_tag" ] || return 0
    while :; do
        replay_candidates "$scratch/before" || { echo 'Process census unavailable.' >&2; return 1; }
        : > "$scratch/clean"
        found=false
        while IFS= read -r row; do
            pid=${row%% *}
            rc=0
            replay_membership "$platform" "$pid" "$run_tag" /proc || rc=$?
            case "$rc" in
                0) kill "-$signal" -- "$pid" 2>/dev/null || :; found=true ;;
                1) printf '%s\n' "$row" >> "$scratch/clean" ;;
                # An unreadable PID may have exited. The second census decides.
            esac
        done < "$scratch/before"
        replay_candidates "$scratch/after" || { echo 'Process census unavailable.' >&2; return 1; }
        # A fork during the scan can introduce a new PID even if its parent has
        # exited. Only accept if *every* remaining identity was verified clean.
        LC_ALL=C awk 'FILENAME == ARGV[1] { clean[$0]; next } !($0 in clean) { print $1 }' \
            "$scratch/clean" "$scratch/after" > "$scratch/unverified" || return 1
        if [ ! -s "$scratch/unverified" ]; then run_tag=''; return 0; fi
        if [ "$SECONDS" -ge "$until" ]; then
            while read -r pid; do echo "Cannot verify isolation for PID $pid." >&2; done < "$scratch/unverified"
            return 1
        fi
        if [ "$found" = true ] && [ "$signal" = TERM ]; then
            sleep "$grace" || return 1
            signal=KILL
        else
            sleep 1 || return 1
        fi
    done
}
