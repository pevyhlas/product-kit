#!/usr/bin/env bash
# Deterministic current-source consumer smoke; no model invocation or credentials.
# stdout: one JSON evidence record; stderr: failed command diagnostics. Fixtures are disposable.
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/install-lib.sh"
revision="$(git -C "$PK_ROOT" rev-parse HEAD)"
dirty=false; [ -z "$(git -C "$PK_ROOT" status --porcelain)" ] || dirty=true
failed=0; rows=''; sep=''
check() {
    local label="$1"; shift
    if ! "$@" > "$PROJ/smoke.out" 2>&1; then
        printf 'Consumer smoke (%s): %s\n' "$harness" "$label" >&2
        cat "$PROJ/smoke.out" >&2; failed=$((failed + 1))
    fi
}
for harness in claude opencode codex agents; do
    PROJ="$(make_project)" || exit 1; track_tmp "$PROJ"
    start_failed="$failed"
    check installation bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --harness "$harness" --copy
    scripts="$PROJ/.prdkit/scripts/bash"
    check adoption bash "$scripts/check-adoption.sh" --json
    check diagnostics bash "$scripts/doctor.sh" --inventory --json
    check status bash "$scripts/status.sh" --json
    printf '\nOwned policy stays byte-identical.\n' >> "$PROJ/.prdkit/memory/constitution.md"
    custom="$(install_hash_stream < "$PROJ/.prdkit/memory/constitution.md")"
    for round in 1 2; do
        check "upgrade $round" bash "$PROJ/.product-kit/scripts/init.sh" --target "$PROJ" --upgrade
        check preservation test "$custom" = "$(install_hash_stream < "$PROJ/.prdkit/memory/constitution.md")"
    done
    mv "$PROJ/.product-kit" "$PROJ/source-removed"
    check source-less-adoption bash "$scripts/check-adoption.sh" --json
    check source-less-inventory bash "$scripts/doctor.sh" --inventory --json
    result=pass; [ "$failed" -eq "$start_failed" ] || result=fail
    hash="$(install_hash_stream < "$PROJ/.prdkit/.manifest")"
    rows="$rows$sep{\"target\":\"$harness\",\"result\":\"$result\",\"manifest_sha256\":\"$hash\",\"native_loading\":\"unknown\",\"agent_execution\":\"unknown\",\"structured_capture\":\"unknown\",\"events\":\"unknown\",\"independent_review_access\":\"unknown\"}"
    sep=,
done
result=pass; [ "$failed" -eq 0 ] || result=fail
printf '{"schema_version":1,"kind":"deterministic-consumer-smoke","kit_revision":"%s","kit_dirty":%s,"kit_version":"%s","platform":"%s","bash_version":"%s","result":"%s","targets":[%s]}\n' \
    "$revision" "$dirty" "$(json_escape "$(cat "$PK_ROOT/VERSION")")" "$(json_escape "$(uname -s)")" "$(json_escape "$BASH_VERSION")" "$result" "$rows"
[ "$failed" -eq 0 ]
