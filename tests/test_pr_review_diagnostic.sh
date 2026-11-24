#!/usr/bin/env bash
# Pure data/projection and observer controls. No repetition of the causal variant campaign.
# shellcheck disable=SC2016,SC2034,SC2329 # source-shared state, literal injected code, indirect ps stubs
# shellcheck disable=SC2030,SC2031 # intentional isolated STATUS-preservation probes; parent assertions use run's fresh STATUS
unit_fail() {
    { printf 'FAIL diagnostic control I/O\n'; } 2>/dev/null || :
    exit 1
}
if ! { source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"; } 2>/dev/null; then unit_fail; fi
if ! { source "$TESTS_DIR/pr-review-native-diagnostic.sh"; } 2>/dev/null; then unit_fail; fi

# Only this unit runner: failures never echo assertion operands or utility output.
assert_eq() {
    if [ "$1" = "$2" ]; then _ok "$_CURRENT"
    else _no 'diagnostic unit check failed'; fi
} 2>/dev/null
unit_cmd() {
    if { "$@" >/dev/null; } 2>/dev/null; then return 0; fi
    unit_fail
}
unit_write() {
    local sink="$1"; shift
    if { "$@" > "$sink"; } 2>/dev/null; then return 0; fi
    unit_fail
}
unit_capture() {
    local out="$1" err="$2" file; shift 2
    # Function containment is established before either fixture sink is opened.
    # A failing callback must return to this parent with public descriptors restored.
    if { ( "$@" ) > "$out" 2> "$err"; } 2>/dev/null; then :; else unit_fail; fi
    for file in "$out" "$err"; do
        unit_cmd test -f "$file"
        unit_cmd test ! -L "$file"
        unit_cmd test -r "$file"
        unit_cmd cat "$file" # A missing/unreadable capture cannot pass an absence check.
    done
}
if ! FIX="$( { mktemp -d; } 2>/dev/null)" || [ -z "$FIX" ] || [ ! -d "$FIX" ]; then unit_fail; fi
track_tmp "$FIX"
nd_dir="$FIX/records"; unit_cmd mkdir "$nd_dir"

project_summary() {
    nd_unit_io_ok=false
    if { jq -c -f "$TESTS_DIR/pr-review-native-summary.jq" "$FIX/input" > "$FIX/summary"; } 2>/dev/null; then
        nd_unit_io_ok=true; return 0
    fi
    return 1
}
base_input() {
    # Synthetic identifiers, not a recorded process inventory. Relations/transitions mirror
    # the retained leader=gate Linux observation; the private evidence is validated as data.
    nd_unit_io_ok=false
    jq -n '
        {kind:"snapshot",available:true,
         leader:{present:true,live:true,in_group:true},
         gate:{present:true,live:true,in_group:true},
         descendant:{present:true,live:true,in_group:true},
         descendant_parent_is_gate:true,live_members:3,owned_live:5} as $live |
        ($live|.leader={present:false,live:false,in_group:null}|
          .gate=.leader|.descendant=.leader|.descendant_parent_is_gate=null|
          .live_members=0|.owned_live=0) as $gone |
        {gate:"101 100 true",owned:"100 101 102 103 104 105",descendant:"106 0",
         events:([
          {kind:"wait",status:143,before:0,generation:1,critical:true,finishing:false,alive:true,native_exit:null},
          ($live+{stage:"term"}),{kind:"signal",signal:"TERM",rc:0},
          ($live+{stage:"kill"}),{kind:"signal",signal:"KILL",rc:0},
          {kind:"wait",status:137,before:4,generation:4,critical:false,finishing:true,alive:false,native_exit:null},
          {kind:"transfer",native_exit:137,group_exit:137,pending:true},
          ($gone+{stage:"remove"})]|to_entries|map(.value+{seq:(.key+1)})|map(tojson)|join("\n")),
         terminal:"8 false",overflow:false,
         object:{available:true,equal:true,extension_keep:true,digest:("a"*40)}}
    ' > "$FIX/input" || return 1
    nd_unit_io_ok=true
} 2>/dev/null
mutate() {
    ${nd_unit_io_ok:-true} || return 1
    nd_unit_io_ok=false
    if { jq "$1" "$FIX/input" > "$FIX/new" && mv "$FIX/new" "$FIX/input"; } 2>/dev/null; then
        project_summary
    else return 1; fi
}
events() { mutate ".events |= (split(\"\n\")|map(fromjson)|($1)|map(tojson)|join(\"\n\"))"; }
value() {
    if ${nd_unit_io_ok:-true}; then nd_value "$FIX/summary" "$1"
    else { printf 'unavailable\n'; } 2>/dev/null || :; return 1; fi
}
unit_text() {
    local text
    if text="$(nd_read "$1" 32768)"; then printf '%s' "$text"
    else printf 'unavailable\n'; return 1; fi
} 2>/dev/null
unit_lines() {
    local lines
    if lines="$( { wc -l < "$1"; } 2>/dev/null)"; then printf '%s\n' "$lines" | tr -d ' '
    else printf 'unavailable\n'; return 1; fi
} 2>/dev/null

it 'same-identity and distinct-wrapper observations remain facts, not native kernel proof'
unit_cmd base_input; unit_cmd project_summary
assert_eq complete "$(value .evidence)"
assert_eq true "$(value .identity.leader_is_gate)"
assert_eq true "$(value .identity.gate_parent_is_launcher)"
assert_eq 137 "$(value .transfer.native_exit)"
assert_eq false "$(value .kernel_status_proven)"
unit_cmd mutate '.gate="107 101 true"'
unit_cmd events 'map(if .kind=="wait" and .finishing then .status=143
    elif .kind=="transfer" then .native_exit=143|.group_exit=143
    elif .kind=="snapshot" and .stage=="kill" then
      .leader={present:false,live:false,in_group:null}|.live_members=3|.owned_live=2
    else . end)'
