#!/usr/bin/env bash
# Extra execution/output cases sourced by test_pr_review.sh, sharing only its disposable fixture.
# Every instrumentation/mutation below is test-only. Synthetic native objects are negative
# transport/oracle controls, never substitutes for the real integrated native gate controls.
# shellcheck disable=SC2016,SC2034 # generated scripts and inputs shared with the fixture driver
source "$TESTS_DIR/pr-review-native-diagnostic.sh"

live_group() {
    ps -axo pid=,pgid=,stat= | awk -v group="$1" '$2 == group && $3 !~ /^Z/ { print $1 }'
}
assert_group_gone() {
    assert_eq '' "$(live_group "$1")" "$2"
    if kill -0 "$1" 2>/dev/null; then _no "$2 (owned leader not reaped)"; else _ok "$2 (owned leader reaped)"; fi
}
restore_control() {
    git branch -f main "$BASE"
    git checkout -q --detach "$HEAD_SHA"
    bindings "$HEAD_SHA"; instrument
}
record_cleanup() {
    # Measure BEFORE the owned root is deleted, not merely after the launcher has exited.
    awk -v dir="$FIX" '
        /^    if \[ -n "\$root" \] && \{ ! rm -rf/ {
            print "    if [ -f \"" dir "/group\" ]; then"
            print "        ps -axo pid=,pgid=,stat= | awk -v g=\"$(cat \"" dir "/group\")\" '\''$2 == g && $3 !~ /^Z/ { print $1 }'\'' > \"" dir "/live-at-remove\""
            print "    fi"
            print "    if [ -f \"$root/native.json\" ]; then wc -c < \"$root/native.json\" > \"" dir "/stdout-size\"; fi"
            print "    if [ -f \"$root/native.err\" ]; then wc -c < \"$root/native.err\" > \"" dir "/stderr-size\"; fi"
        }
        { print }
    ' "$FIX/launcher" > "$FIX/injected"
    mv "$FIX/injected" "$FIX/launcher"
}
bound_gate() { # jq mutation, output mode, actual exit; creates explicitly SYNTHETIC negative gate
    local filter="$1" mode="${2:-normal}" rc="${3:-0}"
    git checkout -q --detach "$BASE"
    {
        printf '#!/bin/bash\nrepo=""; while [ "$#" -gt 0 ]; do\n'
        printf 'case "$1" in --repo) shift; repo="$1" ;; esac; shift; done\n'
        if [ "$mode" = stubborn ]; then
            printf 'trap "" TERM\n'
            nd_gate_source "$nd_dir"
        fi
        printf 'p="$(git -C "$repo" rev-parse origin/HEAD)"\nt="$(git -C "$repo" rev-parse refs/remotes/origin/main)"\n'
        printf 'jq --arg p "$p" --arg t "$t" '\''.policy_at=$p|.diagnostics.policy_at=$p|.diagnostics.base_at=$t'\'' <<'\''JSON'\''\n%s\nJSON\n' \
            "$(printf '%s' "$NATIVE" | jq -c "$filter")"
        case "$mode" in
            stdout) printf 'head -c 5242880 /dev/zero | tr "\\000" " "\n' ;;
            stderr) printf 'head -c 5242880 /dev/zero | tr "\\000" " " >&2\n' ;;
            stubborn)
                printf '/bin/bash -c '\''trap "" TERM; echo "$$" > "$1"; while :; do sleep 60; done'\'' _ %q &\n' "$FIX/stubborn"
                printf 'nd_gate "$$" "$PPID" || :\n'
                printf 'echo ready > %q\nwait\n' "$FIX/native-ready" ;;
        esac
        printf 'exit %s\n' "$rc"
    } > .prdkit/scripts/bash/check-review.sh
    git add -A; git commit -qm "synthetic negative transport $mode"
    git branch -f main HEAD; bindings "$HEAD_SHA"; instrument
}
assert_other_bindings() {
    run jq -e --arg h "$HEAD_SHA" --arg p "$(git rev-parse main)" '
        .native.diagnostics.head == $h and .native.pr_head == $h and
        .native.policy_at == $p and .native.diagnostics.policy_at == $p and
        .native.diagnostics.base_at == $p and
        .native.diagnostics.base_ref == "refs/remotes/origin/main" and
        .native.pr == "https://github.com/owner/repo/pull/7" and .native.problems == []
    ' "$FIX/stdout"
    assert_eq 0 "$STATUS" 'negative has otherwise fresh H/T/P and PR bindings'
}

