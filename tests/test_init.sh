#!/usr/bin/env bash
# Installer behavior, ownership, neutral entry points, and selected harnesses.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"  # physical path, as init.sh prints it: macOS mktemp dirs live under /var -> /private/var
cd "$PROJ" || exit 1
run bash .product-kit/scripts/init.sh
it "fresh install provides the public interface and neutral agent operations"
assert_eq 0 "$STATUS" "install succeeds"
assert_contains "$OUTPUT" 'Product-Kit initialized' "success banner"
for file in constitution.md agents.md config.md task-ledger.md; do assert_file "$PROJ/.prdkit/memory/$file" "$file seeded"; done
assert_file "$PROJ/.prdkit/templates/spec-template.md"
assert_file "$PROJ/.prdkit/workflows/change.md"
assert_file "$PROJ/.prdkit/workflows/protocol.md"
assert_file "$PROJ/.prdkit/scripts/bash/new-change.sh"
if [ -e "$PROJ/.prdkit/memory/signoff-requirements.md" ]; then _no "retired sign-off policy seeded"; else _ok "no sign-off policy seeded"; fi
if [ -e "$PROJ/specs" ]; then _no "installer created specs/"; else _ok "installer leaves specs/ to the project"; fi
if [ -f "$PROJ/.claude/commands/prdkit.md" ] && [ ! -L "$PROJ/.claude/commands/prdkit.md" ]; then
    _ok "bare entry point installed as a copy by default"
else
    _no "bare entry point installed as a copy by default"
