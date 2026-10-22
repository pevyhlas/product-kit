#!/usr/bin/env bash
#
# Test ledger-emit.sh behavior across backend configurations.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SCRIPT="$PK_ROOT/scripts/ledger-emit.sh"

# --- Test setup: create a temporary project directory ---
# Returns the directory path. Caller MUST call track_tmp after command substitution
# because track_tmp modifies an array that doesn't survive subshells.
setup_test_project() {
    local d
    d="$(mktemp -d)"
    mkdir -p "$d/.prdkit/memory"
    mkdir -p "$d/.prdkit/scripts/bash"
    cp "$SCRIPT" "$d/.prdkit/scripts/bash/"
    cp "$PK_ROOT/scripts/common.sh" "$PK_ROOT/scripts/json-lib.sh" "$d/.prdkit/scripts/bash/"
    chmod +x "$d/.prdkit/scripts/bash/ledger-emit.sh"
    git -C "$d" init -q
    git -C "$d" config user.email t@example.com
    git -C "$d" config user.name test
    echo "$d"
}

# Helper: run ledger-emit from within the test project directory
run_emit() {
    local dir="$1"
    shift
    (cd "$dir" && .prdkit/scripts/bash/ledger-emit.sh "$@")
}

# --- Test: No policy file = spool only, exit 0 ---
it "No policy file spools locally and exits 0 (no backend dispatch)"
dir="$(setup_test_project)"; track_tmp "$dir"
result="$(echo '{"event":"test"}' | run_emit "$dir" "test.event" 2>&1)" && status=$? || status=$?
assert_eq "0" "$status" "exit code is 0 when policy file absent"
assert_eq "" "$result" "no output when policy file absent"

# --- Test: backend: none = spool only, exit 0 ---
it "backend: none spools locally and exits 0 (no backend dispatch)"
dir="$(setup_test_project)"; track_tmp "$dir"
cat > "$dir/.prdkit/memory/task-ledger.md" <<'EOF'
# Task Ledger
- backend: none
EOF
result="$(echo '{"event":"test"}' | run_emit "$dir" "test.event" 2>&1)" && status=$? || status=$?
assert_eq "0" "$status" "exit code is 0 with backend: none"
assert_eq "" "$result" "no output with backend: none"

# --- Test: backend: command pipes to configured command ---
it "backend: command pipes event to adapter"
dir="$(setup_test_project)"; track_tmp "$dir"
output_file="$dir/event-output.json"
cat > "$dir/test-adapter.sh" <<EOF
#!/usr/bin/env bash
cat > "$output_file"
EOF
chmod +x "$dir/test-adapter.sh"
cat > "$dir/.prdkit/memory/task-ledger.md" <<EOF
# Task Ledger
- backend: command
- command: $dir/test-adapter.sh
- events: all
- mode: best-effort
EOF
input_event='{"schema":"prdkit.ledger.v1","event":"readiness.changed","feature":{"id":"001-test"}}'
echo "$input_event" | run_emit "$dir" "readiness.changed" && status=$? || status=$?
assert_eq "0" "$status" "exit code is 0 with backend: command"
assert_file "$output_file" "adapter receives event"
output="$(cat "$output_file")"
assert_eq "$input_event" "$output" "adapter receives exact event JSON"

# --- Test: Event filter - only matching events emitted ---
it "Event filter limits emission to matching events"
dir="$(setup_test_project)"; track_tmp "$dir"
output_file="$dir/event-output.json"
cat > "$dir/test-adapter.sh" <<EOF
#!/usr/bin/env bash
cat > "$output_file"
EOF
chmod +x "$dir/test-adapter.sh"
cat > "$dir/.prdkit/memory/task-ledger.md" <<EOF
# Task Ledger
- backend: command
- command: $dir/test-adapter.sh
- events: [readiness.changed, blocker.*]
- mode: best-effort
EOF

# Event that matches filter
echo '{"event":"readiness.changed"}' | run_emit "$dir" "readiness.changed"
assert_file "$output_file" "matching event readiness.changed emitted"
rm -f "$output_file"

# Event that matches glob filter
echo '{"event":"blocker.opened"}' | run_emit "$dir" "blocker.opened"
assert_file "$output_file" "glob-matching event blocker.opened emitted"
rm -f "$output_file"

