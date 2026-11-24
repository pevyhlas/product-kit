#!/usr/bin/env bash
# Faults at real command boundaries, not installer-only test hooks. Each retry uses real tools.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/install-lib.sh"
REAL_CP="$(command -v cp)"; REAL_MV="$(command -v mv)"; REAL_MKTEMP="$(command -v mktemp)"; REAL_RM="$(command -v rm)"
export REAL_CP REAL_MV REAL_MKTEMP REAL_RM
SHIMS="$(mktemp -d)"; track_tmp "$SHIMS"
cat > "$SHIMS/fault" <<'EOF'
#!/usr/bin/env bash
tool="${0##*/}"; last="${!#}"
source_path="${1:-}"; [ "$source_path" != -p ] || source_path="${2:-}"
case "$tool:$FAULT" in
    cp:copy|cp:interrupt|cp:kill)
        if [ "$source_path" = "$FAULT_ROOT/.product-kit/templates/change-template.md" ] &&
            [[ "$last" == "$FAULT_ROOT"/.prdkit/templates/change-template.md.prdkit-install.*/payload ]]; then
            printf 'partial bytes\n' > "$last"
            if [ "$FAULT" = interrupt ]; then kill -TERM "$INSTALL_PID"; fi
            if [ "$FAULT" = kill ]; then kill -KILL "$INSTALL_PID"; fi
            exit 73
        fi ;;
    cp:hold)
        if [ "$source_path" = "$FAULT_ROOT/.product-kit/commands/prdkit.md" ] &&
            [[ "$last" == "$FAULT_ROOT"/.claude/commands/prdkit.md.prdkit-install.*/payload ]]; then
            : > "$FAULT_ROOT/.git/ready"
            for ((i=0;i<300;i++)); do
                [ ! -f "$FAULT_ROOT/.git/release" ] || exec "$REAL_CP" "$@"
                sleep 0.1
            done
            exit 78
        fi ;;
    mv:agents) if [ "$last" = "$FAULT_ROOT/AGENTS.md" ]; then exit 75; fi ;;
    mv:manifest) if [ "$last" = "$FAULT_ROOT/.prdkit/.manifest" ]; then exit 76; fi ;;
    mv:published) if [ "$last" = "$FAULT_ROOT/.prdkit/.manifest" ]; then "$REAL_MV" "$@" || exit; exit 76; fi ;;
    rm:retired) if [ "$last" = "$FAULT_ROOT/.claude/commands/prdkit-retired.md" ]; then "$REAL_RM" "$@" || exit; exit 79; fi ;;
    mktemp:storage) case "$last" in *prdkit-install*) exit 77 ;; esac ;;
esac
case "$tool" in
    cp) exec "$REAL_CP" "$@" ;; mv) exec "$REAL_MV" "$@" ;;
    mktemp) exec "$REAL_MKTEMP" "$@" ;;
    rm) exec "$REAL_RM" "$@" ;;
esac
EOF
chmod +x "$SHIMS/fault"
for tool in cp mv mktemp rm; do ln -s fault "$SHIMS/$tool"; done

it 'a partial mapping cannot become a successful partial install'
PROJ="$(make_project)"; track_tmp "$PROJ"
cat >> "$PROJ/.product-kit/scripts/install-lib.sh" <<'EOF'
install_file_targets() {
    printf '%s.claude/commands/prdkit.md\n' "${4:-}"
    return 1
}
EOF
run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --copy
assert_eq 1 "$STATUS" 'enumeration failure reaches the installer'
assert_contains "$OUTPUT" 'Cannot enumerate kit files' 'failure names the incomplete plan'
if [ ! -e "$PROJ/.prdkit" ] && [ ! -e "$PROJ/.claude" ]; then _ok 'no partial install'; else _no 'partial install created'; fi