fi
assert_contains "$(cat "$PROJ/.prdkit/.manifest")" 'mode: copy' "copy mode recorded by default"
assert_not_contains "$OUTPUT" "Symlinked commands resolve only" "no symlink note for copies"
files=("$PROJ"/.claude/commands/*.md)
assert_eq 8 "${#files[@]}" "exactly eight public commands"
if [ -e "$PROJ/.claude/commands/prdkit-implement.md" ]; then _no 'internal operation leaked'; else _ok 'internal operation outside menu'; fi
if [ -e "$PROJ/.prdkit/scripts/bash/init.sh" ]; then _no 'bootstrap leaked'; else _ok 'bootstrap not installed'; fi
# Kit maintainer tooling (scripts/maintainer/, e.g. the release scripts) never reaches consumers.
maintainer=("$PROJ"/.product-kit/scripts/maintainer/*.sh)
if [ -e "${maintainer[0]}" ]; then _ok 'maintainer tooling present in the kit source'; else _no 'maintainer tooling present in the kit source'; fi
for file in "${maintainer[@]}"; do
    if [ -e "$PROJ/.prdkit/scripts/bash/$(basename "$file")" ]; then _no "$(basename "$file") leaked"; else _ok "$(basename "$file") not installed"; fi
done
if [ -e "$PROJ/.prdkit/scripts/bash/maintainer" ] || grep -q 'maintainer' "$PROJ/.prdkit/.manifest"; then _no 'maintainer tooling leaked'; else _ok 'maintainer tooling outside the install and manifest'; fi
for entry in .prdkit/ledger/ .prdkit/cache/ .worktrees/; do
    if grep -qxF "$entry" "$PROJ/.gitignore"; then _ok "$entry ignored"; else _no "$entry ignored"; fi
done
it "manifest covers every installed file and includes workflow hashes"
assert_contains "$(cat "$PROJ/.prdkit/.manifest")" "version: $(cat "$PK_ROOT/VERSION")" "version recorded"
expected=0
for file in "$PROJ"/.product-kit/commands/*.md "$PROJ"/.product-kit/workflows/*.md "$PROJ"/.product-kit/templates/*.md "$PROJ"/.product-kit/scripts/*.sh; do
    [ "$(basename "$file")" = init.sh ] || expected=$((expected + 1))
done
assert_eq "$((expected + 4))" "$(grep -Ec '^[0-9a-f]{64}  ' "$PROJ/.prdkit/.manifest")" "manifest covers sources plus four policy seeds"
assert_contains "$(cat "$PROJ/.prdkit/.manifest")" '.prdkit/workflows/change.md' "workflows tracked"
it "pristine check is read-only and clean"
run bash .product-kit/scripts/init.sh --check
assert_eq 0 "$STATUS" "clean check"
assert_contains "$OUTPUT" 'nothing to do' "clean report"
it "AGENTS.md points at the protocol and the 1.0 layout, and is idempotent"
assert_contains "$(cat "$PROJ/AGENTS.md")" '.prdkit/workflows/protocol.md' "neutral entry"
assert_contains "$(cat "$PROJ/AGENTS.md")" 'specs/changes/<id>.md' "1.0 layout named"
assert_contains "$(cat "$PROJ/AGENTS.md")" 'never grants action authority' "authority boundary"
first="$(cat "$PROJ/AGENTS.md")"
run bash .product-kit/scripts/init.sh
assert_eq "$first" "$(cat "$PROJ/AGENTS.md")" "managed section idempotent"

it "check detects missing or changed managed entry sections without rewriting them"
mv "$PROJ/AGENTS.md" "$PROJ/AGENTS.saved"
run bash .product-kit/scripts/init.sh --check
assert_eq 1 "$STATUS" "missing managed entry is drift"
assert_contains "$OUTPUT" 'AGENTS.md managed section' "entry finding is actionable"
mv "$PROJ/AGENTS.saved" "$PROJ/AGENTS.md"
sed 's/## Product-Kit workflow/## Changed entry/' "$PROJ/AGENTS.md" > "$PROJ/AGENTS.tmp"
mv "$PROJ/AGENTS.tmp" "$PROJ/AGENTS.md"
before="$(cat "$PROJ/AGENTS.md")"
run bash .product-kit/scripts/init.sh --check
assert_eq 1 "$STATUS" "modified managed section is drift"
assert_eq "$before" "$(cat "$PROJ/AGENTS.md")" "check remains read-only"
assert_contains "$OUTPUT" "KIT-OWNED EDITS" "an edited section is a kit-owned edit"
assert_contains "$OUTPUT" "the text between the Product-Kit markers in $PROJ/AGENTS.md" "hint names AGENTS.md"
assert_not_contains "$OUTPUT" "install-lib.sh" "no diff against a kit script"
it "an unedited section from an older kit is OUTDATED, not a kit-owned edit"
old_hash="$(sed -n '/BEGIN PRODUCT-KIT MANAGED SECTION/,/END PRODUCT-KIT MANAGED SECTION/p' "$PROJ/AGENTS.md" |
    { sha256sum 2>/dev/null || shasum -a 256; } | cut -d' ' -f1)"
sed -i.bak "s/^agents-section: .*/agents-section: $old_hash/" "$PROJ/.prdkit/.manifest" && rm -f "$PROJ/.prdkit/.manifest.bak"
run bash .product-kit/scripts/init.sh --check
assert_eq 1 "$STATUS" "an outdated section is drift"
assert_contains "$OUTPUT" "OUTDATED" "reported as outdated"
assert_not_contains "$OUTPUT" "KIT-OWNED EDITS" "not reported as an edit"
run bash .product-kit/scripts/init.sh --upgrade
assert_eq "$first" "$(cat "$PROJ/AGENTS.md")" "upgrade refreshes only managed entry"
printf '\nConsumer outside managed section\n' >> "$PROJ/AGENTS.md"
run bash .product-kit/scripts/init.sh --check
assert_eq 0 "$STATUS" "consumer-owned outside text is not drift"

PROJ2="$(make_project)"; track_tmp "$PROJ2"
cd "$PROJ2" || exit 1
run bash .product-kit/scripts/init.sh --copy --harness opencode
it "copy mode and explicit harness selection are respected"
assert_eq 0 "$STATUS" "copy install"
assert_file "$PROJ2/.opencode/commands/prdkit.md"
if [ -L "$PROJ2/.opencode/commands/prdkit.md" ]; then _no 'copy mode linked'; else _ok 'real command copy'; fi
if [ -d "$PROJ2/.claude/commands" ]; then _no 'unselected harness installed'; else _ok 'harness selection respected'; fi
mkdir -p "$PROJ2/.codex" "$PROJ2/.claude"
run bash .product-kit/scripts/init.sh --upgrade --copy
assert_contains "$(cat "$PROJ2/.prdkit/.manifest")" 'harnesses: opencode' "upgrade keeps selected set"
it "check distinguishes project customization, kit changes, and kit-owned edits"
echo 'USER TEMPLATE' >> "$PROJ2/.prdkit/templates/spec-template.md"
echo 'USER POLICY' >> "$PROJ2/.prdkit/memory/constitution.md"
echo 'NEW KIT PRODUCT' >> "$PROJ2/.product-kit/templates/product-template.md"
echo 'NEW TEMPLATE' > "$PROJ2/.product-kit/templates/new-template.md"
echo 'LOCAL WORKFLOW EDIT' >> "$PROJ2/.prdkit/workflows/change.md"
echo 'LOCAL COMMAND EDIT' >> "$PROJ2/.opencode/commands/prdkit.md"
run bash .product-kit/scripts/init.sh --check
assert_eq 1 "$STATUS" "drift reported"
for bucket in MODIFIED OUTDATED NEW KIT-OWNED; do assert_contains "$OUTPUT" "$bucket" "$bucket reported"; done
assert_not_contains "$(cat "$PROJ2/.prdkit/templates/product-template.md")" 'NEW KIT PRODUCT' "check does not update"
it "upgrade refreshes kit-owned and untouched files, preserves project edits"
run bash .product-kit/scripts/init.sh --upgrade --copy
assert_eq 0 "$STATUS" "upgrade succeeds"
assert_contains "$OUTPUT" 'Overwrote' "kit edit overwrite reported"
assert_contains "$(cat "$PROJ2/.prdkit/templates/spec-template.md")" 'USER TEMPLATE' "template preserved"
assert_contains "$(cat "$PROJ2/.prdkit/memory/constitution.md")" 'USER POLICY' "policy preserved"
assert_contains "$(cat "$PROJ2/.prdkit/templates/product-template.md")" 'NEW KIT PRODUCT' "untouched template refreshed"
assert_file "$PROJ2/.prdkit/templates/new-template.md"
assert_not_contains "$(cat "$PROJ2/.prdkit/workflows/change.md")" 'LOCAL WORKFLOW EDIT' "workflow refreshed"
assert_not_contains "$(cat "$PROJ2/.opencode/commands/prdkit.md")" 'LOCAL COMMAND EDIT' "command refreshed"
it "force explicitly resets project-owned templates"
run bash .product-kit/scripts/init.sh --force
assert_not_contains "$(cat "$PROJ2/.prdkit/templates/spec-template.md")" 'USER TEMPLATE' "force restores template"
it "missing manifest check explains reinstall"
rm "$PROJ2/.prdkit/.manifest"
run bash .product-kit/scripts/init.sh --check
assert_eq 1 "$STATUS" "missing manifest diagnosed"
assert_contains "$OUTPUT" 'No manifest' "diagnostic"

PROJ3="$(make_project)"; track_tmp "$PROJ3"
cd "$PROJ3" || exit 1
printf '# Project\n\nConsumer notes.\n' > AGENTS.md
run bash .product-kit/scripts/init.sh --harness codex
it "AGENTS.md preserves consumer content and supports non-native harnesses"
assert_eq 0 "$STATUS" "codex install"
assert_contains "$(cat AGENTS.md)" 'Consumer notes.' "notes retained"
assert_contains "$(cat AGENTS.md)" '.prdkit/workflows/protocol.md' "neutral path"
printf '\nTrailing notes.\n' >> AGENTS.md
run bash .product-kit/scripts/init.sh --upgrade
assert_contains "$(cat AGENTS.md)" 'Trailing notes.' "trailing notes retained"
assert_eq 1 "$(grep -c 'BEGIN PRODUCT-KIT MANAGED SECTION' AGENTS.md)" "one managed block"
it "malformed managed markers do not swallow user content"
grep -v 'END PRODUCT-KIT MANAGED SECTION' AGENTS.md > AGENTS.tmp
mv AGENTS.tmp AGENTS.md
before="$(cat AGENTS.md)"
run bash .product-kit/scripts/init.sh --upgrade
assert_eq "$before" "$(cat AGENTS.md)" "malformed block preserved"
assert_contains "$OUTPUT" 'end marker missing' "repair explained"
run bash .product-kit/scripts/init.sh --check
assert_eq 1 "$STATUS" "malformed managed block is diagnosed"

PROJ4="$(make_project)"; track_tmp "$PROJ4"
cd "$PROJ4" || exit 1
mkdir -p .opencode
run bash .product-kit/scripts/init.sh
it "fresh install detects an existing OpenCode configuration"
assert_file "$PROJ4/.opencode/commands/prdkit.md"
assert_file "$PROJ4/.claude/commands/prdkit.md"
it "an unknown harness name fails instead of installing less"
manifest_before="$(cat "$PROJ4/.prdkit/.manifest")"
run bash .product-kit/scripts/init.sh --harness unknown-editor
assert_eq 2 "$STATUS" "unknown name is a usage error"
assert_contains "$OUTPUT" "unknown harness 'unknown-editor'" "error names the harness"
run bash .product-kit/scripts/init.sh --upgrade --copy --harness claudeopencodeagents
assert_eq 2 "$STATUS" "a list glued together without separators is refused"
run bash .product-kit/scripts/init.sh --harness ''
assert_eq 2 "$STATUS" "an empty list is refused"
assert_eq "$manifest_before" "$(cat "$PROJ4/.prdkit/.manifest")" "refused runs leave the manifest untouched"
assert_file "$PROJ4/AGENTS.md"
FRESH="$(make_project)"; track_tmp "$FRESH"
run bash -c "cd '$FRESH' && bash .product-kit/scripts/init.sh --harness claude,unknown-editor"
assert_eq 2 "$STATUS" "an unknown name beside a valid one fails a fresh install"
if [ -e "$FRESH/.prdkit/.manifest" ] || [ -e "$FRESH/.claude/commands/prdkit.md" ]; then _no "a refused fresh install writes nothing"; else _ok "a refused fresh install writes nothing"; fi
it "an explicit harness list may not drop a recorded harness"
run bash .product-kit/scripts/init.sh --upgrade --harness agents
assert_eq 2 "$STATUS" "dropping recorded harnesses is refused"
assert_contains "$OUTPUT" "would drop claude, opencode" "error names the dropped harnesses"
assert_contains "$OUTPUT" "--harness claude,agents,opencode" "error shows the full recorded list"
run bash .product-kit/scripts/init.sh --harness claude,agents
assert_eq 2 "$STATUS" "a plain re-install is held to the same rule"
assert_eq "$manifest_before" "$(cat "$PROJ4/.prdkit/.manifest")" "manifest still records every harness"
assert_file "$PROJ4/.opencode/commands/prdkit.md" "opencode commands untouched"
it "space- and comma-separated lists name the same harnesses"
run bash .product-kit/scripts/init.sh --upgrade --harness "claude opencode agents"
assert_eq 0 "$STATUS" "space-separated list (as the manifest records it) works"
assert_contains "$(cat "$PROJ4/.prdkit/.manifest")" "harnesses: claude opencode agents" "space list keeps the set"
run bash .product-kit/scripts/init.sh --upgrade --harness "claude, opencode" --harness agents
assert_eq 0 "$STATUS" "comma+space and repeated flags work"
assert_contains "$(cat "$PROJ4/.prdkit/.manifest")" "harnesses: claude opencode agents" "mixed list keeps the set"
run bash .product-kit/scripts/init.sh --upgrade --harness all
assert_eq 0 "$STATUS" "all is a superset"
assert_contains "$(cat "$PROJ4/.prdkit/.manifest")" "harnesses: claude opencode codex agents" "all widens explicitly"
run bash .product-kit/scripts/init.sh --upgrade
assert_eq 0 "$STATUS" "upgrade without --harness"
assert_contains "$(cat "$PROJ4/.prdkit/.manifest")" "harnesses: claude opencode codex agents" "omitted --harness keeps the recorded set"
it "bootstrap refuses installation into the toolkit source itself"
run bash "$PK_ROOT/scripts/init.sh" --target "$PK_ROOT"
assert_eq 1 "$STATUS" "self-install guard"
it "install mode is recorded and preserved across upgrades"
PROJ5="$(make_project)"; track_tmp "$PROJ5"
( cd "$PROJ5" && bash .product-kit/scripts/init.sh --copy ) >/dev/null 2>&1
assert_contains "$(cat "$PROJ5/.prdkit/.manifest")" 'mode: copy' "copy mode recorded"
( cd "$PROJ5" && bash .product-kit/scripts/init.sh --upgrade ) >/dev/null 2>&1
if [ -L "$PROJ5/.claude/commands/prdkit.md" ]; then _no "plain upgrade preserves copy mode" "re-linked as symlink"; else _ok "plain upgrade preserves copy mode"; fi
run bash -c 'cd "$1" && bash .product-kit/scripts/init.sh --upgrade --symlink' _ "$PROJ5"
assert_contains "$(cat "$PROJ5/.prdkit/.manifest")" 'mode: symlink' "explicit --symlink wins and is recorded"
assert_symlink "$PROJ5/.claude/commands/prdkit.md" "explicit --symlink re-links"
assert_eq "../../.product-kit/commands/prdkit.md" "$(readlink "$PROJ5/.claude/commands/prdkit.md")" "symlinks are relative"
assert_contains "$OUTPUT" "git submodule update --init .product-kit" "symlink install names what a new checkout needs"
run bash -c 'cd "$1" && bash .product-kit/scripts/init.sh --upgrade' _ "$PROJ5"
assert_symlink "$PROJ5/.claude/commands/prdkit.md" "plain upgrade preserves symlink mode"
assert_contains "$(cat "$PROJ5/.prdkit/.manifest")" 'mode: symlink' "symlink mode stays recorded"
it "pre-0.10 installs are inferred from their command files"
( cd "$PROJ5" && bash .product-kit/scripts/init.sh --upgrade --copy ) >/dev/null 2>&1
grep -v '^mode: ' "$PROJ5/.prdkit/.manifest" > "$PROJ5/.prdkit/.manifest.tmp"
mv "$PROJ5/.prdkit/.manifest.tmp" "$PROJ5/.prdkit/.manifest"
( cd "$PROJ5" && bash .product-kit/scripts/init.sh --upgrade ) >/dev/null 2>&1
if [ -L "$PROJ5/.claude/commands/prdkit.md" ]; then _no "mode inferred from installed copies" "flipped to symlink"; else _ok "mode inferred from installed copies"; fi
assert_contains "$(cat "$PROJ5/.prdkit/.manifest")" 'mode: copy' "inferred mode re-recorded"
( cd "$PROJ5" && bash .product-kit/scripts/init.sh --upgrade --symlink ) >/dev/null 2>&1
grep -v '^mode: ' "$PROJ5/.prdkit/.manifest" > "$PROJ5/.prdkit/.manifest.tmp"
mv "$PROJ5/.prdkit/.manifest.tmp" "$PROJ5/.prdkit/.manifest"
( cd "$PROJ5" && bash .product-kit/scripts/init.sh --upgrade ) >/dev/null 2>&1
assert_symlink "$PROJ5/.claude/commands/prdkit.md" "mode inferred from installed symlinks"
assert_contains "$(cat "$PROJ5/.prdkit/.manifest")" 'mode: symlink' "inferred symlink mode re-recorded"
it "upgrade removes kit-installed commands the kit no longer ships"
PROJ6="$(make_project)"; track_tmp "$PROJ6"
( cd "$PROJ6" && bash .product-kit/scripts/init.sh --copy --harness claude,opencode ) >/dev/null 2>&1
# Simulate a retired entry point an older kit installed and recorded in its manifest,
# a dangling symlink from an old symlink install, and an unrecorded hand-made file.
printf 'retired\n' > "$PROJ6/.claude/commands/prdkit-merge.md"
printf 'retired\n' > "$PROJ6/.opencode/commands/prdkit-merge.md"
retired_hash="$( (sha256sum "$PROJ6/.claude/commands/prdkit-merge.md" 2>/dev/null || shasum -a 256 "$PROJ6/.claude/commands/prdkit-merge.md") | cut -d' ' -f1)"
printf '%s  .claude/commands/prdkit-merge.md\n%s  .opencode/commands/prdkit-merge.md\n' "$retired_hash" "$retired_hash" >> "$PROJ6/.prdkit/.manifest"
ln -s ../../.product-kit/commands/prdkit-taskstoissues.md "$PROJ6/.claude/commands/prdkit-taskstoissues.md"
printf 'mine\n' > "$PROJ6/.claude/commands/prdkit-local.md"
mkdir -p "$PROJ6/tools" && printf 'own\n' > "$PROJ6/tools/mycmd.md"
ln -s ../../tools/mycmd.md "$PROJ6/.claude/commands/prdkit-mine.md"
run bash -c "cd '$PROJ6' && bash .product-kit/scripts/init.sh --check"
assert_contains "$OUTPUT" "RETIRED" "check reports retired commands"
assert_contains "$OUTPUT" ".claude/commands/prdkit-merge.md" "recorded retired command listed"
assert_contains "$OUTPUT" "prdkit-local.md (not recorded as kit-installed; kept" "unrecorded file flagged, not claimed"
assert_file "$PROJ6/.claude/commands/prdkit-merge.md" "check is read-only"
run bash -c "cd '$PROJ6' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 0 "$STATUS" "upgrade with retired commands succeeds"
assert_contains "$OUTPUT" "Removed 3 retired kit command(s)" "removal reported"
if [ -e "$PROJ6/.claude/commands/prdkit-merge.md" ] || [ -e "$PROJ6/.opencode/commands/prdkit-merge.md" ]; then _no "recorded retired commands removed"; else _ok "recorded retired commands removed"; fi
if [ -L "$PROJ6/.claude/commands/prdkit-taskstoissues.md" ]; then _no "dangling retired symlink removed"; else _ok "dangling retired symlink removed"; fi
assert_file "$PROJ6/.claude/commands/prdkit-local.md" "unrecorded regular file preserved"
assert_symlink "$PROJ6/.claude/commands/prdkit-mine.md" "user-made symlink outside the kit preserved"
assert_contains "$OUTPUT" "prdkit-mine.md" "preserved user symlink named in a warning"
assert_contains "$OUTPUT" "prdkit-local.md" "preserved file named in a warning"
assert_not_contains "$(cat "$PROJ6/.prdkit/.manifest")" "prdkit-merge.md" "manifest no longer records the retired command"
assert_file "$PROJ6/.claude/commands/prdkit.md" "current public commands remain installed"
it "upgrade removes retired kit scripts and unmodified templates, keeps edited ones"
PROJ7="$(make_project)"; track_tmp "$PROJ7"
( cd "$PROJ7" && bash .product-kit/scripts/init.sh --copy ) >/dev/null 2>&1
# Simulate files an older kit installed and recorded: a helper and two templates it no longer ships.
printf '#!/usr/bin/env bash\n' > "$PROJ7/.prdkit/scripts/bash/record-analysis.sh"
printf '# Handover\n' > "$PROJ7/.prdkit/templates/handover-template.md"
printf '# Old\n' > "$PROJ7/.prdkit/templates/old-template.md"
for rel in .prdkit/scripts/bash/record-analysis.sh .prdkit/templates/handover-template.md .prdkit/templates/old-template.md; do
    printf '%s  %s\n' "$( (sha256sum "$PROJ7/$rel" 2>/dev/null || shasum -a 256 "$PROJ7/$rel") | cut -d' ' -f1)" "$rel" >> "$PROJ7/.prdkit/.manifest"
done
printf 'Local edit.\n' >> "$PROJ7/.prdkit/templates/old-template.md"
run bash -c "cd '$PROJ7' && bash .product-kit/scripts/init.sh --check"
assert_contains "$OUTPUT" ".prdkit/scripts/bash/record-analysis.sh" "check lists the retired helper"
assert_contains "$OUTPUT" "old-template.md (edited since install; kept" "edited retired template flagged"
assert_file "$PROJ7/.prdkit/scripts/bash/record-analysis.sh" "check is read-only"
run bash -c "cd '$PROJ7' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 0 "$STATUS" "upgrade with retired kit files succeeds"
assert_contains "$OUTPUT" "Removed 2 retired kit file(s)" "removal reported"
if [ -e "$PROJ7/.prdkit/scripts/bash/record-analysis.sh" ] || [ -e "$PROJ7/.prdkit/templates/handover-template.md" ]; then
    _no "retired helper and unmodified template removed"; else _ok "retired helper and unmodified template removed"; fi
assert_file "$PROJ7/.prdkit/templates/old-template.md" "edited template preserved"
assert_not_contains "$(cat "$PROJ7/.prdkit/.manifest")" "record-analysis.sh" "manifest no longer records the retired helper"
run bash -c "cd '$PROJ7' && bash .prdkit/scripts/bash/doctor.sh --json"
assert_not_contains "$OUTPUT" "Missing installed file" "doctor reports nothing missing after the upgrade"

# Containment: each project below sits in its own base directory, so a sentinel next to it is
# outside the target but inside the test's scratch space.
contained_project() { # echoes the project dir, inside a fresh tracked base directory
    local base proj
    base="$(mktemp -d)" || return 1
    base="$(cd "$base" && pwd -P)"
    proj="$(make_project)" || return 1
    mv "$proj" "$base/proj" && echo "$base/proj"
}
hash_of() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1; }
ZERO_HASH="$(printf '%064d' 0)"

