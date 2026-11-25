#!/usr/bin/env bash
# Extra execution/output cases sourced by test_pr_review.sh, sharing only its disposable fixture.
# Every instrumentation/mutation below is test-only. Synthetic native objects are negative
# transport/oracle controls, never substitutes for the real integrated native gate controls.
# shellcheck disable=SC2016,SC2034 # generated scripts and inputs shared with the fixture driver
live_group() {
    ps -axo pid=,pgid=,stat= | awk -v group="$1" '$2 == group && $3 !~ /^Z[+<NsL]*$/ { print $1 }'
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
        /^phase=native$/ { print "native_started=$SECONDS" }
        /^    if \[ -n "\$root" \] && \{ ! rm -rf/ {
            print "    printf attempted > \"" dir "/remove-attempted\""
            print "    if [ -f \"" dir "/group\" ]; then"
            print "        ps -axo pid=,pgid=,stat= | awk -v g=\"$(cat \"" dir "/group\")\" '\''$2 == g && $3 !~ /^Z[+<NsL]*$/ { print $1 }'\'' > \"" dir "/live-at-remove\" || printf unavailable > \"" dir "/live-at-remove\""
            print "    fi"
            print "    if [ -f \"$root/native.json\" ]; then wc -c < \"$root/native.json\" > \"" dir "/stdout-size\"; fi"
            print "    if [ -f \"$root/native.err\" ]; then wc -c < \"$root/native.err\" > \"" dir "/stderr-size\"; fi"
            print "    if [ -n \"${native_started:-}\" ]; then printf \"%s\\n\" \"$((SECONDS-native_started))\" > \"" dir "/native-elapsed\"; fi"
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
        if [ "$mode" = stubborn ]; then printf 'trap "" TERM\n'; fi
        printf 'p="$(git -C "$repo" rev-parse origin/HEAD)"\nt="$(git -C "$repo" rev-parse refs/remotes/origin/main)"\n'
        printf 'jq --arg p "$p" --arg t "$t" '\''.policy_at=$p|.diagnostics.policy_at=$p|.diagnostics.base_at=$t'\'' <<'\''JSON'\''\n%s\nJSON\n' \
            "$(printf '%s' "$NATIVE" | jq -c "$filter")"
        case "$mode" in
            stdout) printf 'head -c 5242880 /dev/zero | tr "\\000" " "\n' ;;
            stderr) printf 'head -c 5242880 /dev/zero | tr "\\000" " " >&2\n' ;;
            stubborn)
                printf '/bin/bash -c '\''trap "" TERM; echo "$$" > "$1"; while :; do sleep 60; done'\'' _ %q &\n' "$FIX/stubborn"
                printf 'ps -o pgid= -p "$$" | tr -d " " > %q\nwait\n' "$FIX/group" ;;
            hidden-member)
                printf 'ps -o pgid= -p "$$" | tr -d " " > %q\n' "$FIX/group"
                printf '/bin/bash -c '\''exec 9<>"$1"; printf "held\\n" > "$HOME/member-held"; echo "$$" > "$2"; read -r -t 120 <&9'\'' _ %q %q </dev/null >/dev/null 2>&1 &\n' "$FIX/member-release" "$FIX/hidden-member"
                printf 'for n in {1..200}; do [ ! -s %q ] || break; sleep 0.1; done\n' "$FIX/hidden-member" ;;
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
bindings "$LARGE_HEAD"
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

it 'cancellation at the very first teardown command cannot recursively exit cleanup'
instrument
awk '
    /^    finishing=true/ { print "    kill -TERM \"$$\"" }
    { print }
' "$FIX/launcher" > "$FIX/injected"
mv "$FIX/injected" "$FIX/launcher"
launch
assert_eq 1 "$STATUS"
assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
assert_eq interrupted "$(jq -r .error.code "$FIX/stdout")"
assert_eq 0 "$(jq -r .native_exit "$FIX/stdout")" 'entry cancellation retains obtained real-native success'
assert_eq pass "$(jq -r .native.result "$FIX/stdout")"
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
    launch
    assert_eq 1 "$STATUS"
    assert_eq capture-limit "$(jq -r .error.code "$FIX/stdout")"
    assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
    run test "$(cat "$FIX/native-elapsed")" -lt 20
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

