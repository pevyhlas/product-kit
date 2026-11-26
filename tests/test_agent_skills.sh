#!/usr/bin/env bash
# Opt-in vendored skill projection. Uses installed helpers, synthetic skills/models only.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

P="$(make_inited_project --with agent-tiers --harness claude,opencode)" || exit 1
track_tmp "$P"
cd "$P" || exit 1
S=.prdkit/scripts/bash
R="$S/render-agents.sh"
MAP=.prdkit/memory/agents.md
LIB="$(mktemp -d)" || exit 1
track_tmp "$LIB"
git -C "$LIB" init -q
git -C "$LIB" config user.name test
git -C "$LIB" config user.email t@example.com
cat > "$LIB/tiers.json" <<'EOF'
{"deep":{"claude":{"model":"example-deep"},"opencode":{"model":"example/deep","variant":"high"}},
 "standard":{"claude":{"model":"example-standard"},"opencode":{"model":"example/standard"}},
 "light":{"claude":{"model":"example-light"},"opencode":{"model":"example/light"}}}
EOF
git -C "$LIB" add tiers.json
git -C "$LIB" commit -qm tiers
cat >> "$MAP" <<'EOF'

| Role | Agent | Notes |
|------|-------|-------|
| Reviewer | review | Example |
| Maker | make | Example |
| Reviewer | plain | Example |

Tier baseline: agent-library tiers.json@0000000
Hand-owned agents: local-policy

| Projection tier | Claude effort | OpenCode permissions | OpenCode preamble |
|-----------------|---------------|----------------------|-------------------|
| deep | high | read, skill | Use the review rubric. |
| standard | | shell, read | |
EOF
run bash "$R" --refresh-baseline "$LIB"
assert_eq 0 "$STATUS" "baseline refresh succeeds"
mkdir -p .prdkit/agents .claude/agents .opencode/agents
def() { # agent tier [additional frontmatter]
    printf '%s\n' '---' "tier: $2" "description: Example $1." ${3:+"$3"} '---' '' "Prompt for $1." > ".prdkit/agents/$1.md"
}
def review deep
def make standard
def plain light
# Keys in other YAML values and in the prompt do not opt in.
cat > .prdkit/agents/plain.md <<'EOF'
---
tier: light
description: Example plain.
example: |
  skills: [example-bad]
---

skills: [example-bad]
EOF
cat > .claude/agents/review.md <<'EOF'
---
name: review
model: stale
tools: Read, Grep # review tools
skills: [hand-owned-skill]
color: blue
---

Prompt for review.
EOF
cat > .opencode/agents/plain.md <<'EOF'
---
description: Example plain.
model: stale/example
permission:
  shell: deny
---

Prompt for plain.
EOF
printf '%s\n' '---' 'model: example/local' '---' 'Locally owned.' > .opencode/agents/local-policy.md
cp -R .claude/agents "$P/orig-claude"
cp -R .opencode/agents "$P/orig-opencode"

bytes() { # expected actual label
    if cmp -s "$1" "$2"; then _ok "$3"; else _no "$3" "$(diff -u "$1" "$2")"; fi
}
capture() { # file command...
    local out="$1" rc=0; shift
    "$@" > "$out.stdout" 2> "$out.stderr" || rc=$?
    printf '%s\n' "$rc" > "$out.exit"
}
replay_opt_out() { # directory: native bytes and raw outputs/statuses, including drift
    local dst="$1" harness file
    mkdir -p "$dst"
    capture "$dst/pre-check" bash "$R" --check --json
    capture "$dst/pre-doctor" bash "$S/doctor.sh" --json
    capture "$dst/pre-adoption" bash "$S/check-adoption.sh" --json
    capture "$dst/render" bash "$R"
    for harness in claude opencode; do
        for file in ".$harness"/agents/*.md; do cp "$file" "$dst/$harness-${file##*/}"; done
    done
    capture "$dst/check" bash "$R" --check --json
    capture "$dst/doctor" bash "$S/doctor.sh" --json
    capture "$dst/adoption" bash "$S/check-adoption.sh" --json
    capture "$dst/rerender" bash "$R"
}

