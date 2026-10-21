#!/usr/bin/env bash
# Upgrading a 0.17 install to 1.0: init.sh --upgrade removes the retired kit files the old
# manifest recorded (keeping edited templates), never touches specs/, says the project needs a
# cutover, and doctor and status report the 0.x layout until the cutover has condensed and
# removed every 0.x folder.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

hash_of() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d' ' -f1; }
tree_digest() { (cd "$1" && find specs -type f -print | LC_ALL=C sort | while IFS= read -r f; do printf '%s %s\n' "$(hash_of "$f")" "$f"; done); }

PROJ="$(make_project)"; track_tmp "$PROJ"
( cd "$PROJ" && bash .product-kit/scripts/init.sh --copy ) >/dev/null 2>&1
# Simulate what a 0.17 install left behind and recorded: retired workflows, scripts and
# templates (one template edited since install), the sign-off policy seed, and 0.x canon.
mkdir -p "$PROJ/specs/product-spec" "$PROJ/specs/features/004-old-feature/reviews/T001/round-1" "$PROJ/specs/targets/t1"
printf '# Product spec\n\nThe 0.x product definition.\n' > "$PROJ/specs/product-spec/product-spec.md"
printf '# Feature spec\n' > "$PROJ/specs/features/004-old-feature/spec.md"
printf 'diff --git a/x b/x\n' > "$PROJ/specs/features/004-old-feature/reviews/T001/round-1/diff.patch"
printf '# Target\n' > "$PROJ/specs/targets/t1/target.md"
printf '# Intake\n' > "$PROJ/.prdkit/workflows/intake.md"
printf '#!/usr/bin/env bash\n' > "$PROJ/.prdkit/scripts/bash/check-signoff.sh"
printf '#!/usr/bin/env bash\n' > "$PROJ/.prdkit/scripts/bash/create-new-feature.sh"
printf '# Plan\n' > "$PROJ/.prdkit/templates/plan-template.md"
printf '# Readiness\n' > "$PROJ/.prdkit/templates/readiness-template.md"
printf '# Verification policy\n\n## Sign-off gate\n\n- gated-paths: [app/*]\n' > "$PROJ/.prdkit/memory/signoff-requirements.md"
sed -i.bak 's/^version: .*/version: 0.17.0/' "$PROJ/.prdkit/.manifest" && rm -f "$PROJ/.prdkit/.manifest.bak"
for rel in .prdkit/workflows/intake.md .prdkit/scripts/bash/check-signoff.sh .prdkit/scripts/bash/create-new-feature.sh \
           .prdkit/templates/plan-template.md .prdkit/templates/readiness-template.md .prdkit/memory/signoff-requirements.md; do
    printf '%s  %s\n' "$(hash_of "$PROJ/$rel")" "$rel" >> "$PROJ/.prdkit/.manifest"
