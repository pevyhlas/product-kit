#!/usr/bin/env bash
# Pure data/projection and observer controls. No repetition of the causal variant campaign.
# shellcheck disable=SC2016,SC2034,SC2329 # source-shared state, literal injected code, indirect ps stubs
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TESTS_DIR/pr-review-native-diagnostic.sh"
FIX="$(mktemp -d)"; track_tmp "$FIX"
nd_dir="$FIX/records"; mkdir "$nd_dir"

project_summary() {
    jq -c -f "$TESTS_DIR/pr-review-native-summary.jq" "$FIX/input" > "$FIX/summary"
}
base_input() {
    # Synthetic identifiers, not a recorded process inventory. Relations/transitions mirror
    # the retained leader=gate Linux observation; the private evidence is validated as data.
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
          ($gone+{stage:"remove"})]|map(tojson)|join("\n")),
         overflow:false,object:{available:true,equal:true,extension_keep:true,digest:("a"*40)}}
    ' > "$FIX/input"
}
mutate() {
    jq "$1" "$FIX/input" > "$FIX/new"; mv "$FIX/new" "$FIX/input"
    project_summary
}
events() { mutate ".events |= (split(\"\n\")|map(fromjson)|($1)|map(tojson)|join(\"\n\"))"; }
value() { jq -cr "$1" "$FIX/summary"; }

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
    '.object.digest="/private/not-a-digest"' '.object.equal="false"' '.overflow=true'; do
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
assert_not_contains "$(cat "$FIX/summary")" PATH_SENTINEL
assert_not_contains "$(cat "$FIX/summary")" 101
assert_not_contains "$(cat "$FIX/summary")" 106
assert_eq '["before_delete","before_kill","before_term","evidence","identity","kernel_status_proven","object","overflow","schema","signals","transfer","waits"]' \
    "$(value 'keys')"
assert_eq '["available","digest","equal","extension_keep"]' "$(value '.object|keys')"
assert_eq true "$(test "$(wc -c < "$FIX/summary")" -le 8192 && echo true || echo false)"

it 'ephemeral collector bounds and failure reporting do not leak error paths'
nd_count=0
for n in {1..40}; do nd_append '{"kind":"wait"}'; done
assert_eq 32 "$(wc -l < "$nd_dir/events" | tr -d ' ')"
assert_file "$nd_dir/overflow"
nd_summary "$nd_dir" "$FIX/missing" > "$FIX/summary" 2>"$FIX/public-errors"
assert_eq incomplete "$(value .evidence)"
assert_eq true "$(value .overflow)"
assert_eq '' "$(cat "$FIX/public-errors")"
assert_not_contains "$(cat "$FIX/summary")" "$FIX"

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
assert_eq false "$(jq -r .available "$nd_dir/events")"
unset -f ps
nd_dir="$FIX/overflow-ps"; mkdir "$nd_dir"
printf '100 101 102 103 104 105\n' > "$nd_dir/owned"
printf '101 100 true\n' > "$nd_dir/gate"
printf '106 0\n' > "$nd_dir/descendant"
ps() { for n in {1..40}; do printf '%s 100 101 S\n' "$((200+n))"; done; }
nd_count=0; nd_snapshot kill
unset -f ps
assert_file "$nd_dir/overflow"
assert_eq 33 "$(wc -l < "$nd_dir/ps-kill" | tr -d ' ')"
assert_eq false "$(jq -r .available "$nd_dir/events")"

it 'instrumentation leaves workload tail, traps, job control and owned registration unchanged'
cp "$PK_ROOT/scripts/check-pr-review.sh" "$FIX/launcher"
nd_instrument
run bash -n "$FIX/launcher"
assert_eq 0 "$STATUS"
sed -n '/^    capture_err=\$!/,/^    child=\$!/p' "$PK_ROOT/scripts/check-pr-review.sh" > "$FIX/old-tail"
sed -n '/^    capture_err=\$!/,/^    child=\$!/p' "$FIX/launcher" > "$FIX/new-tail"
run cmp "$FIX/old-tail" "$FIX/new-tail"
assert_eq 0 "$STATUS" 'workload subshell through immediate PID registration byte-identical'
assert_not_contains "$(cat "$FIX/launcher")" 'exec "$@"'
assert_contains "$(cat "$FIX/launcher")" 'then nd_rc=0; else nd_rc=$?; fi'
assert_contains "$(cat "$FIX/launcher")" 'nd_wait "$pid" "$waited_exit" "$before" "$signal_count"'
finish
