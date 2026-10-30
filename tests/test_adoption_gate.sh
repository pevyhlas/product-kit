#!/usr/bin/env bash
# check-adoption.sh: the consumer CI gate for the reviewed adoption contract —
# pin drift, manifest integrity/version, command surface per install mode, and
# bootstrap leaks. Config is section-scoped in .prdkit/memory/config.md.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
SCRIPT="$PROJ/.prdkit/scripts/bash/check-adoption.sh"
cd "$PROJ" || exit 1

it "an unconfigured fresh install passes on surface checks alone"
run bash "$SCRIPT"
assert_eq 0 "$STATUS" "gate passes"
assert_contains "$OUTPUT" 'no adoption-pin configured' "unpinned state is explicit"
run bash "$SCRIPT" --json
assert_contains "$OUTPUT" '"result":"pass"' "json pass"
assert_contains "$OUTPUT" '"findings":[]' "no findings"

it "malformed command hashes never count as recorded commands"
cp .prdkit/.manifest .git/manifest.saved
command_hash="$(awk '$2 == ".claude/commands/prdkit.md" { print $1 }' .git/manifest.saved)"
for bad_hash in "${command_hash%?}" "${command_hash}a" "g${command_hash#?}"; do
    awk -v bad="$bad_hash" '$2 == ".claude/commands/prdkit.md" { print bad "  " $2; next } { print }' \
        .git/manifest.saved > .prdkit/.manifest
    for checker in check-adoption doctor; do
        run bash ".prdkit/scripts/bash/$checker.sh" --json
        assert_eq 1 "$STATUS" "$checker rejects malformed hash: $bad_hash"
        assert_contains "$OUTPUT" 'Invalid manifest hash entry:' "hash validation still enforced"
        assert_contains "$OUTPUT" 'not recorded in the manifest: .claude/commands/prdkit.md' "invalid digest cannot record a command"
    done
done
cp .git/manifest.saved .prdkit/.manifest

it "version drift between manifest and kit source is a finding"
echo '0.0.0-test' > "$PROJ/.product-kit/VERSION"
run bash "$SCRIPT"
assert_eq 1 "$STATUS" "version drift fails"
assert_contains "$OUTPUT" 'does not match kit source' "drift is named"
git -C "$PROJ" checkout -q -- .product-kit/VERSION 2>/dev/null || cp "$PK_ROOT/VERSION" "$PROJ/.product-kit/VERSION"

it "a missing installed command is a finding"
first=""
for candidate in "$PROJ"/.claude/commands/prdkit*.md; do first="$candidate"; break; done
mv "$first" "$first.away"
run bash "$SCRIPT"
assert_eq 1 "$STATUS" "missing command fails"
assert_contains "$OUTPUT" 'Missing installed command' "finding names the check"
mv "$first.away" "$first"

it "a rogue kit-named command outside the public surface is a finding"
echo 'rogue' > "$PROJ/.claude/commands/prdkit-secret.md"
run bash "$SCRIPT"
assert_eq 1 "$STATUS" "rogue command fails"
assert_contains "$OUTPUT" 'Unexpected kit-named command' "finding names the rogue file"
rm "$PROJ/.claude/commands/prdkit-secret.md"