it "a manifest path outside the installed layout is ignored, never deleted"
PROJ8="$(contained_project)"; track_tmp "${PROJ8%/proj}"
( cd "$PROJ8" && bash .product-kit/scripts/init.sh --copy ) >/dev/null 2>&1
printf 'outside\n' > "${PROJ8%/proj}/victim.sh"
printf '%s  .prdkit/scripts/bash/../../../../victim.sh\n' "$ZERO_HASH" >> "$PROJ8/.prdkit/.manifest"
run bash -c "cd '$PROJ8' && bash .product-kit/scripts/init.sh --check"
assert_not_contains "$OUTPUT" "RETIRED — installed kit files" "check does not list it as retired"
assert_contains "$OUTPUT" "ignoring a .prdkit/.manifest entry outside the installed layout" "check warns"
run bash -c "cd '$PROJ8' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 0 "$STATUS" "upgrade succeeds"
assert_file "${PROJ8%/proj}/victim.sh" "a file outside the project survives the upgrade"
assert_contains "$OUTPUT" "ignoring a .prdkit/.manifest entry outside the installed layout" "upgrade warns"
assert_not_contains "$(cat "$PROJ8/.prdkit/.manifest")" "victim.sh" "the rewritten manifest drops the entry"

it "a kit-owned file replaced by a symlink is replaced, never written through"
PROJ9="$(contained_project)"; track_tmp "${PROJ9%/proj}"
( cd "$PROJ9" && bash .product-kit/scripts/init.sh --copy ) >/dev/null 2>&1
printf 'outside\n' > "${PROJ9%/proj}/sentinel"
rm "$PROJ9/.prdkit/scripts/bash/status.sh" "$PROJ9/.prdkit/workflows/change.md"
ln -s "${PROJ9%/proj}/sentinel" "$PROJ9/.prdkit/scripts/bash/status.sh"
ln -s "${PROJ9%/proj}/sentinel" "$PROJ9/.prdkit/workflows/change.md"
run bash -c "cd '$PROJ9' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 0 "$STATUS" "upgrade succeeds"
assert_eq "outside" "$(cat "${PROJ9%/proj}/sentinel")" "the link target outside the project is unchanged"
if [ -x "${PROJ9%/proj}/sentinel" ]; then _no "the link target gains no execute bit"; else _ok "the link target gains no execute bit"; fi
for rel in .prdkit/scripts/bash/status.sh .prdkit/workflows/change.md; do
    if [ -L "$PROJ9/$rel" ]; then _no "$rel is a regular file again"; else _ok "$rel is a regular file again"; fi