# Event that doesn't match filter - should NOT create file
echo '{"event":"task.upserted"}' | run_emit "$dir" "task.upserted"
if [ -f "$output_file" ]; then
    _no "non-matching event task.upserted should not be emitted"
else
    _ok "non-matching event task.upserted not emitted"
fi

# --- Test: best-effort mode - adapter failure doesn't fail script ---
it "best-effort mode ignores adapter failure"
dir="$(setup_test_project)"; track_tmp "$dir"
cat > "$dir/failing-adapter.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$dir/failing-adapter.sh"
cat > "$dir/.prdkit/memory/task-ledger.md" <<EOF
# Task Ledger
- backend: command
- command: $dir/failing-adapter.sh
- events: all
- mode: best-effort
EOF
echo '{"event":"test"}' | run_emit "$dir" "test.event" 2>/dev/null && status=$? || status=$?
assert_eq "0" "$status" "exit code is 0 in best-effort mode even when adapter fails"

# --- Test: strict mode - adapter failure fails script ---
it "strict mode propagates adapter failure"
dir="$(setup_test_project)"; track_tmp "$dir"
cat > "$dir/failing-adapter.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$dir/failing-adapter.sh"
cat > "$dir/.prdkit/memory/task-ledger.md" <<EOF
# Task Ledger
- backend: command
- command: $dir/failing-adapter.sh
- events: all
- mode: strict
EOF
echo '{"event":"test"}' | run_emit "$dir" "test.event" 2>/dev/null && status=$? || status=$?
if [ "$status" -ne 0 ]; then
    _ok "strict mode fails when adapter fails (exit $status)"
else
    _no "strict mode should fail when adapter fails"
fi

# --- Test: Missing event type argument ---
it "Missing event type argument is an error"
dir="$(setup_test_project)"; track_tmp "$dir"
echo '{"event":"test"}' | run_emit "$dir" 2>/dev/null && status=$? || status=$?
if [ "$status" -ne 0 ]; then
    _ok "missing event type is an error (exit $status)"
else
    _no "missing event type should be an error"
fi

# --- Test: Empty stdin ---
it "Empty stdin is an error"
dir="$(setup_test_project)"; track_tmp "$dir"
echo -n "" | run_emit "$dir" "test.event" 2>/dev/null && status=$? || status=$?
if [ "$status" -ne 0 ]; then
    _ok "empty stdin is an error (exit $status)"
else
    _no "empty stdin should be an error"
fi

# --- Test: spool line appended with backend: none ---
it "Spool records event with backend: none"
dir="$(setup_test_project)"; track_tmp "$dir"
cat > "$dir/.prdkit/memory/task-ledger.md" <<'EOF'
# Task Ledger
- backend: none
EOF
input_event='{"schema":"prdkit.ledger.v1","event":"task.upserted"}'
echo "$input_event" | run_emit "$dir" "task.upserted" && status=$? || status=$?
assert_eq "0" "$status" "exit code is 0 with backend: none"
assert_file "$dir/.prdkit/ledger/events.jsonl" "spool file created with backend: none"
assert_eq "$input_event" "$(cat "$dir/.prdkit/ledger/events.jsonl")" "spool contains exact event line"

# --- Test: spool line appended when policy file absent ---
it "Spool records event when policy file absent"
dir="$(setup_test_project)"; track_tmp "$dir"
input_event='{"event":"test"}'
echo "$input_event" | run_emit "$dir" "test.event"
assert_file "$dir/.prdkit/ledger/events.jsonl" "spool file created without policy file"
assert_eq "$input_event" "$(cat "$dir/.prdkit/ledger/events.jsonl")" "spool contains exact event line"

# --- Test: spool write happens before command backend runs ---
it "Spool is written before the adapter command runs"
dir="$(setup_test_project)"; track_tmp "$dir"
snapshot_file="$dir/spool-snapshot.jsonl"
cat > "$dir/test-adapter.sh" <<EOF
#!/usr/bin/env bash
# Snapshot the spool as it exists at adapter-invocation time
cp .prdkit/ledger/events.jsonl "$snapshot_file"
cat > /dev/null
EOF
chmod +x "$dir/test-adapter.sh"
cat > "$dir/.prdkit/memory/task-ledger.md" <<EOF
# Task Ledger
- backend: command
- command: $dir/test-adapter.sh
- events: all
- mode: best-effort
EOF
input_event='{"event":"readiness.changed"}'
echo "$input_event" | run_emit "$dir" "readiness.changed"
assert_file "$snapshot_file" "spool existed when adapter ran"
assert_eq "$input_event" "$(cat "$snapshot_file")" "spool already contained the event when adapter ran"