it "commands of a harness the manifest no longer records are findings"
MULTI="$(make_project)"; track_tmp "$MULTI"
( cd "$MULTI" && bash .product-kit/scripts/init.sh --copy --harness claude,opencode,agents ) >/dev/null 2>&1
MSCRIPT="$MULTI/.prdkit/scripts/bash/check-adoption.sh"
run bash -c "cd '$MULTI' && bash '$MSCRIPT'"
assert_eq 0 "$STATUS" "a clean multi-harness install passes"
run bash -c "cd '$MULTI' && bash .prdkit/scripts/bash/doctor.sh"
assert_eq 0 "$STATUS" "doctor passes the clean install"
assert_not_contains "$OUTPUT" "not recorded in the manifest" "no false positive on a clean install"
# The failure this guards against: an upgrade with a mangled --harness rewrote the manifest down to
# agents, the commands stayed on disk, and the contract hash was re-recorded over it.
grep -v -E '  \.(claude|opencode)/commands/' "$MULTI/.prdkit/.manifest" | sed 's/^harnesses: .*/harnesses: agents/' > "$MULTI/.prdkit/.manifest.tmp"
mv "$MULTI/.prdkit/.manifest.tmp" "$MULTI/.prdkit/.manifest"
run bash -c "cd '$MULTI' && bash '$MSCRIPT'"
assert_eq 1 "$STATUS" "the adoption gate fails"
assert_contains "$OUTPUT" "not recorded in the manifest: .claude/commands/prdkit.md" "claude command named"
assert_contains "$OUTPUT" "not recorded in the manifest: .opencode/commands/prdkit.md" "opencode command named"
run bash -c "cd '$MULTI' && bash .prdkit/scripts/bash/doctor.sh"
assert_eq 1 "$STATUS" "doctor fails too"
assert_contains "$OUTPUT" "not recorded in the manifest: .opencode/commands/prdkit-status.md" "doctor names the files"

it "copy mode requires regular copies, not symlinks"
COPYPROJ="$(make_project)"; track_tmp "$COPYPROJ"
( cd "$COPYPROJ" && bash .product-kit/scripts/init.sh --copy --harness claude ) >/dev/null 2>&1
CSCRIPT="$COPYPROJ/.prdkit/scripts/bash/check-adoption.sh"
run bash -c "cd '$COPYPROJ' && bash '$CSCRIPT'"
assert_eq 0 "$STATUS" "copy-mode install passes"
rm "$COPYPROJ/.claude/commands/prdkit.md"
ln -s "../../.product-kit/commands/prdkit.md" "$COPYPROJ/.claude/commands/prdkit.md"
run bash -c "cd '$COPYPROJ' && bash '$CSCRIPT'"
assert_eq 1 "$STATUS" "symlink under mode: copy fails"
assert_contains "$OUTPUT" 'regular copy' "mode violation is named"
rm "$COPYPROJ/.claude/commands/prdkit.md"
cp "$COPYPROJ/.product-kit/commands/prdkit.md" "$COPYPROJ/.claude/commands/prdkit.md"

it "the surface check is manifest-driven: a copy install passes without kit source"
mv "$COPYPROJ/.product-kit/commands" "$COPYPROJ/.product-kit/commands.away"
run bash -c "cd '$COPYPROJ' && bash '$CSCRIPT'"
assert_eq 0 "$STATUS" "copy-mode gate passes without a readable kit source"
mv "$COPYPROJ/.product-kit/commands.away" "$COPYPROJ/.product-kit/commands"

it "source-less copy installs detect command and workflow content drift"
mv "$COPYPROJ/.product-kit" "$COPYPROJ/.product-kit.away"
cp "$COPYPROJ/.claude/commands/prdkit.md" "$COPYPROJ/command.saved"
echo 'Changed command body' >> "$COPYPROJ/.claude/commands/prdkit.md"
run bash "$CSCRIPT" --json
assert_eq 1 "$STATUS" "modified command rejected without source"
assert_contains "$OUTPUT" 'Kit-owned content drift: .claude/commands/prdkit.md' "content finding names command"
mv "$COPYPROJ/command.saved" "$COPYPROJ/.claude/commands/prdkit.md"
mv "$COPYPROJ/.prdkit/workflows/change.md" "$COPYPROJ/change.saved"
run bash "$CSCRIPT" --json
assert_eq 1 "$STATUS" "missing workflow rejected without source"
assert_contains "$OUTPUT" 'Missing installed file: .prdkit/workflows/change.md' "missing workflow named"
mv "$COPYPROJ/change.saved" "$COPYPROJ/.prdkit/workflows/change.md"
echo 'Project-owned policy' >> "$COPYPROJ/.prdkit/memory/constitution.md"
echo 'Project-owned presentation' >> "$COPYPROJ/.prdkit/templates/spec-template.md"
run bash "$CSCRIPT"
assert_eq 0 "$STATUS" "customized policy and template remain allowed"
mv "$COPYPROJ/.product-kit.away" "$COPYPROJ/.product-kit"