it 'cancellation immediately before guard registration keeps group ownership'
instrument
rm -f "$FIX/group" "$FIX/descendant" "$FIX/live-at-remove"
touch "$FIX/hang"
awk -v dir="$FIX" '
    /^    work=\$!/ {
        print "    if [ \"$phase\" = fetch ] && [ \"$out\" = \"$root/fetch.out\" ]; then"
        print "        printf \"%s\\n\" \"$!\" > \"" dir "/group\""
        print "        for n in {1..200}; do [ ! -s \"" dir "/descendant\" ] || break; sleep 0.1; done"
        print "        kill -TERM \"$$\""
        print "    fi"
    }
    { print }
' "$FIX/launcher" > "$FIX/injected"
mv "$FIX/injected" "$FIX/launcher"
record_cleanup
launch
rm -f "$FIX/hang"
assert_file "$FIX/group" 'launcher started the workload guard'
assert_file "$FIX/descendant" 'workload is armed at the launch registration boundary'
assert_eq 1 "$STATUS"
assert_eq interrupted "$(jq -r .error.code "$FIX/stdout")"
assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
assert_group_gone "$(cat "$FIX/group")" 'group stopped before result'
assert_file "$FIX/live-at-remove" 'pre-deletion snapshot was taken'
assert_eq '' "$(cat "$FIX/live-at-remove")" 'group stopped before scratch deletion'
assert_terminated "$(cat "$FIX/descendant")" 'registration-boundary descendant terminated'
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

it 'native work guard exiting before readiness refuses promptly and cleans scratch'
bindings "$HEAD_SHA" 999-absent
awk -v dir="$FIX" '
    /^pgid=/ {
        print "if [ \"$role\" = work ] && [ -f \"$op/../selected\" ]; then ps() { return 42; }; fi"
    }
    /^phase=native$/ { print "native_started=$SECONDS" }
    /^if bounded 180 / { sub(/180/, "25") }
    /^    work=\$!/ {
        print "    if [ \"$phase\" = native ]; then printf \"%s\\n\" \"$!\" \"$reader_out\" \"$reader_err\" > \"" dir "/startup-groups\"; fi"
    }
    /^    if ! \$groups_verified \|\| ! remove_scratch; then/ {
        print "    printf \"%s\\n\" \"$((SECONDS-native_started))\" > \"" dir "/startup-elapsed\""
        print "    cp \"$root/guard.err\" \"" dir "/startup-private\""
    }
    { print }
' "$FIX/launcher" > "$FIX/injected"
mv "$FIX/injected" "$FIX/launcher"
STARTUP_SCRATCH_BEFORE="$(scratch_entries)"
launch
assert_eq 1 "$STATUS"
assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
assert_eq native "$(jq -r .error.stage "$FIX/stdout")" 'pre-ready exit is a native transport failure'
assert_eq guard-startup "$(jq -r .error.code "$FIX/stdout")" 'verified shutdown is not cleanup-failed'
assert_eq '[null,null]' "$(jq -c '[.native_exit,.native]' "$FIX/stdout")" 'no native result from a failed guard startup'
run test "$(cat "$FIX/startup-elapsed")" -lt 20
assert_eq 0 "$STATUS" 'pre-ready exit did not wait out the native operation budget'
assert_contains "$(cat "$FIX/startup-private")" 'role=work step=pgid-lookup status=42' 'private diagnostic identifies guard role, step and status'
assert_not_contains "$(cat "$FIX/stderr")" 'pgid-lookup' 'bootstrap details stay private'
assert_eq 3 "$(wc -l < "$FIX/startup-groups" | tr -d '[:space:]')" 'all three native guard PIDs recorded'
while IFS= read -r group; do
    if [[ "$group" =~ ^[1-9][0-9]*$ ]]; then
        assert_group_gone "$group" 'startup failure leaves no live guard group'
    else _no 'startup fixture produced an invalid guard PID' "$group"; fi