it "no declaration leaves projections and diagnostics byte-identical"
# Unusable skill settings and a broken vendored file must not affect the replay.
cp "$MAP" "$P/map-base"
mkdir -p .agents/skills/example-bad
printf '%s\n' '---' 'metadata: [unreadable]' '---' > .agents/skills/example-bad/SKILL.md
replay_opt_out "$P/no-settings"
rm -r .claude/agents .opencode/agents
cp -R "$P/orig-claude" .claude/agents
cp -R "$P/orig-opencode" .opencode/agents
printf '\nSkill roots: /not/a/root\nClaude skill prefix: not:a:plugin\n' >> "$MAP"
replay_opt_out "$P/dormant-settings"
for f in "$P/no-settings/"*; do bytes "$f" "$P/dormant-settings/${f##*/}" "opt-out ${f##*/}"; done
for check in check doctor adoption render rerender; do
    assert_eq 0 "$(cat "$P/no-settings/$check.exit")" "opt-out $check passes after projection (or is the render)"
done
for check in pre-check pre-doctor pre-adoption; do
    assert_eq 1 "$(cat "$P/no-settings/$check.exit")" "opt-out $check detects stale model/drift before first render"
done
assert_contains "$(cat "$P/no-settings/claude-review.md")" "skills: [hand-owned-skill]" "Claude skills are not owned without a declaration"

it "unrelated quoted and explicit neutral keys do not opt into skill validation"
def review deep $'"notes": project-owned neutral metadata\n"m\\u0065mo": also owned by the project\n\'owner\'\'s notes\': retained\n? other-key\n: other-value\n? |-\n  another-key\n: other-value\n? >-\n  notes about\n  skills\n: still-an-unrelated-key\n? |\n  skills\n: the-key-has-a-trailing-newline'
for check in render check doctor adoption; do
    case "$check" in
        render) run bash "$R" ;;
        check) run bash "$R" --check --json ;;
        doctor) run bash "$S/doctor.sh" --json ;;
        adoption) run bash "$S/check-adoption.sh" --json ;;
    esac
    assert_eq 0 "$STATUS" "unrelated neutral keys: $check"
done
for harness in claude opencode; do
    for f in ".$harness"/agents/*.md; do
        bytes "$P/no-settings/$harness-${f##*/}" "$f" "unrelated neutral keys leave $f unchanged"
    done
done
def review deep

it "Claude prose comments and scalar text are not ownership records"
for shape in comment literal quoted; do
    case "$shape" in
        comment) awk '/^tools:/ { print "# Skill projection: configured by this project." } { print }' "$P/no-settings/claude-review.md" ;;
        literal) awk '/^description:/ {
            print "description: |2-"
            print "  Example review."
            print "  # Skill projection: configured by this project."
            print "  # prdkit-skill-projection: begin 4"
            next
        } { print }' "$P/no-settings/claude-review.md" ;;
        quoted) awk '/^description:/ {
            print "description: \"Example review."
            print "  # prdkit-skill-projection: begin 4"
            print "  Still the description.\""
            next
        } { print }' "$P/no-settings/claude-review.md" ;;
    esac > "$P/claude-$shape"
    cp "$P/claude-$shape" .claude/agents/review.md
    # No neutral description override: these bytes belong to the project.
    awk '!/^description:/' .prdkit/agents/review.md > "$P/no-description"
    cp "$P/no-description" .prdkit/agents/review.md
    for check in render check doctor adoption; do
        case "$check" in
            render) run bash "$R" ;;
            check) run bash "$R" --check --json ;;
            doctor) run bash "$S/doctor.sh" --json ;;
            adoption) run bash "$S/check-adoption.sh" --json ;;
        esac
        assert_eq 0 "$STATUS" "$shape is not an ownership record: $check"
    done
    bytes "$P/claude-$shape" .claude/agents/review.md "$shape is preserved byte-for-byte"
    def review deep