done
assert_eq "$(hash_of "$PK_ROOT/scripts/status.sh")" "$(hash_of "$PROJ9/.prdkit/scripts/bash/status.sh")" "the kit's status.sh is installed"

it "a symlinked or escaping managed directory is refused before anything is written"
PROJ10="$(contained_project)"; track_tmp "${PROJ10%/proj}"
( cd "$PROJ10" && bash .product-kit/scripts/init.sh --copy ) >/dev/null 2>&1
mv "$PROJ10/.prdkit/workflows" "${PROJ10%/proj}/workflows"
ln -s "${PROJ10%/proj}/workflows" "$PROJ10/.prdkit/workflows"
printf 'outside edit\n' > "${PROJ10%/proj}/workflows/change.md"
manifest_before="$(hash_of "$PROJ10/.prdkit/.manifest")"
run bash -c "cd '$PROJ10' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 1 "$STATUS" "upgrade refused"
assert_contains "$OUTPUT" ".prdkit/workflows is a symlink" "the unsafe directory is named"
assert_contains "$OUTPUT" "nothing was written" "refusal says nothing was written"
assert_eq "outside edit" "$(cat "${PROJ10%/proj}/workflows/change.md")" "files behind the link are untouched"
assert_eq "$manifest_before" "$(hash_of "$PROJ10/.prdkit/.manifest")" "the manifest is untouched"
PROJ11="$(contained_project)"; track_tmp "${PROJ11%/proj}"
mkdir "${PROJ11%/proj}/claude"
ln -s "${PROJ11%/proj}/claude" "$PROJ11/.claude"
run bash -c "cd '$PROJ11' && bash .product-kit/scripts/init.sh --harness claude,agents"
assert_eq 1 "$STATUS" "fresh install into a symlinked .claude refused"
assert_contains "$OUTPUT" ".claude is a symlink" "the symlinked harness directory is named"
assert_eq "" "$(ls -A "${PROJ11%/proj}/claude")" "nothing written behind the link"
if [ -e "$PROJ11/.prdkit" ]; then _no "no .prdkit created on refusal"; else _ok "no .prdkit created on refusal"; fi
run bash -c "cd '$PROJ11' && bash .product-kit/scripts/init.sh --harness agents"
assert_eq 0 "$STATUS" "a symlinked directory of an unselected harness does not block the install"
assert_eq "" "$(ls -A "${PROJ11%/proj}/claude")" "and is never cleaned"
PROJ12="$(contained_project)"; track_tmp "${PROJ12%/proj}"
( cd "$PROJ12" && bash .product-kit/scripts/init.sh --copy ) >/dev/null 2>&1
rm "$PROJ12/.prdkit/templates/spec-template.md" && mkdir "$PROJ12/.prdkit/templates/spec-template.md"
run bash -c "cd '$PROJ12' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 1 "$STATUS" "a directory where the kit installs a file is refused"
assert_contains "$OUTPUT" ".prdkit/templates/spec-template.md is a directory where the kit installs a file" "the directory is named"

