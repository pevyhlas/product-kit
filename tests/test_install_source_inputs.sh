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

it 'an explicit empty head does not select worktree proof'
fixture_check --head ''
assert_eq 2 "$STATUS" 'explicit empty revision is a usage error'
assert_not_contains "$OUTPUT" '"source_verification":"verified"'

it 'an unexpected final manifest record is checked with and without a newline'
for ending in lf eof; do
    cp "$_SCRATCH_CWD/manifest" "$MANIFEST"
    printf 'not a manifest record' >> "$MANIFEST"
    [ "$ending" != lf ] || printf '\n' >> "$MANIFEST"
    fixture_commit
    fixture_reject
    fixture_reject --head HEAD
done
cp "$_SCRATCH_CWD/manifest" "$MANIFEST"

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

it 'managed files and adoption policy resolve only through in-repository components'
mkdir "$FIXTURE/policy"
mv "$FIXTURE/AGENTS.md" "$FIXTURE/policy/main.md"
mv "$CONFIG" "$FIXTURE/policy/config.md"
ln -s policy "$FIXTURE/current"
ln -s current/main.md "$FIXTURE/AGENTS.md"
ln -s ../../current/config.md "$CONFIG"
fixture_commit
fixture_check; assert_eq 0 "$STATUS" "$OUTPUT"
fixture_check --head HEAD; assert_eq 0 "$STATUS" "$OUTPUT"
printf '## Configuration\n- adoption-pin: wrong\n' > "$FIXTURE/policy/config.md"
fixture_commit
fixture_reject; assert_contains "$OUTPUT" 'Kit pin drift'
fixture_reject --head HEAD; assert_contains "$OUTPUT" 'Kit pin drift'
rm "$CONFIG"; mv "$FIXTURE/policy/config.md" "$CONFIG"
printf '## Configuration\n' > "$CONFIG"
rm "$FIXTURE/current"; ln -s .. "$FIXTURE/current"
fixture_commit
fixture_reject; fixture_reject --head HEAD
rm "$FIXTURE/current" "$FIXTURE/AGENTS.md"; mv "$FIXTURE/policy/main.md" "$FIXTURE/AGENTS.md"

it 'deselected agents harness accepts private prose but no kit markers or metadata'
for state in block crlf metadata prose; do
    sed 's/^harnesses: .*/harnesses: claude/' "$_SCRATCH_CWD/manifest" > "$MANIFEST"
    if [ "$state" != metadata ]; then
        sed '/^agents-section:/d' "$MANIFEST" > "$_SCRATCH_CWD/next"
        cp "$_SCRATCH_CWD/next" "$MANIFEST"
    fi
    case "$state" in
        block) ;;
        crlf) awk '{printf "%s\r\n", $0}' "$KIT/scripts/agents-section.md" > "$FIXTURE/AGENTS.md" ;;
        *) printf 'Project instructions.\n' > "$FIXTURE/AGENTS.md" ;;
    esac
    fixture_commit
    if [ "$state" = prose ]; then
        fixture_check; assert_eq 0 "$STATUS" "$OUTPUT"
        fixture_check --head HEAD; assert_eq 0 "$STATUS" "$OUTPUT"
    else
        fixture_reject; fixture_reject --head HEAD
    fi
done
cp "$KIT/scripts/agents-section.md" "$FIXTURE/AGENTS.md"
cp "$_SCRATCH_CWD/manifest" "$MANIFEST"

it 'only direct definition files activate agent tiers'
mkdir -p "$FIXTURE/.prdkit/agents/examples.md"
printf 'Nested note\n' > "$FIXTURE/.prdkit/agents/examples.md/notes.md"
fixture_commit
fixture_check; assert_eq 0 "$STATUS" 'nested note is not a definition'
fixture_check --head HEAD; assert_eq 0 "$STATUS" 'committed nested note is not a definition'
printf 'Active definition\n' > "$FIXTURE/.prdkit/agents/reviewer.md"
fixture_commit
fixture_reject; assert_contains "$OUTPUT" 'Agent tiers are in use'
fixture_reject --head HEAD; assert_contains "$OUTPUT" 'Agent tiers are in use'
rm "$FIXTURE/.prdkit/agents/reviewer.md"

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