# --- Test: two emissions append two lines ---
it "Two emissions append two spool lines"
dir="$(setup_test_project)"; track_tmp "$dir"
echo '{"event":"first"}' | run_emit "$dir" "test.first"
echo '{"event":"second"}' | run_emit "$dir" "test.second"
line_count="$(wc -l < "$dir/.prdkit/ledger/events.jsonl" | tr -d ' ')"
assert_eq "2" "$line_count" "spool has two lines after two emissions"
assert_eq '{"event":"first"}' "$(head -1 "$dir/.prdkit/ledger/events.jsonl")" "first line is first event"
assert_eq '{"event":"second"}' "$(tail -1 "$dir/.prdkit/ledger/events.jsonl")" "second line is second event"

# --- Test: missing "event" field is injected from the CLI event type ---
# Downstream collectors silently drop spool lines without "event"; the emitter
# must never record a line the pipeline cannot read.
it "A payload without an event field gets the CLI event type injected"
dir="$(setup_test_project)"; track_tmp "$dir"
echo '{"event_id":"001-x/feature.created","payload":{"title":"X"}}' | run_emit "$dir" "feature.created"
assert_contains "$(cat "$dir/.prdkit/ledger/events.jsonl")" '"event": "feature.created"' "event type injected into spooled line"
assert_contains "$(cat "$dir/.prdkit/ledger/events.jsonl")" '"event_id":"001-x/feature.created"' "original payload preserved"
echo '{"event":"task.upserted","detail":1}' | run_emit "$dir" "task.upserted"
assert_eq '{"event":"task.upserted","detail":1}' "$(tail -1 "$dir/.prdkit/ledger/events.jsonl")" "payload already carrying event stays byte-identical"

it "empty objects and nested event keys produce valid top-level events"
dir="$(setup_test_project)"; track_tmp "$dir"
printf ' { \n } \n' | run_emit "$dir" feature.created
assert_eq feature.created "$(jq -r .event "$dir/.prdkit/ledger/events.jsonl")" "whitespace-only object gets valid event"
printf '%s\n' '{"payload":{"event":"nested","note":"event"},"items":[null,true,false,-2.5e+3]}' | run_emit "$dir" feature.created
line="$(tail -1 "$dir/.prdkit/ledger/events.jsonl")"
assert_eq feature.created "$(printf '%s\n' "$line" | jq -r .event)" "nested event does not suppress top-level injection"
assert_eq nested "$(printf '%s\n' "$line" | jq -r .payload.event)" "nested content preserved"

it "escaped top-level event keys are recognized rather than duplicated"
input_event='{"\u0065vent":"feature.created","payload":{"quote":"a\"b","slash":"a\\b"}}'
printf '%s\n' "$input_event" | run_emit "$dir" feature.created
assert_eq "$input_event" "$(tail -1 "$dir/.prdkit/ledger/events.jsonl")" "escaped JSON key preserved"

it "malformed or ambiguous envelopes never enter the spool"
before="$(cat "$dir/.prdkit/ledger/events.jsonl")"
for input_event in 'not-json' '[]' '{"payload":}' '{"n":01}' '{"event":null}' '{"event":""}' '{"event":"a","event":"b"}' '{"event":"a","\u0065vent":"b"}' '{"x":"\q"}' '{} {}'; do
    if printf '%s\n' "$input_event" | run_emit "$dir" feature.created >/dev/null 2>&1; then
        _no "malformed input rejected: $input_event"
    else _ok "malformed input rejected: $input_event"; fi
done
if printf '{"x":"raw\nnewline"}' | run_emit "$dir" feature.created >/dev/null 2>&1; then
    _no 'raw in-string newline rejected'
else _ok 'raw in-string newline rejected'; fi
assert_eq "$before" "$(cat "$dir/.prdkit/ledger/events.jsonl")" "invalid inputs leave existing spool untouched"

it "Unicode-equivalent duplicate keys are rejected across UTF-8 and escape forms"
for input_event in '{"é":1,"\u00e9":2}' '{"😀":1,"\ud83d\ude00":2}' '{"\u00e9":1,"\u00E9":2}' '{"É":1,"\u00C9":2}'; do
    if printf '%s\n' "$input_event" | run_emit "$dir" feature.created >/dev/null 2>&1; then
        _no "Unicode duplicate rejected: $input_event"
    else _ok "Unicode duplicate rejected: $input_event"; fi