for fault in copy interrupt kill agents manifest storage; do
    it "$fault failure remains explicit and the same-source retry preserves consumer bytes"
    PROJ="$(make_project)"; track_tmp "$PROJ"
    # The installer canonicalizes /var to /private/var on macOS; fault operands
    # must identify the same physical paths, not silently miss every boundary.
    PROJ="$(CDPATH='' cd "$PROJ" && pwd -P)"
    printf 'User prefix.\n' > "$PROJ/AGENTS.md"
    bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --harness all >/dev/null
    printf '\nUser suffix.\n' >> "$PROJ/AGENTS.md"
    chmod 640 "$PROJ/AGENTS.md" "$PROJ/.prdkit/templates/change-template.md"
    printf '\nCustom policy.\n' >> "$PROJ/.prdkit/memory/constitution.md"
    printf '\nCustom template.\n' >> "$PROJ/.prdkit/templates/product-template.md"
    old_manifest="$(install_hash_stream < "$PROJ/.prdkit/.manifest")"
    old_template="$(install_hash_stream < "$PROJ/.prdkit/templates/change-template.md")"
    old_agents="$(install_hash_stream < "$PROJ/AGENTS.md")"
    custom_policy="$(install_hash_stream < "$PROJ/.prdkit/memory/constitution.md")"
    custom_template="$(install_hash_stream < "$PROJ/.prdkit/templates/product-template.md")"
    OUTSIDE="$(mktemp -d)"; track_tmp "$OUTSIDE"
    printf 'outside sentinel\n' > "$OUTSIDE/sentinel"
    ln -s "$OUTSIDE/sentinel" "$PROJ/.prdkit/templates/linked-policy.md"
    # Early changed command guarantees an interrupted install can actually be mixed-version.
    printf '\nNew command bytes.\n' >> "$PROJ/.product-kit/commands/prdkit.md"
    printf '\nNew pristine template.\n' >> "$PROJ/.product-kit/templates/change-template.md"
    # Change only the generated section, retaining the same delimiters.
    sed 's/## Product-Kit workflow/## Product-Kit workflow updated/' "$PROJ/.product-kit/scripts/agents-section.md" > "$PROJ/new-section"
    mv "$PROJ/new-section" "$PROJ/.product-kit/scripts/agents-section.md"
    snapshot_upgrade_fixture "$PROJ" || exit 1
    # shellcheck disable=SC2016 # The child expands its own PID, not the test runner's.
    run env PATH="$SHIMS:$PATH" FAULT="$fault" FAULT_ROOT="$PROJ" bash -c 'export INSTALL_PID=$$; exec bash "$1/.product-kit/scripts/init.sh" --target "$1" --upgrade' _ "$PROJ"
    if [ "$STATUS" -ne 0 ]; then _ok 'failed operation exits nonzero'; else _no "masked $fault failure"; fi
    if [ "$fault" != kill ]; then assert_contains "$OUTPUT" 'Incomplete install' 'partial state is explicit, not an upgrade-complete claim'; fi
    assert_not_contains "$OUTPUT" 'Upgrade complete' 'no success message after failure'
    assert_eq "$old_manifest" "$(install_hash_stream < "$PROJ/.prdkit/.manifest")" 'prior manifest remains the recovery baseline'
    case "$fault" in
        copy|interrupt|kill|storage) assert_eq "$old_template" "$(install_hash_stream < "$PROJ/.prdkit/templates/change-template.md")" 'failed conffile replacement cannot become a fake user edit' ;;
        agents) assert_eq "$old_agents" "$(install_hash_stream < "$PROJ/AGENTS.md")" 'failed managed-block replacement preserves the entire old document' ;;
    esac
    assert_file "$PROJ/.prdkit/.install-state" 'persistent incomplete marker survives failure'
    run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --check
    assert_eq 1 "$STATUS" 'check reports incomplete installation'
    assert_contains "$OUTPUT" 'Incomplete install' 'check exposes interrupted state'
    if [ "$fault" = kill ]; then
        run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade
        assert_eq 1 "$STATUS" 'untrappable kill leaves a lock requiring explicit recovery'
        assert_contains "$OUTPUT" 'write lock exists' 'no PID-based guess silently removes a stale lock'
        # The injected child exits immediately and run captured all inherited output pipes;
        # no fixture writer survives here. Stand in for the documented owner recovery.
        rm -f "$PROJ/.prdkit/.install-lock"
    fi
    run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade
    assert_eq 0 "$STATUS" "same-source retry succeeds: $OUTPUT"
    assert_eq "$(install_hash_stream < "$PROJ/.product-kit/templates/change-template.md")" "$(install_hash_stream < "$PROJ/.prdkit/templates/change-template.md")" 'retry reaches the new pristine template'
    assert_eq "$PROJ/.prdkit/templates/change-template.md" "$(find "$PROJ/.prdkit/templates/change-template.md" -prune -type f -perm 0640 -print)" 'template refresh preserves consumer permissions'
    assert_eq "$PROJ/AGENTS.md" "$(find "$PROJ/AGENTS.md" -prune -type f -perm 0640 -print)" 'managed-section refresh preserves consumer permissions'
    assert_eq "$custom_policy" "$(install_hash_stream < "$PROJ/.prdkit/memory/constitution.md")" 'custom policy bytes survive'
    assert_eq "$custom_template" "$(install_hash_stream < "$PROJ/.prdkit/templates/product-template.md")" 'custom template bytes survive'
    assert_eq 'outside sentinel' "$(cat "$OUTSIDE/sentinel")" 'outside sentinel unchanged'
    assert_symlink "$PROJ/.prdkit/templates/linked-policy.md" 'project-owned link survives'
    assert_contains "$(cat "$PROJ/AGENTS.md")" 'User prefix.' 'managed rewrite preserves prefix'
    assert_contains "$(cat "$PROJ/AGENTS.md")" 'User suffix.' 'managed rewrite preserves suffix'
    if [ ! -e "$PROJ/.prdkit/.install-state" ]; then _ok 'completed retry clears marker'; else _no 'marker not cleared'; fi
    run bash "$PROJ/.prdkit/scripts/bash/check-adoption.sh" --json
    assert_eq 0 "$STATUS" "retry restores manifest integrity: $OUTPUT"
    stable="$(install_hash_stream < "$PROJ/.prdkit/.manifest")"
    snapshot_upgrade_fixture "$PROJ" || exit 1
    run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade
    assert_eq 0 "$STATUS" 'second retry is idempotent'
    assert_eq "$stable" "$(install_hash_stream < "$PROJ/.prdkit/.manifest")" 'second retry keeps manifest bytes'