it 'managed text is validated before a utility can normalize its bytes'
BYTE_CASE="$(mktemp -d)"; track_tmp "$BYTE_CASE"
mkdir "$BYTE_CASE/bin"
BYTE_REAL_AWK="$(command -v awk)"
BYTE_ORIGINAL_PATH="$PATH"
export BYTE_REAL_AWK BYTE_CASE
cat > "$BYTE_CASE/bin/awk" <<'EOF'
#!/usr/bin/env bash
last="${!#}"
case "$last" in
    */agents|*/AGENTS.md)
        printf 'managed awk input\n' >> "$BYTE_CASE/managed-calls"
        if [ "${BYTE_EMULATION:-false}" = true ]; then
            temp="$(mktemp)" || exit 1
            trap 'rm -f "$temp"' EXIT
            # Fixture emulation only: numeric od input never asks awk to read NUL.
            # Discard the first zero byte and remainder of that record, preserving LF.
            LC_ALL=C od -An -v -tu1 "$last" | LC_ALL=C "$BYTE_REAL_AWK" '
                { for(i=1;i<=NF;i++) {
                    if($i==0) skip=1
                    else if($i==10) { printf "\n"; skip=0 }
                    else if(!skip) printf "%c", $i
                } }' > "$temp" || exit 1
            args=("$@"); args[$(($# - 1))]="$temp"
            LC_ALL=C "$BYTE_REAL_AWK" "${args[@]}"
            exit "$?"
        fi ;;
esac
exec "$BYTE_REAL_AWK" "$@"
EOF
chmod +x "$BYTE_CASE/bin/awk"
{
    printf 'Project-owned prefix.\n'
    cat "$KIT/scripts/agents-section.md"
    printf '\nProject-owned suffix without newline'
} > "$BYTE_CASE/clean"
{
    printf 'Project-owned prefix.\n'
    while IFS= read -r line; do
        printf '%s' "$line"
        [ "$line" != '## Product-Kit workflow' ] || printf '\000additional bytes'
        printf '\n'
    done < "$KIT/scripts/agents-section.md"
    printf '\nProject-owned suffix without newline'
} > "$BYTE_CASE/altered"
raw_size="$(wc -c < "$BYTE_CASE/altered" | tr -d '[:space:]')"
kept_size="$(LC_ALL=C tr -d '\000' < "$BYTE_CASE/altered" | wc -c | tr -d '[:space:]')"
assert_eq "$((kept_size + 1))" "$raw_size" 'independent byte count proves the fixture contains NUL'
run cmp -s "$BYTE_CASE/clean" "$BYTE_CASE/altered"
assert_eq 1 "$STATUS" 'altered managed input differs as raw bytes'

for tool in awk mawk nawk gawk; do
    if ! BYTE_REAL_AWK="$(PATH="$BYTE_ORIGINAL_PATH" command -v "$tool")"; then
        printf 'OBSERVATION: %s unavailable; not exercised\n' "$tool"
        continue
    fi
    export BYTE_REAL_AWK
    printf 'before\000after\n' > "$BYTE_CASE/probe"
    LC_ALL=C "$BYTE_REAL_AWK" '{print}' "$BYTE_CASE/probe" > "$BYTE_CASE/probe-result"
    if cmp -s "$BYTE_CASE/probe" "$BYTE_CASE/probe-result"; then
        printf 'OBSERVATION: local %s (%s) retained probe bytes\n' "$tool" "$BYTE_REAL_AWK"
    else
        printf 'OBSERVATION: local %s (%s) changed probe bytes\n' "$tool" "$BYTE_REAL_AWK"
    fi
    export PATH="$BYTE_CASE/bin:$BYTE_ORIGINAL_PATH" BYTE_EMULATION=false
    cp "$BYTE_CASE/clean" "$FIXTURE/AGENTS.md"; fixture_commit
    fixture_check
    assert_eq 0 "$STATUS" "clean text with local $tool: $OUTPUT"
    fixture_check --head HEAD
    assert_eq 0 "$STATUS" "committed clean text with local $tool: $OUTPUT"
    cp "$BYTE_CASE/altered" "$FIXTURE/AGENTS.md"; fixture_commit
    before="$(install_hash_stream < "$FIXTURE/AGENTS.md")"
    for lane in worktree committed; do
        : > "$BYTE_CASE/managed-calls"
        args=(); [ "$lane" != committed ] || args=(--head HEAD)
        fixture_reject ${args[@]+"${args[@]}"}
        assert_eq '' "$(cat "$BYTE_CASE/managed-calls")" 'byte refusal precedes managed awk input'
    done
    assert_eq "$before" "$(install_hash_stream < "$FIXTURE/AGENTS.md")" 'refusal leaves all input bytes unchanged'
    export PATH="$BYTE_ORIGINAL_PATH"
done

it 'a deliberately truncating utility model cannot establish source proof'
BYTE_REAL_AWK="$(command -v awk)"; export BYTE_REAL_AWK
export PATH="$BYTE_CASE/bin:$BYTE_ORIGINAL_PATH" BYTE_EMULATION=true
cp "$BYTE_CASE/altered" "$FIXTURE/AGENTS.md"
# Independent positive control: this model really hides the altered body bytes.
cat "$BYTE_CASE/clean" > "$BYTE_CASE/normalized-expected"; printf '\n' >> "$BYTE_CASE/normalized-expected"
awk '{print}' "$FIXTURE/AGENTS.md" > "$BYTE_CASE/normalized"
run cmp -s "$BYTE_CASE/normalized-expected" "$BYTE_CASE/normalized"
assert_eq 0 "$STATUS" 'fixture emulation actually truncates the altered record'
fixture_commit
for lane in worktree committed; do
    : > "$BYTE_CASE/managed-calls"
    args=(); [ "$lane" != committed ] || args=(--head HEAD)
    fixture_reject ${args[@]+"${args[@]}"}
    assert_eq '' "$(cat "$BYTE_CASE/managed-calls")" 'independent byte guard runs before the lossy model'
done
export PATH="$BYTE_ORIGINAL_PATH"
unset BYTE_EMULATION
finish