done
assert_eq "$before" "$(cat "$dir/.prdkit/ledger/events.jsonl")" "Unicode ambiguity leaves spool untouched"

it "unpaired UTF-16 surrogate escapes are rejected in keys and values"
for input_event in '{"payload":"\ud800"}' '{"\ud800":1}' '{"payload":"\udc00"}' '{"payload":"\ud800\u0041"}' '{"payload":"\udc00\ud800"}'; do
    if printf '%s\n' "$input_event" | run_emit "$dir" feature.created >/dev/null 2>&1; then
        _no "unpaired surrogate rejected: $input_event"
    else _ok "unpaired surrogate rejected: $input_event"; fi
done
assert_eq "$before" "$(cat "$dir/.prdkit/ledger/events.jsonl")" 'invalid surrogate escapes leave spool untouched'

it "distinct Unicode keys and legal DEL characters remain valid"
input_event='{"é":1,"😀":2,"payload":{"text":"\ud83d\ude00"}}'
printf '%s\n' "$input_event" | run_emit "$dir" feature.created
line="$(tail -1 "$dir/.prdkit/ledger/events.jsonl")"
assert_eq '😀' "$(printf '%s\n' "$line" | jq -r .payload.text)" 'surrogate-pair value preserved'
assert_eq 1 "$(printf '%s\n' "$line" | jq -r '.["é"]')" 'Unicode key preserved'
printf '%s\n' '{"\u00C9":1,"\u00e9":2}' | run_emit "$dir" feature.created
assert_eq 1 "$(tail -1 "$dir/.prdkit/ledger/events.jsonl" | jq -r '.["É"]')" 'an escape with uppercase hex digits is accepted'
printf '{"payload":{"text":"\177"}}\n' | run_emit "$dir" feature.created
assert_eq '"\u007f"' "$(tail -1 "$dir/.prdkit/ledger/events.jsonl" | jq -c .payload.text)" 'legal raw DEL preserved'

it "malformed UTF-8 and raw controls are rejected before spooling"
before="$(cat "$dir/.prdkit/ledger/events.jsonl")"
for bytes in '\303(' '\300\257' '\355\240\200' '\364\220\200\200' '\000' '\037'; do
    if printf '{"payload":{"text":"%b"}}\n' "$bytes" | run_emit "$dir" feature.created >/dev/null 2>&1; then
        _no "invalid byte sequence rejected: $bytes"
    else _ok "invalid byte sequence rejected: $bytes"; fi
done
assert_eq "$before" "$(cat "$dir/.prdkit/ledger/events.jsonl")" 'invalid bytes do not alter spool'

# --- Test: spool write failure is a warning in best-effort mode ---
it "Spool write failure warns but succeeds in best-effort mode"
dir="$(setup_test_project)"; track_tmp "$dir"
# A regular file where the spool directory should be makes mkdir -p fail
touch "$dir/.prdkit/ledger"
cat > "$dir/.prdkit/memory/task-ledger.md" <<'EOF'
# Task Ledger
- backend: none
- mode: best-effort
EOF
result="$(echo '{"event":"test"}' | run_emit "$dir" "test.event" 2>&1)" && status=$? || status=$?
assert_eq "0" "$status" "exit code is 0 when spool write fails in best-effort mode"
if echo "$result" | grep -q "Warning"; then
    _ok "warning printed when spool write fails in best-effort mode"
else
    _no "expected a warning when spool write fails in best-effort mode"
fi

# --- Test: spool write failure is an error in strict mode ---
it "Spool write failure fails in strict mode"
dir="$(setup_test_project)"; track_tmp "$dir"
touch "$dir/.prdkit/ledger"
cat > "$dir/.prdkit/memory/task-ledger.md" <<'EOF'
# Task Ledger
- backend: none
- mode: strict
EOF
echo '{"event":"test"}' | run_emit "$dir" "test.event" 2>/dev/null && status=$? || status=$?
if [ "$status" -ne 0 ]; then
    _ok "strict mode fails when spool write fails (exit $status)"
else
    _no "strict mode should fail when spool write fails"
fi