done
cp "$P/no-settings/claude-review.md" .claude/agents/review.md
# Optional external replay: run this same fixture on the base revision without
# making the regular suite depend on access to any particular Git history.
if [ -n "${SKILLS_REPLAY_DIR:-}" ]; then
    mkdir -p "$SKILLS_REPLAY_DIR"
    cp -R "$P/no-settings" "$P/dormant-settings" "$SKILLS_REPLAY_DIR/"
    finish
    exit $?
fi
cp "$P/map-base" "$MAP"
cp .claude/agents/plain.md "$P/plain-claude"
cp .opencode/agents/plain.md "$P/plain-opencode"

it "project skill permissions in order from the V2 shell rules; Claude preloads all declarations"
cat >> "$MAP" <<'EOF'

## Skills

```text
Skill roots: /fenced/example
Claude skill prefix: ignored
```
<!--
Claude skill prefix: hidden
-->
Claude skill prefix: example-plugin
EOF
cp "$MAP" "$P/map-skills"
ids='skills: [example-shell, "example-read", example-empty, example-flow]'
def review deep "$ids"
def make standard "$ids"
mkdir -p .claude/skills/example-plugin/skills/example-shell \
    .agents/skills/example-read .agents/skills/example-empty .agents/skills/example-flow
SHELL_SKILL=.claude/skills/example-plugin/skills/example-shell/SKILL.md
cat > "$SHELL_SKILL" <<'EOF'
---
name: example-shell
description: Example.
metadata:
  audience: "reviewers # not a comment"
  prdkit/needs: 'bash python3 git gh dotnet network' # actual comment
---

Example shell skill.
EOF
printf '%s\n' '---' 'name: example-read' 'description: Example.' '---' 'No needs metadata.' > .agents/skills/example-read/SKILL.md
printf '%s\n' '---' 'metadata:' '  prdkit/needs: ""' '---' 'Empty needs.' > .agents/skills/example-empty/SKILL.md
printf '%s\n' '---' 'metadata: { "prdkit/needs": "network", display: "oh, hi" } # comment' '---' > .agents/skills/example-flow/SKILL.md
cp "$SHELL_SKILL" "$P/skill-ok"
rm .claude/agents/make.md .opencode/agents/make.md
run bash "$R"
assert_eq 0 "$STATUS" "mixed roles render"
perm_rules() {
    awk '/^  - action:/ { a=$NF } /^    resource:/ { r=$NF } /^    effect:/ { print a, r, $NF }' "$1"
}
assert_eq '"*" "*" deny
"read" "*" allow
"skill" "*" allow
"skill" "*" deny
"skill" "example-read" allow
"skill" "example-empty" allow' "$(perm_rules .opencode/agents/review.md)" "project skill rules override the broad role's skill allow"
assert_eq '"*" "*" deny
"shell" "*" allow
"read" "*" allow
"skill" "*" deny
"skill" "example-shell" allow
"skill" "example-read" allow
"skill" "example-empty" allow
"skill" "example-flow" allow' "$(perm_rules .opencode/agents/make.md)" "shell role can run all declared skills"
# shellcheck disable=SC2016 # Literal Markdown code spans.
fallback='Skill `example-shell` needs a shell (bash,python3,git,gh,dotnet,network), which you cannot run here. When the review package carries its output (`example-shell.json`, `example-shell.md`), read the facts there; otherwise list them as unverified.'
review="$(cat .opencode/agents/review.md)"
# shellcheck disable=SC2016 # Literal Markdown code spans.
flow_fallback='Skill `example-flow` needs a shell (network), which you cannot run here. When the review package carries its output (`example-flow.json`, `example-flow.md`), read the facts there; otherwise list them as unverified.'
assert_contains "$review" "$(printf 'Use the review rubric.\n\n%s\n%s\n\nPrompt for review.' "$fallback" "$flow_fallback")" \
    "one note per blocked skill, between preamble and prompt"
