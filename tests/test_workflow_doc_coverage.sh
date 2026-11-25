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
it "role digest is discoverable from the script catalog and review workflow"
assert_contains "$(cat "$PK_ROOT/docs/commands.md")" 'review-packages.md#role-digests'
assert_contains "$(cat "$PK_ROOT/workflows/review.md")" '.prdkit/scripts/bash/role-digest.sh'
it "the documented required workflow uses only PR activities that both the ruleset and launcher support"
events="$(awk '/^host-registered immutable required workflow W$/ { block=1; next }
    block && /^  every applicable PR/ { exit }
    block { gsub(/[:,]/,""); for (i=2; i<=NF; i++) print $1, $i }' "$PK_ROOT/docs/ci-gates.md" | LC_ALL=C sort)"
assert_eq "$(printf '%s\n' 'pull_request opened' 'pull_request reopened' 'pull_request synchronize')" "$events" 'native dispatch cannot refresh this workflow on review submission or dismissal'
finish