done < "$FIX/startup-groups"
# Remove just the root(s) left by this fault on an unfixed launcher, for base replay.
while IFS= read -r entry; do "$REAL_RM" -rf -- "$entry"; done < <(new_scratch "$STARTUP_SCRATCH_BEFORE")
restore_control

it 'a failed capture with complete native JSON refuses without exposing a native result'
awk '
    /^        record "\$rc"$/ {
        print "        if [ \"$role\" = out ] && [ \"$1\" = \"${op%/*}/native.json\" ]; then rc=23; fi"
    }
    { print }
' "$FIX/launcher" > "$FIX/injected"
mv "$FIX/injected" "$FIX/launcher"
CAPTURE_SCRATCH_BEFORE="$(scratch_entries)"
launch
assert_eq 1 "$STATUS"
assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
assert_eq native "$(jq -r .error.stage "$FIX/stdout")"
assert_eq capture-failed "$(jq -r .error.code "$FIX/stdout")"
assert_eq '[null,null]' "$(jq -c '[.native_exit,.native]' "$FIX/stdout")" 'failed capture cannot salvage otherwise valid native JSON or exit'
while IFS= read -r entry; do "$REAL_RM" -rf -- "$entry"; done < <(new_scratch "$CAPTURE_SCRATCH_BEFORE")
restore_control

for relay_case in timeout cancellation fifo-timeout fifo-cancellation; do
    relay_stop="${relay_case#fifo-}"
    it "failed native status rename is a capture failure ($relay_case)"
    rm -f "$FIX/work-rename-failed" "$FIX/relay-stop"
    awk -v dir="$FIX" -v stop="$relay_stop" -v mode="$relay_case" '
        /^record\(\) \{/ {
            print "mv() {"
            print "    if [ \"$role\" = work ] && [ \"$fixture_phase\" = native ] &&"
            print "        [ \"$1\" = \"$op/work.tmp\" ] && [ \"$2\" = \"$op/work.status\" ]; then"
            if (mode ~ /^fifo-/) print "        mkdir \"$op/work.failed\"" # Keep the marker from becoming a regular file.
            print "        printf failed > \"" dir "/work-rename-failed\""
            if (stop == "cancellation") print "        kill -TERM \"$launcher_pid\""
            print "        return 23"
            print "    fi"
            print "    command mv \"$@\""
            print "}"
        }
        /^start_guard\(\) \{/ {
            print
            print "    export launcher_pid=$$ fixture_phase=$phase"
            next
        }
        /^    collect_operation 2>>/ {
            print "    if [ \"$phase\" = native ]; then printf \"%s:%s\\n\" \"$bounded_limit\" \"$pending_signal\" > \"" dir "/relay-stop\"; fi"
        }
        { print }
    ' "$FIX/launcher" > "$FIX/injected"
    mv "$FIX/injected" "$FIX/launcher"
    arm_fixture_deadline native.json work-rename-failed end
    launch
    assert_eq 1 "$STATUS"
    assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
    assert_eq native "$(jq -r .error.stage "$FIX/stdout")"
    assert_eq capture-failed "$(jq -r .error.code "$FIX/stdout")"
    assert_eq '[null,null]' "$(jq -c '[.native_exit,.native]' "$FIX/stdout")" \
        'failed work-status rename cannot publish native JSON or exit'
    assert_file "$FIX/work-rename-failed" 'the native relay attempted the targeted rename'
    case "$relay_case" in
        fifo-timeout) assert_eq timeout: "$(cat "$FIX/relay-stop")" 'deadline reached before collecting the FIFO notice' ;;
        fifo-cancellation) assert_eq :interrupted "$(cat "$FIX/relay-stop")" 'cancellation queued before collecting the FIFO notice' ;;
    esac
    restore_control
done

