#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
it "human overview mentions the public controls"
for file in "$PK_ROOT"/commands/*.md; do
    name="$(basename "$file" .md)"
    assert_contains "$(cat "$PK_ROOT/docs/workflow.md")" "/$name" "overview names $name"
done
it "human and agent guides link to their shared source"
assert_contains "$(cat "$PK_ROOT/docs/agent-workflow.md")" '../workflows/protocol.md' "agent guide links protocol"
assert_file "$PK_ROOT/docs/human-workflow.md" "human guide exists"
finish