it "AGENTS-only installations require their managed entry point"
AGENTPROJ="$(make_project)"; track_tmp "$AGENTPROJ"
( cd "$AGENTPROJ" && bash .product-kit/scripts/init.sh --harness agents --copy ) >/dev/null 2>&1
ASCRIPT="$AGENTPROJ/.prdkit/scripts/bash/check-adoption.sh"
printf '\nConsumer-owned trailing notes\n' >> "$AGENTPROJ/AGENTS.md"
run bash "$ASCRIPT"
assert_eq 0 "$STATUS" "consumer notes outside managed section allowed"
rm "$AGENTPROJ/AGENTS.md"
run bash "$ASCRIPT" --json
assert_eq 1 "$STATUS" "missing AGENTS entry rejected"
assert_contains "$OUTPUT" 'managed section in AGENTS.md' "missing entry named"

it "missing manifests still produce a structured failure"
mv "$AGENTPROJ/.prdkit/.manifest" "$AGENTPROJ/manifest.saved"
run bash "$ASCRIPT" --json
assert_eq 1 "$STATUS" "missing manifest fails normally"
assert_contains "$OUTPUT" '"result":"fail"' "JSON failure preserved"
mv "$AGENTPROJ/manifest.saved" "$AGENTPROJ/.prdkit/.manifest"

it "a leaked bootstrap is a finding"
touch "$PROJ/.prdkit/scripts/bash/init.sh"
run bash "$SCRIPT"
assert_eq 1 "$STATUS" "leak fails"
assert_contains "$OUTPUT" 'bootstrap leaked' "leak is named"
rm "$PROJ/.prdkit/scripts/bash/init.sh"

it "adoption-pin verifies the tracked submodule gitlink, section-scoped"
PINSHA="$(git -C "$PROJ" rev-parse HEAD)"
git -C "$PROJ" rm -rq --cached .product-kit 2>/dev/null || true
git -C "$PROJ" update-index --add --cacheinfo "160000,$PINSHA,.product-kit"
cat > "$PROJ/.prdkit/memory/config.md" <<EOF
# Optional flow configuration

Documentation example (must NOT be parsed as config):

- adoption-pin: 0000000000000000000000000000000000000000

## Configuration

- retrospective: off
- adoption-pin: $PINSHA

## Meaning

- adoption-pin: also-not-config
EOF
run bash "$SCRIPT"
assert_eq 0 "$STATUS" "matching pin passes (decoy lines ignored)"
assert_not_contains "$OUTPUT" 'no adoption-pin configured' "pin check ran"
git -C "$PROJ" update-index --add --cacheinfo "160000,1111111111111111111111111111111111111111,.product-kit"
run bash "$SCRIPT"
assert_eq 1 "$STATUS" "pin drift fails"
assert_contains "$OUTPUT" 'Kit pin drift' "drift finding names both revisions"
git -C "$PROJ" update-index --add --cacheinfo "160000,$PINSHA,.product-kit"

it "adoption-manifest-sha256 pins the manifest bytes"
if command -v sha256sum >/dev/null 2>&1; then MSHA="$(sha256sum "$PROJ/.prdkit/.manifest" | cut -d ' ' -f 1)"
else MSHA="$(shasum -a 256 "$PROJ/.prdkit/.manifest" | cut -d ' ' -f 1)"; fi
cat > "$PROJ/.prdkit/memory/config.md" <<EOF
# Optional flow configuration

## Configuration

- retrospective: off
- adoption-pin: $PINSHA
- adoption-manifest-sha256: $MSHA
EOF
run bash "$SCRIPT"
assert_eq 0 "$STATUS" "matching manifest hash passes"
echo 'drift' >> "$PROJ/.prdkit/.manifest"
run bash "$SCRIPT"
assert_eq 1 "$STATUS" "manifest edit fails the hash pin"
assert_contains "$OUTPUT" 'Manifest hash drift' "hash finding is named"

finish