it 'complete history exceeds the former object ceiling with real native evaluation and small diagnostics'
git checkout -q --detach "$BASE"
dd if=/dev/urandom of=historical.bin bs=1048576 count=8 2>"$FIX/dd.err"
git add historical.bin; git commit -qm 'large historical object'
git rm -q historical.bin; git commit -qm 'large object is historical, not at target tip'
LARGE_BASE="$(git rev-parse HEAD)"
git branch -f main "$LARGE_BASE"
mkdir -p specs/changes
printf '# Carrier\n**Tier**: T1\n## State\n' > specs/changes/001-carrier.md
dd if=/dev/urandom of=source.bin bs=1048576 count=8 2>>"$FIX/dd.err"
git add -A; git commit -qm 'large reviewed implementation'
LARGE_HEAD="$(git rev-parse HEAD)"
LARGE_FP="$(review_fingerprint "$PROJ" 001-carrier "$LARGE_BASE" "$LARGE_HEAD")"
bindings "$LARGE_HEAD"
PAYLOAD="$(jq -cn --arg head "$LARGE_HEAD" --arg base "$LARGE_BASE" --arg fp "$LARGE_FP" '
    {schema:"prdkit.review.v3",id:"00000000000000000000000000000011",repo:"owner/repo",pr:7,
     change:"001-carrier",reviewer:"code",from:"start",to:$fp,head:$head,since:"",
     base:"refs/remotes/origin/main",base_at:$base,verdict:"PASS",
     critical:0,high:0,medium:0,low:0,report:"https://example.invalid/report"}')"
fx_review 7 "$(printf '<!-- prdkit-review\n%s\n-->\n' "$PAYLOAD")"
instrument
awk -v dir="$FIX" '
    /^bounded 120 "\$root\/fsck.out"/ {
        print "find \"$objects/.git/objects\" -type f -exec wc -c {} \\; > \"" dir "/object-sizes\""
    }
    { print }
' "$FIX/launcher" > "$FIX/injected"
mv "$FIX/injected" "$FIX/launcher"
record_cleanup
launch
assert_eq 0 "$STATUS" 'real native gate evaluates the acquired complete large history'
assert_eq pass "$(jq -r .native.result "$FIX/stdout")"
run awk '$1 > 4194304 { n++ } END { exit !n }' "$FIX/object-sizes"
assert_eq 0 "$STATUS" 'fetched Git object/pack actually exceeds the former inherited cap'
run test "$(cat "$FIX/stdout-size")" -lt 16384
assert_eq 0 "$STATUS" 'large objects are not large diagnostic capture'
printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
restore_control

