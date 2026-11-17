#!/usr/bin/env bash
# Exact-object installation proof, using local synthetic Git repositories only.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/install-lib.sh"

PROJ="$(make_project)"; track_tmp "$PROJ"
PROJ="$(CDPATH='' cd "$PROJ" && pwd -P)"
cd "$PROJ" || exit 1
git rm -rq --cached .product-kit || exit 1
git -C .product-kit init -q
git -C .product-kit config user.name test
git -C .product-kit config user.email t@example.com
printf '#!/bin/sh\nexit 0\n' > .product-kit/scripts/retired-c7a.sh
printf '# Retired fixture command\n' > .product-kit/commands/prdkit-retired.md
git -C .product-kit add -A
git -C .product-kit commit -qm 'synthetic source before upgrade' || exit 1
OLD_PIN="$(git -C .product-kit rev-parse HEAD)"
git update-index --add --cacheinfo "160000,$OLD_PIN,.product-kit"
printf '[submodule ".product-kit"]\n\tpath = .product-kit\n\turl = https://example.invalid/kit.git\n' > .gitmodules
printf 'Consumer prefix.\n' > AGENTS.md
bash .product-kit/scripts/init.sh --copy --harness all --with agent-tiers >/dev/null || exit 1
printf '\nConsumer suffix without final newline.' >> AGENTS.md
printf '# Policy\n- **Rigor**: full\n' > .prdkit/memory/constitution.md
printf '# Local configuration\n## Configuration\n' > .prdkit/memory/config.md
printf '\nCustomized template.\n' >> .prdkit/templates/spec-template.md
policy="$(install_hash_stream < .prdkit/memory/constitution.md)"
template="$(install_hash_stream < .prdkit/templates/spec-template.md)"
git add -A
git commit -qm 'prepared policy and initial installation' || exit 1
git remote add origin https://example.invalid/consumer.git
git update-ref refs/remotes/origin/main HEAD
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
SCRIPT="$PROJ/.prdkit/scripts/bash/check-adoption.sh"

check_source() { run bash "$SCRIPT" --require-source --json "$@"; }
reject_source() {
    check_source "$@"
    assert_eq 1 "$STATUS" 'strict proof refuses invalid installation'
    assert_contains "$OUTPUT" '"source_verification":"failed"' 'no source-verified success'
}
save_manifest() { cp .prdkit/.manifest .git/manifest.saved; }
restore_manifest() { cp .git/manifest.saved .prdkit/.manifest; }

it 'prepared upgrade needs one installer command and no copied hashes'
printf '2.0.0\n' > .product-kit/VERSION
printf '\nNew shipped command content.\n' >> .product-kit/commands/prdkit.md
rm .product-kit/scripts/retired-c7a.sh .product-kit/commands/prdkit-retired.md
git -C .product-kit add -A
git -C .product-kit commit -qm 'synthetic prepared upgrade' || exit 1
PIN="$(git -C .product-kit rev-parse HEAD)"
git add .product-kit
git commit -qm 'prepared committed source pointer' || exit 1
run bash .product-kit/scripts/init.sh --upgrade --without agent-tiers
assert_eq 0 "$STATUS" "one-command prepared upgrade: $OUTPUT"
check_source
assert_eq 0 "$STATUS" "strict source proof: $OUTPUT"
assert_contains "$OUTPUT" '"source_verification":"verified"' 'source proof is explicit'
assert_contains "$OUTPUT" "\"source_revision\":\"$PIN\"" 'revision derives from committed gitlink'
assert_eq "$policy" "$(install_hash_stream < .prdkit/memory/constitution.md)" 'custom policy preserved'
assert_eq "$template" "$(install_hash_stream < .prdkit/templates/spec-template.md)" 'custom template preserved'
assert_contains "$(cat AGENTS.md)" 'Consumer prefix.' 'unmanaged prefix preserved'
assert_eq '.' "$(tail -c 1 AGENTS.md)" 'unmanaged suffix keeps absent final newline'
for path in .prdkit/scripts/bash/retired-c7a.sh .prdkit/scripts/bash/render-agents.sh .claude/commands/prdkit-retired.md; do
    if [ ! -e "$path" ]; then _ok "retired path absent: $path"; else _no "retired path retained: $path"; fi