assert_eq complete "$(value .evidence)"
assert_eq false "$(value .identity.leader_is_gate)"
assert_eq true "$(value .identity.gate_parent_is_leader)"
assert_eq 143 "$(value .transfer.native_exit)"
assert_eq 0 "$(value .signals.KILL)"
assert_eq true "$(value .before_kill.gate.live)"
assert_eq false "$(value .before_kill.leader.live)"
assert_eq false "$(value .kernel_status_proven)"
unit_cmd base_input; unit_cmd project_summary # data only, same relation as the historical counterfactual
assert_eq complete "$(value .evidence)"

it 'missing, errors, invalid types and overflow never become false or zero evidence'
for mutation in '.gate=""' '.owned=""' '.descendant=""' '.events=""' \
    '.gate="bad 100 true"' '.gate="101 100 null"' '.object.available=false' \
    '.object.digest="/private/not-a-digest"' '.object.equal="false"' '.overflow=true' \
    '.terminal=""' '.terminal="8 true"' '.terminal="9 false"'; do
    unit_cmd base_input; unit_cmd mutate "$mutation"
    assert_eq incomplete "$(value .evidence)" "$mutation is incomplete"
done
unit_cmd base_input; unit_cmd events 'map(select(.stage!="kill"))'
assert_eq false "$(value .before_kill.available)"
assert_eq null "$(value .before_kill.live_members)"
unit_cmd base_input; unit_cmd events 'map(if .kind=="snapshot" and .stage=="term" then .available=false else . end)'
assert_eq false "$(value .before_term.available)"
assert_eq null "$(value .before_term.leader.live)"
for mutation in '.status=-1' '.status=256' '.generation=0.5' '.before="PATH_SENTINEL"' \
    '.critical="true"' '.native_exit="143"'; do
    unit_cmd base_input; unit_cmd events "map(if .kind==\"wait\" then $mutation else . end)"
    assert_eq incomplete "$(value .evidence)"
    assert_eq null "$(value '.waits[0].status')"