normal_capture_drain() { # stream; synchronized ordinary collection, not launch or finish
    local stream="$1" case_dir="$FIX/drain-$1" target
    case "$stream" in stdout) target=capture_out ;; stderr) target=capture_err ;; *) return 1 ;; esac
    mkdir "$case_dir"
    restore_control
    # Hold only the selected native reader, AFTER it captures the real gate's output and EOF.
    # Snapshot every asynchronous job, ordinary wait entry/interruption, and pre-removal state.
    awk -v dir="$case_dir" -v stream="$stream" -v target="$target" '
        /^capture_read\(\) / { in_reader=1 }
        in_reader && /^    return 0/ {
            print "    if [ \"$phase\" = native ] && [ \"$3\" = \"" stream "\" ]; then"
            print "        trap \"\" TERM HUP"
            print "        printf ready > \"" dir "/reader-ready\""
            print "        while :; do sleep 60; done"
            print "    fi"
        }
        /^}/ { in_reader=0 }
        $0 ~ /^[[:space:]]*(overall|capture_out|capture_err|child|watcher)=\$!$/ {
            print
            name=$0; sub(/^[[:space:]]*/, "", name); sub(/=.*/, "", name)
            print "printf '\''%s %s\\n'\'' \"" name "\" \"$" name "\" >> \"" dir "/groups\""
            next
        }
        /^        if wait "\$pid"/ {
            print "        if [ \"$phase\" = native ] && ! $finishing && [ \"$pid\" = \"$" target "\" ]; then"
            print "            printf '\''%s\\n'\'' \"$pid\" > \"" dir "/normal-wait\""
            print "            cp \"$root/native.json\" \"" dir "/native-produced.json\""
            print "        fi"
        }
        /^        (\[ "\$before" != "\$signal_count" \]|if \[ "\$before" = "\$signal_count" \])/ {
            print "        drain_trace_count=${drain_trace_count:-0}"
            print "        if [ \"$phase\" = native ] && [ \"$drain_trace_count\" -lt 50 ]; then"
            print "            alive=false; kill -0 \"$pid\" 2>/dev/null && alive=true"
            print "            printf '\''{\"pid\":%s,\"wait_exit\":%s,\"finishing\":%s,\"critical\":%s,\"before\":%s,\"signals\":%s,\"alive\":%s}\\n'\'' \"$pid\" \"$waited_exit\" \"$finishing\" \"$critical\" \"$before\" \"$signal_count\" \"$alive\" >> \"" dir "/wait-results\""
            print "            drain_trace_count=$((drain_trace_count+1))"
            print "        fi"
            print "        if [ \"$phase\" = native ] && ! $finishing && [ \"$pid\" = \"$" target "\" ] && [ \"$before\" != \"$signal_count\" ]; then"
            print "            alive=false; kill -0 \"$pid\" 2>/dev/null && alive=true"
            print "            printf '\''{\"reader\":%s,\"wait_exit\":%s,\"finishing\":%s,\"child\":\"%s\",\"watcher\":%s,\"alive\":%s}\\n'\'' \"$pid\" \"$waited_exit\" \"$finishing\" \"$child\" \"$watcher\" \"$alive\" > \"" dir "/interrupted-normal-wait\""
            print "        fi"
        }
        /^    finishing=true/ {
            print
            print "    printf ready > \"" dir "/finish-ready\""
            next
        }
        /^    if \[ -n "\$root" \] && \{ ! rm -rf/ {
            print "    ps -axo pid=,pgid=,stat= > \"" dir "/ps-at-remove\""
            print "    awk '\''NR==FNR { owned[$2]=1; next } ($2 in owned) && $3 !~ /^Z/ { print }'\'' \"" dir "/groups\" \"" dir "/ps-at-remove\" > \"" dir "/live-at-remove\""
            print "    awk '\''NR==FNR { owned[$2]=1; next } $1 in owned { print }'\'' \"" dir "/groups\" \"" dir "/ps-at-remove\" > \"" dir "/leaders-at-remove\""
        }
        { print }
    ' "$FIX/launcher" > "$FIX/injected"
    mv "$FIX/injected" "$FIX/launcher"
    env -i PATH="$ORIGINAL_PATH" GH_TOKEN=synthetic GITHUB_EVENT_NAME=pull_request \
        GITHUB_REPOSITORY=owner/repo GITHUB_REPOSITORY_ID=42 \
        "$REAL_BASH" --noprofile --norc "$FIX/launcher" --repository owner/repo --event "$FIX/event" \
        > "$FIX/stdout" 2>"$FIX/stderr" &
    LAUNCHER_PID=$!
    # Bounded fixture handshakes, not polling a background suite or a host/runtime authority.
    for n in {1..100}; do
        [ ! -f "$case_dir/reader-ready" ] || [ ! -f "$case_dir/normal-wait" ] || break
        sleep 0.1
    done
    assert_file "$case_dir/reader-ready" "$stream reader alive after capture and EOF"
    assert_file "$case_dir/normal-wait" "$stream ordinary collection wait reached"
    READER="$(cat "$case_dir/normal-wait")"
    if kill -0 "$READER" 2>/dev/null; then _ok "$stream reader live at normal wait"; else _no "$stream reader missing before signal"; fi
    # Let the parent enter wait. The post-wait trace below must show actual interruption
    # (143), finishing=false, child retired, and a still-live reader; a launch signal cannot pass.
    sleep 0.2
    START="$SECONDS"
    kill -TERM "$LAUNCHER_PID"
    for n in {1..100}; do
        [ ! -f "$case_dir/interrupted-normal-wait" ] || [ ! -f "$case_dir/finish-ready" ] || break
        sleep 0.1
    done
    assert_file "$case_dir/interrupted-normal-wait" "$stream normal wait was actually interrupted"
    run jq -e --argjson pid "$READER" '
        .reader == $pid and .wait_exit == 143 and .finishing == false and
        .child == "" and .watcher > 0 and .alive == true
    ' "$case_dir/interrupted-normal-wait"
    assert_eq 0 "$STATUS" "$stream failure window is ordinary drain with live ownership/watchdog"
    if kill -HUP "$LAUNCHER_PID" 2>/dev/null && kill -USR1 "$LAUNCHER_PID" 2>/dev/null; then
        _ok "$stream repeated catchable signals delivered"
    else _no "$stream repeated signals could not reach teardown"; fi
    if wait "$LAUNCHER_PID"; then STATUS=0; else STATUS=$?; fi
    ELAPSED=$((SECONDS-START))
    assert_eq 1 "$STATUS" "$stream interrupted drain refuses"
    assert_eq 1 "$(jq -s length "$FIX/stdout")" "$stream complete structured refusal"
    assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
    assert_eq interrupted "$(jq -r .error.code "$FIX/stdout")"
    assert_eq 0 "$(jq -r .native_exit "$FIX/stdout")" "$stream obtained actual native status retained"
    run jq -e --arg h "$HEAD_SHA" --arg p "$BASE" '
        .native.result == "pass" and .native.authority == "host" and .native.problems == [] and
        .native.head == $h and .native.pr_head == $h and .native.policy_at == $p and
        .native.diagnostics.base_at == $p and .native.diagnostics.policy_at == $p
    ' "$FIX/stdout"
    assert_eq 0 "$STATUS" "$stream real native diagnostic object retained"
    assert_eq "$(jq -cS . "$case_dir/native-produced.json")" "$(jq -cS .native "$FIX/stdout")" \
        "$stream entire captured native object preserved"
    assert_eq '' "$(cat "$case_dir/live-at-remove")" "$stream all groups terminated BEFORE root deletion"
    assert_eq '' "$(cat "$case_dir/leaders-at-remove")" "$stream all owned leaders reaped BEFORE root deletion"
    assert_group_gone "$READER" "$stream reader terminated/reaped before result"
    assert_eq '' "$(find "$FIX/scratch" -mindepth 1 -print)" "$stream root cleaned after group cleanup"
    run test "$ELAPSED" -lt 15
    assert_eq 0 "$STATUS" "$stream repeated-signal refusal remains bounded"
    # Preserve trace evidence for the private failing-before driver; ordinary suites clean their
    # fixture through lib.sh. Kill any observed orphan only AFTER the assertions above.
    cp "$FIX/stdout" "$case_dir/result.json"; cp "$FIX/stderr" "$case_dir/stderr"
    while read -r name pid; do kill -KILL -- "-$pid" 2>/dev/null || true; done < "$case_dir/groups"
    "$REAL_RM" -rf "$FIX/scratch/"*
}

