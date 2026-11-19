#!/usr/bin/env bash
# Test-only observer for the synthetic stubborn case. Never sourced/installed by the product.
# Raw records belong to lib.sh's ephemeral fixture. Only nd_summary's fixed projection is printed.
# shellcheck disable=SC2016,SC2034,SC2154 # generated code; nd_dir/phase/child are fixture/launcher state

nd_append() {
    nd_count=$((${nd_count:-0}+1))
    if [ "$nd_count" -le 32 ] && [ "${#1}" -le 1024 ]; then
        printf '%s\n' "$1" >> "$nd_dir/events"
    else
        printf overflow > "$nd_dir/overflow"
    fi
    return 0
}
nd_gate() {
    local disposition rc ignored=null
    if disposition="$(trap -p TERM)"; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 0 ]; then
        case "$disposition" in "trap -- '' SIGTERM"|"trap -- '' TERM") ignored=true ;; *) ignored=false ;; esac
    fi
    printf '%s %s %s\n' "$1" "$2" "$ignored" > "$nd_dir/gate"
    return 0
}
nd_owned() {
    [ "$phase" = native ] || return 0
    printf '%s %s %s %s %s %s\n' "$@" > "$nd_dir/owned"
    return 0
}
nd_snapshot() { # fixed stage; raw ps is filtered/capped before it reaches a fixture file
    [ "$phase" = native ] || return 0
    local launcher leader out err watchdog overall gate=0 parent=0 ignored=null descendant=0 term_rc=0
    local snapshot="$nd_dir/ps-$1" data
    if ! read -r launcher leader out err watchdog overall < "$nd_dir/owned"; then
        nd_append "{\"kind\":\"snapshot\",\"stage\":\"$1\",\"available\":false}"
        return 0
    fi
    read -r gate parent ignored < "$nd_dir/gate" || gate=0
    read -r descendant term_rc < "$nd_dir/descendant" || descendant=0
    if ! ps -axo pid=,ppid=,pgid=,stat= | awk -v g="$leader" -v a="$gate" -v b="$descendant" \
        -v c="$out" -v d="$err" -v e="$watchdog" -v f="$overall" '
        $3==g || $1==g || $1==a || $1==b || $1==c || $1==d || $1==e || $1==f {
            if (++n<=32) print $1,$2,$3,$4
        }
        END {if(n>32) print "overflow"}
    ' > "$snapshot" 2>/dev/null; then
        nd_append "{\"kind\":\"snapshot\",\"stage\":\"$1\",\"available\":false}"
        return 0
    fi
    if grep -qx overflow "$snapshot"; then
        printf overflow > "$nd_dir/overflow"
        nd_append "{\"kind\":\"snapshot\",\"stage\":\"$1\",\"available\":false}"
        return 0
    fi
    data="$(awk -v stage="$1" -v leader="$leader" -v gate="$gate" -v descendant="$descendant" \
        -v a="$out" -v b="$err" -v c="$watchdog" -v d="$overall" '
        function role(pid) {
            if(!pid) return "{\"present\":null,\"live\":null,\"in_group\":null}"
            return "{\"present\":" (pid in seen ? "true" : "false") \
                ",\"live\":" (live[pid] ? "true" : "false") \
                ",\"in_group\":" (pid in seen ? (group[pid]==leader ? "true" : "false") : "null") "}"
        }
        {seen[$1]=1; group[$1]=$3; live[$1]=($4!~/^Z/); parent[$1]=$2
         if($3==leader && live[$1]) members++
         if(($1==leader || $1==a || $1==b || $1==c || $1==d) && live[$1]) owned_live++}
        END {
            print "{\"kind\":\"snapshot\",\"stage\":\"" stage "\",\"available\":true," \
                "\"leader\":" role(leader) ",\"gate\":" role(gate) ",\"descendant\":" role(descendant) \
                ",\"descendant_parent_is_gate\":" \
                (descendant in seen && gate ? (parent[descendant]==gate ? "true" : "false") : "null") \
                ",\"live_members\":" members+0 ",\"owned_live\":" owned_live+0 "}"
        }
    ' "$snapshot")" || data="{\"kind\":\"snapshot\",\"stage\":\"$1\",\"available\":false}"
    nd_append "$data"
    return 0
}
nd_wait() { # original wait result and flags are arguments, captured before diagnostic commands
    [ "$phase" = native ] && [ "$1" = "$child" ] || return 0
    local alive=false
    kill -0 "$1" 2>/dev/null && alive=true
    nd_append "{\"kind\":\"wait\",\"status\":$2,\"before\":$3,\"generation\":$4,\"critical\":$5,\"finishing\":$6,\"alive\":$alive,\"native_exit\":$7}"
    return 0
}
nd_signal() {
    [ "$phase" = native ] || return 0
    nd_append "{\"kind\":\"signal\",\"signal\":\"$1\",\"rc\":$2}"
    return 0
}
nd_transfer() {
    [ "$phase" = native ] || return 0
    nd_append "{\"kind\":\"transfer\",\"native_exit\":$1,\"group_exit\":$2,\"pending\":$3}"
    return 0
}
nd_predelete() {
    [ "$phase" = native ] || return 0
    nd_snapshot remove
    # This copy cannot authorize product acceptance; unavailable/oversize is explicit.
    if head -c 4194305 "$1" > "$nd_dir/produced" 2>/dev/null; then
        if [ "$(wc -c < "$nd_dir/produced")" -gt 4194304 ]; then printf overflow > "$nd_dir/overflow"; fi
    else
        printf error > "$nd_dir/copy-error"
    fi
    return 0
}
nd_gate_source() {
    printf 'nd_dir=%q\n' "$1"
    declare -f nd_gate
}
nd_instrument() {
    # Definitions and calls stay OUTSIDE the bounded workload subshell, whose tail stays exact.
    {
        printf 'nd_dir=%q\n' "$nd_dir"
        declare -f nd_append nd_owned nd_snapshot nd_wait nd_signal nd_transfer nd_predelete
    } > "$nd_dir/functions"
    awk -v functions="$nd_dir/functions" '
        /^phase=bootstrap;/ {while((getline line < functions)>0) print line; close(functions)}
        /^cancel_group\(\)/ {cancel=1}
        /^}/ {cancel=0}
        cancel && /^    local pid=/ {print; print "    local nd_rc"; next}
        cancel && /kill -TERM --/ {
            print "        nd_snapshot term || :"
            print "        if kill -TERM -- \"-$pid\" 2>/dev/null; then nd_rc=0; else nd_rc=$?; fi"
            print "        nd_signal TERM \"$nd_rc\" || :"
            next
        }
        cancel && /kill -KILL --/ {
            print "        nd_snapshot kill || :"
            print "        if kill -KILL -- \"-$pid\" 2>/dev/null; then nd_rc=0; else nd_rc=$?; fi"
            print "        nd_signal KILL \"$nd_rc\" || :"
            next
        }
        /^        if wait "\$pid"/ {
            print
            print "        nd_wait \"$pid\" \"$waited_exit\" \"$before\" \"$signal_count\" \"$critical\" \"$finishing\" \"$native_exit\" || :"
            next
        }
        /^    watcher=\$!/ {
            print
            print "    nd_owned \"$$\" \"$child\" \"$capture_out\" \"$capture_err\" \"$watcher\" \"$overall\" || :"
            next
        }
        /^    if \$native_pending; then/ {
            print
            print "    nd_transfer \"$native_exit\" \"$group_exit\" \"$native_pending\" || :"
            next
        }
        /^    if \[ -n "\$root" \] && \{ ! rm -rf/ {print "    nd_predelete \"$root/native.json\" || :"}
        {print}
    ' "$FIX/launcher" > "$nd_dir/launcher"
    mv "$nd_dir/launcher" "$FIX/launcher"
}
nd_read() { # bounded raw input; missing/error are not false or zero
    local file="$1" cap="$2" size
    if [ -f "$file" ] && [ ! -L "$file" ] && size="$(wc -c < "$file")" && [ "$size" -le "$cap" ]; then
        cat "$file" 2>/dev/null
    fi
    return 0
}
nd_summary() { # never emit raw data, errors or arbitrary object keys
    local dir="$1" result="$2" equal=null digest="" extension=null available=false summary overflow=false file cap
    [ ! -e "$dir/overflow" ] || overflow=true
    for file in gate owned descendant events; do
        case "$file" in gate|descendant) cap=128 ;; owned) cap=256 ;; events) cap=32768 ;; esac
        if [ -f "$dir/$file" ] && [ "$(wc -c < "$dir/$file")" -gt "$cap" ]; then overflow=true; fi
    done
    if [ ! -e "$dir/copy-error" ] && [ -f "$dir/produced" ] && [ -f "$result" ] &&
        [ "$(wc -c < "$dir/produced")" -le 4194304 ] && [ "$(wc -c < "$result")" -le 4194304 ] &&
        jq -cSe -s 'if length==1 and (.[0]|type)=="object" then .[0] else error("shape") end' \
            "$dir/produced" > "$dir/canonical-produced" 2>/dev/null &&
        jq -cSe -s 'if length==1 and (.[0].native|type)=="object" then .[0].native else error("shape") end' \
            "$result" > "$dir/canonical-result" 2>/dev/null; then
        available=true; equal=false; extension=false
        cmp -s "$dir/canonical-produced" "$dir/canonical-result" && equal=true
        jq -e '.extension.keep == [null,17,true]' "$dir/canonical-result" >/dev/null 2>&1 && extension=true
        digest="$(git hash-object --no-filters "$dir/canonical-produced" 2>/dev/null)" || digest=""
    fi
    summary="$(jq -cn \
        --arg gate "$(nd_read "$dir/gate" 128)" --arg owned "$(nd_read "$dir/owned" 256)" \
        --arg descendant "$(nd_read "$dir/descendant" 128)" --arg events "$(nd_read "$dir/events" 32768)" \
        --argjson overflow "$overflow" \
        --argjson available "$available" --argjson equal "$equal" --argjson extension "$extension" \
        --arg digest "$digest" \
        '{gate:$gate,owned:$owned,descendant:$descendant,events:$events,overflow:$overflow,
          object:{available:$available,equal:$equal,extension_keep:$extension,digest:$digest}}' |
        jq -c -f "$TESTS_DIR/pr-review-native-summary.jq" 2>/dev/null)" || summary=""
    if [ -n "$summary" ] && [ "${#summary}" -le 8192 ]; then
        printf '%s\n' "$summary"
    else
        printf '{"schema":"native-case-v1","evidence":"unavailable"}\n'
    fi
    return 0
} 2>/dev/null
