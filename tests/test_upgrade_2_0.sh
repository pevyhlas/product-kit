#!/usr/bin/env bash
# Upgrading a 1.x install to 2.0, which removes the execution ledger and the retrospective:
# init.sh --upgrade removes the helpers, the template and the unedited ledger policy the old
# manifest recorded, keeps an edited ledger policy with a warning, leaves local ledger data and
# other memory alone, and flags project files that still call a removed helper.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

hash_of() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1; }
RETIRED_SCRIPTS="ledger-emit.sh ledger-spool-adapter.sh json-lib.sh retrospective.sh"

# A current install plus what a 1.5.0 install also left behind and recorded in its manifest.
make_1x_project() {
    local proj rel
    proj="$(make_project)" || return 1
    ( cd "$proj" && bash .product-kit/scripts/init.sh --copy ) >/dev/null 2>&1
    for rel in $RETIRED_SCRIPTS; do
        printf '#!/usr/bin/env bash\n# %s\n' "$rel" > "$proj/.prdkit/scripts/bash/$rel"
        chmod +x "$proj/.prdkit/scripts/bash/$rel"
    done
    printf '# Optional execution ledger\n\n## Configuration\n\n- backend: none\n' > "$proj/.prdkit/templates/task-ledger-template.md"
    cp "$proj/.prdkit/templates/task-ledger-template.md" "$proj/.prdkit/memory/task-ledger.md"
    sed 's/^version: .*/version: 1.5.0/' "$proj/.prdkit/.manifest" > "$proj/.prdkit/.manifest.new" &&
        mv "$proj/.prdkit/.manifest.new" "$proj/.prdkit/.manifest"
    for rel in $RETIRED_SCRIPTS; do
        printf '%s  %s\n' "$(hash_of "$proj/.prdkit/scripts/bash/$rel")" ".prdkit/scripts/bash/$rel" >> "$proj/.prdkit/.manifest"
    done
    for rel in .prdkit/templates/task-ledger-template.md .prdkit/memory/task-ledger.md; do
        printf '%s  %s\n' "$(hash_of "$proj/$rel")" "$rel" >> "$proj/.prdkit/.manifest"
    done
    echo "$proj"
}

it "a fresh install ships no ledger or retrospective file"
PROJ="$(make_project)"; track_tmp "$PROJ"
( cd "$PROJ" && bash .product-kit/scripts/init.sh --copy ) >/dev/null 2>&1
for rel in $RETIRED_SCRIPTS; do
    assert_not_contains "$(cat "$PROJ/.prdkit/.manifest")" "scripts/bash/$rel" "manifest records no $rel"
done
assert_not_contains "$(cat "$PROJ/.prdkit/.manifest")" "task-ledger" "manifest records no ledger policy or template"
if [ -e "$PROJ/.prdkit/memory/task-ledger.md" ] || [ -e "$PROJ/.prdkit/templates/task-ledger-template.md" ]; then
    _no "no ledger policy or template installed"; else _ok "no ledger policy or template installed"; fi

it "check lists the 1.x ledger and retrospective files as retired, read-only"
PROJ="$(make_1x_project)"; track_tmp "$PROJ"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --check"
assert_contains "$OUTPUT" "RETIRED — installed kit files the kit no longer ships" "retired section shown"
for rel in $RETIRED_SCRIPTS; do assert_contains "$OUTPUT" ".prdkit/scripts/bash/$rel" "check lists $rel"; done
assert_contains "$OUTPUT" ".prdkit/templates/task-ledger-template.md" "check lists the ledger template"
assert_contains "$OUTPUT" ".prdkit/memory/task-ledger.md" "check lists the unedited ledger policy"
assert_file "$PROJ/.prdkit/scripts/bash/ledger-emit.sh" "check is read-only"

it "upgrade removes every recorded ledger and retrospective file"
mkdir -p "$PROJ/.prdkit/ledger" "$PROJ/.github/workflows"
printf '{"event":"feature.created"}\n' > "$PROJ/.prdkit/ledger/events.jsonl"
printf 'jobs:\n  emit:\n    steps:\n      - run: bash .prdkit/scripts/bash/ledger-emit.sh feature.merged\n' > "$PROJ/.github/workflows/ledger.yml"
git -C "$PROJ" add .github >/dev/null 2>&1
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 0 "$STATUS" "upgrade succeeds"
assert_contains "$OUTPUT" "Removed 6 retired kit file(s)" "removal reported"
for rel in $RETIRED_SCRIPTS; do
    if [ -e "$PROJ/.prdkit/scripts/bash/$rel" ]; then _no "$rel removed"; else _ok "$rel removed"; fi
done
if [ -e "$PROJ/.prdkit/templates/task-ledger-template.md" ] || [ -e "$PROJ/.prdkit/memory/task-ledger.md" ]; then
    _no "ledger template and unedited policy removed"; else _ok "ledger template and unedited policy removed"; fi
assert_not_contains "$(cat "$PROJ/.prdkit/.manifest")" "ledger" "manifest no longer records ledger files"
assert_not_contains "$(cat "$PROJ/.prdkit/.manifest")" "retrospective" "manifest no longer records the retrospective"
assert_contains "$(cat "$PROJ/.prdkit/.manifest")" "version: $(cat "$PK_ROOT/VERSION")" "manifest records the new version"
for file in constitution.md agents.md config.md; do assert_file "$PROJ/.prdkit/memory/$file" "$file kept"; done
assert_eq '{"event":"feature.created"}' "$(cat "$PROJ/.prdkit/ledger/events.jsonl")" "local ledger data left alone"
run git -C "$PROJ" check-ignore -q .prdkit/ledger/events.jsonl
assert_eq 0 "$STATUS" "local ledger data stays ignored"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade"
assert_contains "$OUTPUT" ".github/workflows/ledger.yml: ledger-emit.sh" "a CI call to a removed helper is flagged"
assert_not_contains "$OUTPUT" "retired kit file(s)" "a second upgrade removes nothing"
run bash -c "cd '$PROJ' && bash .prdkit/scripts/bash/doctor.sh --json"
assert_not_contains "$OUTPUT" "Missing installed file" "doctor reports nothing missing after the upgrade"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --check"
assert_not_contains "$OUTPUT" "RETIRED — installed kit files" "no retired kit files remain"

it "an edited ledger policy is kept and named; other memory is never retired"
PROJ="$(make_1x_project)"; track_tmp "$PROJ"
printf -- '- backend: command\n- command: ./scripts/adapter.sh\n' >> "$PROJ/.prdkit/memory/task-ledger.md"
printf 'Project policy.\n' > "$PROJ/.prdkit/memory/house-rules.md"
printf '%s  .prdkit/memory/house-rules.md\n' "$(hash_of "$PROJ/.prdkit/memory/house-rules.md")" >> "$PROJ/.prdkit/.manifest"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --check"
assert_contains "$OUTPUT" ".prdkit/memory/task-ledger.md (edited since install; kept" "check flags the edited policy"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 0 "$STATUS" "upgrade succeeds"
assert_contains "$OUTPUT" "Removed 5 retired kit file(s)" "helpers and template removed"
assert_contains "$OUTPUT" "Kept 1 edited template or memory file(s) the kit no longer ships" "edited policy reported"
assert_contains "$(cat "$PROJ/.prdkit/memory/task-ledger.md")" "./scripts/adapter.sh" "edited policy kept intact"
assert_file "$PROJ/.prdkit/memory/house-rules.md" "a project memory file is never retired"

finish