done
git add -A
git commit -qm 'installed prepared upgrade' || exit 1
HEAD_SHA="$(git rev-parse HEAD)"
check_source --head "$HEAD_SHA"
assert_eq 0 "$STATUS" "committed proof: $OUTPUT"

it 'a recomputed malicious manifest never substitutes for source bytes'
save_manifest
cp .prdkit/scripts/bash/status.sh .git/status.saved
printf '\n# Unreviewed installed change.\n' >> .prdkit/scripts/bash/status.sh
bad="$(install_hash_stream < .prdkit/scripts/bash/status.sh)"
awk -v h="$bad" '$2 == ".prdkit/scripts/bash/status.sh" { print h "  " $2; next } { print }' .git/manifest.saved > .prdkit/.manifest
reject_source
assert_contains "$OUTPUT" 'Installed content differs from pinned source: .prdkit/scripts/bash/status.sh' 'exact content comparison fails'
assert_contains "$OUTPUT" 'Manifest differs from pinned source' 'rewritten digest also fails'
cp .git/status.saved .prdkit/scripts/bash/status.sh
restore_manifest

it 'missing and extra paths cannot disappear into rewritten manifests'
for target in .prdkit/scripts/bash/status.sh .prdkit/workflows/review.md .claude/commands/prdkit.md; do
    mv "$target" .git/path.saved
    awk -v p="$target" '$2 != p' .git/manifest.saved > .prdkit/.manifest
    reject_source
    assert_contains "$OUTPUT" "Manifest must record exactly one installed path: $target" 'omitted mapping is found'
    mv .git/path.saved "$target"
    restore_manifest
done
for target in .prdkit/scripts/bash/extra.sh .prdkit/workflows/extra.md .opencode/commands/prdkit-extra.md; do
    printf 'extra\n' > "$target"
    reject_source
    assert_contains "$OUTPUT" "Unexpected kit-owned installed path: $target" 'unrecorded disk path found'
    printf '%s  %s\n' "$(install_hash_stream < "$target")" "$target" >> .prdkit/.manifest
    reject_source
    assert_contains "$OUTPUT" "Unexpected installed manifest path: $target" 'self-recorded extra also fails'
    rm "$target"; restore_manifest
done
mv .prdkit/templates/spec-template.md .git/template.saved
reject_source
assert_contains "$OUTPUT" 'Missing project-owned installed path' 'missing conffile is not a customization'
mv .git/template.saved .prdkit/templates/spec-template.md

it 'Git executable modes and copy types are enforced'
chmod -x .prdkit/scripts/bash/status.sh
reject_source
assert_contains "$OUTPUT" 'Installed Git mode mismatch' 'missing executable bit fails'
chmod +x .prdkit/scripts/bash/status.sh
chmod +x .prdkit/workflows/review.md
reject_source
chmod -x .prdkit/workflows/review.md
mv .prdkit/scripts/bash/status.sh .git/path.saved
ln -s ../../../.git/path.saved .prdkit/scripts/bash/status.sh
reject_source
rm .prdkit/scripts/bash/status.sh
mv .git/path.saved .prdkit/scripts/bash/status.sh

it 'managed content is compared to a source object, not its mutable manifest digest'
cp AGENTS.md .git/agents.saved
sed 's/## Product-Kit workflow/## Altered workflow/' AGENTS.md > .git/agents.next
cp .git/agents.next AGENTS.md
section="$(managed_agents_section AGENTS.md | install_hash_stream)"
sed "s/^agents-section: .*/agents-section: $section/" .git/manifest.saved > .prdkit/.manifest
reject_source
assert_contains "$OUTPUT" 'managed section differs from pinned source' 'source section remains authoritative'
cp .git/agents.saved AGENTS.md; restore_manifest

