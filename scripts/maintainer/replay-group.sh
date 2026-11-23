#!/usr/bin/env bash
# Internal snapshot group leader, launched as a single async job under Bash monitor
# mode. Only the live leader signals its own group: Bash may already have reaped
# an async child by the time its parent gets around to calling wait.
set -eu
set +m
control=$1 root=$2 path=$3 tag=$4 limit=$5
group=$(LC_ALL=C ps -p "$$" -o pgid=)
[[ ${group//[[:space:]]/} == "$$" ]] || exit 2
cd "$root"
(
    export "${tag?}"
    status=0
    bash "$path" || status=$?
    printf '%s\n' "$status" > "$control/status.tmp"
    mv "$control/status.tmp" "$control/status"
) &

until=$((SECONDS + limit))
while [ ! -e "$control/status" ]; do
    if [ -e "$control/cancel" ]; then break; fi
    if [ "$SECONDS" -ge "$until" ]; then break; fi
    sleep 0.1
done
if [ -f "$control/status" ]; then
    outcome=$(cat "$control/status")
else
    outcome=timeout
    # The suite inherited the default TERM disposition. Keep the leader alive
    # through grace so its PGID still cannot be reassigned at escalation.
    trap ':' TERM
    kill -TERM -- "-$$"
    sleep 2
fi
printf '%s\n' "$outcome" > "$control/outcome"
kill -KILL -- "-$$"
exit 2 # No fall-through is a verified group shutdown.
