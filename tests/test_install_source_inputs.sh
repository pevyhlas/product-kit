#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TESTS_DIR/install-fixture.sh"
source_fixture
CONFIG="$FIXTURE/.prdkit/memory/config.md"
MANIFEST="$FIXTURE/.prdkit/.manifest"
cp "$MANIFEST" "$_SCRATCH_CWD/manifest"

it 'an explicit small installation is source verified'
fixture_check
assert_eq 0 "$STATUS" "$OUTPUT"
fixture_check --head HEAD
assert_eq 0 "$STATUS" "$OUTPUT"

it 'accepted configuration headings retain each explicit restriction in both lanes'
for heading in '##Configuration' '## Configuration' $'##\tConfiguration' '##Configuration — local' $'##Configuration\r'; do
    for restriction in matching pin hash; do
        {
            printf '# Config\n%s\n' "$heading"
            pin="$KIT_PIN"; hash="$(install_hash_stream < "$MANIFEST")"
            case "$restriction" in pin) pin=0000000000000000000000000000000000000000 ;; hash) hash=bad ;; esac
            printf -- '- adoption-pin: %s\n- adoption-manifest-sha256: %s\n' "$pin" "$hash"
        } > "$CONFIG"
        fixture_commit
        for lane in worktree committed; do
            args=(); [ "$lane" != committed ] || args=(--head HEAD)
            fixture_check ${args[@]+"${args[@]}"}
            if [ "$restriction" = matching ]; then assert_eq 0 "$STATUS" "$heading $lane: $OUTPUT"
            else
                assert_eq 1 "$STATUS" "$heading $restriction $lane"
                assert_contains "$OUTPUT" '"source_verification":"failed"' 'restriction cannot disappear'
            fi
        done
    done
done
printf '# Config\n##Configuration\r\n- adoption-pin: %s\r\n' "$KIT_PIN" > "$CONFIG"
fixture_commit
fixture_check --head HEAD
assert_eq 0 "$STATUS" 'CRLF configuration remains effective'
printf '# Config\n- adoption-pin: decoy\n## Configuration\n## Meaning\n- adoption-pin: decoy\n' > "$CONFIG"
fixture_commit
fixture_check --head HEAD
assert_eq 0 "$STATUS" 'examples outside configuration are not restrictions'
printf '##Configuration\n- adoption-pin: %s\n- adoption-pin: %s\n' "$KIT_PIN" "$KIT_PIN" > "$CONFIG"
fixture_reject
assert_contains "$OUTPUT" 'Ambiguous adoption-pin' 'duplicates fail explicitly'
printf '# Config\n## Configuration\n' > "$CONFIG"

it 'harness selections have one interpretation throughout the installation'
for harnesses in $'claude\tagents' ' claude   agents '; do
    sed "s/^harnesses: .*/harnesses: $harnesses/" "$_SCRATCH_CWD/manifest" > "$MANIFEST"
    fixture_commit
    fixture_check --head HEAD
    assert_eq 0 "$STATUS" "equivalent selection: $OUTPUT"
    mv "$FIXTURE/.claude/commands/prdkit.md" "$_SCRATCH_CWD/command"
    mv "$FIXTURE/AGENTS.md" "$_SCRATCH_CWD/agents"
    sed '/  \.claude\/commands\/prdkit.md$/d' "$MANIFEST" > "$_SCRATCH_CWD/next"
    cp "$_SCRATCH_CWD/next" "$MANIFEST"
    fixture_commit
    fixture_reject
    fixture_reject --head HEAD
    mv "$_SCRATCH_CWD/command" "$FIXTURE/.claude/commands/prdkit.md"
    mv "$_SCRATCH_CWD/agents" "$FIXTURE/AGENTS.md"
done
cp "$_SCRATCH_CWD/manifest" "$MANIFEST"
for harnesses in '   ' 'claude unknown'; do
    sed "s/^harnesses: .*/harnesses: $harnesses/" "$_SCRATCH_CWD/manifest" > "$MANIFEST"
    fixture_commit
    fixture_reject
    fixture_reject --head HEAD
done
cp "$_SCRATCH_CWD/manifest" "$MANIFEST"

it 'installed path membership treats every character literally'
extra="$FIXTURE/.prdkit/workflows/"'wor\153.md'
printf 'extra\n' > "$extra"
fixture_commit
fixture_reject
fixture_reject --head HEAD
rm "$extra"

it 'managed-section extraction preserves its actual EOF terminator'
size="$(wc -c < "$FIXTURE/AGENTS.md" | tr -d '[:space:]')"
head -c "$((size - 1))" "$FIXTURE/AGENTS.md" > "$_SCRATCH_CWD/agents-no-newline"
cp "$_SCRATCH_CWD/agents-no-newline" "$FIXTURE/AGENTS.md"
managed_agents_section "$FIXTURE/AGENTS.md" > "$_SCRATCH_CWD/extracted"
run cmp -s "$FIXTURE/AGENTS.md" "$_SCRATCH_CWD/extracted"
assert_eq 0 "$STATUS" 'raw extraction does not add a terminator'
fixture_commit
fixture_reject
fixture_reject --head HEAD
cp "$KIT/scripts/agents-section.md" "$FIXTURE/AGENTS.md"
printf '\nProject-owned suffix without newline' >> "$FIXTURE/AGENTS.md"
fixture_commit
fixture_check --head HEAD
assert_eq 0 "$STATUS" 'unmanaged suffix terminator does not affect managed bytes'
finish