done
unit_cmd base_input; unit_cmd events '. + [range(0;33)|{kind:"wait",status:143}]'
assert_eq true "$(value .overflow)"
assert_eq 16 "$(value '.waits|length')"
unit_cmd base_input; unit_cmd mutate '.events="not-json PATH_SENTINEL"'
assert_eq incomplete "$(value .evidence)"
unit_cmd base_input; unit_cmd mutate '.object.equal=false'
assert_eq complete "$(value .evidence)" 'known inequality is an observation, not missing evidence'
assert_eq false "$(value .object.equal)"

it 'public projection never reflects arbitrary fields, identifiers, strings or raw objects'
unit_cmd base_input
unit_cmd mutate '.secret="PATH_SENTINEL"|.object.secret="PATH_SENTINEL"'
unit_cmd events 'map(.secret="PATH_SENTINEL")'
for forbidden in PATH_SENTINEL 101 106; do
    run grep -qF -- "$forbidden" "$FIX/summary"
    assert_eq 1 "$STATUS" 'projection does not print forbidden input'
done
assert_eq '["before_delete","before_kill","before_term","collection","evidence","identity","kernel_status_proven","object","overflow","schema","signals","transfer","waits"]' \
    "$(value 'keys')"
assert_eq '["available","digest","equal","extension_keep"]' "$(value '.object|keys')"
summary_bytes="$( { wc -c < "$FIX/summary"; } 2>/dev/null)" || summary_bytes=8193
assert_eq true "$(test "$summary_bytes" -le 8192 && echo true || echo false)"

it 'ephemeral collector bounds and failure reporting do not leak error paths'
nd_count=0
for n in {1..40}; do nd_append '{"kind":"wait"}'; done
assert_eq 32 "$(unit_lines "$nd_dir/events")"
run test -f "$nd_dir/overflow"
assert_eq 0 "$STATUS" 'collector records overflow'
nd_unit_io_ok=false
unit_capture "$FIX/summary" "$FIX/public-errors" nd_summary "$nd_dir" "$FIX/missing"
nd_unit_io_ok=true
assert_eq incomplete "$(value .evidence)"
assert_eq true "$(value .overflow)"
assert_eq '' "$(unit_text "$FIX/public-errors")"
run grep -qF -- "$FIX" "$FIX/summary"
assert_eq 1 "$STATUS" 'collector never prints its fixture path'

it 'ps failure and filtered-row overflow remain explicit, not empty-group success'
nd_dir="$FIX/failed-ps"; unit_cmd mkdir "$nd_dir"
nd_count=0
unit_write "$nd_dir/owned" printf '100 101 102 103 104 105\n'
unit_write "$nd_dir/gate" printf '101 100 true\n'
unit_write "$nd_dir/descendant" printf '106 0\n'
phase=native
set -o pipefail # the generated launcher already has this option
ps() { return 1; }
nd_snapshot term
assert_eq false "$(nd_value "$nd_dir/events" .available)"
unset -f ps
nd_dir="$FIX/overflow-ps"; unit_cmd mkdir "$nd_dir"
unit_write "$nd_dir/owned" printf '100 101 102 103 104 105\n'
unit_write "$nd_dir/gate" printf '101 100 true\n'
unit_write "$nd_dir/descendant" printf '106 0\n'
ps() { for n in {1..40}; do printf '%s 100 101 S\n' "$((200+n))"; done; }
nd_count=0; nd_snapshot kill
unset -f ps
run test -f "$nd_dir/overflow"
assert_eq 0 "$STATUS" 'filtered snapshot records overflow'
assert_eq 33 "$(unit_lines "$nd_dir/ps-kill")"
assert_eq false "$(nd_value "$nd_dir/events" .available)"