for stream in stdout stderr; do
    it "signal-interrupted normal $stream collection retains ownership until reaped"
    normal_capture_drain "$stream"
done
restore_control

it 'cancellation at the very first teardown command cannot recursively exit cleanup'
instrument
rm -f "$FIX/group" "$FIX/live-at-remove"
awk -v dir="$FIX" '
    /^overall=\$!/ { print; print "printf '\''%s\\n'\'' \"$overall\" > \"" dir "/group\""; next }
    /^    local native_pending=false/ { print "    kill -TERM \"$$\"" }
    { print }
' "$FIX/launcher" > "$FIX/injected"
mv "$FIX/injected" "$FIX/launcher"
record_cleanup
launch
assert_eq 1 "$STATUS"
assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
assert_eq interrupted "$(jq -r .error.code "$FIX/stdout")"
assert_eq 0 "$(jq -r .native_exit "$FIX/stdout")" 'entry cancellation retains obtained real-native success'
assert_eq pass "$(jq -r .native.result "$FIX/stdout")"
assert_group_gone "$(cat "$FIX/group")" 'overall group reaped despite teardown-entry cancellation'
assert_eq '' "$(cat "$FIX/live-at-remove")"
restore_control

it 'isolated head/type negatives reject for their own guard, not a stale target'
for fault in head type; do
    if [ "$fault" = head ]; then mutation='.head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"'
    else mutation='.head_is_pr_head="true"'; fi
    bound_gate "$mutation"
    launch
    assert_eq 1 "$STATUS"
    assert_eq inconsistent-result "$(jq -r .error.code "$FIX/stdout")"
    assert_other_bindings
    # Deliberately remove ONLY the intended guard in a disposable launcher. Acceptance of this
    # synthetic negative by the mutant proves unrelated stale bindings cannot be its oracle.
    if [ "$fault" = head ]; then
        sed 's/\.pr == \$pr and \.head == \$h and /.pr == $pr and /' "$FIX/launcher" > "$FIX/mutant"
    else
        sed 's/ and \.head_is_pr_head == true//' "$FIX/launcher" > "$FIX/mutant"
    fi
    mv "$FIX/mutant" "$FIX/launcher"
    launch
    assert_eq 0 "$STATUS" "isolated $fault guard mutation is detected by the negative oracle"
    assert_eq complete "$(jq -r .launcher "$FIX/stdout")"