assert_not_contains "$(cat .opencode/agents/make.md)" "needs a shell" "no fallback on shell role"
claude_skills='skills: [example-plugin:example-shell, example-plugin:example-read, example-plugin:example-empty, example-plugin:example-flow]'
for who in review make; do
    assert_contains "$(cat ".claude/agents/$who.md")" "$claude_skills"
    assert_not_contains "$(cat ".claude/agents/$who.md")" "needs a shell" "Claude receives all declarations without OpenCode notes"
done
assert_contains "$(cat .claude/agents/review.md)" 'tools: Read, Grep, Skill # review tools'
assert_contains "$(cat .claude/agents/review.md)" 'color: blue'
assert_not_contains "$(grep '^skills:' .claude/agents/review.md)" 'hand-owned-skill'
assert_not_contains "$(cat .claude/agents/make.md)" 'tools:' "unrestricted Claude inherits tools; do not add a list"
bytes "$P/plain-claude" .claude/agents/plain.md "undeclared Claude file untouched"
bytes "$P/plain-opencode" .opencode/agents/plain.md "undeclared OpenCode file untouched"
run bash "$R" --check --json
assert_eq 0 "$STATUS" "projection agrees with shared verifier"
run bash "$R"
assert_contains "$OUTPUT" "0 created, 0 updated" "idempotent render"

it "Claude preserves native list forms, adds Skill once, and never grants Bash"
cp "$P/no-settings/claude-review.md" .claude/agents/review.md
for tools in 'tools: [Read, Bash]' 'tools: [Read, Skill]' 'tools: "Read, Bash" # quoted scalar' \
    $'tools:\n  - Read  # preserve\n  - Bash' $'tools:\n- Read\n- Bash\n# Neighbor comment' 'tools: []'; do
    sed '/^tools:/d' .claude/agents/review.md | TOOLS="$tools" awk '/^color:/ { print ENVIRON["TOOLS"] } { print }' > "$P/new-tools"
    cp "$P/new-tools" .claude/agents/review.md
    run bash "$R"
    assert_eq 0 "$STATUS" "render $tools"
    assert_eq 1 "$(grep -E '^(tools:| *- )' .claude/agents/review.md | grep -c Skill)" "one explicit Skill tool"
    if [[ "$tools" != *Bash* ]]; then
        assert_not_contains "$(cat .claude/agents/review.md)" Bash "missing Bash is not granted"
    fi
    run bash "$R" --check
    assert_eq 0 "$STATUS" "checks clean"
    cp "$P/no-settings/claude-review.md" .claude/agents/review.md
done
run bash "$R"
assert_eq 0 "$STATUS"
cp .claude/agents/review.md "$P/claude-ok"
cp .opencode/agents/review.md "$P/oc-ok"

it "a deny-only OpenCode agent with only shell-dependent skills gains no skill allows"
printf '%s\n' '---' 'tier: deep' 'description: Example review.' 'skills: [example-shell]' '---' > .prdkit/agents/review.md
sed 's/read, skill | Use the review rubric/deny | Use the review rubric/' "$P/map-skills" > "$MAP"
run bash "$R"
assert_eq 0 "$STATUS"
assert_eq '"*" "*" deny
"skill" "*" deny' "$(perm_rules .opencode/agents/review.md)"
assert_contains "$(cat .opencode/agents/review.md)" "$fallback"
run bash "$R" --check
assert_eq 0 "$STATUS" "an empty neutral body still renders the preamble and fallback"
def review deep "$ids"
cp "$P/map-skills" "$MAP"
run bash "$R"
assert_eq 0 "$STATUS"

it "check and diagnostics detect skill/tool, permission and fallback text drift"
sed -e 's/^skills:.*/skills: [example-plugin:stale]/' -e '/^tools:/s/, Skill//' "$P/claude-ok" > .claude/agents/review.md
sed -e 's/"example-read"/"example-shell"/' -e '/^Skill .*needs a shell/d' "$P/oc-ok" > .opencode/agents/review.md
for checker in "$R" "$S/doctor.sh" "$S/check-adoption.sh"; do
    if [ "$checker" = "$R" ]; then run bash "$R" --check --json; else run bash "$checker" --json; fi
    assert_eq 1 "$STATUS" "$checker fails on projected drift"
    assert_contains "$OUTPUT" "skills frontmatter, Skill tool"
    assert_contains "$OUTPUT" "native model/permissions or skills frontmatter"
    assert_contains "$OUTPUT" "prompt body differs"