it "a symlinked template or memory file is kept, even with --force"
PROJ13="$(contained_project)"; track_tmp "${PROJ13%/proj}"
( cd "$PROJ13" && bash .product-kit/scripts/init.sh --copy ) >/dev/null 2>&1
printf 'SHARED POLICY\n' > "${PROJ13%/proj}/constitution.md"
rm "$PROJ13/.prdkit/memory/constitution.md" "$PROJ13/.prdkit/templates/spec-template.md"
ln -s "${PROJ13%/proj}/constitution.md" "$PROJ13/.prdkit/memory/constitution.md"
ln -s "${PROJ13%/proj}/missing.md" "$PROJ13/.prdkit/templates/spec-template.md"
run bash -c "cd '$PROJ13' && bash .product-kit/scripts/init.sh --upgrade --force"
assert_eq 0 "$STATUS" "forced upgrade succeeds"
assert_eq "SHARED POLICY" "$(cat "${PROJ13%/proj}/constitution.md")" "the shared policy behind the link is unchanged"
assert_symlink "$PROJ13/.prdkit/memory/constitution.md" "the memory link is kept"
assert_symlink "$PROJ13/.prdkit/templates/spec-template.md" "the dangling template link is kept"
if [ -e "${PROJ13%/proj}/missing.md" ]; then _no "nothing created behind a dangling link"; else _ok "nothing created behind a dangling link"; fi
assert_contains "$OUTPUT" "symlinked template/memory file(s)" "kept links are reported"