done

refusal_snapshot() ( # consumer bytes, path types, modes, and staged state (including ignored markers)
    set -o pipefail
    cd "$1" || return 1
    {
        git ls-files --stage || return 1
        tar --format ustar --exclude=./.git --exclude=./.product-kit -cf - .
    } | git hash-object --stdin
)

refuses_unchanged() { # label diagnostic
    local before after
    before="$(refusal_snapshot "$PROJ")" || exit 1
    run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade
    assert_eq 1 "$STATUS" "$1 refuses"
    assert_contains "$OUTPUT" "$2" "$1 diagnosis"
    after="$(refusal_snapshot "$PROJ")" || exit 1
    assert_eq "$before" "$after" "$1 leaves target, index and marker unchanged"
}

it 'plain upgrade refuses dirty checkouts and invalid retry states without changing them'
BASE="$(make_inited_project)"; track_tmp "$BASE"
printf '\nNew command bytes.\n' >> "$BASE/.product-kit/commands/prdkit.md"
# Exercise marker validation even if the runtime marker is visible to Git.
grep -vxF '.prdkit/.install-state' "$BASE/.gitignore" > "$BASE/.git/ignore"
mv "$BASE/.git/ignore" "$BASE/.gitignore"
snapshot_upgrade_fixture "$BASE" || exit 1
version="$(cat "$BASE/.product-kit/VERSION")"
for kind in staged unstaged untracked wrong-source unrelated edited retry-staged outside \
    bytes type mode missing duplicate extra wrong-path executable; do
    PROJ="$(mktemp -d)" || exit 1; track_tmp "$PROJ"
    cp -pR "$BASE/." "$PROJ/" || exit 1
    marker="$PROJ/.prdkit/.install-state"
    conffile="$PROJ/.prdkit/templates/change-template.md"
    command_path=.claude/commands/prdkit.md
    diagnosis='checkout must be clean'
    case "$kind" in
        staged|unstaged|untracked) ;;
        *)
            cp "$PROJ/.product-kit/commands/prdkit.md" "$PROJ/$command_path"
            printf 'phase: file\npath: %s\nsource-version: %s\n' "$command_path" "$version" > "$marker"
            diagnosis='not a valid installer marker' ;;
    esac
    case "$kind" in
        staged|unstaged)
            printf '\nUser edit.\n' >> "$PROJ/AGENTS.md"
            if [ "$kind" = staged ]; then git -C "$PROJ" add AGENTS.md || exit 1; fi ;;
        untracked) printf 'User work.\n' > "$PROJ/unrelated" ;;
        wrong-source)
            printf 'phase: file\npath: %s\nsource-version: 0.0.0\n' "$command_path" > "$marker"
            diagnosis='checkout must be clean' ;;
        unrelated)
            printf 'User work.\n' > "$PROJ/unrelated"
            diagnosis='not a validated installer-owned intermediate state: unrelated' ;;
        edited)
            printf '\nUser edit.\n' >> "$PROJ/.claude/commands/prdkit-inbox.md"
            diagnosis='not a validated intermediate state (bytes, type or mode): .claude/commands/prdkit-inbox.md' ;;
        retry-staged)
            git -C "$PROJ" add "$command_path" || exit 1
            diagnosis='checkout must be clean' ;;
        outside)
            printf '\nUser edit.\n' >> "$PROJ/AGENTS.md"
            diagnosis='AGENTS.md changed outside the managed section' ;;
        bytes|type|mode)
            case "$kind" in
                bytes) printf '\nUser edit.\n' >> "$conffile" ;;
                type) rm "$conffile" && ln -s product-template.md "$conffile" || exit 1 ;;
                mode) chmod +x "$conffile" || exit 1 ;;
            esac
            diagnosis='not a validated intermediate state (bytes, type or mode): .prdkit/templates/change-template.md' ;;
        missing) printf 'source-version: %s\n' "$version" > "$marker" ;;
        duplicate) printf 'phase: file\n' >> "$marker" ;;
        extra) printf 'unrelated: data\n' >> "$marker" ;;
        wrong-path) printf 'phase: file\npath: unrelated\nsource-version: %s\n' "$version" > "$marker" ;;
        executable) chmod +x "$marker" || exit 1 ;;
    esac
    refuses_unchanged "$kind" "$diagnosis"