record_case() { # Otherwise-valid actual-helper input, not a mutated comparison-result field.
    nd_dir="$FIX/helper-$1"
    unit_cmd mkdir "$nd_dir"
    unit_cmd base_input
    for field in gate owned descendant events; do
        unit_write "$nd_dir/$field" jq -r ".$field" "$FIX/input"
    done
    unit_write "$nd_dir/produced" printf '{"extension":{"keep":[null,17,true]},"result":"pass"}\n'
    unit_write "$FIX/stdout" jq -n --slurpfile p "$nd_dir/produced" '{native:$p[0],native_exit:137}'
    nd_count=8; nd_failed=false
    nd_terminal
    unit_cmd test -f "$nd_dir/terminal"
    unit_cmd cat "$nd_dir/terminal"
} 2>/dev/null
helper_summary() {
    nd_unit_io_ok=false
    unit_write "$FIX/summary" nd_summary "$nd_dir" "$FIX/stdout"
    nd_unit_io_ok=true
}
it 'actual comparison distinguishes equal, different and operational error'
record_case equal; helper_summary
assert_eq complete "$(value .evidence)"
assert_eq true "$(value .object.equal)"
record_case different
unit_write "$FIX/changed" jq '.native.changed=true' "$FIX/stdout"
unit_cmd mv "$FIX/changed" "$FIX/stdout"
helper_summary
assert_eq complete "$(value .evidence)"
assert_eq false "$(value .object.equal)" 'cmp1 is a measured inequality'
record_case cmp-error
cmp() { printf 'UTILITY_SENTINEL\n'; printf 'UTILITY_SENTINEL\n' >&2; return 2; }
helper_summary
unset -f cmp
assert_eq incomplete "$(value .evidence)"
assert_eq false "$(value .object.available)"
assert_eq null "$(value .object.equal)" 'cmp error is unknown, never known unequal'
run grep -qF UTILITY_SENTINEL "$FIX/summary"
assert_eq 1 "$STATUS" 'comparison utility output is contained'

it 'early event loss remains detectable even when its error marker cannot be written'
record_case lost-event
unit_cmd rm "$nd_dir/events" "$nd_dir/terminal"
unit_cmd mkdir "$nd_dir/events" "$nd_dir/write-error"
nd_count=0; nd_failed=false; event_index=0
unit_write "$FIX/events-input" jq -r '.events|split("\n")[]|fromjson|del(.seq)|tojson' "$FIX/input"
if {
    while IFS= read -r event; do
        event_index=$((event_index+1))
        nd_append "$event"
        if [ "$event_index" -eq 1 ]; then unit_cmd rmdir "$nd_dir/events"; fi
    done < "$FIX/events-input"
} 2>/dev/null; then :; else unit_fail; fi
nd_terminal; helper_summary
assert_eq incomplete "$(value .evidence)"
assert_eq true "$(value .collection.error)"
assert_eq false "$(value .collection.complete)"
nd_failed=false; nd_terminal; helper_summary
assert_eq incomplete "$(value .evidence)" 'sequence gap alone also prevents completeness'
unit_cmd rm "$nd_dir/terminal"; helper_summary
assert_eq false "$(value .collection.terminal_available)"
assert_eq incomplete "$(value .evidence)" 'missing terminal state is not success'
unit_cmd mkdir "$nd_dir/terminal.tmp"
nd_terminal; helper_summary
assert_eq incomplete "$(value .evidence)" 'unwritable terminal state is not success'

it 'digest is exactly forty lowercase hex characters, not an embedded matching line'
for digest in '("a"*40)+"\nPRIVATE_PATH_OR_TOKEN_SENTINEL"' \
    '"PRIVATE_PATH_OR_TOKEN_SENTINEL\n"+("a"*40)' '("a"*40)+"\n"' \
    '"x"+("a"*40)' '("a"*40)+"x"' '("A"*40)'; do
    unit_cmd base_input; unit_cmd mutate ".object.digest=$digest"
    assert_eq null "$(value .object.digest)"
    assert_eq incomplete "$(value .evidence)"
    run grep -qF PRIVATE_PATH_OR_TOKEN_SENTINEL "$FIX/summary"
    assert_eq 1 "$STATUS" 'rejected digest is never reflected'
