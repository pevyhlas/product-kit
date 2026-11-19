#!/usr/bin/env bash
# Pure data/projection and observer controls. No repetition of the causal variant campaign.
# shellcheck disable=SC2016,SC2034,SC2329 # source-shared state, literal injected code, indirect ps stubs
# shellcheck disable=SC2030,SC2031 # intentional isolated STATUS-preservation probes; parent assertions use run's fresh STATUS
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TESTS_DIR/pr-review-native-diagnostic.sh"
FIX="$(mktemp -d)"; track_tmp "$FIX"
nd_dir="$FIX/records"; mkdir "$nd_dir"

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
base_input; project_summary
assert_eq complete "$(value .evidence)"
assert_eq true "$(value .identity.leader_is_gate)"
assert_eq true "$(value .identity.gate_parent_is_launcher)"
assert_eq 137 "$(value .transfer.native_exit)"
assert_eq false "$(value .kernel_status_proven)"
mutate '.gate="107 101 true"'
events 'map(if .kind=="wait" and .finishing then .status=143
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
base_input; project_summary # explicit-exec counterfactual has the same identity relation as baseline
assert_eq complete "$(value .evidence)"

it 'missing, errors, invalid types and overflow never become false or zero evidence'
for mutation in '.gate=""' '.owned=""' '.descendant=""' '.events=""' \
    '.gate="bad 100 true"' '.gate="101 100 null"' '.object.available=false' \
    '.object.digest="/private/not-a-digest"' '.object.equal="false"' '.overflow=true' \
    '.terminal=""' '.terminal="8 true"' '.terminal="9 false"'; do
    base_input; mutate "$mutation"
    assert_eq incomplete "$(value .evidence)" "$mutation is incomplete"
done
base_input; events 'map(select(.stage!="kill"))'
assert_eq false "$(value .before_kill.available)"
assert_eq null "$(value .before_kill.live_members)"
base_input; events 'map(if .kind=="snapshot" and .stage=="term" then .available=false else . end)'
assert_eq false "$(value .before_term.available)"
assert_eq null "$(value .before_term.leader.live)"
for mutation in '.status=-1' '.status=256' '.generation=0.5' '.before="PATH_SENTINEL"' \
    '.critical="true"' '.native_exit="143"'; do
    base_input; events "map(if .kind==\"wait\" then $mutation else . end)"
    assert_eq incomplete "$(value .evidence)"
    assert_eq null "$(value '.waits[0].status')"
done
base_input; events '. + [range(0;33)|{kind:"wait",status:143}]'
assert_eq true "$(value .overflow)"
assert_eq 16 "$(value '.waits|length')"
base_input; mutate '.events="not-json PATH_SENTINEL"'
assert_eq incomplete "$(value .evidence)"
base_input; mutate '.object.equal=false'
assert_eq complete "$(value .evidence)" 'known inequality is an observation, not missing evidence'
assert_eq false "$(value .object.equal)"

it 'public projection never reflects arbitrary fields, identifiers, strings or raw objects'
base_input
mutate '.secret="PATH_SENTINEL"|.object.secret="PATH_SENTINEL"'
events 'map(.secret="PATH_SENTINEL")'
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
if { nd_summary "$nd_dir" "$FIX/missing" > "$FIX/summary" 2>"$FIX/public-errors"; } 2>/dev/null; then
    nd_unit_io_ok=true
fi
assert_eq incomplete "$(value .evidence)"
assert_eq true "$(value .overflow)"
assert_eq '' "$(unit_text "$FIX/public-errors")"
run grep -qF -- "$FIX" "$FIX/summary"
assert_eq 1 "$STATUS" 'collector never prints its fixture path'