fd_lsof_matches() { # FIFO path, lsof field records; print matching f fields or a safe error
    local path key
    # Apple libproc lsof can report a vnode path (n) and inode (i) for a
    # named FIFO, but omits its device (D). Check the inode against the
    # known FIFO, using the device too when lsof supplies it.
    if ! path="$(cd -P -- "${1%/*}" 2>/dev/null && printf '%s/%s' "$PWD" "${1##*/}")" ||
        ! key="$(stat -Lc 'D0x%D i%i' "$path" 2>/dev/null || stat -Lf 'D0x%Xd i%i' "$path" 2>/dev/null)" ||
        ! [[ "$key" =~ ^D0x[[:xdigit:]]+\ i[1-9][0-9]*$ ]]; then
        printf '%s\n' 'cannot identify target FIFO'
        return 1
    fi
    FD_FIFO_PATH="$path" LC_ALL=C awk -v want_dev="${key%% *}" -v want_inode="${key#* }" '
        function problem(message) {
            if (failure == "") failure = message
        }
        function check_fd() {
            if (fd == "") return
            # Older lsof versions abbreviate FDs above 9999 as *nnn.
            if (fd !~ /^f([0-9]+|\*[0-9][0-9][0-9])$/) {
                problem("invalid FD record")
                return
            }
            seen = 1
            # Darwin can leave just f and an n error message if a vnode lookup fails.
            if (type !~ /^t[[:alpha:]][[:alnum:]_.-]*$/ ||
                tolower(type) ~ /^t(unknown|unkn?|un|none|nofd|vnon|vbad)$/) {
                problem("unclassified FD " fd)
                return
            }
            if (type != "tFIFO") return
            # A bare NAME such as "pipe" or "no more information" is not a path.
            if (name !~ /^n\/./ && inode !~ /^i[1-9][0-9]*$/) {
                problem("unidentified FIFO " fd)
                return
            }
            if (name == ("n" ENVIRON["FD_FIFO_PATH"]) ||
                (inode == want_inode && (dev == "" || dev == want_dev)))
                matches = matches (matches == "" ? "" : " ") fd
        }
        /^f/ { check_fd(); fd = $0; type = name = inode = dev = "" }
        /^t/ { type = $0 }
        /^n/ { name = $0 }
        /^i/ { inode = $0 }
        /^D/ { dev = $0 }
        END {
            check_fd()
            if (!seen) problem("no numeric FD records")
            if (failure != "") { print failure; exit 1 }
            if (matches != "") print matches
        }
    ' <<< "$2" 2>/dev/null
}

fd_lsof_observe() { # FIFO path, pid, lsof binary
    local fields matches
    # Include every numeric FD, even ones Bash saves beyond its usual range.
    if ! fields="$("$3" -w -a -p "$2" -d 0-2147483647 -F ftDin 2>/dev/null)"; then
        printf '%s\n' 'observer failed: lsof command failed'
    elif ! matches="$(fd_lsof_matches "$1" "$fields")"; then
        printf 'observer failed: %s\n' "${matches:-invalid lsof listing}"
    elif [ -n "$matches" ]; then
        printf 'inherited descriptor: %s\n' "$matches"
    else
        printf '%s\n' clean
    fi
}

fd_lsof_probe() { # known FIFO path, lsof binary
    local fields matches
    if ! fields="$("$REAL_BASH" -c '
        exec 7<>"$1" || exit 1
        "$2" -w -a -p "$$" -d 7 -F ftDin
        exit "$?"
    ' _ "$1" "$2" 2>/dev/null)"; then
        printf '%s\n' 'lsof probe command failed'
    elif ! matches="$(fd_lsof_matches "$1" "$fields")"; then
        printf '%s\n' "${matches:-invalid lsof listing}"
    elif [ "$matches" = f7 ]; then
        return 0
    else
        printf '%s\n' 'probe FIFO was not identified on f7'
    fi
    return 1
}