done
printf 'Project-specific readiness notes.\n' >> "$PROJ/.prdkit/templates/readiness-template.md"
mkdir -p "$PROJ/.github/workflows"
# A workflow without kit references sorts first; it must not end the scan.
printf 'jobs:\n  build:\n    steps:\n      - run: make\n' > "$PROJ/.github/workflows/a-build.yml"
printf 'jobs:\n  verify:\n    steps:\n      - run: bash .prdkit/scripts/bash/check-artifacts.sh\n      - run: bash .prdkit/scripts/bash/doctor.sh\n' > "$PROJ/.github/workflows/verify.yml"
mkdir -p "$PROJ/scripts" "$PROJ/docs"
printf 'source .prdkit/scripts/bash/artifact-lib.sh\nbash .prdkit/scripts/bash/doctor.sh\n' > "$PROJ/scripts/validate.sh"
# A script that builds the helper path, and a test pinning a retired template.
printf 'helper(root, "check-implement-gates.sh")\n' > "$PROJ/scripts/tool.py"
printf 'PINS = {".prdkit/templates/readiness-template.md": "abc", ".prdkit/templates/spec-template.md": "def"}\n' > "$PROJ/scripts/test_pins.py"
# Not references: another tool's scripts and permissions with the same names, a longer name, a
# script naming itself, and a template the project added.
mkdir -p "$PROJ/.specify/scripts/bash" "$PROJ/.claude"
printf '{"permissions": {"allow": ["Bash(.specify/scripts/bash/check-prerequisites.sh:*)"]}}\n' > "$PROJ/.claude/settings.local.json"
printf 'echo "Usage: setup-plan.sh [--json]"\n' > "$PROJ/.specify/scripts/bash/setup-plan.sh"
printf 'exec ./scripts/pre-check-canon.sh\n' > "$PROJ/scripts/run-pre.sh"
printf 'NAME="update-agent-context.sh"\n' > "$PROJ/scripts/update-agent-context.sh"
printf '# Own template\n' > "$PROJ/.prdkit/templates/my-own-template.md"
printf 'TEMPLATE = ".prdkit/templates/my-own-template.md"\n' > "$PROJ/scripts/own.py"
printf 'We used to run .prdkit/scripts/bash/check-canon.sh here.\n' > "$PROJ/docs/notes.md"
printf 'Ran .prdkit/scripts/bash/review-scope.sh\n' > "$PROJ/specs/features/004-old-feature/notes.txt"
printf -- '- [x] T001 [IMPL] first\n- [I] T002 [TEST] second\n- [ ] T003 [DOCS] third\n' > "$PROJ/specs/features/004-old-feature/tasks.md"
git -C "$PROJ" add -A >/dev/null 2>&1; git -C "$PROJ" commit -qm "0.17 install" >/dev/null 2>&1
SPECS_BEFORE="$(tree_digest "$PROJ")"

it "a 0.x project is reported as needing a cutover before the upgrade"
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh"
assert_contains "$OUTPUT" "0.x layout — run the cutover" "doctor names the cutover"

it "check lists CI steps that call a retired helper"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --check"
assert_contains "$OUTPUT" "RETIRED — CI workflows and project files that reference kit files" "CI section"
assert_contains "$OUTPUT" ".github/workflows/verify.yml: check-artifacts.sh" "retired helper call named"
assert_not_contains "$OUTPUT" "verify.yml: doctor.sh" "shipped helper not flagged"
assert_contains "$OUTPUT" "scripts/validate.sh: artifact-lib.sh" "a project script CI runs is scanned too"
assert_not_contains "$OUTPUT" "notes.md" "prose is not a call"
assert_not_contains "$OUTPUT" "notes.txt" "specs/ is not scanned"
assert_contains "$OUTPUT" "scripts/tool.py: check-implement-gates.sh" "a helper named without its path"
assert_contains "$OUTPUT" "scripts/test_pins.py: readiness-template.md" "a retired template path"
assert_not_contains "$OUTPUT" "spec-template.md" "a shipped template is not flagged"
assert_not_contains "$OUTPUT" "a-build.yml" "a workflow without kit references is not listed"
assert_not_contains "$OUTPUT" "settings.local.json" "another tool's permission with the same name"
assert_not_contains "$OUTPUT" ".specify/" "another tool's script naming itself in prose"
assert_not_contains "$OUTPUT" "run-pre.sh" "a longer name that contains a retired one"
assert_not_contains "$OUTPUT" "scripts/update-agent-context.sh:" "a script naming itself"
assert_not_contains "$OUTPUT" "my-own-template.md" "a template the project added"

it "the retired helper list matches the kit and the migration guide"
helpers="$(sed -n "/^RETIRED_HELPERS='/,/'\$/p" "$PK_ROOT/scripts/init.sh" | tr -d "'" | sed 's/^RETIRED_HELPERS=//')"
for name in $helpers; do
    if [ -e "$PK_ROOT/scripts/$name" ]; then _no "$name is retired but still shipped"; else _ok "$name not shipped"; fi
    assert_contains "$(cat "$PK_ROOT/docs/migrating-to-1.0.md")" "\`$name\`" "the guide names $name"
done