# --- Test: pretty-printed JSON is normalized to one spool line ---
it "Multi-line event JSON is normalized to a single JSONL spool line"
dir="$(setup_test_project)"; track_tmp "$dir"
printf '{\n  "event": "test",\n  "payload": {\n    "k": "v"\n  }\n}\n' | run_emit "$dir" "test.event"
line_count="$(wc -l < "$dir/.prdkit/ledger/events.jsonl" | tr -d ' ')"
assert_eq "1" "$line_count" "pretty-printed event occupies exactly one spool line"
if grep -q '"k": "v"' "$dir/.prdkit/ledger/events.jsonl"; then
    _ok "normalized line preserves the payload content"
else
    _no "normalized line lost payload content"
fi

# --- Test: operator attribution is off by default ---
it "No operator field is added without 'operator: git' in the policy"
dir="$(setup_test_project)"; track_tmp "$dir"
cat > "$dir/.prdkit/memory/task-ledger.md" <<'EOF'
# Task Ledger

## Configuration

- backend: none
EOF
echo '{"event":"test"}' | run_emit "$dir" "test.event"
if grep -q '"operator"' "$dir/.prdkit/ledger/events.jsonl"; then
    _no "operator field must not be injected by default"
else
    _ok "no operator field without the opt-in"
fi

# --- Test: operator: git appends the git identity ---
it "operator: git appends the repo git identity to the event"
dir="$(setup_test_project)"; track_tmp "$dir"
cat > "$dir/.prdkit/memory/task-ledger.md" <<'EOF'
# Task Ledger

## Configuration

- backend: none
- operator: git
EOF
echo '{"event":"test","payload":{}}' | run_emit "$dir" "test.event"
if grep -q '"operator": "t@example.com"' "$dir/.prdkit/ledger/events.jsonl"; then
    _ok "operator injected from git config user.email"
else
    _no "expected operator t@example.com in spool line: $(cat "$dir/.prdkit/ledger/events.jsonl")"
fi

# --- Test: operator: git never double-writes an existing operator ---
it "operator: git preserves an operator field already present"
dir="$(setup_test_project)"; track_tmp "$dir"
cat > "$dir/.prdkit/memory/task-ledger.md" <<'EOF'
# Task Ledger

## Configuration

- backend: none
- operator: git
EOF
input_event='{"event":"test","operator":"someone-else"}'
echo "$input_event" | run_emit "$dir" "test.event"
assert_eq "$input_event" "$(cat "$dir/.prdkit/ledger/events.jsonl")" "pre-set operator passes through unchanged"

it "nested operator keys do not suppress real top-level operator attribution"
printf '%s\n' '{"payload":{"operator":"nested"}}' | run_emit "$dir" feature.created
line="$(tail -1 "$dir/.prdkit/ledger/events.jsonl")"
assert_eq t@example.com "$(printf '%s\n' "$line" | jq -r .operator)" "top-level operator injected"
assert_eq nested "$(printf '%s\n' "$line" | jq -r .payload.operator)" "nested operator preserved"

# --- Test: adapter with arguments is rejected ---
it "Adapter command with arguments or shell syntax is rejected"
dir="$(setup_test_project)"; track_tmp "$dir"
cat > "$dir/.prdkit/memory/task-ledger.md" <<'EOF'
# Task Ledger

## Configuration

- backend: command
- command: bash -c 'echo pwned'
EOF
echo '{"event":"test"}' | run_emit "$dir" "test.event" 2>/dev/null && status=$? || status=$?
if [ "$status" -ne 0 ]; then
    _ok "adapter with arguments is rejected (exit $status)"
else
    _no "adapter with arguments should be rejected"
fi

# --- Test: adapter outside the repository is rejected ---
it "Adapter command outside the repository is rejected"
dir="$(setup_test_project)"; track_tmp "$dir"
outside="$(mktemp -d)"; track_tmp "$outside"
cat > "$outside/evil.sh" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
EOF
chmod +x "$outside/evil.sh"
cat > "$dir/.prdkit/memory/task-ledger.md" <<EOF
# Task Ledger

## Configuration

- backend: command
- command: $outside/evil.sh
EOF
echo '{"event":"test"}' | run_emit "$dir" "test.event" 2>/dev/null && status=$? || status=$?
if [ "$status" -ne 0 ]; then
    _ok "out-of-repo adapter is rejected (exit $status)"
else
    _no "out-of-repo adapter should be rejected"
