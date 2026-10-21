#!/usr/bin/env bash
# ledger-spool-adapter.sh: the shipped central-spool adapter — per-project
# durable spool under XDG_DATA_HOME, project derived (override > origin >
# directory), attribution injected without clobbering, ledger-emit wiring.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
ADAPTER="$PK_ROOT/scripts/ledger-spool-adapter.sh"

DATA="$(mktemp -d)"; track_tmp "$DATA"
WORK="$(mktemp -d)"; track_tmp "$WORK"

it "PRDKIT_PROJECT override names the spool directory"
( cd "$WORK" && echo '{"event":"feature.created"}' | XDG_DATA_HOME="$DATA" PRDKIT_PROJECT=proj-x bash "$ADAPTER" )
assert_file "$DATA/prdkit/ledger/proj-x/events.jsonl" "per-project spool file created"
assert_contains "$(cat "$DATA/prdkit/ledger/proj-x/events.jsonl")" '"event":"feature.created", "project": "proj-x"' "event kept and project injected"

it "the project is derived from the git origin, worktree-safe"
git -C "$WORK" init -q
git -C "$WORK" remote add origin git@example.com:owner/derived-repo.git
( cd "$WORK" && echo '{"event":"tasks.generated"}' | XDG_DATA_HOME="$DATA" bash "$ADAPTER" )
assert_file "$DATA/prdkit/ledger/derived-repo/events.jsonl" "origin repo name is the directory"

it "an embedded project field is preserved, not clobbered"
( cd "$WORK" && echo '{"event":"x","project":"already-tagged"}' | XDG_DATA_HOME="$DATA" PRDKIT_PROJECT=proj-x bash "$ADAPTER" )
assert_eq '{"event":"x","project":"already-tagged"}' "$(tail -1 "$DATA/prdkit/ledger/proj-x/events.jsonl")" "existing tag kept byte-identical"

it "nested project fields do not suppress top-level attribution"
( cd "$WORK" && printf '%s\n' '{"event":"x","payload":{"project":"nested"}}' | XDG_DATA_HOME="$DATA" PRDKIT_PROJECT=proj-x bash "$ADAPTER" )
line="$(tail -1 "$DATA/prdkit/ledger/proj-x/events.jsonl")"
assert_eq proj-x "$(printf '%s\n' "$line" | jq -r .project)" "top-level project injected"
assert_eq nested "$(printf '%s\n' "$line" | jq -r .payload.project)" "nested project preserved"

it "dot-only project names cannot escape the central spool root"
( cd "$WORK" && printf '%s\n' '{}' | XDG_DATA_HOME="$DATA" PRDKIT_PROJECT=.. bash "$ADAPTER" )
assert_file "$DATA/prdkit/ledger/unattributed/events.jsonl" "invalid path segment uses explicit fallback"
if [ -e "$DATA/prdkit/events.jsonl" ]; then _no 'spool escaped project directory'; else _ok 'spool remains beneath project directory'; fi

it "a directory-name fallback still yields one safe path segment"
NOGIT="$(mktemp -d)"; track_tmp "$NOGIT"
mkdir -p "$NOGIT/my repo!"
( cd "$NOGIT/my repo!" && echo '{"event":"y"}' | XDG_DATA_HOME="$DATA" env -u PRDKIT_PROJECT bash "$ADAPTER" ) 2>/dev/null
assert_file "$DATA/prdkit/ledger/myrepo/events.jsonl" "unsafe characters stripped from the segment"

it "ledger-emit pipes through the installed adapter into the central spool"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cat > "$PROJ/.prdkit/memory/task-ledger.md" <<'EOF'
# Task Ledger

## Configuration

- backend: command
- command: .prdkit/scripts/bash/ledger-spool-adapter.sh
- events: all
- mode: best-effort
EOF
( cd "$PROJ" && echo '{"event":"feature.merged"}' | XDG_DATA_HOME="$DATA" PRDKIT_PROJECT=wired bash .prdkit/scripts/bash/ledger-emit.sh feature.merged ) >/dev/null 2>&1
assert_file "$PROJ/.prdkit/ledger/events.jsonl" "local spool still written"
assert_file "$DATA/prdkit/ledger/wired/events.jsonl" "central spool written via backend: command"
assert_contains "$(cat "$DATA/prdkit/ledger/wired/events.jsonl")" '"event":"feature.merged"' "event delivered"

finish
