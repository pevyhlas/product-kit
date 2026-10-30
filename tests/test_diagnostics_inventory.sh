#!/usr/bin/env bash
# Installed diagnostics are local observations, not claims about a running agent.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
mkdir -p .prdkit/agents .opencode/agents
cat > .prdkit/agents/reviewer.md <<'EOF'
---
tier: high
harnesses: [opencode]
---
Review.
EOF
cat >> .prdkit/memory/agents.md <<'EOF'

| Review | reviewer | test |

| Tier | OpenCode model | OpenCode variant |
|---|---|---|
| high | synthetic/base | medium |

| Scope | Harness | Model | Variant | Reason |
|---|---|---|---|---|
| tier:high | opencode | synthetic/tier | high | test |
| agent:reviewer | opencode | synthetic/agent | low | test |
EOF
bash .prdkit/scripts/bash/render-agents.sh >/dev/null
printf '\nProject customization.\n' >> .prdkit/templates/change-template.md
before="$(git status --porcelain --untracked-files=all)"
it "inventory distinguishes source copies, ownership and winning model rules without mutation"
run bash .prdkit/scripts/bash/doctor.sh --json --inventory
assert_eq 0 "$STATUS" "doctor succeeds: $OUTPUT"
json="$OUTPUT"
run jq -e '.configuration | .schema_version == 1 and .source.state == "copy" and .source.checkout_head == null and .source.tracked_pin == null and .active_harness == null and .active_model == null' <<< "$json"
assert_eq 0 "$STATUS" 'parent Git discovery cannot masquerade as a kit source revision'
run jq -e '.configuration.files[] | select(.path == ".prdkit/templates/change-template.md") | .owner == "project" and .effective == "project-copy" and .state == "customized" and .recorded_sha256 != .actual_sha256' <<< "$json"
assert_eq 0 "$STATUS" 'customized project copy wins over pristine seed'
run jq -e '.configuration.agents[] | select(.agent == "reviewer") | .resolved_model == "synthetic/agent" and .winning_rule == "override agent:reviewer" and .projected_model == .resolved_model' <<< "$json"
assert_eq 0 "$STATUS" 'agent override beats tier override and literal map'
run jq -e 'all(.configuration.harnesses[]; .version == null and .native_loading == "unknown" and .execution == "unknown" and .structured_capture == "unknown" and .events == "unknown" and .independent_review_access == "unknown")' <<< "$json"
assert_eq 0 "$STATUS" 'installation never becomes runtime capability evidence'
run jq -e '(.configuration.harnesses | map(select(.configured)) | map(.harness)) == ["claude", "agents"]' <<< "$json"
assert_eq 0 "$STATUS" 'space-separated manifest harness selections are reported accurately'
assert_eq "$before" "$(git status --porcelain --untracked-files=all)" 'inventory leaves repository contents unchanged'
run bash .prdkit/scripts/bash/doctor.sh --json --inventory
assert_eq "$json" "$OUTPUT" 'inventory has deterministic ordering and no wall-clock fields'

it "source-less and malformed-manifest observations remain explicit"
mv .product-kit kit-not-at-configured-source
printf '\n# drift\n' >> .prdkit/workflows/change.md
printf '%064d  ../outside\n' 0 >> .prdkit/.manifest
run bash .prdkit/scripts/bash/doctor.sh --json --inventory
assert_eq 1 "$STATUS" 'drift remains a diagnostic failure'
json="$OUTPUT"
run jq -e '.configuration.source.state == "unavailable" and any(.configuration.files[]; .path == "../outside" and .state == "unsafe-path" and .actual_sha256 == null) and any(.configuration.files[]; .path == ".prdkit/workflows/change.md" and .state == "drift")' <<< "$json"
assert_eq 0 "$STATUS" 'source absence and unsafe paths do not suppress the rest of the report'

it "tracked source pin is distinct from configured expected pin and absent checkout"
mkdir -p .product-kit
pin="$(git rev-parse HEAD)"
git rm -qr --cached -- .product-kit
git update-index --add --cacheinfo "160000,$pin,.product-kit"
printf '# Config\n\n## Configuration\n\n- adoption-pin: %040d\n' 0 > .prdkit/memory/config.md
run bash .prdkit/scripts/bash/doctor.sh --json --inventory
run jq -e --arg pin "$pin" '.configuration.source | .state == "uninitialized" and .tracked_pin == $pin and .expected_pin != $pin and .checkout_head == null' <<< "$OUTPUT"
assert_eq 0 "$STATUS" 'configured expectation does not replace observation'
rmdir .product-kit
run bash .prdkit/scripts/bash/doctor.sh --json --inventory
run jq -e '.configuration.source | .state == "uninitialized" and .checkout_head == null' <<< "$OUTPUT"
assert_eq 0 "$STATUS" 'absent submodule directory is uninitialized too'
mkdir .product-kit

it "nested gitlinks and external symlinks never impersonate the configured source"
git update-index --force-remove .product-kit
git update-index --add --cacheinfo "160000,$pin,.product-kit/vendor/nested"
run bash .prdkit/scripts/bash/doctor.sh --json --inventory
run jq -e '.configuration.source | .state == "copy" and .tracked_pin == null' <<< "$OUTPUT"
assert_eq 0 "$STATUS" 'descendant submodule pin is not the source pin'
outside="$(mktemp -d)"; track_tmp "$outside"
rmdir .product-kit
ln -s "$outside" .product-kit
run bash .prdkit/scripts/bash/doctor.sh --json --inventory
run jq -e '.configuration.source | .state == "symlink-uninspected" and .tracked_pin == null and .checkout_head == null' <<< "$OUTPUT"
assert_eq 0 "$STATUS" 'external link is explicitly uninspected, not a source copy'
finish