it "AGENTS.md and .gitignore are edited through a symlink only inside the project"
PROJ14="$(contained_project)"; track_tmp "${PROJ14%/proj}"
printf '# Notes\n' > "$PROJ14/CLAUDE.md"
ln -s CLAUDE.md "$PROJ14/AGENTS.md"
run bash -c "cd '$PROJ14' && bash .product-kit/scripts/init.sh --harness claude,agents"
assert_eq 0 "$STATUS" "install through an in-project link succeeds"
assert_contains "$(cat "$PROJ14/CLAUDE.md")" 'BEGIN PRODUCT-KIT MANAGED SECTION' "the section lands in the link target"
sed 's/protocol\.md/protocol-old.md/' "$PROJ14/CLAUDE.md" > "${PROJ14%/proj}/edited" && cat "${PROJ14%/proj}/edited" > "$PROJ14/CLAUDE.md"
run bash -c "cd '$PROJ14' && bash .product-kit/scripts/init.sh --upgrade"
assert_contains "$OUTPUT" "AGENTS.md managed section: updated" "an outdated section is rewritten"
assert_symlink "$PROJ14/AGENTS.md" "the update keeps AGENTS.md a link"
assert_not_contains "$(cat "$PROJ14/CLAUDE.md")" 'protocol-old.md' "the target holds the current section"
assert_contains "$(cat "$PROJ14/CLAUDE.md")" '# Notes' "the target keeps its own content"
PROJ15="$(contained_project)"; track_tmp "${PROJ15%/proj}"
printf 'outside agents\n' > "${PROJ15%/proj}/AGENTS.md"
printf 'outside ignore\n' > "${PROJ15%/proj}/gitignore"
ln -s "${PROJ15%/proj}/AGENTS.md" "$PROJ15/AGENTS.md"
ln -s "${PROJ15%/proj}/gitignore" "$PROJ15/.gitignore"
run bash -c "cd '$PROJ15' && bash .product-kit/scripts/init.sh --harness claude,agents"
assert_eq 0 "$STATUS" "install with outside links succeeds"
assert_eq "outside agents" "$(cat "${PROJ15%/proj}/AGENTS.md")" "an AGENTS.md outside the project is untouched"
assert_eq "outside ignore" "$(cat "${PROJ15%/proj}/gitignore")" "a .gitignore outside the project is untouched"
assert_contains "$OUTPUT" "AGENTS.md managed section: skipped (symlink outside the project)" "AGENTS.md skip reported"
assert_contains "$OUTPUT" ".gitignore is a symlink that leads outside the project" ".gitignore skip reported"
finish
