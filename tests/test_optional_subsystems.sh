#!/usr/bin/env bash
# Optional subsystems install only on request: agent tiers (render-agents.sh and the neutral
# agent-definition template) need --with agent-tiers, the manifest records the choice, a project
# that uses agent tiers keeps them, and --without removes them unless the project uses them.
# shellcheck disable=SC2034 # TIERS_DIAG_* observations are read by the sourced test-local helper.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# Contain the shell's source error too, not just utilities inside the helper.
TIERS_DIAG_LOAD_STATUS=0
if { source "$TESTS_DIR/optional-diagnostics.sh"; } >/dev/null 2>&1; then :; else
    TIERS_DIAG_LOAD_STATUS=$?
    { printf '%s\n' 'optional-diag status=unavailable stage=load'; } 2>/dev/null
    { _no "diagnostic helper available"; } 2>/dev/null
fi

tiers_diag_record_failure() {
    [ "${TIERS_DIAG_CAPTURE:-false}" = true ] || return 0
    # Braces keep the observations in this shell while containing undefined/noisy callbacks.
    if { tiers_diag_original_failure "$@"; } >/dev/null 2>&1; then return 0; fi
    TIERS_DIAG_CALLBACK_FAILED=true
    TIERS_DIAG_ORIGINAL_ITEM=unavailable; TIERS_DIAG_ORIGINAL_CHECK=unavailable; TIERS_DIAG_ORIGINAL_STATUS=unavailable
}

tiers_diag_report() {
    if [ "$TIERS_DIAG_LOAD_STATUS" -ne 0 ]; then
        { printf '%s\n' 'optional-diag status=unavailable stage=load'; } 2>/dev/null
    elif [ "${TIERS_DIAG_CALLBACK_FAILED:-false}" = true ]; then
        { printf '%s\n' 'optional-diag status=unavailable stage=callback'; } 2>/dev/null
    elif { tiers_diag_emit "$1"; } 2>/dev/null; then return 0
    else
        { printf '%s\n' 'optional-diag status=unavailable stage=report'; } 2>/dev/null
    fi
    return 1 # Best effort only: delivery failure cannot clear the already-recorded assertion.
}

tiers_assert_first_install() { # actual first-result caller, also exercised by synthetic controls
    TIERS_DIAG_FIRST_STATUS="$STATUS"
    TIERS_DIAG_FIRST_OUTPUT="$OUTPUT"
    assert_eq 0 "$STATUS" "upgrade with the option succeeds"
    TIERS_DIAG_CAPTURE=true
    TIERS_DIAG_CALLBACK_FAILED=false
    TIERS_DIAG_ORIGINAL_ITEM=unavailable; TIERS_DIAG_ORIGINAL_CHECK=unavailable; TIERS_DIAG_ORIGINAL_STATUS=unavailable
    if tiers_installed "$1"; then _ok "agent-tier files installed and recorded"; else
        _no "agent-tier files installed and recorded"
        tiers_diag_report "$1" || :
    fi
    TIERS_DIAG_CAPTURE=false
    # Guard the ASSIGNMENT boundary as well as helper utilities: Bash can warn there.
    # The helper never returns raw manifest bytes; only the fixed substring projection.
    if { TIERS_DIAG_CHOICE="$(_tiers_diag_choice "$1/.prdkit/.manifest")"; } 2>/dev/null; then :; else
        TIERS_DIAG_CHOICE=unavailable
        { printf '%s\n' 'optional-diag status=unavailable stage=choice'; } 2>/dev/null
    fi
    case "$TIERS_DIAG_CHOICE" in "options: agent-tiers") ;; *) TIERS_DIAG_CHOICE=unavailable ;; esac
    assert_contains "$TIERS_DIAG_CHOICE" "options: agent-tiers" "choice recorded" 2>/dev/null
}

hash_of() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1; }
TIER_FILES=".prdkit/scripts/bash/render-agents.sh .prdkit/templates/agent-definition-template.md"
tiers_installed() { # project -> 0 when both agent-tier files are on disk and in the manifest
    local rel failed
    for rel in $TIER_FILES; do
        # shellcheck disable=SC2319 # The failed file-test condition status is the intended original observation.
        [ -f "$1/$rel" ] || { failed=$?; tiers_diag_record_failure "$rel" file "$failed"; return 1; }
        grep -qF "  $rel" "$1/.prdkit/.manifest" >/dev/null 2>&1 ||
            { failed=$?; tiers_diag_record_failure "$rel" manifest "$failed"; return 1; }
    done
}
tiers_absent() {
    local rel
    for rel in $TIER_FILES; do
        [ ! -e "$1/$rel" ] || return 1
        ! grep -qF "  $rel" "$1/.prdkit/.manifest" || return 1
    done
}
# Rewrite a current manifest as a pre-2.0 one: no options line, agent-tier files recorded.
make_legacy() {
    local proj="$1" rel
    ( cd "$proj" && bash .product-kit/scripts/init.sh --with agent-tiers ) >/dev/null 2>&1
    grep -v '^options: ' "$proj/.prdkit/.manifest" | sed 's/^version: .*/version: 1.5.0/' > "$proj/.prdkit/.manifest.new" &&
        mv "$proj/.prdkit/.manifest.new" "$proj/.prdkit/.manifest"
    for rel in $TIER_FILES; do grep -qF "  $rel" "$proj/.prdkit/.manifest" || return 1; done
}