done

boundary_body() (
        local fault="$1"
        STATUS=137; nd_diagnostic_ok=false
        if [ "$fault" = read-error ]; then
            cat() {
                if [ "${1:-}" = "$nd_dir/summary" ]; then
                    printf 'UTILITY_SENTINEL\n'; printf 'UTILITY_SENTINEL\n' >&2; return 1
                fi
                command cat "$@"
            }
        fi
        case "$fault" in stdout-closed|both-closed) exec 1>&- ;; esac
        case "$fault" in stderr-closed|both-closed) exec 2>&- ;; esac
        if nd_publish "$nd_dir" "$FIX/stdout"; then publish_rc=0; else publish_rc=$?; fi
        unit_write "$nd_dir/status" printf '%s %s %s\n' "$STATUS" "$publish_rc" "$nd_diagnostic_ok"
)
boundary_probe() {
    unit_capture "$nd_dir/public-out" "$nd_dir/public-err" boundary_body "$1"
}
it 'actual publication boundary contains sink/read/closed-stream errors and preserves native status'
for fault in healthy summary-sink read-error stdout-closed stderr-closed both-closed; do
    record_case "$fault"
    case "$fault" in summary-sink|stderr-closed) unit_cmd mkdir "$nd_dir/summary" ;; esac
    boundary_probe "$fault"
    if [ "$fault" = healthy ]; then expected='137 0 true'; else expected='137 1 false'; fi
    run grep -qxF "$expected" "$nd_dir/status"
    assert_eq 0 "$STATUS" 'publisher failure never overwrites obtained native status'
    for stream in public-out public-err; do
        run grep -qE 'UTILITY_SENTINEL|Could not open|Bad file descriptor|Input error' "$nd_dir/$stream"
        assert_eq 1 "$STATUS" 'new boundary emits no utility diagnostics'
        run grep -qF "$FIX" "$nd_dir/$stream"
        assert_eq 1 "$STATUS" 'new boundary emits no fixture path'
    done
    if [ "$fault" = summary-sink ] || [ "$fault" = read-error ] || [ "$fault" = stderr-closed ]; then
        run grep -qxF 'native-diagnostic: {"schema":"native-case-v1","evidence":"unavailable"}' "$nd_dir/public-out"
        assert_eq 0 "$STATUS" 'fixed unavailable state survives usable stdout'
    fi
    if [ "$fault" = stdout-closed ]; then
        run grep -qxF 'native-diagnostic: {"schema":"native-case-v1","evidence":"unavailable"}' "$nd_dir/public-err"
        assert_eq 0 "$STATUS" 'fixed unavailable state survives usable stderr'
    fi
done

it 'actual unit read/project boundaries contain missing and non-readable record errors'
unit_read_body() {
    local read_rc
    if "$@"; then read_rc=0; else read_rc=$?; fi
    unit_write "$FIX/read-rc" printf '%s\n' "$read_rc"
}
unit_read_probe() {
    unit_capture "$FIX/read-out" "$FIX/read-err" unit_read_body "$@"
}
prepare_project_sink() {
    unit_cmd mv "$FIX/summary" "$FIX/saved-summary"
    unit_cmd mkdir "$FIX/summary"
}
restore_project_sink() {
    unit_cmd rmdir "$FIX/summary"
    unit_cmd mv "$FIX/saved-summary" "$FIX/summary"
}
prepare_missing_summary() { unit_cmd mv "$FIX/summary" "$FIX/saved-summary"; }
restore_missing_summary() { unit_cmd mv "$FIX/saved-summary" "$FIX/summary"; }
for fault in missing directory; do
    if [ "$fault" = missing ]; then record="$FIX/no-such-record"
    else record="$FIX/unreadable-record"; unit_cmd mkdir "$record"; fi
    unit_read_probe nd_value "$record" .available
    rc="$(unit_text "$FIX/read-rc")"
    assert_eq 1 "$rc"
    run grep -qxF unavailable "$FIX/read-out"
    assert_eq 0 "$STATUS"
    run test ! -s "$FIX/read-err"
    assert_eq 0 "$STATUS"