it 'ps failure and filtered-row overflow remain explicit, not empty-group success'
nd_dir="$FIX/failed-ps"; mkdir "$nd_dir"
nd_count=0
printf '100 101 102 103 104 105\n' > "$nd_dir/owned"
printf '101 100 true\n' > "$nd_dir/gate"
printf '106 0\n' > "$nd_dir/descendant"
phase=native
set -o pipefail # the generated launcher already has this option
ps() { return 1; }
nd_snapshot term
assert_eq false "$(nd_value "$nd_dir/events" .available)"
unset -f ps
nd_dir="$FIX/overflow-ps"; mkdir "$nd_dir"
printf '100 101 102 103 104 105\n' > "$nd_dir/owned"
printf '101 100 true\n' > "$nd_dir/gate"
printf '106 0\n' > "$nd_dir/descendant"
ps() { for n in {1..40}; do printf '%s 100 101 S\n' "$((200+n))"; done; }
nd_count=0; nd_snapshot kill
unset -f ps
run test -f "$nd_dir/overflow"
assert_eq 0 "$STATUS" 'filtered snapshot records overflow'
assert_eq 33 "$(unit_lines "$nd_dir/ps-kill")"
assert_eq false "$(nd_value "$nd_dir/events" .available)"

record_case() { # Otherwise-valid actual-helper input, not a mutated comparison-result field.
    nd_dir="$FIX/helper-$1"
    mkdir "$nd_dir" || return 1
    base_input || return 1
    for field in gate owned descendant events; do
        jq -r ".$field" "$FIX/input" > "$nd_dir/$field" || return 1
    done
    printf '{"extension":{"keep":[null,17,true]},"result":"pass"}\n' > "$nd_dir/produced" || return 1
    jq -n --slurpfile p "$nd_dir/produced" '{native:$p[0],native_exit:137}' > "$FIX/stdout" || return 1
    nd_count=8; nd_failed=false
    nd_terminal
} 2>/dev/null
helper_summary() {
    nd_unit_io_ok=false
    if { nd_summary "$nd_dir" "$FIX/stdout" > "$FIX/summary"; } 2>/dev/null; then
        nd_unit_io_ok=true; return 0
    fi
    return 1
}
it 'actual comparison distinguishes equal, different and operational error'
record_case equal; helper_summary
assert_eq complete "$(value .evidence)"
assert_eq true "$(value .object.equal)"
record_case different
if ! { jq '.native.changed=true' "$FIX/stdout" > "$FIX/changed" && mv "$FIX/changed" "$FIX/stdout"; } 2>/dev/null; then
    nd_unit_io_ok=false
fi
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
rm "$nd_dir/events" "$nd_dir/terminal"
mkdir "$nd_dir/events" "$nd_dir/write-error"
nd_count=0; nd_failed=false; event_index=0
while IFS= read -r event; do
    event_index=$((event_index+1))
    nd_append "$event"
    if [ "$event_index" -eq 1 ]; then rmdir "$nd_dir/events"; fi
done < <(jq -r '.events|split("\n")[]|fromjson|del(.seq)|tojson' "$FIX/input" 2>/dev/null)
nd_terminal; helper_summary
assert_eq incomplete "$(value .evidence)"
assert_eq true "$(value .collection.error)"
assert_eq false "$(value .collection.complete)"
nd_failed=false; nd_terminal; helper_summary
assert_eq incomplete "$(value .evidence)" 'sequence gap alone also prevents completeness'
rm "$nd_dir/terminal"; helper_summary
assert_eq false "$(value .collection.terminal_available)"
assert_eq incomplete "$(value .evidence)" 'missing terminal state is not success'
mkdir "$nd_dir/terminal.tmp"
nd_terminal; helper_summary
assert_eq incomplete "$(value .evidence)" 'unwritable terminal state is not success'

it 'digest is exactly forty lowercase hex characters, not an embedded matching line'
for digest in '("a"*40)+"\nPRIVATE_PATH_OR_TOKEN_SENTINEL"' \
    '"PRIVATE_PATH_OR_TOKEN_SENTINEL\n"+("a"*40)' '("a"*40)+"\n"' \
    '"x"+("a"*40)' '("a"*40)+"x"' '("A"*40)'; do
    base_input; mutate ".object.digest=$digest"
    assert_eq null "$(value .object.digest)"
    assert_eq incomplete "$(value .evidence)"
    run grep -qF PRIVATE_PATH_OR_TOKEN_SENTINEL "$FIX/summary"
    assert_eq 1 "$STATUS" 'rejected digest is never reflected'
done