done
run bash "$R"
assert_eq 0 "$STATUS"
bytes "$P/claude-ok" .claude/agents/review.md "Claude drift repaired"
bytes "$P/oc-ok" .opencode/agents/review.md "OpenCode drift repaired"

blocked() { # expected finding substring
    local before checker
    before="$(cat .claude/agents/*.md .opencode/agents/*.md | cksum)"
    for checker in check write; do
        if [ "$checker" = check ]; then run bash "$R" --check --json; else run bash "$R"; fi
        assert_eq 1 "$STATUS" "$checker refuses $1"
        assert_contains "$OUTPUT" "$1" "$checker names $1"
        [ "$checker" != write ] || assert_contains "$OUTPUT" "nothing written"
    done
    assert_eq "$before" "$(cat .claude/agents/*.md .opencode/agents/*.md | cksum)" "no projection was touched"
}

it "malformed IDs, declarations, missing directories and missing SKILL.md refuse all writes"
# Leave a repairable drift in the other role to prove failed preflight writes nothing.
printf '\nOld prompt.\n' >> .opencode/agents/make.md
for id in 'caps-Skill' 'foo--bar' '../outside' 'skill_' 'a b' "$(printf '%065d' 0)"; do
    def review deep "skills: [$id]"
    blocked "Agent 'review': .prdkit/agents/review.md line 4: skill '$id': invalid skill id"
done
def review deep 'skills: [example-read,, example-shell]'
blocked "line 4: skill '<empty>': invalid skill id"
def review deep 'skills: [example-read, example-read]'
blocked "line 4: skill 'example-read': duplicate skill id"
def review deep 'skills: [example-missing, Example-invalid]'
blocked "line 4: skill 'example-missing': no vendored skill directory containing SKILL.md"
blocked "line 4: skill 'Example-invalid': invalid skill id"
def review deep $'skills:\n  - example-read'
blocked "line 4: skill '<list>': unreadable skills: declaration"
printf '%s\n' '---' 'tier: deep' 'skills: [example-read]' > .prdkit/agents/review.md
blocked "line 3: skill '<list>': unreadable skills: declaration"
mkdir -p .agents/skills/example-no-file
for id in example-missing example-no-file; do
    def review deep "skills: [$id]"
    blocked "line 4: skill '$id': no vendored skill directory containing SKILL.md"
done
def review deep "$ids"

it "unknown tokens and metadata that cannot be read reliably are findings with lines"
printf '%s\n' '---' 'metadata:' '  prdkit/needs: "bash example-unknown"' '---' > "$SHELL_SKILL"
blocked "Agent 'review': $SHELL_SKILL line 3: skill 'example-shell': unknown prdkit/needs token: example-unknown"
for metadata in 'metadata: *shared' 'metadata: [bash]' $'metadata:\n  prdkit/needs: |-\n    bash' \
    $'metadata:\n  prdkit/needs: [bash]' $'metadata:\n  "prdkit/nee\\u0064s": bash' \
    $'metadata:\n  prdkit/needs: bash\n  prdkit/needs: ""'; do
    printf '%s\n' '---' "$metadata" '---' > "$SHELL_SKILL"
    it "unreadable metadata: $metadata"
    blocked "skill 'example-shell': unreadable metadata"
done
cp "$P/skill-ok" "$SHELL_SKILL"
mkdir -p .agents/skills/example-shell
printf '%s\n' '---' 'metadata: {}' '---' > .agents/skills/example-shell/SKILL.md
blocked "skill 'example-shell': vendored copies disagree"
cp "$SHELL_SKILL" .agents/skills/example-shell/SKILL.md
run bash "$R"
assert_eq 0 "$STATUS" "copies with matching needs are accepted"