it "upgrade removes retired kit files and keeps an edited retired template"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade"
assert_contains "$OUTPUT" "reference kit files this kit no longer ships" "upgrade warns about CI"
assert_contains "$OUTPUT" "scripts/validate.sh: artifact-lib.sh" "upgrade names the project script"
assert_eq 0 "$STATUS" "upgrade succeeds"
for rel in .prdkit/workflows/intake.md .prdkit/scripts/bash/check-signoff.sh .prdkit/scripts/bash/create-new-feature.sh .prdkit/templates/plan-template.md; do
    if [ -e "$PROJ/$rel" ]; then _no "retired file removed: $rel"; else _ok "retired file removed: $rel"; fi
    assert_not_contains "$(cat "$PROJ/.prdkit/.manifest")" "  $rel" "manifest drops $rel"
done
assert_contains "$OUTPUT" "Removed 4 retired kit file(s)" "removal reported"
assert_file "$PROJ/.prdkit/templates/readiness-template.md" "edited retired template kept"
assert_contains "$OUTPUT" "readiness-template.md" "kept template named for folding by hand"
assert_file "$PROJ/.prdkit/memory/signoff-requirements.md" "project-owned memory never deleted"
assert_contains "$(cat "$PROJ/.prdkit/.manifest")" "version: $(cat "$PK_ROOT/VERSION")" "manifest records the new version"

it "upgrade never touches specs/ and says a cutover is needed"
assert_eq "$SPECS_BEFORE" "$(tree_digest "$PROJ")" "specs/ byte-identical after the upgrade"
assert_eq "absent" "$([ -e "$PROJ/specs/changes" ] && echo present || echo absent)" "no 1.0 directories created in specs/"
assert_contains "$OUTPUT" "needs a cutover before 1.0 workflows apply" "cutover message printed"
assert_contains "$OUTPUT" "specs/ was not" "message says specs/ was left alone"
assert_contains "$OUTPUT" "configures the 0.x CI sign-off gate" "gated project warned"
assert_contains "$OUTPUT" "check-signoff.sh with check-review.sh" "the replacement named"

it "doctor and status report the 0.x layout until the cutover"
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh" --json
assert_eq 0 "$STATUS" "the layout is an advisory, not a failure"
assert_contains "$OUTPUT" "0.x layout — run the cutover (.prdkit/workflows/compact.md)" "doctor names the cutover workflow"
assert_contains "$OUTPUT" "Raw evidence tracked under specs/" "tracked raw evidence surfaced"
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh" --strict
assert_eq 1 "$STATUS" "--strict fails until the cutover"
run bash "$PROJ/.prdkit/scripts/bash/status.sh"
assert_eq 0 "$STATUS" "status still runs"
assert_contains "$OUTPUT" "0.x layout — run the cutover" "status names the cutover"

it "a half-done cutover is two canons, a feature folder left on main too"
printf '# Demo — product\n\n- **R-01 Greet** (validated): greets.\n' > "$PROJ/specs/product.md"
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh"
assert_contains "$OUTPUT" "Two canons" "doctor flags two canons"
BASE="$(git -C "$PROJ" rev-parse HEAD)"
git -C "$PROJ" rm -rq specs/product-spec specs/targets
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh"
assert_contains "$OUTPUT" "Two canons: 1.0 spec files beside 0.x folders (specs/product-spec, specs/targets or specs/features)" "a feature folder is no legacy change"
assert_contains "$OUTPUT" "git rm them (.prdkit/workflows/compact.md)" "the fix is named"
run bash "$PROJ/.prdkit/scripts/bash/status.sh"
assert_contains "$OUTPUT" "Two canons" "status names the unfinished cutover"
assert_contains "$OUTPUT" "0.x feature 004-old-feature — still in specs/features/004-old-feature/, tasks 1/3 checked; finish the cutover" "an open 0.x feature is in flight, as a cutover to finish"
assert_not_contains "$OUTPUT" "No open changes." "it is not hidden"
run bash "$PROJ/.prdkit/scripts/bash/status.sh" --json
assert_contains "$OUTPUT" '"leftover_features":[{"id":"004-old-feature","tasks_done":1,"tasks_total":3}]' "and in JSON"
assert_not_contains "$OUTPUT" "legacy_changes" "no legacy changes in JSON"
printf '# Agents\n\nThe product spec: specs/product-spec/product-spec.md. Old work: specs/features/.\n' > "$PROJ/CLAUDE.md"
git -C "$PROJ" add CLAUDE.md

