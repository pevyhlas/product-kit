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
assert_contains "$OUTPUT" 'commit the .product-kit pin' "fresh install explains the upgrade pin"
assert_not_contains "$OUTPUT" 'submodule update --remote' "upgrades select a release instead of following a branch"
for file in constitution.md agents.md config.md; do assert_file "$PROJ/.prdkit/memory/$file" "$file seeded"; done
memfiles=("$PROJ"/.prdkit/memory/*.md)
assert_eq 3 "${#memfiles[@]}" "only the three memory files are seeded"
for file in ledger-emit.sh ledger-spool-adapter.sh json-lib.sh retrospective.sh; do
    if [ -e "$PROJ/.prdkit/scripts/bash/$file" ]; then _no "removed $file installed"; else _ok "removed $file not installed"; fi
done
assert_file "$PROJ/.prdkit/templates/spec-template.md"
assert_file "$PROJ/.prdkit/templates/authority-template.md"
assert_file "$PROJ/.prdkit/templates/history-log-template.md"
assert_file "$PROJ/.prdkit/scripts/bash/authority-ref.sh"
assert_file "$PROJ/.prdkit/workflows/change.md"
assert_file "$PROJ/.prdkit/workflows/protocol.md"
assert_file "$PROJ/.prdkit/workflows/planning.md"
assert_file "$PROJ/.prdkit/workflows/implementation.md"
assert_file "$PROJ/.prdkit/workflows/inbox.md"
assert_file "$PROJ/.claude/commands/prdkit-inbox.md"
assert_file "$PROJ/.prdkit/templates/implementation-plan-template.md"
assert_file "$PROJ/.prdkit/templates/pr-summary-template.md"
assert_file "$PROJ/.prdkit/scripts/bash/new-change.sh"
assert_file "$PROJ/.prdkit/scripts/bash/check-pr-review.sh"
assert_contains "$(cat "$PROJ/.prdkit/.manifest")" '.prdkit/scripts/bash/check-pr-review.sh' 'trusted launcher participates in installation integrity'
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
assert_eq 9 "${#files[@]}" "exactly nine public commands"
if [ -e "$PROJ/.claude/commands/prdkit-implement.md" ]; then _no 'internal operation leaked'; else _ok 'internal operation outside menu'; fi
if [ -e "$PROJ/.prdkit/scripts/bash/init.sh" ]; then _no 'bootstrap leaked'; else _ok 'bootstrap not installed'; fi
# Kit maintainer tooling (scripts/maintainer/, e.g. the release scripts) never reaches consumers.
maintainer=("$PROJ"/.product-kit/scripts/maintainer/*.sh)
if [ -e "${maintainer[0]}" ]; then _ok 'maintainer tooling present in the kit source'; else _no 'maintainer tooling present in the kit source'; fi
for file in "${maintainer[@]}"; do
    if [ -e "$PROJ/.prdkit/scripts/bash/$(basename "$file")" ]; then _no "$(basename "$file") leaked"; else _ok "$(basename "$file") not installed"; fi
done
if [ -e "$PROJ/.prdkit/scripts/bash/maintainer" ] || grep -q 'maintainer' "$PROJ/.prdkit/.manifest"; then _no 'maintainer tooling leaked'; else _ok 'maintainer tooling outside the install and manifest'; fi
for entry in .prdkit/cache/ .worktrees/; do
    if grep -qxF "$entry" "$PROJ/.gitignore"; then _ok "$entry ignored"; else _no "$entry ignored"; fi
done
mkdir -p "$PROJ/.prdkit/cache"
printf '{}\n' > "$PROJ/.prdkit/cache/001-x.enrich.json"
run git -C "$PROJ" check-ignore -q .prdkit/cache/001-x.enrich.json
assert_eq 0 "$STATUS" "usage-enrichment input ignored by Git"
rm "$PROJ/.prdkit/cache/001-x.enrich.json"
it "fresh project history is tracked, not installed or ignored"
mkdir -p .prdkit/history
cp .prdkit/templates/history-log-template.md .prdkit/history/log.md
cp .prdkit/templates/archive-template.md .prdkit/history/archive.md
assert_contains "$(cat .prdkit/history/log.md)" 'History only; never cited by the spec.'
assert_contains "$(cat .prdkit/history/log.md)" 'git log --diff-filter=A -- .prdkit/history/log/<id>.md'
run git add -- .prdkit/history/
assert_eq 0 "$STATUS" "history needs no forced add"
assert_eq "$(printf '.prdkit/history/archive.md\n.prdkit/history/log.md')" "$(git ls-files .prdkit/history/)"
assert_not_contains "$(cat .prdkit/.manifest)" '.prdkit/history/' "history belongs to the project"
git rm -rqf -- .prdkit/history/ || exit 1

it "execution scratch stays ignored while templates and neutral playbooks install"
mkdir -p "$PROJ/.prdkit/cache/implementation"
printf 'unfinished task details\n' > "$PROJ/.prdkit/cache/implementation/001-demo.md"
run git -C "$PROJ" check-ignore -q .prdkit/cache/implementation/001-demo.md
assert_eq 0 "$STATUS" "execution scratch cannot enter a routine add"
snapshot_upgrade_fixture "$PROJ" || exit 1
run bash .product-kit/scripts/init.sh --upgrade
assert_eq 0 "$STATUS" "upgrade with execution scratch succeeds"
assert_eq 'unfinished task details' "$(cat "$PROJ/.prdkit/cache/implementation/001-demo.md")" "upgrade leaves consumer scratch untouched"
it "an upgrade adds the cache ignore entry once to a project seeded before it"
grep -vxF '.prdkit/cache/' "$PROJ/.gitignore" > "$PROJ/.gitignore.old" || true
mv "$PROJ/.gitignore.old" "$PROJ/.gitignore"
snapshot_upgrade_fixture "$PROJ" || exit 1
run bash .product-kit/scripts/init.sh --upgrade
assert_eq 0 "$STATUS" "upgrade succeeds"
assert_contains "$OUTPUT" "Added '.prdkit/cache/' to .gitignore" "entry added on upgrade"
snapshot_upgrade_fixture "$PROJ" || exit 1
run bash .product-kit/scripts/init.sh --upgrade
assert_eq 0 "$STATUS" "repeat upgrade succeeds"
assert_not_contains "$OUTPUT" "Added '.prdkit/cache/'" "not added twice"
assert_eq 1 "$(grep -cxF '.prdkit/cache/' "$PROJ/.gitignore")" "entry present exactly once"
it "manifest covers every installed file and includes workflow hashes"
assert_contains "$(cat "$PROJ/.prdkit/.manifest")" "version: $(cat "$PK_ROOT/VERSION")" "version recorded"
expected=0
for file in "$PROJ"/.product-kit/commands/*.md "$PROJ"/.product-kit/workflows/*.md "$PROJ"/.product-kit/templates/*.md "$PROJ"/.product-kit/scripts/*.sh "$PROJ"/.product-kit/scripts/{agents-section,outcome-checkpoint}.md; do
    case "$(basename "$file")" in
        init.sh|render-agents.sh|agent-definition-template.md) ;;   # bootstrap; optional agent tiers
        *) expected=$((expected + 1)) ;;
    esac
done
assert_eq "$((expected + 3))" "$(grep -Ec '^[0-9a-f]{64}  ' "$PROJ/.prdkit/.manifest")" "manifest covers the core sources plus three policy seeds"
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
snapshot_upgrade_fixture "$PROJ" || exit 1
run bash .product-kit/scripts/init.sh --upgrade
assert_eq 0 "$STATUS" "upgrade refreshes the old managed section"
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
assert_file "$PROJ2/.opencode/commands/prdkit-inbox.md"
if [ -L "$PROJ2/.opencode/commands/prdkit.md" ]; then _no 'copy mode linked'; else _ok 'real command copy'; fi
if [ -d "$PROJ2/.claude/commands" ]; then _no 'unselected harness installed'; else _ok 'harness selection respected'; fi
mkdir -p "$PROJ2/.codex" "$PROJ2/.claude"
snapshot_upgrade_fixture "$PROJ2" || exit 1
run bash .product-kit/scripts/init.sh --upgrade --copy
assert_eq 0 "$STATUS" "upgrade succeeds with the recorded harness"
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
assert_contains "$OUTPUT" '--upgrade refuses to overwrite these customizations' "check tells consumers to reconcile before upgrading"
assert_not_contains "$OUTPUT" 'will OVERWRITE' "check does not promise to overwrite"
assert_not_contains "$(cat "$PROJ2/.prdkit/templates/product-template.md")" 'NEW KIT PRODUCT' "check does not update"
it "upgrade refreshes kit-owned and untouched files, preserves project edits"
snapshot_upgrade_fixture "$PROJ2" || exit 1
run bash .product-kit/scripts/init.sh --upgrade --copy
assert_eq 1 "$STATUS" "upgrade refuses committed customizations to kit-owned files"
assert_contains "$OUTPUT" "Customized overwrite/delete destination: .prdkit/workflows/change.md" "workflow edit named"
assert_contains "$OUTPUT" "Customized overwrite/delete destination: .opencode/commands/prdkit.md" "command edit named"
assert_contains "$(cat "$PROJ2/.prdkit/workflows/change.md")" 'LOCAL WORKFLOW EDIT' "refusal keeps the workflow"
assert_contains "$(cat "$PROJ2/.opencode/commands/prdkit.md")" 'LOCAL COMMAND EDIT' "refusal keeps the command"
cp .product-kit/workflows/change.md .prdkit/workflows/change.md
cp .product-kit/commands/prdkit.md .opencode/commands/prdkit.md
printf '\nNEW KIT WORKFLOW\n' >> .product-kit/workflows/change.md
printf '\nNEW KIT COMMAND\n' >> .product-kit/commands/prdkit.md
snapshot_upgrade_fixture "$PROJ2" || exit 1
run bash .product-kit/scripts/init.sh --upgrade --copy
assert_eq 0 "$STATUS" "upgrade succeeds"
assert_contains "$(cat "$PROJ2/.prdkit/templates/spec-template.md")" 'USER TEMPLATE' "template preserved"
assert_contains "$(cat "$PROJ2/.prdkit/memory/constitution.md")" 'USER POLICY' "policy preserved"
assert_contains "$(cat "$PROJ2/.prdkit/templates/product-template.md")" 'NEW KIT PRODUCT' "untouched template refreshed"
assert_file "$PROJ2/.prdkit/templates/new-template.md"
assert_contains "$(cat "$PROJ2/.prdkit/workflows/change.md")" 'NEW KIT WORKFLOW' "workflow refreshed"
assert_contains "$(cat "$PROJ2/.opencode/commands/prdkit.md")" 'NEW KIT COMMAND' "command refreshed"
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
assert_contains "$(cat AGENTS.md)" '.prdkit/workflows/inbox.md' "inbox review reachable without native slash commands"
printf '\nTrailing notes.\n' >> AGENTS.md
snapshot_upgrade_fixture "$PROJ3" || exit 1
run bash .product-kit/scripts/init.sh --upgrade
assert_eq 0 "$STATUS" "upgrade preserves surrounding notes"
assert_contains "$(cat AGENTS.md)" 'Trailing notes.' "trailing notes retained"
assert_eq 1 "$(grep -c 'BEGIN PRODUCT-KIT MANAGED SECTION' AGENTS.md)" "one managed block"
it "malformed managed markers do not swallow user content"
grep -v 'END PRODUCT-KIT MANAGED SECTION' AGENTS.md > AGENTS.tmp
mv AGENTS.tmp AGENTS.md
before="$(cat AGENTS.md)"
snapshot_upgrade_fixture "$PROJ3" || exit 1
run bash .product-kit/scripts/init.sh --upgrade
assert_eq 1 "$STATUS" "upgrade refuses malformed managed markers"
assert_eq "$before" "$(cat AGENTS.md)" "malformed block preserved"
run bash .product-kit/scripts/init.sh --check
assert_eq 1 "$STATUS" "malformed managed block is diagnosed"
assert_contains "$OUTPUT" 'managed section (missing or malformed)' "check explains the repair"

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
snapshot_upgrade_fixture "$PROJ4" || exit 1
run bash .product-kit/scripts/init.sh --upgrade --harness "claude opencode agents"
assert_eq 0 "$STATUS" "space-separated list (as the manifest records it) works"
assert_contains "$(cat "$PROJ4/.prdkit/.manifest")" "harnesses: claude opencode agents" "space list keeps the set"
snapshot_upgrade_fixture "$PROJ4" || exit 1
run bash .product-kit/scripts/init.sh --upgrade --harness "claude, opencode" --harness agents
assert_eq 0 "$STATUS" "comma+space and repeated flags work"
assert_contains "$(cat "$PROJ4/.prdkit/.manifest")" "harnesses: claude opencode agents" "mixed list keeps the set"
run bash .product-kit/scripts/init.sh --upgrade --harness all
assert_eq 0 "$STATUS" "all is a superset"
assert_contains "$(cat "$PROJ4/.prdkit/.manifest")" "harnesses: claude opencode codex agents" "all widens explicitly"
snapshot_upgrade_fixture "$PROJ4" || exit 1
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
snapshot_upgrade_fixture "$PROJ5" || exit 1
run bash -c 'cd "$1" && bash .product-kit/scripts/init.sh --upgrade' _ "$PROJ5"
assert_eq 0 "$STATUS" "plain upgrade succeeds in copy mode"
if [ -L "$PROJ5/.claude/commands/prdkit.md" ]; then _no "plain upgrade preserves copy mode" "re-linked as symlink"; else _ok "plain upgrade preserves copy mode"; fi
run bash -c 'cd "$1" && bash .product-kit/scripts/init.sh --upgrade --symlink' _ "$PROJ5"
assert_contains "$(cat "$PROJ5/.prdkit/.manifest")" 'mode: symlink' "explicit --symlink wins and is recorded"
assert_symlink "$PROJ5/.claude/commands/prdkit.md" "explicit --symlink re-links"
assert_eq "../../.product-kit/commands/prdkit.md" "$(readlink "$PROJ5/.claude/commands/prdkit.md")" "symlinks are relative"
assert_contains "$OUTPUT" "git submodule update --init .product-kit" "symlink install names what a new checkout needs"
snapshot_upgrade_fixture "$PROJ5" || exit 1
run bash -c 'cd "$1" && bash .product-kit/scripts/init.sh --upgrade' _ "$PROJ5"
assert_eq 0 "$STATUS" "plain upgrade succeeds in symlink mode"
assert_symlink "$PROJ5/.claude/commands/prdkit.md" "plain upgrade preserves symlink mode"
assert_contains "$(cat "$PROJ5/.prdkit/.manifest")" 'mode: symlink' "symlink mode stays recorded"
it "an installed file absent from the current mapping blocks upgrade without deletion"
ZERO_HASH="$(printf '%064d' 0)"
PROJ6="$(make_inited_project)"; track_tmp "$PROJ6"
cp "$PROJ6/.prdkit/scripts/bash/common.sh" "$PROJ6/.prdkit/scripts/bash/earlier.sh"
printf '%s  .prdkit/scripts/bash/earlier.sh\n' "$ZERO_HASH" >> "$PROJ6/.prdkit/.manifest"
snapshot_upgrade_fixture "$PROJ6" || exit 1
for flag in --check --upgrade; do
    run bash "$PROJ6/.product-kit/scripts/init.sh" --target "$PROJ6" "$flag"
    assert_eq 1 "$STATUS" "unsupported install entry refuses $flag"
    assert_contains "$OUTPUT" 'earlier.sh is not in the current kit mapping'
    assert_eq '' "$(git -C "$PROJ6" status --porcelain)" 'refusal performs no writes'
done

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

it "a manifest path outside the installed layout fails without writes"
PROJ8="$(contained_project)"; track_tmp "${PROJ8%/proj}"
( cd "$PROJ8" && bash .product-kit/scripts/init.sh --copy ) >/dev/null 2>&1
printf 'outside\n' > "${PROJ8%/proj}/victim.sh"
printf '%s  .prdkit/scripts/bash/../../../../victim.sh\n' "$ZERO_HASH" >> "$PROJ8/.prdkit/.manifest"
snapshot_upgrade_fixture "$PROJ8" || exit 1
run bash "$PROJ8/.product-kit/scripts/init.sh" --target "$PROJ8" --upgrade
assert_eq 1 "$STATUS" "format error blocks upgrade"
assert_contains "$OUTPUT" "SHA-256 entries for installed kit paths"
assert_file "${PROJ8%/proj}/victim.sh" "a file outside the project survives"
assert_eq '' "$(git -C "$PROJ8" status --porcelain)" 'no writes'

it "upgrade refuses a kit-owned symlink instead of writing through it"
PROJ9="$(contained_project)"; track_tmp "${PROJ9%/proj}"
( cd "$PROJ9" && bash .product-kit/scripts/init.sh --copy ) >/dev/null 2>&1
printf 'outside\n' > "${PROJ9%/proj}/sentinel"
rm "$PROJ9/.prdkit/scripts/bash/status.sh" "$PROJ9/.prdkit/workflows/change.md"
ln -s "${PROJ9%/proj}/sentinel" "$PROJ9/.prdkit/scripts/bash/status.sh"
ln -s "${PROJ9%/proj}/sentinel" "$PROJ9/.prdkit/workflows/change.md"
snapshot_upgrade_fixture "$PROJ9" || exit 1
run bash -c "cd '$PROJ9' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 1 "$STATUS" "upgrade does not overwrite either customization"
assert_contains "$OUTPUT" "Customized overwrite/delete destination: .prdkit/scripts/bash/status.sh" "replaced helper named"
assert_contains "$OUTPUT" "Customized overwrite/delete destination: .prdkit/workflows/change.md" "replaced workflow named"
assert_eq "outside" "$(cat "${PROJ9%/proj}/sentinel")" "the link target outside the project is unchanged"
if [ -x "${PROJ9%/proj}/sentinel" ]; then _no "the link target gains no execute bit"; else _ok "the link target gains no execute bit"; fi
rm "$PROJ9/.prdkit/scripts/bash/status.sh" "$PROJ9/.prdkit/workflows/change.md"
snapshot_upgrade_fixture "$PROJ9" || exit 1
run bash -c "cd '$PROJ9' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 0 "$STATUS" "upgrade works after removing the links"
assert_file "$PROJ9/.prdkit/workflows/change.md" "workflow installed again"
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
snapshot_upgrade_fixture "$PROJ13" || exit 1
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
sed 's/## Product-Kit workflow/## Product-Kit workflow updated/' "$PROJ14/.product-kit/scripts/agents-section.md" > "${PROJ14%/proj}/edited" &&
    cat "${PROJ14%/proj}/edited" > "$PROJ14/.product-kit/scripts/agents-section.md"
snapshot_upgrade_fixture "$PROJ14" || exit 1
run bash -c "cd '$PROJ14' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 0 "$STATUS" "upgrade through an in-project link succeeds"
assert_contains "$OUTPUT" "AGENTS.md managed section: updated" "an outdated section is rewritten"
assert_symlink "$PROJ14/AGENTS.md" "the update keeps AGENTS.md a link"
assert_contains "$(cat "$PROJ14/CLAUDE.md")" '## Product-Kit workflow updated' "the target holds the current section"
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