it "custom roots and Claude prefixes are configurable; unsafe or ambiguous settings fail closed"
mv .agents/skills custom-skills
mkdir -p .agents/skills
sed 's/^Claude skill prefix: example-plugin$/Claude skill prefix: another-plugin/' "$P/map-skills" > "$MAP"
printf '\nSkill roots: absent-root, custom-skills\n' >> "$MAP"
run bash "$R"
assert_eq 0 "$STATUS" "custom roots replace defaults"
assert_contains "$(cat .claude/agents/review.md)" "skills: [another-plugin:example-shell"
cp "$MAP" "$P/map-custom"
printf '\nSkill roots: custom-skills\n' >> "$MAP"
blocked "expected one nonempty 'Skill roots:' setting"
for root in '../outside' '/absolute' 'custom-*' 'custom-skills,'; do
    sed "s@^Skill roots: absent-root, custom-skills\$@Skill roots: $root@" "$P/map-custom" > "$MAP"
    blocked "'Skill roots:' must list comma-separated repository-relative directories"
done
cp "$P/map-custom" "$MAP"
mv custom-skills/example-read/SKILL.md "$P/read-skill"
ln -s "$P/read-skill" custom-skills/example-read/SKILL.md
blocked "custom-skills/example-read/SKILL.md line 1: skill 'example-read': SKILL.md must be a regular file"
rm custom-skills/example-read/SKILL.md
mv "$P/read-skill" custom-skills/example-read/SKILL.md
sed '/^Claude skill prefix: another-plugin$/d' "$P/map-custom" > "$MAP"
blocked "set 'Claude skill prefix:' to the plugin name"
cp "$P/map-custom" "$MAP"

it "hand-owned OpenCode permissions and unverifiable Claude tools are never guessed"
cp .prdkit/agents/plain.md "$P/neutral-plain"
def plain light 'skills: [example-read]'
blocked "Agent 'plain': .prdkit/agents/plain.md line 4: skill 'example-read': OpenCode permissions are not renderer-owned"
cp "$P/neutral-plain" .prdkit/agents/plain.md
cp .claude/agents/review.md "$P/claude-custom"
sed 's/^tools:.*/tools: *unknown/' "$P/claude-custom" > .claude/agents/review.md
blocked "skill 'example-shell': unreadable Claude tools/frontmatter"
cp "$P/claude-custom" .claude/agents/review.md
cp .opencode/agents/review.md "$P/oc-custom"
awk 'NR == 2 { print "tools: {}" } { print }' "$P/oc-custom" > .opencode/agents/review.md
blocked "line 4: skill 'example-shell': Agent projection .opencode/agents/review.md has OpenCode V1-only frontmatter keys: tools"
cp "$P/oc-custom" .opencode/agents/review.md
printf '%s\n' '---' 'model: example/stray' '---' 'Old projection.' > .opencode/agents/unowned.md
blocked ".opencode/agents/unowned.md is unowned"
rm .opencode/agents/unowned.md
run bash "$R" --check
assert_eq 0 "$STATUS" "clean after restoring the valid fixture"

it "unsafe multiline native headers are refused before any projection is touched"
cp .prdkit/agents/review.md "$P/review-round2"
cp .claude/agents/review.md "$P/claude-round2"
cat > .prdkit/agents/review.md <<'EOF'
---
tier: deep
skills: [example-read]
---

Prompt for review.
EOF
cat > .claude/agents/review.md <<'EOF'
---
name: review
model: example-deep
description: "Notes for the reviewer
skills: [reading]
and a project-owned summary."
tools: Read, Grep
color: blue
---

Prompt for review.
EOF
blocked "line 4: skill 'example-read': unsafe multiline frontmatter"
cp "$P/claude-round2" .claude/agents/review.md
cp "$P/review-round2" .prdkit/agents/review.md