done
unit_cmd base_input; unit_cmd project_summary
prepare_project_sink
if project_summary; then rc=0; else rc=$?; fi
assert_eq 1 "$rc" 'project sink failure is not silent success'
assert_eq unavailable "$(value .evidence)" 'failed projection cannot reuse an old healthy value'
restore_project_sink
unit_cmd base_input; unit_cmd project_summary
prepare_missing_summary
unit_read_probe value .evidence
rc="$(unit_text "$FIX/read-rc")"
assert_eq 1 "$rc" 'unit value reader reports missing summary'
run grep -qxF unavailable "$FIX/read-out"
assert_eq 0 "$STATUS"
run test ! -s "$FIX/read-err"
assert_eq 0 "$STATUS"
restore_missing_summary

it 'unit record reads contain errors with either or both inherited streams closed'
unit_stream_body() (
        local stream_fault="$1"
        STATUS=137
        case "$stream_fault" in stdout-closed|both-closed) exec 1>&- ;; esac
        case "$stream_fault" in stderr-closed|both-closed) exec 2>&- ;; esac
        # Force a genuine file-read failure, not merely an absent JSON key.
        read_rc=0; value .evidence || read_rc=$?
        unit_write "$FIX/unit-stream-status" printf '%s %s\n' "$STATUS" "$read_rc"
)
unit_stream_probe() {
    unit_capture "$FIX/unit-stream-out" "$FIX/unit-stream-err" unit_stream_body "$1"
}
prepare_missing_summary
for stream_fault in stdout-closed stderr-closed both-closed; do
    unit_stream_probe "$stream_fault"
    run grep -qxF '137 1' "$FIX/unit-stream-status"
    assert_eq 0 "$STATUS"
    for stream in unit-stream-out unit-stream-err; do
        run grep -qE 'Could not open|Bad file descriptor|Input error' "$FIX/$stream"
        assert_eq 1 "$STATUS"
        run grep -qF "$FIX" "$FIX/$stream"
        assert_eq 1 "$STATUS"
    done
done
restore_missing_summary