fi

# --- Test: '..' traversal in the adapter path is rejected ---
it "Adapter command with '..' segments is rejected"
dir="$(setup_test_project)"; track_tmp "$dir"
cat > "$dir/.prdkit/memory/task-ledger.md" <<'EOF'
# Task Ledger

## Configuration

- backend: command
- command: ../outside/evil.sh
EOF
echo '{"event":"test"}' | run_emit "$dir" "test.event" 2>/dev/null && status=$? || status=$?
if [ "$status" -ne 0 ]; then
    _ok "'..' adapter path is rejected (exit $status)"
else
    _no "'..' adapter path should be rejected"
fi

# --- Test: a symlinked adapter is rejected and never runs ---
it "Adapter command that is a symlink is rejected and never runs"
dir="$(setup_test_project)"; track_tmp "$dir"
outside="$(mktemp -d)"; track_tmp "$outside"
printf '#!/usr/bin/env bash\ncat > /dev/null\ntouch "%s/ran"\n' "$outside" > "$outside/evil.sh"
chmod +x "$outside/evil.sh"
ln -s "$outside/evil.sh" "$dir/linked-adapter.sh"
cat > "$dir/.prdkit/memory/task-ledger.md" <<'EOF'
# Task Ledger

## Configuration

- backend: command
- mode: best-effort
- command: linked-adapter.sh
EOF
echo '{"event":"test"}' | run_emit "$dir" "test.event" > "$dir/emit.out" 2>&1 && status=$? || status=$?
assert_eq 1 "$status" "a symlink to an outside executable is refused, even in best-effort mode"
assert_contains "$(cat "$dir/emit.out")" "must not be a symlink" "the refusal names the rule"
if [ ! -e "$outside/ran" ]; then _ok "the link target never runs"; else _no "the link target never runs"; fi
printf '#!/usr/bin/env bash\ncat > /dev/null\n' > "$dir/inside-adapter.sh"
chmod +x "$dir/inside-adapter.sh"
rm "$dir/linked-adapter.sh"; ln -s inside-adapter.sh "$dir/linked-adapter.sh"
echo '{"event":"test"}' | run_emit "$dir" "test.event" 2>/dev/null && status=$? || status=$?
assert_eq 1 "$status" "a symlink to an executable inside the repository is refused too"

# --- Test: non-executable adapter is rejected ---
it "Non-executable adapter file is rejected"
dir="$(setup_test_project)"; track_tmp "$dir"
touch "$dir/not-executable.sh"
cat > "$dir/.prdkit/memory/task-ledger.md" <<'EOF'
# Task Ledger

## Configuration

- backend: command
- command: not-executable.sh
EOF
echo '{"event":"test"}' | run_emit "$dir" "test.event" 2>/dev/null && status=$? || status=$?
if [ "$status" -ne 0 ]; then
    _ok "non-executable adapter is rejected (exit $status)"
else
    _no "non-executable adapter should be rejected"
fi

# --- Test: repo-relative adapter path works ---
it "Repo-relative adapter path resolves and receives the event"
dir="$(setup_test_project)"; track_tmp "$dir"
mkdir -p "$dir/scripts"
output_file="$dir/relative-output.json"
cat > "$dir/scripts/rel-adapter.sh" <<EOF
#!/usr/bin/env bash
cat > "$output_file"
EOF
chmod +x "$dir/scripts/rel-adapter.sh"
cat > "$dir/.prdkit/memory/task-ledger.md" <<'EOF'
# Task Ledger

## Configuration

- backend: command
- command: scripts/rel-adapter.sh
EOF
echo '{"event":"test"}' | run_emit "$dir" "test.event" && status=$? || status=$?
assert_eq "0" "$status" "repo-relative adapter path exits 0"
assert_file "$output_file" "repo-relative adapter received the event"

# --- Test: backend: command without command configured ---
it "backend: command without command configured is an error"
dir="$(setup_test_project)"; track_tmp "$dir"
cat > "$dir/.prdkit/memory/task-ledger.md" <<'EOF'
# Task Ledger
- backend: command
EOF
echo '{"event":"test"}' | run_emit "$dir" "test.event" 2>/dev/null && status=$? || status=$?
if [ "$status" -ne 0 ]; then
    _ok "missing command with backend: command is an error (exit $status)"
else
    _no "missing command with backend: command should be an error"
fi

finish