it "quoted, escaped and explicit root keys cannot silently opt out"
for key in '"skills": [example-read]' "'skills': [example-read]" \
    '"sk\u0069lls": [example-read]' '"\x73kill\U00000073": [example-read]' \
    '"sk\x6Zlls": [example-read]' '"sk\qlls": [example-read]' '!!str "skills": [example-read]' \
    $'? skills\n: [example-read]' $'?\n  "skills"\n: [example-read]' \
    $'? |-\n  skills\n: [example-read]' $'? >2-\n  skills\n: [example-read]' \
    $'? !!str\n  skills\n: [example-read]' $'? !!str # node follows\n\n  skills\n: [example-read]' \
    $'? &reserved\n  skills\n: [example-read]' $'? !!str &reserved |-2\n  skills\n\n: [example-read]' \
    $'? !!str "ski\\\n  lls"\n: [example-read]'; do
    def review deep "$key"
    blocked "line 4: skill '<list>': unsupported neutral frontmatter key"
done
def review deep $'notes: "unrelated\nskills: [example-not-a-skill]\nend of notes."'
run bash "$R"
assert_eq 0 "$STATUS" "a key-shaped line in an unrelated neutral value does not opt in"
run bash "$R" --check
assert_eq 0 "$STATUS"
def review deep $'"notes": "project-owned\n  multiline metadata"\n'"$ids"
run bash "$R"
assert_eq 0 "$STATUS" "unrelated quoted metadata is allowed while opted in"
run bash "$R" --check
assert_eq 0 "$STATUS"
cp "$P/review-round2" .prdkit/agents/review.md

it "cleanup restores the project-owned preloads and only undoes the generated tool addition"
for tools in 'tools: Read, Grep # retain comment' 'tools: [Read, Skill]' 'tools: []' \
    $'tools:\n  - Read # retain comment\n  - Bash'; do
    # Export only to awk to preserve embedded newlines in block lists on BWK.
    TOOLS="$tools" awk '/^tools:/ { print ENVIRON["TOOLS"]; next } { print }' \
        "$P/no-settings/claude-review.md" > "$P/cleanup-fixture"
    cp "$P/cleanup-fixture" .claude/agents/review.md
    def review deep "$ids"
    run bash "$R"
    assert_eq 0 "$STATUS" "render with $tools"
    def review deep
    run bash "$R" --check --json
    assert_eq 1 "$STATUS" "removing the declaration creates drift"
    assert_contains "$OUTPUT" "stale generated Claude skill entries"
    run bash "$R"
    assert_eq 0 "$STATUS" "clean up after declaration removal"
    bytes "$P/cleanup-fixture" .claude/agents/review.md "restore exact project tools and preload"
    run bash "$R" --check --json
    assert_eq 0 "$STATUS" "cleanup is clean"
done
def review deep "$ids"
sed '/^skills:/d; /^tools:/d' "$P/no-settings/claude-review.md" > .claude/agents/review.md
cp .claude/agents/review.md "$P/cleanup-inherited"
run bash "$R"
assert_eq 0 "$STATUS"
def review deep
run bash "$R"
assert_eq 0 "$STATUS"
bytes "$P/cleanup-inherited" .claude/agents/review.md "remove an added preload from an agent with inherited tools"

it "cleanup preserves edits to neighboring block tools and agent fields"
TOOLS=$'tools:\n  - Read' awk '/^tools:/ { print ENVIRON["TOOLS"]; next } { print }' \
    "$P/no-settings/claude-review.md" > .claude/agents/review.md
def review deep "$ids"
run bash "$R"
assert_eq 0 "$STATUS"
awk '/^  - Skill$/ { print "  - Grep # project addition" } { print }' \
    .claude/agents/review.md > "$P/block-edit"
sed 's/^color: blue$/color: green/' "$P/block-edit" > .claude/agents/review.md
def review deep
run bash "$R"
assert_eq 0 "$STATUS"
assert_contains "$(cat .claude/agents/review.md)" '  - Grep # project addition'
assert_contains "$(cat .claude/agents/review.md)" 'color: green'
assert_not_contains "$(cat .claude/agents/review.md)" '  - Skill'