boundary_probe() {
    local fault="$1" probe="$nd_dir"
    (
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
        printf '%s %s %s\n' "$STATUS" "$publish_rc" "$nd_diagnostic_ok" > "$probe/status"
    ) > "$probe/public-out" 2> "$probe/public-err"
} 2>/dev/null
it 'actual publication boundary contains sink/read/closed-stream errors and preserves native status'
for fault in healthy summary-sink read-error stdout-closed stderr-closed both-closed; do
    record_case "$fault"
    case "$fault" in summary-sink|stderr-closed) mkdir "$nd_dir/summary" ;; esac
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
for fault in missing directory; do
    if [ "$fault" = missing ]; then record="$FIX/no-such-record"; else record="$FIX/unreadable-record"; mkdir "$record"; fi
    rc=0
    if { nd_value "$record" .available > "$FIX/read-out" 2> "$FIX/read-err"; } 2>/dev/null; then rc=0; else rc=$?; fi
    assert_eq 1 "$rc"
    run grep -qxF unavailable "$FIX/read-out"
    assert_eq 0 "$STATUS"
    run test ! -s "$FIX/read-err"
    assert_eq 0 "$STATUS"
done
base_input; project_summary
mv "$FIX/summary" "$FIX/saved-summary"; mkdir "$FIX/summary"
if project_summary; then rc=0; else rc=$?; fi
assert_eq 1 "$rc" 'project sink failure is not silent success'
assert_eq unavailable "$(value .evidence)" 'failed projection cannot reuse an old healthy value'
rmdir "$FIX/summary"; mv "$FIX/saved-summary" "$FIX/summary"
base_input; project_summary
mv "$FIX/summary" "$FIX/saved-summary"
rc=0
if { value .evidence > "$FIX/read-out" 2> "$FIX/read-err"; } 2>/dev/null; then rc=0; else rc=$?; fi
assert_eq 1 "$rc" 'unit value reader reports missing summary'
run grep -qxF unavailable "$FIX/read-out"
assert_eq 0 "$STATUS"
run test ! -s "$FIX/read-err"
assert_eq 0 "$STATUS"
mv "$FIX/saved-summary" "$FIX/summary"

it 'unit record reads contain errors with either or both inherited streams closed'
mv "$FIX/summary" "$FIX/saved-summary"
for stream_fault in stdout-closed stderr-closed both-closed; do
    (
        STATUS=137
        case "$stream_fault" in stdout-closed|both-closed) exec 1>&- ;; esac
        case "$stream_fault" in stderr-closed|both-closed) exec 2>&- ;; esac
        # Force a genuine file-read failure, not merely an absent JSON key.
        read_rc=0; value .evidence || read_rc=$?
        printf '%s %s\n' "$STATUS" "$read_rc" > "$FIX/unit-stream-status"
    ) > "$FIX/unit-stream-out" 2> "$FIX/unit-stream-err"
    run grep -qxF '137 1' "$FIX/unit-stream-status"
    assert_eq 0 "$STATUS"
    for stream in unit-stream-out unit-stream-err; do
        run grep -qE 'Could not open|Bad file descriptor|Input error' "$FIX/$stream"
        assert_eq 1 "$STATUS"
        run grep -qF "$FIX" "$FIX/$stream"
        assert_eq 1 "$STATUS"
    done
done
mv "$FIX/saved-summary" "$FIX/summary"

it 'instrumentation leaves workload tail, traps, job control and owned registration unchanged'
cp "$PK_ROOT/scripts/check-pr-review.sh" "$FIX/launcher"
nd_instrument
run bash -n "$FIX/launcher"
assert_eq 0 "$STATUS"
sed -n '/^    capture_err=\$!/,/^    child=\$!/p' "$PK_ROOT/scripts/check-pr-review.sh" > "$FIX/old-tail"
sed -n '/^    capture_err=\$!/,/^    child=\$!/p' "$FIX/launcher" > "$FIX/new-tail"
run cmp "$FIX/old-tail" "$FIX/new-tail"
assert_eq 0 "$STATUS" 'workload subshell through immediate PID registration byte-identical'
run grep -qF 'exec "$@"' "$FIX/launcher"
assert_eq 1 "$STATUS" 'observer does not add exec'
run grep -qF 'then nd_rc=0; else nd_rc=$?; fi' "$FIX/launcher"
assert_eq 0 "$STATUS" 'signal return code is captured before diagnostics'
run grep -qF 'nd_wait "$pid" "$waited_exit" "$before" "$signal_count"' "$FIX/launcher"
assert_eq 0 "$STATUS" 'wait observation receives original status and signal generation'
finish