done

it "deselecting an option can resume after manifest publication"
PROJ="$(make_inited_project --with agent-tiers)"; track_tmp "$PROJ"
PROJ="$(CDPATH='' cd "$PROJ" && pwd -P)"
snapshot_upgrade_fixture "$PROJ" || exit 1
run env PATH="$SHIMS:$PATH" FAULT=published FAULT_ROOT="$PROJ" bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade --without agent-tiers
assert_eq 76 "$STATUS" "$OUTPUT"
assert_contains "$(cat "$PROJ/.prdkit/.manifest")" 'options: none'
assert_file "$PROJ/.prdkit/.install-state"
run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade --without agent-tiers
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq absent "$([ -e "$PROJ/.prdkit/.install-state" ] && echo present || echo absent)"

for fault in retired published; do
    it "retirement resumes after $fault failure, without accepting a deleted customization"
    PROJ="$(make_project)"; track_tmp "$PROJ"
    PROJ="$(CDPATH='' cd "$PROJ" && pwd -P)"
    printf 'retiring command\n' > "$PROJ/.product-kit/commands/prdkit-retired.md"
    printf 'retiring script\n' > "$PROJ/.product-kit/scripts/retired.sh"
    bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --symlink >/dev/null || exit 1
    rm "$PROJ/.product-kit/commands/prdkit-retired.md" "$PROJ/.product-kit/scripts/retired.sh"
    printf 'consumer version\n' > "$PROJ/.prdkit/scripts/bash/retired.sh"
    printf 'Run prdkit-retired.md\n' > "$PROJ/guide.md"
    snapshot_upgrade_fixture "$PROJ" || exit 1
    marker=retired
    expected=79
    if [ "$fault" = published ]; then marker=manifest; expected=76; fi
    run env PATH="$SHIMS:$PATH" FAULT="$fault" FAULT_ROOT="$PROJ" bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade --copy
    assert_eq "$expected" "$STATUS" "$OUTPUT"
    assert_contains "$(cat "$PROJ/.prdkit/.install-state")" "phase: $marker"
    if [ -L "$PROJ/.claude/commands/prdkit-retired.md" ]; then _no 'retired link remains'; else _ok 'retired link already removed'; fi
    rm "$PROJ/.prdkit/scripts/bash/retired.sh"
    run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade --copy
    assert_eq 1 "$STATUS" 'retry refuses unrelated deletion'
    assert_contains "$OUTPUT" 'not a validated installer-owned intermediate state: .prdkit/scripts/bash/retired.sh'
    git -C "$PROJ" restore -- .prdkit/scripts/bash/retired.sh || exit 1
    run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade --copy
    assert_eq 0 "$STATUS" "$OUTPUT"
    assert_contains "$OUTPUT" 'Kept retired files'
    assert_contains "$OUTPUT" '  .prdkit/scripts/bash/retired.sh'
    assert_contains "$OUTPUT" 'guide.md:1:Run prdkit-retired.md'
    assert_eq 'consumer version' "$(cat "$PROJ/.prdkit/scripts/bash/retired.sh")"
    assert_not_contains "$(cat "$PROJ/.prdkit/.manifest")" '/retired.sh'
    if [ -e "$PROJ/.prdkit/.install-state" ]; then _no 'marker not cleared'; else _ok 'retry clears marker'; fi