done
restore_control

it 'finite valid-data stdout/stderr overflow is causal, byte-bounded and prompt'
for stream in stdout stderr; do
    bound_gate . "$stream"
    record_cleanup
    START="$SECONDS"
    launch
    ELAPSED=$((SECONDS-START))
    assert_eq 1 "$STATUS"
    assert_eq capture-limit "$(jq -r .error.code "$FIX/stdout")"
    assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
    run test "$ELAPSED" -lt 20
    assert_eq 0 "$STATUS" "$stream finite overflow is not a native timeout"
    assert_eq 4194304 "$(tr -d '[:space:]' < "$FIX/$stream-size")" "$stream capture stops at the byte ceiling"
    assert_other_bindings
    # Increase only the disposable capture ceiling above the finite 5 MiB producer. It now
    # completes with valid bound JSON, so malformed data/timeouts cannot make the oracle pass.
    instrument
    sed 's/4194304/8388608/g' "$FIX/launcher" > "$FIX/mutant"
    mv "$FIX/mutant" "$FIX/launcher"
    record_cleanup
    launch
    assert_eq 0 "$STATUS" "$stream bound mutation is caught by the overflow oracle"
    assert_eq complete "$(jq -r .launcher "$FIX/stdout")"
    run test "$(cat "$FIX/$stream-size")" -gt 4194304
    assert_eq 0 "$STATUS" 'finite mutant producer really exceeds the intended capture ceiling'
done
restore_control