it "a fresh install leaves agent tiers out and records no options"
PROJ="$(make_project)"; track_tmp "$PROJ"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh"
assert_eq 0 "$STATUS" "install succeeds"
if tiers_absent "$PROJ"; then _ok "agent-tier files not installed"; else _no "agent-tier files not installed"; fi
assert_file "$PROJ/.prdkit/scripts/bash/agent-tiers-lib.sh" "the tier-map library stays core"
assert_contains "$(cat "$PROJ/.prdkit/.manifest")" "options: none" "manifest records no options"
run bash -c "cd '$PROJ' && bash .prdkit/scripts/bash/doctor.sh --json"
assert_not_contains "$OUTPUT" "Missing installed file" "doctor is clean without agent tiers"
assert_not_contains "$OUTPUT" "Agent tiers are in use" "no tier finding for a project without definitions"
run bash -c "cd '$PROJ' && bash .prdkit/scripts/bash/check-adoption.sh"
assert_eq 0 "$STATUS" "adoption gate passes without agent tiers: $OUTPUT"

it "--with agent-tiers installs them; later upgrades keep the recorded choice"
snapshot_upgrade_fixture "$PROJ" || exit 1
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade --with agent-tiers"
tiers_assert_first_install "$PROJ"
snapshot_upgrade_fixture "$PROJ" || exit 1
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 0 "$STATUS" "plain upgrade succeeds"
if tiers_installed "$PROJ"; then _ok "a plain upgrade keeps them"; else _no "a plain upgrade keeps them"; fi
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --check"
assert_eq 0 "$STATUS" "no drift with the option recorded: $OUTPUT"

it "--without agent-tiers removes them, and is refused while the project uses them"
mkdir -p "$PROJ/.prdkit/agents"
printf -- '---\nname: reviewer\ntier: deep\n---\nReview.\n' > "$PROJ/.prdkit/agents/reviewer.md"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade --without agent-tiers"
assert_eq 2 "$STATUS" "refused while definitions exist"
assert_contains "$OUTPUT" "--without agent-tiers would remove files this project uses" "refusal explains"
if tiers_installed "$PROJ"; then _ok "nothing removed by the refusal"; else _no "nothing removed by the refusal"; fi
rm -rf "$PROJ/.prdkit/agents"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade --without agent-tiers"
assert_eq 0 "$STATUS" "dropping an unused subsystem succeeds"
assert_contains "$OUTPUT" "Removed 2 retired kit file(s) no longer shipped or installed" "removal reported"
if tiers_absent "$PROJ"; then _ok "agent-tier files removed"; else _no "agent-tier files removed"; fi
assert_contains "$(cat "$PROJ/.prdkit/.manifest")" "options: none" "choice cleared"

it "unknown or contradictory options are refused before anything changes"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade --with ledger"
assert_eq 2 "$STATUS" "unknown subsystem refused"
assert_contains "$OUTPUT" "unknown optional subsystem 'ledger'" "names the unknown subsystem"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade --with agent-tiers --without agent-tiers"
assert_eq 2 "$STATUS" "contradiction refused"
if tiers_absent "$PROJ"; then _ok "refusals change nothing"; else _no "refusals change nothing"; fi