it 'group scan fails closed on ambiguous leaders, threaded zombies and malformed rows'
prepare_structure() {
    unit_cmd cp "$PK_ROOT/scripts/check-pr-review.sh" "$FIX/launcher"
    unit_write "$FIX/group-view" sed -n \
        -e '/^group_view() {/,/^}/p' -e '/^probe_group() {/,/^}/p' -e '/^stop_guard() {/,/^}/p' \
        -e '/^groups_empty() {/,/^}/p' "$FIX/launcher"
    unit_cmd test -s "$FIX/group-view"
}
prepare_structure
scan_group() (
    source "$FIX/group-view"
    ps() { printf '%s\n' "$snapshot"; }
    snapshot="$1"
    group_view 20
)
run scan_group $'1 1 S\n21 20 Z+'
assert_eq 0 "$STATUS"
assert_eq gone "$OUTPUT" 'plain dead non-child zombie does not keep the group live'
run scan_group $'20 20 S\n21 20 Zl'
assert_eq 0 "$STATUS"
assert_eq busy "$OUTPUT" 'a Linux Zl member may still have a live thread'
run scan_group $'20 20 Zl\n21 20 Z'
assert_eq 0 "$STATUS"
assert_eq unconfirmed "$OUTPUT" 'an ambiguous leader is not permission to wait or retire'
run scan_group $'1 1 S\n21 20 Z?'
assert_eq 0 "$STATUS"
assert_eq unconfirmed "$OUTPUT" 'unknown state is live even after leader disappears'
run scan_group $'1 1 S\n20 999 S'
assert_eq 1 "$STATUS" 'a PID in another group is not an owned leader'
run scan_group $'1 1 S\nbad'
assert_eq 1 "$STATUS" 'malformed inventory cannot verify group shutdown'
retired_probe() (
    source "$FIX/group-view"
    : > "$FIX/work.ready"
    probe_group() { state=gone; }
    guard_request() { printf 'stale request %s\n' "$*"; return 1; }
    operation="$FIX"
    stop_guard work 20 3
)
run retired_probe
assert_eq 0 "$STATUS"
assert_eq '' "$OUTPUT" 'retired ID receives no control request, even if readiness was published'
stalled_probe() (
    source "$FIX/group-view"
    unit_cmd mkfifo "$FIX/stalled-inventory"
    exec 8<>"$FIX/stalled-inventory"
    local state="" probe_ok=true
    group_view() {
        # Do not produce any result until the controller has returned.
        while [ ! -f "$FIX/release-inventory" ]; do sleep 0.1; done
        printf 'gone\n'
    }
    if probe_group 20 1; then return 1; fi
    : > "$FIX/release-inventory"
    IFS= read -r -t 5 state <&8 || return 1
    [ "$state" = gone ] && ! probe_group 20 1
)
run stalled_probe
assert_eq 0 "$STATUS" 'a stalled inventory times out without accepting any later response'
kernel_probe() (
    source "$FIX/group-view"
    guarded_pgids=(20 30)
    builtin() {
        [ "$*" = 'kill -0 -- -20' ] || [ "$*" = 'kill -0 -- -30' ] || return 2
        if [ "$4" = -20 ]; then printf 'kill: (-20) - No such process\n' >&2; return 1; fi
        [ -z "$probe_result" ] || printf 'kill: (-30) - %s\n' "$probe_result" >&2
        return "$probe_status"
    }
    local probe_status="$1" probe_result="$2"
    groups_empty
)
run kernel_probe 1 'No such process'
assert_eq 0 "$STATUS" 'only ESRCH on every recorded group permits deletion'
run kernel_probe 0 ''
assert_eq 1 "$STATUS" 'a live group (including a reused ID) blocks deletion'
run kernel_probe 1 'Operation not permitted'
assert_eq 1 "$STATUS" 'EPERM is not proof of absence'
run kernel_probe 1 ''
assert_eq 1 "$STATUS" 'an unrecognized failure is not proof of absence'
run kernel_probe 2 'No such process'
assert_eq 1 "$STATUS" 'the diagnostic alone is insufficient'
run awk '
    /cat .*group-guard.*GUARD/ {in_guard=1}
    /^GUARD$/ {in_guard=0}
    /^[[:blank:]]*(kill|wait)[[:blank:]]/ {
        if (!in_guard || $1 != "kill" || $4 != "\"-$$\"") bad=1
        signals++
    }
    /builtin kill/ && $0 !~ /builtin kill -0 -- "-\$pgid"/ {bad=1}
    END {exit (bad || signals != 2)}
' "$FIX/launcher"
assert_eq 0 "$STATUS" 'only the executing group leader may signal; launcher never waits on a PID'