it 'committed-head proof is independent of unrelated index and worktree substitutions'
printf '\nDirty installed bytes.\n' >> .prdkit/scripts/bash/status.sh
printf 'bad\n' > .prdkit/.manifest
git update-index --cacheinfo "160000,$OLD_PIN,.product-kit"
git add .prdkit/scripts/bash/status.sh .prdkit/.manifest
check_source --head "$HEAD_SHA"
assert_eq 0 "$STATUS" "committed objects ignore substitutions: $OUTPUT"
# Fixture-only index restoration, without touching any real checkout.
git read-tree "$HEAD_SHA"
cp .git/status.saved .prdkit/scripts/bash/status.sh
restore_manifest
check_source
assert_eq 0 "$STATUS" 'worktree proof also ignores a separate index gitlink'
git update-index --cacheinfo "160000,$OLD_PIN,.product-kit"
check_source
assert_eq 0 "$STATUS" 'worktree proof uses committed gitlink, never substituted index'
git read-tree "$HEAD_SHA"

it 'wrong committed revisions fail even when the index supplies the correct pin'
git update-index --cacheinfo "160000,$OLD_PIN,.product-kit"
tree="$(git write-tree)"
wrong_head="$(printf 'wrong synthetic gitlink\n' | git commit-tree "$tree" -p "$HEAD_SHA")"
git read-tree "$HEAD_SHA"
reject_source --head "$wrong_head"
assert_contains "$OUTPUT" 'Manifest version does not match pinned source' 'committed pointer, not index, determines source'

it 'source-worktree substitutions never redefine pinned source objects'
printf '999.0.0\n' > .product-kit/VERSION
printf '\nDirty source bytes.\n' >> .product-kit/scripts/status.sh
check_source --head "$HEAD_SHA"
assert_eq 0 "$STATUS" "source objects, not source worktree: $OUTPUT"
printf '2.0.0\n' > .product-kit/VERSION
git -C .product-kit show HEAD:scripts/status.sh > .product-kit/scripts/status.sh

it 'replacement refs cannot substitute consumer or source history'
git replace "$HEAD_SHA" "$wrong_head"
git -C .product-kit replace "$PIN" "$OLD_PIN"
check_source --head "$HEAD_SHA"
assert_eq 0 "$STATUS" "raw objects ignore replacement refs: $OUTPUT"
git replace -d "$HEAD_SHA" >/dev/null
git -C .product-kit replace -d "$PIN" >/dev/null

it 'explicit pin and manifest-hash restrictions remain binding'
cp .prdkit/memory/config.md .git/config.saved
printf -- '- adoption-pin: %s\n' "$OLD_PIN" >> .prdkit/memory/config.md
reject_source
assert_contains "$OUTPUT" 'Kit pin drift' 'explicit pin never ignored'
cp .git/config.saved .prdkit/memory/config.md
printf -- '- adoption-manifest-sha256: %064d\n' 0 >> .prdkit/memory/config.md
reject_source
assert_contains "$OUTPUT" 'Manifest hash drift' 'explicit hash never ignored'
cp .git/config.saved .prdkit/memory/config.md

it 'missing source objects fail without fetching, installing or editing records'
object="$(git -C .product-kit rev-parse "$PIN:scripts/status.sh")"
object_file=".product-kit/.git/objects/${object:0:2}/${object:2}"
mv "$object_file" .git/object.saved
before="$(git status --porcelain --untracked-files=all --ignore-submodules=all)"
reject_source --head "$HEAD_SHA"
assert_contains "$OUTPUT" 'Missing pinned source object: scripts/status.sh' 'missing blob is explicit'
assert_eq "$before" "$(git status --porcelain --untracked-files=all --ignore-submodules=all)" 'verification writes no project state'
mv .git/object.saved "$object_file"
for object in "$PIN" "$(git -C .product-kit rev-parse "$PIN^{tree}")"; do
    object_file=".product-kit/.git/objects/${object:0:2}/${object:2}"
    mv "$object_file" .git/object.saved
    reject_source --head "$HEAD_SHA"
    assert_contains "$OUTPUT" 'Source proof unavailable: missing source' 'missing commit/tree also fail'
    mv .git/object.saved "$object_file"