it "a pre-2.0 install that never used agent tiers loses them on upgrade, with a note"
PROJ="$(make_project)"; track_tmp "$PROJ"
make_legacy "$PROJ" || _no "legacy manifest prepared"
mkdir -p "$PROJ/.github/workflows" "$PROJ/scripts"
printf 'jobs:\n  agents:\n    steps:\n      - run: bash .prdkit/scripts/bash/render-agents.sh --check\n' > "$PROJ/.github/workflows/agents.yml"
# A tracked script that builds the renderer's path from its name.
printf 'helper(root, "render-agents.sh")\n' > "$PROJ/scripts/tool.py"
snapshot_upgrade_fixture "$PROJ" || exit 1
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --check"
assert_contains "$OUTPUT" ".prdkit/scripts/bash/render-agents.sh" "check lists the renderer for removal"
assert_contains "$OUTPUT" ".github/workflows/agents.yml: render-agents.sh" "check flags the CI call before the upgrade"
assert_contains "$OUTPUT" "scripts/tool.py: render-agents.sh" "check flags a script that builds the renderer's path"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 0 "$STATUS" "upgrade succeeds"
if tiers_absent "$PROJ"; then _ok "unused agent-tier files removed"; else _no "unused agent-tier files removed"; fi
assert_contains "$OUTPUT" "install them" "upgrade says how to get them back"
assert_contains "$OUTPUT" "again with --with agent-tiers" "names the option"
assert_contains "$OUTPUT" ".github/workflows/agents.yml: render-agents.sh" "upgrade flags the CI call"
assert_contains "$OUTPUT" "scripts/tool.py: render-agents.sh" "upgrade flags the constructed path"
assert_contains "$OUTPUT" "install with --with agent-tiers" "CI warning names the option"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --check"
assert_contains "$OUTPUT" "scripts/tool.py: render-agents.sh" "check keeps flagging it after the upgrade"
assert_contains "$(cat "$PROJ/.prdkit/.manifest")" "options: none" "choice recorded"

it "an edited agent-definition template is kept when its subsystem is dropped"
PROJ="$(make_project)"; track_tmp "$PROJ"
make_legacy "$PROJ" || _no "legacy manifest prepared"
printf '\nLocal note.\n' >> "$PROJ/.prdkit/templates/agent-definition-template.md"
snapshot_upgrade_fixture "$PROJ" || exit 1
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 0 "$STATUS" "upgrade succeeds"
assert_file "$PROJ/.prdkit/templates/agent-definition-template.md" "edited template kept"
assert_contains "$OUTPUT" "Kept 1 edited template or memory file(s)" "kept template named"
if [ -e "$PROJ/.prdkit/scripts/bash/render-agents.sh" ]; then _no "renderer removed"; else _ok "renderer removed"; fi

it "a pre-2.0 install that uses agent tiers keeps them and records the choice"
for marker in definition baseline; do
    PROJ="$(make_project)"; track_tmp "$PROJ"
    make_legacy "$PROJ" || _no "legacy manifest prepared"
    if [ "$marker" = definition ]; then
        mkdir -p "$PROJ/.prdkit/agents"
        printf -- '---\nname: reviewer\ntier: deep\n---\nReview.\n' > "$PROJ/.prdkit/agents/reviewer.md"
    else
        mkdir -p "$PROJ/.prdkit/agent-library"
        printf '{}\n' > "$PROJ/.prdkit/agent-library/tiers.json"
    fi
    mkdir -p "$PROJ/scripts"
    printf 'helper(root, "render-agents.sh")\n' > "$PROJ/scripts/tool.py"
    snapshot_upgrade_fixture "$PROJ" || exit 1
    run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade"
    assert_eq 0 "$STATUS" "upgrade succeeds ($marker)"
    if tiers_installed "$PROJ"; then _ok "agent tiers kept ($marker)"; else _no "agent tiers kept ($marker)"; fi
    assert_contains "$(cat "$PROJ/.prdkit/.manifest")" "options: agent-tiers" "choice recorded ($marker)"
    assert_not_contains "$OUTPUT" "scripts/tool.py: render-agents.sh" "a constructed path to an installed renderer is not flagged ($marker)"
done

it "doctor reports agent definitions without the renderer"
PROJ="$(make_project)"; track_tmp "$PROJ"
( cd "$PROJ" && bash .product-kit/scripts/init.sh ) >/dev/null 2>&1
mkdir -p "$PROJ/.prdkit/agents"
printf -- '---\nname: reviewer\ntier: deep\n---\nReview.\n' > "$PROJ/.prdkit/agents/reviewer.md"
run bash -c "cd '$PROJ' && bash .prdkit/scripts/bash/doctor.sh"
assert_contains "$OUTPUT" "Agent tiers are in use" "doctor names the missing subsystem"
assert_contains "$OUTPUT" "--with agent-tiers" "doctor names the option"
snapshot_upgrade_fixture "$PROJ" || exit 1
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 0 "$STATUS" "plain upgrade succeeds: $OUTPUT"
if tiers_installed "$PROJ"; then _ok "a plain upgrade installs what the project uses"; else _no "a plain upgrade installs what the project uses"; fi

# Separate synthetic diagnostics: runs on healthy installers too, including native's
# existing explicit test_optional_subsystems.sh invocation. Never installs a fault model.
if { source "$TESTS_DIR/optional-diagnostics-cases.sh"; } 2>/dev/null &&
    declare -F tiers_diag_cases >/dev/null; then
    tiers_diag_cases
else
    _no "diagnostic controls available"
fi

finish