it "the cutover condenses: a feature kept open becomes a change record, the rest leaves main"
mkdir -p "$PROJ/specs/changes"
# shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
printf '# Change: Old feature\n\n**Opened**: 2026-10-19 · **Parts**: P1 · **Tier**: T1 · **Parent**: none\n\n## Intent\n\nKept open at the cutover: `git show %s:specs/features/004-old-feature/tasks.md`.\n\n## State\n\n**Step**: build\n' \
    "$BASE" > "$PROJ/specs/changes/004-old-feature.md"
# shellcheck disable=SC2016 # backticks are Markdown code spans, not command substitution
printf '# Demo — archive\n\n**Base**: `%s`, main before the cutover (2026-10-20).\n**Last 0.x feature**: 004; new changes number above it.\n\n## Greeting by target\n\n- **Tried**: a target per greeting.\n- **Details**: `specs/targets/t1/` at the base.\n' \
    "$BASE" > "$PROJ/specs/archive.md"
git -C "$PROJ" rm -rq specs/features
git -C "$PROJ" add -A >/dev/null 2>&1; git -C "$PROJ" commit -qm "cutover" >/dev/null 2>&1
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh"
assert_not_contains "$OUTPUT" "Two canons" "no 0.x folder left"
assert_not_contains "$OUTPUT" "0.x layout" "cutover complete"
assert_not_contains "$OUTPUT" "Archive on main" "no raw archive on main"
assert_not_contains "$OUTPUT" "Raw evidence" "its evidence left main with its folder"
assert_eq "absent" "$([ -e "$PROJ/specs/features" ] && echo present || echo absent)" "no feature folder left"
assert_contains "$(git -C "$PROJ" show "$BASE:specs/features/004-old-feature/tasks.md")" "T003" "git keeps the removed files"
assert_contains "$OUTPUT" "Agent context names removed 0.x paths (CLAUDE.md: specs/product-spec/product-spec.md)" "agent context still pointing at a removed file; a bare folder is no path"
printf '# Agents\n\nThe product: specs/product.md. History: specs/archive.md.\n' > "$PROJ/CLAUDE.md"
git -C "$PROJ" add CLAUDE.md
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh"
assert_not_contains "$OUTPUT" "Agent context names" "agent context points at the spec and the archive"
run bash "$PROJ/.prdkit/scripts/bash/status.sh"
assert_contains "$OUTPUT" "004-old-feature — Old feature" "the kept feature is an open change"
assert_not_contains "$OUTPUT" "0.x feature 004-old-feature" "its old folder is gone from main"

it "an ignored leftover of a removed folder is not a second canon"
mkdir -p "$PROJ/specs/features/004-old-feature/results/native"; echo t > "$PROJ/specs/features/004-old-feature/results/native/t.jsonl"
printf 'specs/features/004-old-feature/results/native/\n' >> "$PROJ/.gitignore"
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh" --strict
assert_not_contains "$OUTPUT" "Two canons" "doctor judges what git would keep"
run bash "$PROJ/.prdkit/scripts/bash/status.sh"
assert_not_contains "$OUTPUT" "Two canons" "so does status"
assert_not_contains "$OUTPUT" "0.x feature 004-old-feature" "the ignored leftover is not in flight"
echo '# stray' > "$PROJ/specs/features/004-old-feature/notes.md"
run bash "$PROJ/.prdkit/scripts/bash/doctor.sh"
assert_contains "$OUTPUT" "Two canons" "a file git would keep still counts"
rm -rf "$PROJ/specs/features"; git -C "$PROJ" checkout -q -- .gitignore 2>/dev/null || true

it "a re-run of the upgrade after the cutover is quiet about it"
run bash -c "cd '$PROJ' && bash .product-kit/scripts/init.sh --upgrade"
assert_eq 0 "$STATUS" "second upgrade succeeds"
assert_not_contains "$OUTPUT" "needs a cutover" "no cutover message once the layout is 1.0"

finish