it 'every asynchronous launch is registered before queued cancellation runs'
for boundary in overall child watcher capture_out capture_err; do
    instrument
    rm -f "$FIX/group" "$FIX/descendant" "$FIX/live-at-remove"
    if [ "$boundary" != overall ]; then touch "$FIX/hang"; fi
    awk -v name="$boundary" -v dir="$FIX" '
        $0 ~ /^[[:space:]]*[a-z_]+=\$!$/ && index($0, name "=$!") {
            print "if [ \"" name "\" = overall ] || [ \"$phase\" = fetch ]; then"
            print "printf '\''%s\\n'\'' \"$!\" > \"" dir "/group\""
            if (name == "child") {
                print "for n in 1 2 3 4 5; do [ ! -f \"" dir "/descendant\" ] || break; sleep 1; done"
            }
            print "kill -TERM \"$$\""
            print "fi"
        }
        { print }
    ' "$FIX/launcher" > "$FIX/injected"
    mv "$FIX/injected" "$FIX/launcher"
    record_cleanup
    launch
    rm -f "$FIX/hang"
    assert_file "$FIX/group" "$boundary boundary was actually reached"
    assert_eq 1 "$STATUS"
    assert_eq interrupted "$(jq -r .error.code "$FIX/stdout")"
    assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
    assert_group_gone "$(cat "$FIX/group")" "$boundary group stopped before result"
    assert_eq '' "$(cat "$FIX/live-at-remove")" "$boundary group stopped before scratch deletion"
    if [ "$boundary" = child ]; then
        assert_file "$FIX/descendant" 'workload is armed at its registration boundary'
        assert_terminated "$(cat "$FIX/descendant")" 'registration-boundary descendant terminated'
    fi
done
restore_control

it 'obtained native status survives the bounded-to-caller transfer window'
bound_gate . normal 17
sed '/^native_exit="\$bounded_exit"/i\
kill -TERM "$$"
' "$FIX/launcher" > "$FIX/injected"
mv "$FIX/injected" "$FIX/launcher"
launch
assert_eq 1 "$STATUS"
assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
assert_eq interrupted "$(jq -r .error.code "$FIX/stdout")"
assert_eq 17 "$(jq -r .native_exit "$FIX/stdout")"
assert_eq '[null,17,true]' "$(jq -c .native.extension.keep "$FIX/stdout")"
assert_other_bindings
restore_control

it 'overlapping overall deadline and repeated signals cannot interrupt KILL escalation/teardown'
nd_dir="$FIX/native-diagnostic"
mkdir "$nd_dir"
bound_gate . stubborn
rm -f "$FIX/native-ready" "$FIX/stubborn" "$FIX/group" "$FIX/teardown-ready" "$FIX/live-at-remove"
awk -v dir="$FIX" '
    /sleep "\$\(\(deadline-SECONDS\)\)"/ {
        print "    for n in 1 2 3 4 5 6 7 8 9 10; do [ ! -f \"" dir "/native-ready\" ] || break; sleep 1; done"
        print "    sleep 1"
        next
    }
    /^    finishing=true/ { print; print "    printf ready > \"" dir "/teardown-ready\""; next }
    /^    child=\$!/ { print; print "    if [ \"$phase\" = native ]; then printf '\''%s\\n'\'' \"$child\" > \"" dir "/group\"; fi"; next }
    { print }
' "$FIX/launcher" > "$FIX/injected"
mv "$FIX/injected" "$FIX/launcher"
record_cleanup
nd_instrument
set -m
env -i PATH="$ORIGINAL_PATH" GH_TOKEN=synthetic GITHUB_EVENT_NAME=pull_request \
    GITHUB_REPOSITORY=owner/repo GITHUB_REPOSITORY_ID=42 \
    "$REAL_BASH" --noprofile --norc "$FIX/launcher" --repository owner/repo --event "$FIX/event" \
    > "$FIX/stdout" 2>"$FIX/stderr" &