done

it "overlapping writers refuse before mutation and the original writer finishes coherently"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(CDPATH='' cd "$PROJ" && pwd -P)"
snapshot_upgrade_fixture "$PROJ" || exit 1
env PATH="$SHIMS:$PATH" FAULT=hold FAULT_ROOT="$PROJ" bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade > "$PROJ/.git/first.log" 2>&1 &
first=$!
for ((i=0;i<300;i++)); do [ ! -f "$PROJ/.git/ready" ] || break; sleep 0.1; done
assert_file "$PROJ/.git/ready" 'first writer reached synchronized copy boundary'
before="$(install_hash_stream < "$PROJ/.prdkit/.manifest")"
run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade
assert_eq 1 "$STATUS" 'overlapping writer is refused'
assert_contains "$OUTPUT" 'write lock exists' 'refusal names active lock'
assert_eq "$before" "$(install_hash_stream < "$PROJ/.prdkit/.manifest")" 'contender cannot publish a manifest'
: > "$PROJ/.git/release"
if wait "$first"; then _ok 'original writer completes'; else _no "original writer failed: $(cat "$PROJ/.git/first.log")"; fi
run bash "$PROJ/.prdkit/scripts/bash/check-adoption.sh" --json
assert_eq 0 "$STATUS" 'serialized install is coherent'

it "fresh staged files honor a restrictive consumer umask"
PROJ="$(make_project)"; track_tmp "$PROJ"
chmod 664 "$PROJ/.product-kit/templates/change-template.md" "$PROJ/.product-kit/templates/constitution-template.md" "$PROJ/.product-kit/commands/prdkit.md"
run bash -c 'umask 077; exec bash "$1/.product-kit/scripts/init.sh" --target "$1" --harness all' _ "$PROJ"
assert_eq 0 "$STATUS" 'fresh restrictive install succeeds'
for path in .prdkit/templates/change-template.md .prdkit/memory/constitution.md .claude/commands/prdkit.md .opencode/commands/prdkit.md; do
    assert_eq "$PROJ/$path" "$(find "$PROJ/$path" -prune -type f -perm 0600 -print)" "$path honors umask 077"
done
finish