# Existing run() captures BOTH inherited public streams in memory, independently of the
# inner fixture captures under test. It introduces no further pathname-based capture.
unit_parent_fault_case() (
    local fault="$1"
    STATUS=137
    trap 'printf "obtained-status:%s\n" "$STATUS"' EXIT
    FIX="$FIX/parent-$fault"
    unit_cmd mkdir "$FIX"
    record_case parent
    helper_summary
    case "$fault" in
        stream-out|stream-err|stream-status|healthy|inspect-read|missing-capture)
            prepare_missing_summary
            case "$fault" in
                stream-out) unit_cmd mkdir "$FIX/unit-stream-out" ;;
                stream-err) unit_cmd mkdir "$FIX/unit-stream-err" ;;
                stream-status) unit_cmd mkdir "$FIX/unit-stream-status" ;;
                inspect-read)
                    cat() {
                        if [ "$1" = "$FIX/unit-stream-out" ]; then
                            printf 'PARENT_UTILITY_SENTINEL\n'; printf 'PARENT_UTILITY_SENTINEL\n' >&2; return 1
                        fi
                        command cat "$@"
                    } ;;
                missing-capture)
                    unit_stream_body() {
                        # Only the capture is absent; a later receipt check must not mask it.
                        unit_write "$FIX/unit-stream-status" printf '%s 1\n' "$STATUS"
                        unit_cmd rm "$FIX/unit-stream-err"
                    } ;;
            esac
            printf 'fault-armed:%s\n' "$fault"
            unit_stream_probe stdout-closed
            unit_cmd grep -qxF '137 1' "$FIX/unit-stream-status"
            ;;
        publish-out|publish-err|publish-status)
            case "$fault" in
                publish-out) unit_cmd mkdir "$nd_dir/public-out" ;;
                publish-err) unit_cmd mkdir "$nd_dir/public-err" ;;
                publish-status) unit_cmd mkdir "$nd_dir/status" ;;
            esac
            printf 'fault-armed:%s\n' "$fault"
            boundary_probe stdout-closed
            ;;
        read-out|read-err|read-status)
            case "$fault" in
                read-out) unit_cmd mkdir "$FIX/read-out" ;;
                read-err) unit_cmd mkdir "$FIX/read-err" ;;
                read-status) unit_cmd mkdir "$FIX/read-rc" ;;
            esac
            printf 'fault-armed:%s\n' "$fault"
            unit_read_probe nd_value "$FIX/no-such-record" .available
            ;;
        summary|public-errors)
            unit_cmd rm "$FIX/summary"
            unit_cmd mkdir "$FIX/$fault"
            printf 'fault-armed:%s\n' "$fault"
            unit_capture "$FIX/summary" "$FIX/public-errors" nd_summary "$nd_dir" "$FIX/stdout"
            ;;
        setup-mv|setup-mkdir)
            if [ "$fault" = setup-mv ]; then unit_cmd rm "$FIX/summary"
            else
                mkdir() {
                    if [ "$1" = "$FIX/summary" ]; then
                        printf 'PARENT_UTILITY_SENTINEL\n'; printf 'PARENT_UTILITY_SENTINEL\n' >&2; return 1
                    fi
                    command mkdir "$@"
                }
            fi
            printf 'fault-armed:%s\n' "$fault"
            prepare_project_sink
            ;;
        setup-cp)
            cp() { printf 'PARENT_UTILITY_SENTINEL\n'; printf 'PARENT_UTILITY_SENTINEL\n' >&2; return 1; }
            printf 'fault-armed:%s\n' "$fault"
            prepare_structure
            ;;
    esac
)
it 'outer captures, setup and inspection fail closed without leaking either inherited stream'
for parent_fault in stream-out stream-err stream-status publish-out publish-err publish-status \
    read-out read-err read-status summary public-errors setup-mv setup-mkdir setup-cp \
    inspect-read missing-capture; do
    run unit_parent_fault_case "$parent_fault"
    assert_eq 1 "$STATUS"
    assert_eq "fault-armed:$parent_fault"$'\nFAIL diagnostic control I/O\nobtained-status:137' "$OUTPUT"
done
run unit_parent_fault_case healthy
assert_eq 0 "$STATUS"
assert_eq $'fault-armed:healthy\nobtained-status:137' "$OUTPUT"
finish