LAUNCHER_PID=$!
(
    sleep 20
    kill -KILL "$LAUNCHER_PID" 2>/dev/null || true
    [ ! -f "$FIX/group" ] || kill -KILL -- "-$(cat "$FIX/group")" 2>/dev/null || true
) >/dev/null 2>&1 &
GUARD=$!
for n in 1 2 3 4 5 6 7 8 9 10; do
    [ ! -f "$FIX/native-ready" ] || [ ! -f "$FIX/stubborn" ] || break
    sleep 1
done
assert_file "$FIX/native-ready"; assert_file "$FIX/stubborn"
STUBBORN="$(cat "$FIX/stubborn")"
kill -TERM "$STUBBORN"
nd_descendant_rc=$?
{ printf '%s %s\n' "$STUBBORN" "$nd_descendant_rc" > "$nd_dir/descendant"; } 2>/dev/null || :
if kill -0 "$STUBBORN" 2>/dev/null; then _ok 'descendant is armed to resist TERM'; else _no 'stubborn fixture not armed'; fi
START="$SECONDS"
kill -TERM "$LAUNCHER_PID"
for n in 1 2 3 4 5; do [ ! -f "$FIX/teardown-ready" ] || break; sleep 1; done
assert_file "$FIX/teardown-ready"
kill -TERM "$LAUNCHER_PID" 2>/dev/null || true
kill -HUP "$LAUNCHER_PID" 2>/dev/null || true
kill -USR1 "$LAUNCHER_PID" 2>/dev/null || true
if wait "$LAUNCHER_PID"; then STATUS=0; else STATUS=$?; fi
ELAPSED=$((SECONDS-START))
kill -KILL -- "-$GUARD" 2>/dev/null || true
wait "$GUARD" 2>/dev/null || true
nd_publish "$nd_dir" "$FIX/stdout" || :
assert_eq 1 "$STATUS"
assert_eq 1 "$(jq -s length "$FIX/stdout")" 'one complete refusal after repeated catchable signals'
assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
assert_eq interrupted "$(jq -r .error.code "$FIX/stdout")"
assert_eq 137 "$(jq -r .native_exit "$FIX/stdout")" 'TERM-resistant native group required actual KILL escalation'
assert_terminated "$STUBBORN" 'TERM-resistant descendant terminated'
assert_group_gone "$(cat "$FIX/group")" 'native group terminated and owned leader reaped'
assert_eq '' "$(cat "$FIX/live-at-remove")" 'native group is gone before scratch deletion'
assert_eq '' "$(find "$FIX/scratch" -mindepth 1 -print)"
run test "$ELAPSED" -lt 15
assert_eq 0 "$STATUS" 'teardown remains bounded despite repeated signals'
assert_other_bindings
{ # Contain only these new diagnostic assertions, not inherited whole-suite output.
    assert_eq complete "$(nd_public_value .evidence)" 'bounded diagnostic witnesses are available'
    assert_eq true "$(nd_public_value .identity.leader_is_gate)" 'registered native leader is the external gate'
    assert_eq true "$(nd_public_value .identity.gate_ignores_term)" 'registered gate is armed to resist TERM'
    assert_eq true "$(nd_public_value .before_kill.leader.live)" 'registered gate survives until group KILL'
    assert_eq 0 "$(nd_public_value .signals.KILL)" 'native group KILL succeeds independently of its wait status'
    assert_eq 137 "$(nd_public_value '.waits | map(select(.finishing and (.alive == false))) | last | .status')" \
        'finishing wait independently records gate KILL status'
    assert_eq false "$(nd_public_value .before_delete.leader.present)" 'native leader reaped before scratch deletion'
    assert_eq true "$(nd_public_value .object.equal)" 'entire synthetic native object retained'
    assert_eq true "$(nd_public_value .object.extension_keep)" 'actual sequence retains unknown field'
} 2>/dev/null
restore_control
