#!/usr/bin/env bash
# Faults at real command boundaries, not installer-only test hooks. Each retry uses real tools.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/install-lib.sh"
REAL_CP="$(command -v cp)"; REAL_MV="$(command -v mv)"; REAL_RM="$(command -v rm)"; REAL_MKTEMP="$(command -v mktemp)"
export REAL_CP REAL_MV REAL_RM REAL_MKTEMP
SHIMS="$(mktemp -d)"; track_tmp "$SHIMS"
cat > "$SHIMS/fault" <<'EOF'
#!/usr/bin/env bash
tool="${0##*/}"; last="${!#}"
source_path="${1:-}"; [ "$source_path" != -p ] || source_path="${2:-}"
case "$tool:$FAULT" in
    cp:copy|cp:interrupt|cp:kill)
        if [ "$source_path" = "$FAULT_ROOT/.product-kit/templates/change-template.md" ]; then
            printf 'partial bytes\n' > "$last"
            if [ "$FAULT" = interrupt ]; then kill -TERM "$INSTALL_PID"; fi
            if [ "$FAULT" = kill ]; then kill -KILL "$INSTALL_PID"; fi
            exit 73
        fi ;;
    cp:hold)
        if [ "$source_path" = "$FAULT_ROOT/.product-kit/commands/prdkit.md" ]; then
            : > "$FAULT_ROOT/ready"
            for ((i=0;i<300;i++)); do
                [ ! -f "$FAULT_ROOT/release" ] || exec "$REAL_CP" "$@"
                sleep 0.1
            done
            exit 78
        fi ;;
    rm:retire) if [ "$last" = "$FAULT_ROOT/.prdkit/scripts/bash/retired-probe.sh" ]; then exit 74; fi ;;
    mv:agents) if [ "$last" = "$FAULT_ROOT/AGENTS.md" ]; then exit 75; fi ;;
    mv:manifest) if [ "$last" = "$FAULT_ROOT/.prdkit/.manifest" ]; then exit 76; fi ;;
    mktemp:storage) case "$last" in *prdkit-install*) exit 77 ;; esac ;;
esac
case "$tool" in
    cp) exec "$REAL_CP" "$@" ;; mv) exec "$REAL_MV" "$@" ;;
    rm) exec "$REAL_RM" "$@" ;; mktemp) exec "$REAL_MKTEMP" "$@" ;;
esac
EOF
chmod +x "$SHIMS/fault"
for tool in cp mv rm mktemp; do ln -s fault "$SHIMS/$tool"; done

for fault in copy interrupt kill retire agents manifest storage; do
    it "$fault failure remains explicit and the same-source retry preserves consumer bytes"
    PROJ="$(make_project)"; track_tmp "$PROJ"
    # The installer canonicalizes /var to /private/var on macOS; fault operands
    # must identify the same physical paths, not silently miss every boundary.
    PROJ="$(CDPATH='' cd "$PROJ" && pwd -P)"
    printf '#!/bin/sh\nexit 0\n' > "$PROJ/.product-kit/scripts/retired-probe.sh"
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
    rm "$PROJ/.product-kit/scripts/retired-probe.sh"
    # Change only the generated section, retaining the same delimiters.
    printf '\n' >> "$PROJ/.product-kit/scripts/install-lib.sh"
    sed 's/## Product-Kit workflow/## Product-Kit workflow updated/' "$PROJ/.product-kit/scripts/install-lib.sh" > "$PROJ/new-lib"
    mv "$PROJ/new-lib" "$PROJ/.product-kit/scripts/install-lib.sh"
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
    run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade
    assert_eq 0 "$STATUS" 'second retry is idempotent'
    assert_eq "$stable" "$(install_hash_stream < "$PROJ/.prdkit/.manifest")" 'second retry keeps manifest bytes'
done

it "overlapping writers refuse before mutation and the original writer finishes coherently"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(CDPATH='' cd "$PROJ" && pwd -P)"
env PATH="$SHIMS:$PATH" FAULT=hold FAULT_ROOT="$PROJ" bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade > "$PROJ/first.log" 2>&1 &
first=$!
for ((i=0;i<300;i++)); do [ ! -f "$PROJ/ready" ] || break; sleep 0.1; done
assert_file "$PROJ/ready" 'first writer reached synchronized copy boundary'
before="$(install_hash_stream < "$PROJ/.prdkit/.manifest")"
run bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade
assert_eq 1 "$STATUS" 'overlapping writer is refused'
assert_contains "$OUTPUT" 'write lock exists' 'refusal names active lock'
assert_eq "$before" "$(install_hash_stream < "$PROJ/.prdkit/.manifest")" 'contender cannot publish a manifest'
: > "$PROJ/release"
if wait "$first"; then _ok 'original writer completes'; else _no "original writer failed: $(cat "$PROJ/first.log")"; fi
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