it "damaged ownership and changed inline tools fail closed even after the declaration is removed"
cp "$P/no-settings/claude-review.md" .claude/agents/review.md
def review deep "$ids"
run bash "$R"
assert_eq 0 "$STATUS"
cp .claude/agents/review.md "$P/marked-claude"
def review deep
sed '/^# prdkit-skill-projection: prior-skill/d' "$P/marked-claude" > .claude/agents/review.md
blocked "cannot establish Claude skill projection ownership"
sed 's/^tools: Read, Grep, Skill/tools: Read, Bash, Skill/' "$P/marked-claude" > .claude/agents/review.md
blocked "cannot establish Claude skill projection ownership"
sed 's/^skills:.*/skills: [project-edited]/' "$P/marked-claude" > .claude/agents/review.md
blocked "cannot establish Claude skill projection ownership"
cp "$P/marked-claude" .claude/agents/review.md
run bash "$R"
assert_eq 0 "$STATUS"
bytes "$P/plain-claude" .claude/agents/plain.md "cleanup never touches a Claude agent that never declared skills"

it "indented ownership comments work with direct cleanup and with an intervening opt-in render"
for rerender in false true; do
    sed '/^# prdkit-skill-projection:/s/^/  /' "$P/marked-claude" > .claude/agents/review.md
    def review deep "$ids"
    if $rerender; then
        run bash "$R"
        assert_eq 0 "$STATUS" "rerender the existing ownership block"
        assert_eq 1 "$(grep -c '^[[:blank:]]*# prdkit-skill-projection: begin ' .claude/agents/review.md)" "rerender leaves exactly one block"
        bytes "$P/marked-claude" .claude/agents/review.md "rerender keeps the original ownership, normalizing indentation"
    fi
    def review deep
    run bash "$R" --check --json
    assert_eq 1 "$STATUS"
    assert_contains "$OUTPUT" "stale generated Claude skill entries"
    run bash "$R"
    assert_eq 0 "$STATUS" "cleanup recognizes indented records"
    bytes "$P/no-settings/claude-review.md" .claude/agents/review.md "cleanup restores exact Claude preload and tools"
    run bash "$R" --check
    assert_eq 0 "$STATUS"
done

it "only exact ownership records can be damaged"
for damage in malformed empty partial duplicate reordered; do
    case "$damage" in
        malformed) sed 's/^# prdkit-skill-projection: end$/  # prdkit-skill-projection: gibberish/' "$P/marked-claude" ;;
        empty) sed 's/^# prdkit-skill-projection: end$/  # prdkit-skill-projection:/' "$P/marked-claude" ;;
        partial) sed '/^# prdkit-skill-projection: begin /d' "$P/marked-claude" ;;
        duplicate) awk '/^# prdkit-skill-projection: begin / { print } { print }' "$P/marked-claude" ;;
        reordered) awk '/^# prdkit-skill-projection: generated-skills / { held = $0; next }
            /^# prdkit-skill-projection: prior-skills / { print; print held; next } { print }' "$P/marked-claude" ;;
    esac > .claude/agents/review.md
    def review deep "$ids"
    blocked "cannot establish Claude skill projection ownership"
    def review deep
    blocked "cannot establish Claude skill projection ownership"
done
cp "$P/no-settings/claude-review.md" .claude/agents/review.md

it "an existing Claude block-list preload gets a migration hint"
def review deep "$ids"
awk '/^skills:/ { print "skills:\n  - hand-owned-skill"; next } { print }' \
    "$P/no-settings/claude-review.md" > .claude/agents/review.md
blocked "put native Claude skills on one line as a flow list ([a, b])"
cp "$P/no-settings/claude-review.md" .claude/agents/review.md

it "more than 32 declarations are refused before vendored skill lookup"
many="$(awk 'BEGIN { printf "skills: ["; for (i=1; i<=33; i++) printf "%sexample-%d", (i==1 ? "" : ", "), i; print "]" }')"
def review deep "$many"
blocked "line 4: skill '<list>': declare at most 32 skills"

finish