fd_lsof_version() {
    # lsof writes its version report to stderr; allow only the revision token.
    "$1" -v 2>&1 | LC_ALL=C awk '
        /^[[:blank:]]*revision:[[:blank:]]+[0-9]+\.[0-9]+(\.[0-9]+)*[[:alpha:]]?[[:blank:]]*$/ && !seen {
            print "lsof revision: " $2
            seen = 1
        }
        END { if (!seen) print "lsof revision: unavailable" }
    '
}

it 'partial lsof observations never certify a clean descriptor audit'
FD_CONTROL_FIFO="$FIX/fd-control"
FD_CONTROL_LSOF="$FIX/lsof-control"
mkfifo "$FD_CONTROL_FIFO"
cat > "$FD_CONTROL_LSOF" <<'SHIM'
#!/bin/bash
if [ "$1" = -v ]; then
    printf '%s\n' '    revision: 4.99.4' 'synthetic private stderr' >&2
    exit 0
fi
printf '%s\n' p123 f6 tREG n/synthetic/private-file
case "${FD_CONTROL_MODE:-}" in
    partial) printf '%s\n' f8 'nno more information' ;;
    unknown-type) printf '%s\n' f8 tUNKN n/synthetic/private-file ;;
    missing-identity) printf '%s\n' f8 tFIFO ;;
    invalid-identity) printf '%s\n' f8 tFIFO i0 'nno more information' ;;
    failure)
        printf '%s\n' 'synthetic private stderr' >&2
        exit 1 ;;
esac
SHIM
chmod +x "$FD_CONTROL_LSOF"
for fd_case in partial unknown-type missing-identity invalid-identity failure; do
    case "$fd_case" in
        partial|unknown-type) expected='unclassified FD f8' ;;
        missing-identity|invalid-identity) expected='unidentified FIFO f8' ;;
        failure) expected='lsof command failed' ;;
    esac
    # The mock leaves the open FIFO on f8 unclassifiable, while f6 remains classifiable.
    FD_CONTROL_MODE="$fd_case" run fd_lsof_observe "$FD_CONTROL_FIFO" "$$" "$FD_CONTROL_LSOF" 8<>"$FD_CONTROL_FIFO"
    assert_eq "observer failed: $expected" "$OUTPUT" "descriptor audit rejects and redacts the $fd_case listing"
done
FD_CONTROL_MODE=partial run fd_lsof_probe "$FD_CONTROL_FIFO" "$FD_CONTROL_LSOF"
assert_eq 1 "$STATUS" 'partial listing cannot pass preflight'
assert_eq 'unclassified FD f8' "$OUTPUT" 'preflight redacts names and the vnode error'
FD_CONTROL_MODE=failure run fd_lsof_probe "$FD_CONTROL_FIFO" "$FD_CONTROL_LSOF"
assert_eq 1 "$STATUS" 'failed lsof command cannot pass preflight'
assert_eq 'lsof probe command failed' "$OUTPUT" 'preflight drops stdout and stderr from failed lsof'
run fd_lsof_version "$FD_CONTROL_LSOF"
assert_eq 'lsof revision: 4.99.4' "$OUTPUT" 'preflight version diagnostic prints only the revision'
rm "$FD_CONTROL_FIFO" "$FD_CONTROL_LSOF"

it 'native workload and status helper do not inherit either end of the failure FIFO'
FD_OBSERVER=''
FD_LSOF=''
FD_PROBE_ERROR='probe not run'
if [ "${PRDKIT_TEST_FORCE_LSOF:-0}" != 1 ] && [ -d /proc/self/fd ]; then
    FD_OBSERVER=proc
elif FD_LSOF="$(type -P lsof)" && mkfifo "$FIX/fd-observer"; then
    # Confirm that the same identity matcher used by the audit finds a known open FIFO.
    if FD_PROBE_ERROR="$(fd_lsof_probe "$FIX/fd-observer" "$FD_LSOF")"; then
        FD_OBSERVER=lsof
    fi
    rm "$FIX/fd-observer"
