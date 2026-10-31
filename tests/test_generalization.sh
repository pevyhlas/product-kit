#!/usr/bin/env bash
# Public interface and project-agnostic shipped contracts.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
EXPECTED=(prdkit prdkit-init prdkit-product prdkit-target prdkit-status prdkit-inbox prdkit-learn prdkit-configure prdkit-doctor)
it "exactly nine public entry points exist"
for command in "${EXPECTED[@]}"; do assert_file "$PK_ROOT/commands/$command.md" "$command exists"; done
files=("$PK_ROOT"/commands/*.md)
assert_eq 9 "${#files[@]}" "only the public interface is exposed"
it "shipped operations remain generic"
stacks='\.tscn|\b(godot|unity|unreal|gameplay|playtest|player-facing|django|rails|laravel|spring boot|flutter|xcodebuild|gradlew|dotnet build|cargo build|npm run|go test|mvn|kubectl|terraform)\b'
offenders="$(grep -rIilnE "$stacks" "$PK_ROOT/commands" "$PK_ROOT/workflows" "$PK_ROOT/templates" 2>/dev/null || true)"
assert_eq "" "$offenders" "no project-specific stack assumptions"
it "scripts defer to actual project commands"
offenders="$(grep -rIlnE '(^|[^[:alnum:]_])(pytest|ruff|cargo (test|clippy|build)|npm (test|run)|dotnet build)([^[:alnum:]_]|$)' "$PK_ROOT/scripts" 2>/dev/null || true)"
assert_eq "" "$offenders" "no hardcoded toolchain execution"
it "private-era aliases and automatic migrations are absent"
assert_eq "" "$(grep -rlE 'SPECIFY_FEATURE|migrate_legacy' "$PK_ROOT/scripts" || true)" "no compatibility runtime"
it "all shell helpers parse"
for script in "$PK_ROOT"/scripts/*.sh; do
    if bash -n "$script"; then _ok "$(basename "$script") syntax"; else _no "$(basename "$script") syntax"; fi
done
finish