done
mv .product-kit .product-kit-away
reject_source --head "$HEAD_SHA"
assert_contains "$OUTPUT" 'local source object repository absent' 'uninitialized source is not proof'
run bash "$SCRIPT" --json
assert_eq 0 "$STATUS" 'source-less copy integrity remains available'
assert_contains "$OUTPUT" '"source_verification":"not-requested"' 'copy integrity cannot be mistaken for source proof'
mv .product-kit-away .product-kit
git -C .product-kit config remote.origin.promisor true
run env GIT_TRACE="$PROJ/.git/proof-trace" bash "$SCRIPT" --head "$HEAD_SHA" --json
assert_not_contains "$(cat .git/proof-trace)" ' fetch ' 'proof performs no lazy or explicit fetch'
# Older Git rejects the partial-clone evidence lane even when all objects happen to exist.
if [ "$STATUS" -eq 0 ]; then
    assert_contains "$OUTPUT" '"source_verification":"verified"' 'local-only capable Git verifies'
else
    assert_eq 1 "$STATUS" 'unsupported local-only Git fails closed'
    assert_contains "$OUTPUT" 'cannot guarantee local-only object reads' 'partial-clone restriction is explicit'
fi
git -C .product-kit config --unset remote.origin.promisor

it 'legitimate managed aliases work in both evidence lanes'
mv AGENTS.md CLAUDE.md
ln -s CLAUDE.md AGENTS.md
check_source
assert_eq 0 "$STATUS" "in-repo alias: $OUTPUT"
git add AGENTS.md CLAUDE.md
git commit -qm 'synthetic managed alias' || exit 1
check_source --head HEAD
assert_eq 0 "$STATUS" "committed alias: $OUTPUT"

it 'a mutable option selection cannot conceal a subsystem still in use'
mkdir -p .prdkit/agents
printf '# Local definition\n' > .prdkit/agents/reviewer.md
reject_source
assert_contains "$OUTPUT" 'Agent tiers are in use' 'option usage remains effective'
rm .prdkit/agents/reviewer.md

it 'selected optional components and canonical command links are source verified'
run bash .product-kit/scripts/init.sh --upgrade --symlink --with agent-tiers
assert_eq 0 "$STATUS" "prepared optional install: $OUTPUT"
check_source
assert_eq 0 "$STATUS" "optional symlink installation: $OUTPUT"
git add -A; git commit -qm 'synthetic optional symlink install' || exit 1
check_source --head HEAD
assert_eq 0 "$STATUS" "committed command links: $OUTPUT"
link_head="$(git rev-parse HEAD)"
mv .claude/commands .claude/commands.saved
ln -s commands.saved .claude/commands
reject_source
assert_contains "$OUTPUT" 'Symlinked installation directory: .claude/commands' 'link parents cannot masquerade as an installer layout'
rm .claude/commands
mv .claude/commands.saved .claude/commands
rm .claude/commands/prdkit.md
ln -s $'../../.product-kit/commands/prdkit.md\n' .claude/commands/prdkit.md
git add .claude/commands/prdkit.md
tree="$(git write-tree)"
newline_head="$(printf 'synthetic newline link\n' | git commit-tree "$tree" -p "$link_head")"
reject_source --head "$newline_head"
assert_contains "$OUTPUT" 'Wrong command link target' 'raw committed link text retains trailing newline'
git read-tree "$link_head"
rm .claude/commands/prdkit.md
ln -s ../../.product-kit/commands/prdkit-status.md .claude/commands/prdkit.md
reject_source
assert_contains "$OUTPUT" 'Wrong command link target' 'same-source wrong command link rejected'
rm .claude/commands/prdkit.md
ln -s ../../.product-kit/commands/prdkit.md .claude/commands/prdkit.md
printf '\nModified linked command.\n' >> .product-kit/commands/prdkit.md
reject_source
assert_contains "$OUTPUT" 'Command link content differs from pinned source' 'resolving dirty link also rejected'

finish