fi
if [ -n "$FD_OBSERVER" ]; then
    _ok "descriptor observer: $FD_OBSERVER"
    {
        printf '#!/bin/bash\nresult_dir=%q\nobserver=%q\nlsof_bin=%q\n' "$FIX" "$FD_OBSERVER" "$FD_LSOF"
        declare -f fd_lsof_matches fd_lsof_observe
        cat <<'AUDIT'
role="$1"; shift
checked=false; result=clean
# Inspect the FIFO inode, not a descriptor number: Bash can save a copy
# on an otherwise unused FD when redirections are restored after a call.
for pipe in "$HOME"/../op.*/work.failure; do
    [ -p "$pipe" ] || continue
    checked=true
    case "$observer" in
        proc)
            for fd in /proc/self/fd/*; do
                if [ "$fd" -ef "$pipe" ]; then
                    if [ "$result" = clean ]; then result='inherited FDs:'; fi
                    result="$result ${fd##*/}"
                fi
            done ;;
        lsof)
            result="$(fd_lsof_observe "$pipe" "$$" "$lsof_bin")"
            [ "$result" = clean ] || break ;;
    esac
done
if ! $checked; then result='failure FIFO not found'; fi
printf '%s\n' "$result" > "$result_dir/fd-$role"
exec "$@"
AUDIT
    } > "$FIX/fd-audit"
    REAL_MV="$(command -v mv)"
    {
        printf '#!/bin/bash\n'
        printf 'if [ "${fixture_phase:-}" = native ] && [[ "$1" == */work.tmp && "$2" == */work.status ]]; then\n'
        printf '    exec %q status %q "$@"\nfi\n' "$FIX/fd-audit" "$REAL_MV"
        printf 'exec %q "$@"\n' "$REAL_MV"
    } > "$FIX/bin/mv"
    chmod +x "$FIX/fd-audit" "$FIX/bin/mv"
    awk -v dir="$FIX" '
        /^start_guard\(\) \{/ {
            print
            print "    export fixture_phase=$phase"
            next
        }
        /^if bounded 180 / { sub(/\/bin\/bash/, "\"" dir "/fd-audit\" native /bin/bash") }
        { print }
    ' "$FIX/launcher" > "$FIX/injected"
    mv "$FIX/injected" "$FIX/launcher"
    launch
    assert_eq 0 "$STATUS" 'descriptor probe preserves the native pass'
    assert_eq complete "$(jq -r .launcher "$FIX/stdout")"
    assert_eq clean "$(cat "$FIX/fd-native")" 'native workload has no descriptor to work.failure'
    assert_eq clean "$(cat "$FIX/fd-status")" 'status rename helper has no descriptor to work.failure'
    rm "$FIX/bin/mv"
    restore_control
else
    if [ -n "$FD_LSOF" ]; then
        fd_lsof_version "$FD_LSOF" >&2
        printf 'lsof probe FD 7 (-F ftDin): %s\n' "$FD_PROBE_ERROR" >&2
    else
        printf '%s\n' 'lsof not found on PATH' >&2
    fi
    if [ "${GITHUB_ACTIONS:-}" = true ]; then
        _no 'descriptor identity requires /proc/self/fd or usable lsof' || :
    else
        printf '%s\n' 'SKIP: descriptor identity requires /proc/self/fd or usable lsof'
    fi
fi

it 'a live member missed by ps prevents scratch deletion'
rm -f "$FIX/group" "$FIX/hidden-member" "$FIX/remove-attempted"
mkfifo "$FIX/member-release"
bound_gate . hidden-member
# Hide only members of the native workload group, not its guard or other
# groups. The real kernel probe must still see the surviving member.
awk '
    /^group_view\(\) {/ {
        print "ps() {"
        print "    if [ \"$phase\" = native ]; then"
        print "        command ps \"$@\" | awk -v g=\"$work\" '\''$2 != g || $1 == g'\''"
        print "    else command ps \"$@\"; fi"
        print "}"
    }
    { print }
' "$FIX/launcher" > "$FIX/injected"
mv "$FIX/injected" "$FIX/launcher"
record_cleanup
invoke_launcher
assert_eq 1 "$STATUS"
assert_eq cleanup "$(jq -r .error.stage "$FIX/stdout")"
assert_eq cleanup-failed "$(jq -r .error.code "$FIX/stdout")"
assert_eq 0 "$(jq -r .native_exit "$FIX/stdout")"
assert_other_bindings
assert_file "$FIX/hidden-member"
GROUP="$(cat "$FIX/group")"
MEMBER="$(cat "$FIX/hidden-member")"
assert_eq "$MEMBER" "$(live_group "$GROUP")" 'real member remains, but its guard was reaped'
run find "$FIX/scratch" -name member-held -print
assert_contains "$OUTPUT" '/home/member-held' 'retained scratch contains the member marker'
run test ! -e "$FIX/remove-attempted"
assert_eq 0 "$STATUS" 'deletion was never attempted'
if [[ "$MEMBER" =~ ^[1-9][0-9]*$ ]]; then kill -TERM "$MEMBER" 2>/dev/null || :; fi
"$REAL_RM" -rf "$FIX/scratch/"*
restore_control

for shutdown in clean survivor threaded ambiguous; do
    it "one owned KILL; bounded verification for $shutdown"
    rm -f "$FIX/stubborn" "$FIX/group" "$FIX/remove-attempted" "$FIX/live-at-remove" "$FIX/signal-trace"
    bound_gate . stubborn
    awk -v dir="$FIX" -v mode="$shutdown" '
        /^    work=\$!/ {
            print "    [ \"$phase\" != native ] || : > \"$operation/native\""
        }
        /^[[:blank:]]+kill -(TERM|KILL) / {
            print "            if [ -f \"$op/native\" ] && [ \"$role\" = work ]; then"
            print "                printf \"%s %s\\n\" \"" $2 "\" \"$$\" >> \"" dir "/signal-trace\""
            if (mode == "survivor" && $2 == "-KILL") print "                builtin kill -KILL \"$$\""
            print "            fi"
        }
        /^group_view\(\) {/ && mode == "threaded" {
            print "ps() {"
            print "    command ps \"$@\" || return 1"
            print "    if [ -f \"$operation/native\" ] && grep -q -- \"^-KILL \" \"" dir "/signal-trace\"; then"
            print "        printf \"99999999 %s Zl\\n\" \"$work\""
            print "    fi"
            print "}"
        }
        /^group_view\(\) {/ && mode == "ambiguous" {
            print "ps() {"
            print "    if [ -f \"$operation/native\" ]; then"
            print "        command ps \"$@\" | awk -v leader=\"$work\" '\''$1 == leader {$3=\"Zl\"} { print }'\''"
            print "    else command ps \"$@\"; fi"
            print "}"
        }
        { print }
    ' "$FIX/launcher" > "$FIX/injected"
    mv "$FIX/injected" "$FIX/launcher"
    record_cleanup
    env -i PATH="$ORIGINAL_PATH" GH_TOKEN=synthetic GITHUB_EVENT_NAME=pull_request \
        GITHUB_REPOSITORY=owner/repo GITHUB_REPOSITORY_ID=42 \
        "$REAL_BASH" --noprofile --norc "$FIX/launcher" --repository owner/repo --event "$FIX/event" --policy-ref main \
        > "$FIX/stdout" 2>"$FIX/stderr" &
    LAUNCHER_PID=$!
    if ! await_fixture "$LAUNCHER_PID" "$FIX/group" "$FIX/stubborn"; then
        _no 'native stubborn fixture did not become ready' "$(cat "$FIX/stdout" "$FIX/stderr")"
        kill -TERM "$LAUNCHER_PID" 2>/dev/null || :
        wait "$LAUNCHER_PID" || :
        restore_control
        continue
    fi
    assert_file "$FIX/group"; assert_file "$FIX/stubborn"
    STUBBORN="$(cat "$FIX/stubborn")"
    START="$SECONDS"
    kill -TERM "$LAUNCHER_PID"
    if [ "$shutdown" != ambiguous ]; then
        for n in {1..40}; do [ ! -s "$FIX/signal-trace" ] || break; sleep 0.1; done
    fi
    if kill -USR1 "$LAUNCHER_PID" && kill -HUP "$LAUNCHER_PID"; then
        _ok 'queued overlapping catchable signals during teardown'
    else
        _no 'catchable signals could not reach teardown'
    fi
    # The fixture must not hang indefinitely if a regression blocks in wait.
    for n in {1..200}; do kill -0 "$LAUNCHER_PID" 2>/dev/null || break; sleep 0.1; done
    if kill -0 "$LAUNCHER_PID" 2>/dev/null; then
        _no 'teardown did not finish before the test deadline'
        kill -KILL "$LAUNCHER_PID"
    fi
    if wait "$LAUNCHER_PID"; then STATUS=0; else STATUS=$?; fi
    ELAPSED=$((SECONDS-START))
    assert_eq 1 "$STATUS"
    assert_eq 1 "$(jq -s length "$FIX/stdout")" 'one complete refusal after repeated catchable signals'
    assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
    GROUP="$(cat "$FIX/group")"
    if [ "$shutdown" = ambiguous ]; then
        run test ! -e "$FIX/signal-trace"
        assert_eq 0 "$STATUS" 'an unconfirmed leader is neither signalled nor waited for'
    else
        assert_eq "-TERM $GROUP"$'\n'"-KILL $GROUP" "$(cat "$FIX/signal-trace")" \
            'only the live native leader signals; nothing sends another signal after KILL'
    fi
    if [ "$shutdown" = clean ]; then
        assert_eq native "$(jq -r .error.stage "$FIX/stdout")"
        assert_eq interrupted "$(jq -r .error.code "$FIX/stdout")"
        assert_eq null "$(jq -r .native_exit "$FIX/stdout")" 'KILL interrupted status relay; do not invent an exit'
        assert_eq pass "$(jq -r .native.result "$FIX/stdout")" 'supervised KILL preserves an otherwise valid native diagnostic'
        assert_terminated "$STUBBORN" 'TERM-resistant descendant terminated'
        assert_group_gone "$GROUP" 'native group terminated and owned leader reaped'
        assert_file "$FIX/live-at-remove" 'native deletion snapshot exists'
        assert_eq '' "$(cat "$FIX/live-at-remove")" 'native group is gone before scratch deletion'
        assert_eq '' "$(find "$FIX/scratch" -mindepth 1 -print)"
        assert_other_bindings
        assert_eq '[null,17,true]' "$(jq -c .native.extension.keep "$FIX/stdout")" 'refusal retains unknown native fields'
    else
        assert_eq cleanup-failed "$(jq -r .error.code "$FIX/stdout")"
        assert_eq cleanup "$(jq -r .error.stage "$FIX/stdout")"
        run test -n "$(find "$FIX/scratch" -mindepth 1 -print)"
        assert_eq 0 "$STATUS" 'unverified cleanup retains scratch'
        run test ! -e "$FIX/remove-attempted"
        assert_eq 0 "$STATUS" 'failed verification never attempts scratch deletion'
        run test "$ELAPSED" -ge 8
        assert_eq 0 "$STATUS" 'verification waited after the signal instead of treating the remaining row as dead'
        if [ "$shutdown" = survivor ] || [ "$shutdown" = ambiguous ]; then
            run test -n "$(live_group "$GROUP")"
            assert_eq 0 "$STATUS" 'the actual running member survived the refusal'
            # Test-only cleanup of known stubborn fixture processes.
            for member in $(live_group "$GROUP"); do kill -KILL "$member" 2>/dev/null || :; done
        fi
        "$REAL_RM" -rf "$FIX/scratch/"*
    fi
    run test "$ELAPSED" -lt 20
    assert_eq 0 "$STATUS" 'teardown remains bounded despite repeated signals'
    restore_control
done
