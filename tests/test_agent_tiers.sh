#!/usr/bin/env bash
# render-agents.sh + agent-tiers-lib.sh: deterministic projections, shared tier baseline,
# reasoned overrides, unsupported literal tables, drift checks, banned ids, and the doctor /
# adoption-gate findings. Model ids are synthetic: the kit names no real model.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project --with agent-tiers)"; track_tmp "$PROJ"
SCRIPTS="$PROJ/.prdkit/scripts/bash"
RENDER="$SCRIPTS/render-agents.sh"
MAP="$PROJ/.prdkit/memory/agents.md"
cd "$PROJ" || exit 1
mkdir -p .prdkit/agents .opencode/agents

def() { # name tier [extra frontmatter line]
    {
        printf -- '---\nname: %s\ndomain: Review\ntier: %s\ndescription: %s reviewer.\n' "$1" "$2" "$1"
        [ -z "${3:-}" ] || printf '%s\n' "$3"
        printf -- '---\n\n# %s\n\nReview carefully.\n\n<!-- LOCAL OVERLAY -->\nProject rubric for %s.\n' "$1" "$1"
    } > ".prdkit/agents/$1.md"
    printf '| Review | %s | test |\n' "$1" >> "$MAP"
}
def rev-a deep
def rev-b standard
def rev-c fast 'source: agent-library'

# shellcheck disable=SC2016 # Literal markdown fixture: backticks are data, not command substitution.
LEGACY='
## Tier map

| Tier | Claude Code model | OpenCode model | OpenCode variant |
|------|-------------------|----------------|------------------|
| high | `lit-claude-high` | `lit/oc-high` | xhigh |
| standard | `lit-claude-std` | `lit/oc-std` | high |
| fast | `lit-claude-fast` | `lit/oc-fast` | medium |
'
cp "$MAP" "$PROJ/agents.base"
printf '%s' "$LEGACY" >> "$MAP"

# ---------------------------------------------------------------------------
it "a literal-only map is refused without writing projections"
run bash "$RENDER"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "expected a Tier baseline"
[ ! -e .opencode/agents/rev-a.md ] || _no "no projection written"
run bash "$SCRIPTS/check-adoption.sh"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "expected a Tier baseline"
cp "$PROJ/agents.base" "$MAP"

# --- shared baseline ---------------------------------------------------------
LIB="$(mktemp -d)"; track_tmp "$LIB"
git -C "$LIB" init -q; git -C "$LIB" config user.email t@example.com; git -C "$LIB" config user.name test
cat > "$LIB/tiers.json" <<'EOF'
{
  "verydeep": { "claude": { "model": "lib-claude-vd" }, "opencode": { "model": "lib/oc-vd", "variant": "xhigh" } },
  "deep":     { "claude": { "model": "lib-claude-deep" }, "opencode": { "model": "lib/oc-deep", "variant": "xhigh" } },
  "standard": { "claude": { "model": "lib-claude-std" }, "opencode": { "model": "lib/oc-std", "variant": "high" } },
  "light":    { "claude": { "model": "lib-claude-light" }, "opencode": { "model": "lib/oc-light" } }
}
EOF
git -C "$LIB" add tiers.json; git -C "$LIB" commit -qm tiers
LIBREF="$(git -C "$LIB" rev-parse HEAD)"

it "refresh-baseline vendors a committed snapshot with provenance"
run bash "$RENDER" --refresh-baseline "$LIB"
assert_eq 0 "$STATUS" "refresh succeeds"
assert_file .prdkit/agent-library/tiers.json "snapshot vendored"
assert_contains "$(cat .prdkit/agent-library/tiers.json.ref)" "library-ref: $LIBREF" "provenance names the library commit"
assert_contains "$OUTPUT" "Tier baseline: agent-library tiers.json@$LIBREF" "opt-in line printed when absent"
echo '{"deep": {}}' > "$LIB/tiers.json"
run bash "$RENDER" --refresh-baseline "$LIB"
assert_eq 1 "$STATUS" "uncommitted library tiers.json refused"
git -C "$LIB" checkout -q -- tiers.json

it "baseline resolves library names and explicit mappings"
cp "$PROJ/agents.base" "$MAP"
# shellcheck disable=SC2016 # Literal markdown fixture: backticks are data, not command substitution.
printf '\nTier baseline: agent-library tiers.json@0000000\n\n```text\nTier baseline: agent-library tiers.json@1111111\n| Scope | Harness | Model | Variant | Reason |\n| tier:deep | claude | doc-example | | |\n```\n\n| Local tier | Library tier |\n|---|---|\n| fast | standard |\n' >> "$MAP"
run bash "$RENDER" --refresh-baseline "$LIB"
assert_contains "$(cat "$MAP")" "tiers.json@$LIBREF" "baseline line updated in place"
assert_contains "$(cat "$MAP")" "tiers.json@1111111" "fenced example left untouched"
run bash "$RENDER" --resolve
assert_eq 0 "$STATUS" "resolves (fenced example is not configuration)"
assert_contains "$OUTPUT" "lib-claude-deep" "library deep tier resolves"
assert_contains "$(grep '^rev-b ' <<<"$OUTPUT")" "baseline standard" "library tier name maps to itself"
assert_contains "$(grep '^rev-c .*claude' <<<"$OUTPUT")" "lib-claude-std" "project tier uses explicit mapping"
run bash "$RENDER"
assert_contains "$(cat .claude/agents/rev-a.md)" "model: lib-claude-deep" "projection takes the baseline model"
run bash "$RENDER" --check
assert_eq 0 "$STATUS" "baseline render is clean"
run bash "$SCRIPTS/doctor.sh" --json
assert_not_contains "$OUTPUT" "Tier map" "doctor clean with a vendored baseline"

it "native extras survive a render; only model/variant/body are renderer-owned"
printf -- '---\nname: rev-b\ndescription: rev-b reviewer.\ntools: Read, Grep\nmodel: hand-picked\ncolor: blue\n---\n\n<!-- Generated by hand once -->\n\nStale body.\n' > .claude/agents/rev-b.md
printf -- '---\nname: rev-b\ndescription: rev-b reviewer.\nmode: all\nmodel: lib/oc-std\nvariant: low\ntier: standard\nlibrary-ref: abc1234\npermission:\n  edit: deny\n---\n\n# rev-b\n\nReview carefully.\n\n<!-- LOCAL OVERLAY -->\nProject rubric for rev-b.\n' > .opencode/agents/rev-b.md
run bash "$RENDER" --check
assert_contains "$OUTPUT" "prompt body differs" "body drift reported"
assert_contains "$OUTPUT" "carries neutral/provenance key 'library-ref:'" "opencode provenance field flagged"
run bash "$RENDER"
assert_eq 0 "$STATUS" "render repairs"
claude_b="$(cat .claude/agents/rev-b.md)"
assert_contains "$claude_b" "tools: Read, Grep" "claude tools preserved"
assert_contains "$claude_b" "color: blue" "claude color preserved"
assert_contains "$claude_b" "model: lib-claude-std" "claude model corrected"
assert_contains "$claude_b" "<!-- Generated by hand once -->" "leading generated marker kept"
assert_contains "$claude_b" "Project rubric for rev-b." "body refreshed"
assert_not_contains "$claude_b" "Stale body." "stale body replaced"
oc_b="$(cat .opencode/agents/rev-b.md)"
assert_contains "$oc_b" "mode: all" "opencode mode preserved"
assert_contains "$oc_b" "  edit: deny" "opencode permission block preserved"
assert_contains "$oc_b" "variant: high" "opencode variant corrected"
assert_not_contains "$oc_b" "library-ref:" "provenance field removed"
assert_not_contains "$oc_b" "tier: standard" "neutral tier field removed"
run bash "$RENDER" --check
assert_eq 0 "$STATUS" "clean after repair"

it "overrides apply with precedence and require a reason"
printf '\n| Scope | Harness | Model | Variant | Reason |\n|---|---|---|---|---|\n| tier:deep | opencode | lib/oc-next | | Newer generation validated locally |\n| agent:rev-a | * | | max | Security reviewer runs hotter |\n| agent:rev-a | claude | lib-claude-vd | | Highest-stakes domain |\n' >> "$MAP"
run bash "$RENDER" --resolve
assert_contains "$(grep '^rev-a .*opencode' <<<"$OUTPUT")" "lib/oc-next" "tier override sets model"
assert_contains "$(grep '^rev-a .*opencode' <<<"$OUTPUT")" "max" "agent wildcard override sets variant"
assert_contains "$(grep '^rev-a .*claude' <<<"$OUTPUT")" "lib-claude-vd" "agent harness override wins"
assert_contains "$(grep '^rev-a .*claude' <<<"$OUTPUT")" "override agent:rev-a" "source names the override"
run bash "$SCRIPTS/doctor.sh" --json
assert_contains "$OUTPUT" "differs from resolved" "doctor reports projection drift once a baseline exists"
run bash "$SCRIPTS/check-adoption.sh"
assert_eq 1 "$STATUS" "adoption gate fails on drift"
run bash "$RENDER"
run bash "$SCRIPTS/check-adoption.sh"
assert_eq 0 "$STATUS" "adoption gate passes after render"
printf '| agent:rev-b | claude | lib-claude-vd | | |\n' >> "$MAP"
before="$(cat .claude/agents/rev-b.md)"
run bash "$RENDER"
assert_eq 1 "$STATUS" "render refuses with a reasonless override"
assert_contains "$OUTPUT" "has no Reason" "missing reason named"
assert_eq "$before" "$(cat .claude/agents/rev-b.md)" "nothing written"
sed -i.bak '$d' "$MAP" && rm -f "$MAP.bak"

it "literal ids restated beside a baseline are a finding"
cp "$MAP" "$PROJ/agents.shared"
printf '%s' "$LEGACY" >> "$MAP"
run bash "$SCRIPTS/doctor.sh" --json
assert_contains "$OUTPUT" "unsupported literal table" "restated literal ids flagged"
cp "$PROJ/agents.shared" "$MAP"

it "banned exact ids are findings wherever they appear"
# shellcheck disable=SC2016 # Literal markdown fixture: backticks are data, not command substitution.
printf '\nBanned models: `lib-claude-vd`, `lib/oc-gone`\n' >> "$MAP"
run bash "$SCRIPTS/doctor.sh" --json
assert_contains "$OUTPUT" "resolves claude to banned model 'lib-claude-vd'" "banned baseline model flagged"
assert_contains "$OUTPUT" "uses banned model 'lib-claude-vd'" "banned projection model flagged"
assert_not_contains "$OUTPUT" "lib-claude-vd-x" "exact match only"
cp "$PROJ/agents.shared" "$MAP"

it "snapshot provenance: hand edits and baseline mismatch are findings"
cp .prdkit/agent-library/tiers.json "$PROJ/snap.saved"
sed -i.bak 's/lib-claude-std/lib-claude-edited/' .prdkit/agent-library/tiers.json && rm -f .prdkit/agent-library/tiers.json.bak
run bash "$RENDER" --check
assert_contains "$OUTPUT" "edited after vendoring" "hand edit detected"
cp "$PROJ/snap.saved" .prdkit/agent-library/tiers.json
sed -i.bak "s/tiers.json@$LIBREF/tiers.json@abcdef1/" "$MAP" && rm -f "$MAP.bak"
run bash "$RENDER" --check
assert_contains "$OUTPUT" "vendored snapshot is from $LIBREF" "baseline/snapshot mismatch detected"
cp "$PROJ/agents.shared" "$MAP"
mv .prdkit/agent-library/tiers.json "$PROJ/snap.away"
run bash "$SCRIPTS/doctor.sh" --json
assert_contains "$OUTPUT" "baseline snapshot .prdkit/agent-library/tiers.json is missing" "missing snapshot is a finding"
mv "$PROJ/snap.away" .prdkit/agent-library/tiers.json
BADLIB="$(mktemp -d)"; track_tmp "$BADLIB"
git -C "$BADLIB" init -q; git -C "$BADLIB" config user.email t@example.com; git -C "$BADLIB" config user.name test
echo '{"deep": { "claude": { "model": "x" }' > "$BADLIB/tiers.json"
git -C "$BADLIB" add tiers.json; git -C "$BADLIB" commit -qm bad
run bash "$RENDER" --refresh-baseline "$BADLIB"
assert_eq 1 "$STATUS" "malformed library tiers JSON fails closed"
assert_contains "$OUTPUT" "not valid tiers JSON" "parse failure named"
assert_eq "$(cat "$PROJ/snap.saved")" "$(cat .prdkit/agent-library/tiers.json)" "existing snapshot untouched"

it "an unmapped tier is a finding, not an improvised model"
def rev-d bespoke
sed -i.bak '$d' "$MAP" && rm -f "$MAP.bak"   # roster row would extend the overrides table
run bash "$RENDER" --check
assert_contains "$OUTPUT" "tier 'bespoke' has no Local tier -> Library tier mapping" "unresolvable tier named"
rm -f .prdkit/agents/rev-d.md
run bash "$RENDER" --check
assert_eq 0 "$STATUS" "clean again"


# --- hardening ---------------------------------------------------------------
cp "$MAP" "$PROJ/agents.ok"
proj_state() { cat .claude/agents/*.md .opencode/agents/*.md .prdkit/agent-library/tiers.json* | cksum; }
# shellcheck disable=SC2012 # ls -l is the portable mode read (stat flags differ on GNU/BSD); names are fixed fixtures.
mode_of() { ls -l "$1" | cut -c1-10; }
presence() { if [ -e "$1" ] || [ -L "$1" ]; then echo present; else echo absent; fi; }
perms_enforced() { # false when running as root or on a filesystem that ignores modes
    local p="$PROJ/ro.probe" ok=0
    : > "$p"; chmod 444 "$p"
    if ( : > "$p" ) 2>/dev/null; then ok=1; fi
    chmod 644 "$p"; rm -f "$p"
    [ "$ok" -eq 0 ]
}

it "a banned id in an override, or the baseline blocks render and --check; nothing is written"
before="$(proj_state)"
# shellcheck disable=SC2016 # Literal markdown fixture: backticks are data, not command substitution.
printf '\nBanned models: `lib/oc-next`\n' >> "$MAP"
run bash "$RENDER"
assert_eq 1 "$STATUS" "render refuses a banned override model"
assert_contains "$OUTPUT" "banned model 'lib/oc-next'" "banned override named"
assert_contains "$OUTPUT" "nothing written" "refusal says nothing was written"
assert_eq "$before" "$(proj_state)" "no projection written (override)"
run bash "$RENDER" --check
assert_eq 1 "$STATUS" "--check fails on a banned override model"
cp "$PROJ/agents.ok" "$MAP"
printf '\nBanned models: lib-claude-std\n' >> "$MAP"
run bash "$RENDER"
assert_eq 1 "$STATUS" "render refuses a banned baseline model"
assert_contains "$OUTPUT" "resolves claude to banned model 'lib-claude-std'" "banned baseline tier named"
assert_eq "$before" "$(proj_state)" "no projection written (baseline)"
run bash "$RENDER" --check
assert_eq 1 "$STATUS" "--check fails on a banned baseline model"
cp "$PROJ/agents.ok" "$MAP"

it "a projection that already uses a banned id is repaired by render, then --check passes"
printf '\nBanned models: lib-claude-gone\n' >> "$MAP"
sed -i.bak 's/^model: .*/model: lib-claude-gone/' .claude/agents/rev-b.md && rm -f .claude/agents/rev-b.md.bak
run bash "$RENDER" --check
assert_eq 1 "$STATUS" "--check fails while the projection uses the banned id"
assert_contains "$OUTPUT" "uses banned model 'lib-claude-gone'" "banned projection named"
run bash "$RENDER"
assert_eq 0 "$STATUS" "render is not blocked by a projection it can repair"
assert_contains "$OUTPUT" "~ .claude/agents/rev-b.md" "projection rewritten"
assert_not_contains "$(cat .claude/agents/rev-b.md)" "lib-claude-gone" "banned id gone"
run bash "$RENDER" --check
assert_eq 0 "$STATUS" "--check passes after the repair"
printf -- '---\nname: hand\nmodel: lib-claude-gone\n---\n\nHand-made agent.\n' > .claude/agents/hand.md
run bash "$RENDER"
assert_eq 1 "$STATUS" "a banned projection the render does not own still fails"
assert_contains "$OUTPUT" "uses banned model 'lib-claude-gone'" "unowned banned projection named"
assert_contains "$OUTPUT" "does not own" "explains why render cannot repair it"
rm -f .claude/agents/hand.md
cp "$PROJ/agents.ok" "$MAP"

it "a Baseline snapshot path outside the checkout is refused"
OUTSIDE="$(mktemp -d)"; track_tmp "$OUTSIDE"
outside_rel="../$(basename "$PROJ")-outside-snap.json"
printf '\nBaseline snapshot: %s\n' "$outside_rel" >> "$MAP"
run bash "$RENDER" --refresh-baseline "$LIB"
assert_eq 1 "$STATUS" "'..' snapshot path refused"
assert_contains "$OUTPUT" "has a '..' segment" "reason named"
assert_eq absent "$(presence "$PROJ/$outside_rel")" "no snapshot written outside the checkout"
assert_eq absent "$(presence "$PROJ/$outside_rel.ref")" "no provenance written outside the checkout"
run bash "$RENDER" --check
assert_eq 1 "$STATUS" "--check reports the unsafe path"
assert_contains "$OUTPUT" "must be a relative path inside the repository" "check finding names the rule"
cp "$PROJ/agents.ok" "$MAP"
printf '\nBaseline snapshot: %s/abs-snap.json\n' "$OUTSIDE" >> "$MAP"
run bash "$RENDER" --refresh-baseline "$LIB"
assert_eq 1 "$STATUS" "absolute snapshot path refused"
assert_contains "$OUTPUT" "is absolute" "absolute reason named"
assert_eq "" "$(ls -A "$OUTSIDE")" "nothing written at the absolute path"
cp "$PROJ/agents.ok" "$MAP"
ln -s "$OUTSIDE" .prdkit/linked
printf '\nBaseline snapshot: .prdkit/linked/tiers.json\n' >> "$MAP"
run bash "$RENDER" --refresh-baseline "$LIB"
assert_eq 1 "$STATUS" "snapshot path through a symlinked directory refused"
assert_contains "$OUTPUT" "resolves outside the repository" "symlink escape named"
assert_eq "" "$(ls -A "$OUTSIDE")" "nothing written through the symlink"
rm -f .prdkit/linked
cp "$PROJ/agents.ok" "$MAP"

it "an unsafe default snapshot path is not a finding until the map opts in"
cp "$PROJ/agents.base" "$MAP"
[ ! -e .prdkit/agent-library ] || mv .prdkit/agent-library .prdkit/agent-library.keep
ln -s "$OUTSIDE" .prdkit/agent-library
run bash "$RENDER" --check
assert_not_contains "$OUTPUT" "must be a relative path inside the repository" "unconfigured map does not inspect the default snapshot path"
run bash "$RENDER" --refresh-baseline "$LIB"
assert_eq 1 "$STATUS" "refresh still refuses the unsafe default path"
assert_eq "" "$(ls -A "$OUTSIDE")" "nothing written through the default-path symlink"
rm -f .prdkit/agent-library
[ ! -e .prdkit/agent-library.keep ] || mv .prdkit/agent-library.keep .prdkit/agent-library
cp "$PROJ/agents.ok" "$MAP"

it "--library-ref must resolve to a commit and is never parsed as a git option"
run bash "$RENDER" --refresh-baseline "$LIB" --library-ref "--output=$PROJ/injected"
assert_eq 2 "$STATUS" "option-shaped ref is a usage error"
assert_contains "$OUTPUT" "not an option" "reason named"
assert_eq absent "$(presence "$PROJ/injected")" "no git option took effect"
run bash "$RENDER" --refresh-baseline "$LIB" --library-ref no-such-ref
assert_eq 1 "$STATUS" "unknown ref refused"
assert_contains "$OUTPUT" "is not a commit" "unknown ref named"
run bash "$RENDER" --refresh-baseline "$LIB" --library-ref "$LIBREF"
assert_eq 0 "$STATUS" "a commit ref vendors"
run bash "$RENDER" --check
assert_eq 0 "$STATUS" "clean after vendoring by ref"

it "new files get the umask default mode, existing modes are kept, temp files are removed"
umask 022
T="$PROJ/tmpd"; mkdir -p "$T"
rm -f .claude/agents/rev-c.md
run env TMPDIR="$T" bash "$RENDER"
assert_eq 0 "$STATUS" "render recreates the projection"
assert_eq "-rw-r--r--" "$(mode_of .claude/agents/rev-c.md)" "new projection is 0644 under umask 022"
assert_eq "" "$(ls -A "$T")" "no temp files left after render"
chmod 640 .opencode/agents/rev-c.md
printf '\nStale tail.\n' >> .opencode/agents/rev-c.md
run bash "$RENDER"
assert_contains "$OUTPUT" "~ .opencode/agents/rev-c.md" "drifted projection rewritten"
assert_eq "-rw-r-----" "$(mode_of .opencode/agents/rev-c.md)" "existing projection mode kept"
rm -f .prdkit/agent-library/tiers.json .prdkit/agent-library/tiers.json.ref
run env TMPDIR="$T" bash "$RENDER" --refresh-baseline "$LIB"
assert_eq 0 "$STATUS" "refresh re-vendors"
assert_eq "-rw-r--r--" "$(mode_of .prdkit/agent-library/tiers.json)" "new snapshot is 0644 under umask 022"
assert_eq "-rw-r--r--" "$(mode_of .prdkit/agent-library/tiers.json.ref)" "new provenance file is 0644 under umask 022"
assert_eq "" "$(ls -A "$T")" "no temp files left after refresh"
chmod 640 .prdkit/agent-library/tiers.json
run bash "$RENDER" --refresh-baseline "$LIB"
assert_eq "-rw-r-----" "$(mode_of .prdkit/agent-library/tiers.json)" "existing snapshot mode kept"
chmod 644 .prdkit/agent-library/tiers.json

it "a write failure exits non-zero, claims nothing and leaves no temp files"
if perms_enforced; then
    printf '\nStale tail.\n' >> .claude/agents/rev-a.md
    chmod 444 .claude/agents/rev-a.md
    run env TMPDIR="$T" bash "$RENDER"
    assert_eq 1 "$STATUS" "read-only projection file fails the render"
    assert_contains "$OUTPUT" ".claude/agents/rev-a.md: write failed" "failed file named"
    assert_not_contains "$OUTPUT" "~ .claude/agents/rev-a.md" "no updated claim for the failed file"
    assert_not_contains "$OUTPUT" "✓ Agent projections" "no success summary"
    assert_eq "" "$(ls -A "$T")" "temp files removed after a failed write"
    chmod 644 .claude/agents/rev-a.md
    run bash "$RENDER"
    assert_eq 0 "$STATUS" "render repairs once writable"
    rm -f .opencode/agents/rev-b.md
    chmod 555 .opencode/agents
    run env TMPDIR="$T" bash "$RENDER"
    assert_eq 1 "$STATUS" "read-only agents directory fails the render"
    assert_not_contains "$OUTPUT" "+ .opencode/agents/rev-b.md" "no created claim"
    assert_not_contains "$OUTPUT" "✓ Agent projections" "no success summary"
    assert_eq absent "$(presence .opencode/agents/rev-b.md)" "no partial projection left"
    assert_eq "" "$(ls -A "$T")" "temp files removed after a failed create"
    chmod 755 .opencode/agents
    chmod 444 .prdkit/agent-library/tiers.json
    run env TMPDIR="$T" bash "$RENDER" --refresh-baseline "$LIB"
    assert_eq 1 "$STATUS" "read-only snapshot fails the refresh"
    assert_not_contains "$OUTPUT" "✓ Vendored" "no vendored claim"
    assert_eq "" "$(ls -A "$T")" "temp files removed after a failed refresh"
    chmod 644 .prdkit/agent-library/tiers.json
    run bash "$RENDER"
    assert_eq 0 "$STATUS" "render recreates the projection once writable"
else
    echo "  (write-failure cases skipped: file modes are not enforced for this user)"
fi
run bash "$RENDER" --check
assert_eq 0 "$STATUS" "clean at the end"

# --- fail-closed definitions and projection ownership ------------------------------------
P2="$(make_inited_project --with agent-tiers)"; track_tmp "$P2"
R2="$P2/.prdkit/scripts/bash/render-agents.sh"
MAP2="$P2/.prdkit/memory/agents.md"
cd "$P2" || exit 1
mkdir -p .prdkit/agents .opencode/agents .claude/agents
def2() { # name [harnesses line]
    {
        printf -- '---\nname: %s\ndomain: Review\ntier: deep\ndescription: %s reviewer.\n' "$1" "$1"
        [ -z "${2:-}" ] || printf '%s\n' "$2"
        printf -- '---\n\n# %s\n\nReview carefully.\n' "$1"
    } > ".prdkit/agents/$1.md"
    grep -qF "| $1 |" "$MAP2" || printf '| Review | %s | test |\n' "$1" >> "$MAP2"
}
def2 own-a
def2 own-b '# harnesses limited below'
printf -- '---\nname: hand-made\ndescription: hand-made.\nmodel: whatever\n---\n\nHand body.\n' > .claude/agents/hand-made.md
printf '\nTier baseline: agent-library tiers.json@%s\n' "$LIBREF" >> "$MAP2"
run bash "$R2" --refresh-baseline "$LIB"
assert_eq 0 "$STATUS" "baseline vendored for the ownership fixture"

it "an unowned projection is a finding once a baseline is declared"
run bash "$R2" --check
assert_eq 1 "$STATUS" "check fails on an unowned projection"
assert_contains "$OUTPUT" ".claude/agents/hand-made.md is unowned (no neutral definition .prdkit/agents/hand-made.md)" "finding names the file and cause"
run bash "$P2/.prdkit/scripts/bash/check-adoption.sh"
assert_eq 1 "$STATUS" "adoption gate fails"
assert_contains "$OUTPUT" "hand-made.md is unowned" "adoption gate names it"
run bash "$P2/.prdkit/scripts/bash/doctor.sh"
assert_eq 1 "$STATUS" "doctor fails"
run bash "$R2"
assert_eq 1 "$STATUS" "render reports what it cannot fix"
assert_contains "$OUTPUT" "hand-made.md is unowned" "render names the unowned projection"
assert_contains "$(cat .claude/agents/own-a.md)" "model: lib-claude-deep" "owned projections were still rendered"
assert_contains "$(cat .claude/agents/hand-made.md)" "model: whatever" "the unowned file is not touched"
# shellcheck disable=SC2016 # Literal markdown fixture: backticks are data, not command substitution.
printf '\nHand-owned agents: `hand-made`, other-tool\n' >> "$MAP2"
run bash "$R2" --check
assert_eq 0 "$STATUS" "Hand-owned agents: opt-out clears it"
run bash "$P2/.prdkit/scripts/bash/check-adoption.sh"
assert_eq 0 "$STATUS" "adoption gate clean with the opt-out"

it "a harnesses: list that excludes an existing projection leaves it unowned"
def2 own-b 'harnesses: [opencode]'
run bash "$R2" --check
assert_eq 1 "$STATUS" "narrowed definition's old projection is a finding"
assert_contains "$OUTPUT" ".claude/agents/own-b.md is unowned (its neutral definition's harnesses: list excludes claude)" "cause named"
rm .claude/agents/own-b.md
run bash "$R2" --check
assert_eq 0 "$STATUS" "clean once the excluded projection is removed"
def2 own-b 'harnesses: ["opencode", claude]   # both, quoted and commented'
run bash "$R2"
assert_eq 0 "$STATUS" "quoted names and a trailing comment are a valid list"
assert_file .claude/agents/own-b.md "claude projection rendered again"

it "a malformed harnesses: line is a finding and blocks the render"
for bad in 'harnesses: opencode|must be a bracketed list' 'harnesses: []|is an empty list' 'harnesses: [opencode, codex]|unknown harness '"'"'codex'"'"''; do
    def2 own-b "${bad%%|*}"
    run bash "$R2" --check
    assert_eq 1 "$STATUS" "check fails: ${bad%%|*}"
    assert_contains "$OUTPUT" "${bad#*|}" "finding explains: ${bad%%|*}"
    run bash "$P2/.prdkit/scripts/bash/check-adoption.sh"
    assert_eq 1 "$STATUS" "adoption gate fails: ${bad%%|*}"
    run bash "$P2/.prdkit/scripts/bash/doctor.sh"
    assert_eq 1 "$STATUS" "doctor fails: ${bad%%|*}"
    sed -i.bak 's/^model: .*/model: drifted/' .claude/agents/own-a.md && rm -f .claude/agents/own-a.md.bak
    before="$(cat .claude/agents/*.md .opencode/agents/*.md | cksum)"
    run bash "$R2"
    assert_eq 1 "$STATUS" "render refuses: ${bad%%|*}"
    assert_contains "$OUTPUT" "nothing written" "render fails closed: ${bad%%|*}"
    assert_eq "$before" "$(cat .claude/agents/*.md .opencode/agents/*.md | cksum)" "no projection written: ${bad%%|*}"
done
def2 own-b
run bash "$R2"
assert_eq 0 "$STATUS" "valid definitions render again"

it "the renderer owns a single-line description"
sed -i.bak 's/^description: .*/description: "Hand-tuned wording."/' .opencode/agents/own-a.md && rm -f .opencode/agents/own-a.md.bak
run bash "$R2" --check
assert_eq 1 "$STATUS" "description drift fails the check"
assert_contains "$OUTPUT" ".opencode/agents/own-a.md description differs from the neutral definition" "drift named"
run bash "$R2"
assert_eq 0 "$STATUS" "render repairs the description"
assert_contains "$(cat .opencode/agents/own-a.md)" "description: own-a reviewer." "neutral description written"
sed -i.bak 's/^description: .*/description: "own-a reviewer, reworded."/' .prdkit/agents/own-a.md && rm -f .prdkit/agents/own-a.md.bak
run bash "$R2"
assert_contains "$(cat .claude/agents/own-a.md)" 'description: "own-a reviewer, reworded."' "neutral change reaches claude"
assert_contains "$(cat .opencode/agents/own-a.md)" 'description: "own-a reviewer, reworded."' "neutral change reaches opencode"
printf -- '---\nname: own-a\ndescription: >-\n  folded line one\n  folded line two\ntools: Read\nmodel: lib-claude-deep\n---\n\n# own-a\n\nReview carefully.\n' > .claude/agents/own-a.md
run bash "$R2"
assert_eq 0 "$STATUS" "a block-scalar projection description is replaced"
claude_a="$(cat .claude/agents/own-a.md)"
assert_not_contains "$claude_a" "folded line" "continuation lines dropped with the old description"
assert_contains "$claude_a" "tools: Read" "the following key survives"
run bash "$R2" --check
assert_eq 0 "$STATUS" "clean after the block-scalar repair"
printf -- '---\nname: own-a\ndomain: Review\ntier: deep\ndescription: |\n  Block description stays project-owned.\n---\n\n# own-a\n\nReview carefully.\n' > .prdkit/agents/own-a.md
run bash "$R2" --check
assert_eq 0 "$STATUS" "a block-scalar neutral description is not compared"
printf -- '---\nname: own-c\ndomain: Review\ntier: deep\ndescription: |\n  Reviews the first concern.\n\n  Then the second.\ntools: Read\n---\n\n# own-c\n\nReview carefully.\n' > .prdkit/agents/own-c.md
grep -qF '| own-c |' "$MAP2" || printf '| Review | own-c | test |\n' >> "$MAP2"
run bash "$R2"
assert_eq 0 "$STATUS" "a new projection renders from a block-scalar description"
for proj in .claude/agents/own-c.md .opencode/agents/own-c.md; do
    assert_contains "$(cat "$proj")" "$(printf 'description: |\n  Reviews the first concern.\n\n  Then the second.\nm')" "$proj copies the whole block, blank line included"
    assert_not_contains "$(cat "$proj")" "tools: Read" "$proj stops at the next neutral key"
done
before="$(cat .claude/agents/own-c.md .opencode/agents/own-c.md | cksum)"
run bash "$R2"
assert_eq "$before" "$(cat .claude/agents/own-c.md .opencode/agents/own-c.md | cksum)" "a second render leaves the block alone"
run bash "$R2" --check
assert_eq 0 "$STATUS" "check is clean after creating from a block description"
cd "$PROJ" || exit 1

# --- optional projection fields -----------------------------------------------------------
projection_table() {
    printf '\n| Projection tier | Claude effort | OpenCode permissions | OpenCode preamble |\n|---|---|---|---|\n'
    printf '%s\n' "$@"
}
same_bytes() {
    if cmp -s "$1" "$2"; then _ok "$3"; else _no "$3" "$(diff -u "$1" "$2")"; fi
}
it "without projection settings, new renders match the legacy bytes and native fields stay untouched"
cp "$MAP" "$PROJ/agents.before-extras"
# Golden bytes from the legacy writer (including the generated comment and separate variant).
cat > "$PROJ/legacy-oc" <<'EOF'
---
# Generated from .prdkit/agents/rev-a.md by render-agents.sh; model/variant resolve from .prdkit/memory/agents.md. Edit the neutral definition, then re-render.
name: rev-a
description: rev-a reviewer.
mode: subagent
model: lib/oc-next
variant: max
---

# rev-a

Review carefully.

<!-- LOCAL OVERLAY -->
Project rubric for rev-a.
EOF
sed -e '/^mode: subagent$/d' -e 's@^model: lib/oc-next$@model: lib-claude-vd@' \
    -e '/^variant: max$/d' "$PROJ/legacy-oc" > "$PROJ/legacy-claude"
rm -f .opencode/agents/rev-a.md .claude/agents/rev-a.md
run bash "$RENDER"
assert_eq 0 "$STATUS"
same_bytes "$PROJ/legacy-oc" .opencode/agents/rev-a.md "legacy OpenCode creation is byte-identical"
same_bytes "$PROJ/legacy-claude" .claude/agents/rev-a.md "legacy Claude creation is byte-identical"

cat > .opencode/agents/rev-a.md <<'EOF'
---
name: rev-a
description: rev-a reviewer.
model: lib/oc-next
variant: max
# Native policies belong to the project unless it opts in.
permission:
  shell:
    "*": deny
    "status *": allow

"permissions":
- action: edit
  resource: "*"
  effect: deny
# Keep this neighboring key and comment.
mode: all
---

<!-- Generated locally -->

# rev-a

Review carefully.

<!-- LOCAL OVERLAY -->
Project rubric for rev-a.
EOF
awk '/^model:/ { print "effort: low  # project-owned" } { print }' "$PROJ/legacy-claude" > .claude/agents/rev-a.md
cp .opencode/agents/rev-a.md "$PROJ/hand-oc"
cp .claude/agents/rev-a.md "$PROJ/hand-claude"
{
    printf '\n```text\n'
    projection_table '| deep | invalid-example | * | Example, not a setting |'
    printf '```\n\n<!--\n'
    projection_table '| deep | other-example | * | Also not a setting |'
    printf '%s\n' '-->'
} >> "$MAP"
run bash "$RENDER" --check
assert_eq 0 "$STATUS" "sample tables and undeclared native fields are ignored"
run bash "$RENDER"
assert_eq 0 "$STATUS"
same_bytes "$PROJ/hand-oc" .opencode/agents/rev-a.md "both kinds of native permission block untouched when undeclared"
same_bytes "$PROJ/hand-claude" .claude/agents/rev-a.md "native effort untouched when undeclared"

it "an opted-in tier refreshes effort, native permissions, combined model and preamble"
# Complete the manual migration first: V2 derives the ID from the filename.
sed '/^name: rev-a$/d' "$PROJ/hand-oc" > .opencode/agents/rev-a.md
# Earlier write-failure coverage may have regenerated rev-b; give it explicit native policy.
if ! grep -q '^permission:' .opencode/agents/rev-b.md; then
    sed '/^variant: high$/a\
permission:\
  edit: deny
' .opencode/agents/rev-b.md > "$PROJ/old-permission"
    cp "$PROJ/old-permission" .opencode/agents/rev-b.md
fi
# shellcheck disable=SC2016 # Literal Markdown preamble, including backticks.
projection_table \
    '| * | | | Follow the shared rubric. |' \
    '| deep | high | read, grep | First follow `local` guidance; keep \n literal. |' \
    '| fast | | deny | |' >> "$MAP"
cp "$MAP" "$PROJ/agents.extras"
cp .claude/agents/rev-b.md "$PROJ/untouched-claude"
rm -f .opencode/agents/rev-c.md
run bash "$RENDER" --check --json
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "effort differs" "effort drift reported on its own"
assert_contains "$OUTPUT" "model 'lib/oc-next' differs from resolved 'lib/oc-next#max'" "combined-model drift uses the resolved agent override"
assert_contains "$OUTPUT" "permissions frontmatter or legacy variant" "permission drift reported"
assert_contains "$OUTPUT" "prompt body differs" "preamble drift reported"
run bash "$RENDER"
assert_eq 0 "$STATUS"
cat > "$PROJ/native-oc" <<'EOF'
---
description: rev-a reviewer.
model: lib/oc-next#max
# Native policies belong to the project unless it opts in.
permissions:
  - action: "*"
    resource: "*"
    effect: deny
  - action: "read"
    resource: "*"
    effect: allow
  - action: "grep"
    resource: "*"
    effect: allow

# Keep this neighboring key and comment.
mode: all
---

<!-- Generated locally -->

First follow `local` guidance; keep \n literal.

# rev-a

Review carefully.

<!-- LOCAL OVERLAY -->
Project rubric for rev-a.
EOF
same_bytes "$PROJ/native-oc" .opencode/agents/rev-a.md "replace both owned blocks whole and retain neighboring fields and marker"
assert_contains "$(cat .claude/agents/rev-a.md)" "effort: high" "Claude effort is rendered"
same_bytes "$PROJ/untouched-claude" .claude/agents/rev-b.md "the other Claude tier is untouched"
oc_b="$(cat .opencode/agents/rev-b.md)"
assert_contains "$oc_b" "Follow the shared rubric." "global preamble reaches unconfigured tier"
assert_contains "$oc_b" "variant: high" "preamble alone does not migrate the tier to native V2"
assert_contains "$oc_b" "  edit: deny" "preamble alone does not adopt permissions"
oc_c="$(cat .opencode/agents/rev-c.md)"
assert_contains "$oc_c" "model: lib/oc-std#high" "local tier gets mapped baseline variant"
assert_contains "$oc_c" "effect: deny" "deny-only policy is supported on creation"
assert_not_contains "$oc_c" "effect: allow" "deny-only policy has no exception"
assert_not_contains "$oc_c" "name:" "fresh V2 projection uses an ID derived from its path"
run bash "$RENDER" --resolve --json
assert_contains "$OUTPUT" '"model":"lib/oc-next","variant":"max"' "resolution output remains logical, with separate model and variant"
run bash "$RENDER" --check
assert_eq 0 "$STATUS" "check is clean after projection"
run bash "$RENDER"
assert_contains "$OUTPUT" "0 created, 0 updated, 6 unchanged" "render is idempotent"

it "check notices independent edits to managed effort, permission rules and preamble"
sed 's/^effort: high$/effort: low/' .claude/agents/rev-a.md > "$PROJ/drift"
cp "$PROJ/drift" .claude/agents/rev-a.md
sed 's/^    effect: deny$/    effect: allow/' "$PROJ/native-oc" > .opencode/agents/rev-a.md
sed '/^Follow the shared rubric\.$/d' .opencode/agents/rev-c.md > "$PROJ/drift"
cp "$PROJ/drift" .opencode/agents/rev-c.md
run bash "$RENDER" --check
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" ".claude/agents/rev-a.md effort differs"
assert_contains "$OUTPUT" ".opencode/agents/rev-a.md native model/permissions frontmatter"
assert_contains "$OUTPUT" ".opencode/agents/rev-c.md prompt body differs"
run bash "$RENDER"
assert_eq 0 "$STATUS"
same_bytes "$PROJ/native-oc" .opencode/agents/rev-a.md "edited permission policy is repaired"
run bash "$RENDER" --check
assert_eq 0 "$STATUS"

it "invalid projection settings are findings and block all writes"
sed 's/^effort: high$/effort: low/' .claude/agents/rev-a.md > "$PROJ/drift"
cp "$PROJ/drift" .claude/agents/rev-a.md
for bad_row in \
    '| deep | too-high | | |' \
    '| deep | n/a | read | |' \
    '| deep | - | read | |' \
    '| deep | high | none | |' \
    '| deep | high | n/a | |' \
    '| deep | high | read, none | |' \
    '| deep | high | read | Begin here <!-- note --> please. |' \
    '| deep | high | | Begin here <!-- unclosed |' \
    '| deep | low | read, * | |' \
    '| deep | low | | preamble | extra cell |' \
    '| * | high | | |' \
    '| deep | | | |' \
    '| unidentified | high | | |'; do
    cp "$PROJ/agents.before-extras" "$MAP"
    projection_table "$bad_row" >> "$MAP"
    run bash "$RENDER" --check --json
    assert_eq 1 "$STATUS" "invalid row: $bad_row"
    assert_contains "$OUTPUT" "Tier map line" "line-numbered finding"
    run bash "$RENDER"
    assert_eq 1 "$STATUS"
    assert_contains "$OUTPUT" "nothing written"
    same_bytes "$PROJ/drift" .claude/agents/rev-a.md "would-be update remains unwritten"
done
cp "$PROJ/agents.extras" "$MAP"
printf '%s\n' '| deep | low | | Duplicate |' >> "$MAP"
run bash "$RENDER" --check
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "duplicate Projection tier deep"
run bash "$SCRIPTS/doctor.sh" --json
assert_contains "$OUTPUT" "duplicate Projection tier deep" "doctor shares the projection settings lint"

it "write and check both refuse a CRLF projection table without changing files"
cp "$PROJ/agents.before-extras" "$MAP"
projection_table '| deep | high | read | Follow the local rubric. |' |
    awk '{ printf "%s\r\n", $0 }' >> "$MAP"
before="$(proj_state)"
for mode in --check --write; do
    if [ "$mode" = --check ]; then run bash "$RENDER" --check --json
    else run bash "$RENDER" --json; fi
    assert_eq 1 "$STATUS" "$mode rejects CRLF"
    assert_contains "$OUTPUT" "Invalid tier map: expected non-empty LF-terminated text"
    assert_eq "$before" "$(proj_state)" "$mode leaves all projections unchanged"
done

it "native opt-in refuses V1-only keys, even when quoted, before writing to either harness"
cp "$PROJ/agents.extras" "$MAP"
sed '/^name:/a\
maxSteps: 2\
"disable": true\
tools: {edit: false}
' "$PROJ/hand-oc" > "$PROJ/v1-options"
cp "$PROJ/v1-options" .opencode/agents/rev-a.md
before="$(proj_state)"
run bash "$RENDER" --check --json
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" ".opencode/agents/rev-a.md has OpenCode V1-only frontmatter keys: name, maxSteps, disable, tools"
run bash "$RENDER"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "nothing written"
same_bytes "$PROJ/v1-options" .opencode/agents/rev-a.md "legacy step cap and other settings remain untouched"
assert_eq "$before" "$(proj_state)" "legacy blocker prevents changes to any projection"

it "native replacement refuses a YAML anchor in permissions used by an unrelated header"
cat > "$PROJ/with-alias" <<'EOF'
---
description: Reviewer with a shared scalar.
mode: subagent
model: lib/oc-next#max
permissions:
  - action: read
    resource: &scope "*"
    effect: allow
request:
  headers:
    x-review-scope: *scope
---

Review only.
EOF
cp "$PROJ/with-alias" .opencode/agents/rev-a.md
before="$(proj_state)"
run bash "$RENDER" --check --json
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" ".opencode/agents/rev-a.md may use YAML anchors or aliases"
run bash "$RENDER"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "nothing written"
same_bytes "$PROJ/with-alias" .opencode/agents/rev-a.md "both the anchor and its alias survive"
assert_eq "$before" "$(proj_state)" "YAML blocker prevents changes to any projection"
for node in 'request: {<<: *defaults}' 'request: {label: !!str &label review}' \
    'request: [*defaults]' '<<: *defaults'; do
    # Keep the tested token as the only reference (an unresolved alias is also unsafe).
    printf '%s\n' '---' 'model: lib/oc-next#max' "$node" '---' '' 'Review only.' > "$PROJ/merge"
    cp "$PROJ/merge" .opencode/agents/rev-a.md
    run bash "$RENDER" --check
    assert_contains "$OUTPUT" "YAML anchors or aliases" "$node is not a scalar literal"
    run bash "$RENDER"
    assert_eq 1 "$STATUS"
    same_bytes "$PROJ/merge" .opencode/agents/rev-a.md "flow/reference fixture unchanged"
done
cp "$PROJ/native-oc" .opencode/agents/rev-a.md
run bash "$RENDER"
assert_eq 0 "$STATUS" "a plain opt-in file still renders"

it "node scanning ignores quoted and plain text, globs, and block-scalar descriptions"
for fixture in glob ampersand markdown plain; do
    {
        printf '%s\n' '---' 'mode: subagent' 'model: lib/oc-next#max'
        case "$fixture" in
            glob) printf '%s\n' 'permissions:' '  - action: read' '    resource: "notes *draft*.md"' '    effect: allow' ;;
            ampersand) printf '%s\n' 'request:' "  headers: {x-label: \"review &follow-up\", note: 'a ''quoted'' *word'}" ;;
            markdown) printf '%s\n' 'description: >-' '  Keep *short notes* in the report.' '  *literal paragraph*' ;;
            plain) printf '%s\n' 'request:' '  headers:' '    x-label: review &follow-up' '      *continued plain text*' ;;
        esac
        printf '%s\n' '---' '' 'Review only.'
    } > .opencode/agents/rev-a.md
    run bash "$RENDER" --check
    assert_not_contains "$OUTPUT" "YAML anchors or aliases" "$fixture is scalar text"
    run bash "$RENDER"
    assert_eq 0 "$STATUS" "$fixture permits replacement"
    run bash "$RENDER" --check
    assert_eq 0 "$STATUS" "$fixture checks clean after replacement"
done

it "the opt-in cannot hide a banned base model id behind a variant suffix"
cp "$PROJ/agents.extras" "$MAP"
printf '\nBanned models: lib/oc-blocked\n' >> "$MAP"
sed 's@model: lib/oc-next#max@model: lib/oc-blocked#high@' "$PROJ/native-oc" > .opencode/agents/rev-a.md
run bash "$RENDER" --check
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "uses banned model 'lib/oc-blocked'"
run bash "$RENDER"
assert_eq 0 "$STATUS"

it "the base-model ban covers hand-owned V2 projections without opt-in"
cp "$PROJ/agents.before-extras" "$MAP"
printf '\nBanned models: lib/oc-blocked\nHand-owned agents: hand-native\n' >> "$MAP"
cat > .opencode/agents/hand-native.md <<'EOF'
---
description: Project-owned reviewer.
model: lib/oc-blocked#high
permissions:
  - action: "*"
    resource: "*"
    effect: deny
---

Review only.
EOF
cp .opencode/agents/hand-native.md "$PROJ/hand-native"
run bash "$RENDER" --check --json
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" ".opencode/agents/hand-native.md uses banned model 'lib/oc-blocked'"
run bash "$RENDER"
assert_eq 1 "$STATUS" "render reports the hand-owned banned model without repairing it"
same_bytes "$PROJ/hand-native" .opencode/agents/hand-native.md "hand-owned projection stays unchanged"
sed 's@^model: .*@"model" : "lib/oc-blocked#high" # native model@' "$PROJ/hand-native" > .opencode/agents/hand-native.md
run bash "$RENDER" --check --json
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" ".opencode/agents/hand-native.md uses banned model 'lib/oc-blocked'" "quoted native references are also checked"
for style in '>-' '>' '|'; do
    awk -v style="$style" '/^model:/ { print "model: " style " # native model"; print "  " $2; next } { print }' \
        "$PROJ/hand-native" > .opencode/agents/hand-native.md
    for command in check write; do
        if [ "$command" = check ]; then run bash "$RENDER" --check --json; else run bash "$RENDER"; fi
        assert_eq 1 "$STATUS" "$command rejects banned $style block scalar"
        assert_contains "$OUTPUT" ".opencode/agents/hand-native.md uses banned model 'lib/oc-blocked'"
    done
done

it "unsupported model forms fail closed before writes when model bans are configured"
for form in indented flow merge escaped multiline duplicate; do
    case "$form" in
        indented) sed '2,7s/^/  /' "$PROJ/hand-native" ;;
        flow) printf '%s\n' '---' '{model: "lib/oc-blocked#high"}' '---' ;;
        merge) printf '%s\n' '---' 'defaults: &base {model: "lib/oc-blocked#high"}' '<<: *base' '---' ;;
        escaped) printf '%s\n' '---' '"mo\u0064el": "lib/oc-blocked#high"' '---' ;;
        multiline) printf '%s\n' '---' 'model: >-' '  lib/oc-blocked' '  #high' '---' ;;
        duplicate) printf '%s\n' '---' 'model: lib/oc-next' 'model: lib/oc-blocked#high' '---' ;;
    esac > .opencode/agents/hand-native.md
    cp .opencode/agents/hand-native.md "$PROJ/unverifiable"
    before="$(proj_state)"
    for command in check write; do
        if [ "$command" = check ]; then run bash "$RENDER" --check --json; else run bash "$RENDER"; fi
        assert_eq 1 "$STATUS" "$command refuses $form"
        assert_contains "$OUTPUT" ".opencode/agents/hand-native.md line " "$form finding names file and line"
        assert_contains "$OUTPUT" "model reference could not be verified"
    done
    same_bytes "$PROJ/unverifiable" .opencode/agents/hand-native.md "$form stays unchanged"
    assert_eq "$before" "$(proj_state)" "$form blocks all writes"
done
rm -f .opencode/agents/hand-native.md
# Recreate the migrated fast-tier file without the legacy name emitted by the opt-out.
rm -f .opencode/agents/rev-c.md

it "a native OpenCode projection works without a variant; prejoined model overrides are findings"
cp "$PROJ/agents.extras" "$MAP"
cat > .prdkit/agents/rev-light.md <<'EOF'
---
name: rev-light
tier: light
harnesses: [opencode]
description: Light review.
---

Review carefully.
EOF
printf '%s\n' '| light | | deny | |' >> "$MAP"
run bash "$RENDER"
assert_eq 0 "$STATUS"
assert_eq 'model: lib/oc-light' "$(grep '^model:' .opencode/agents/rev-light.md)"
assert_not_contains "$(cat .opencode/agents/rev-light.md)" "variant:"
printf '\n| Scope | Harness | Model | Variant | Reason |\n|---|---|---|---|---|\n| tier:light | opencode | lib/oc-light#high | | Example |\n' >> "$MAP"
run bash "$RENDER" --check
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "requires a provider/model id and an optional separate variant token"
run bash "$RENDER"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" "nothing written"

it "a kit-source run refuses instead of treating the kit checkout as the project"
KIT="$(mktemp -d)"; track_tmp "$KIT"
cp -R "$PK_ROOT/scripts" "$KIT/scripts"
git -C "$KIT" init -q
for script in render-agents.sh check-adoption.sh status.sh; do
    if [ "$script" = render-agents.sh ]; then run bash "$KIT/scripts/$script" --check; else run bash "$KIT/scripts/$script"; fi
    assert_eq 2 "$STATUS" "$script refuses a root without .prdkit/"
    assert_contains "$OUTPUT" "has no .prdkit/" "$script names the cause"
done
run bash "$KIT/scripts/render-agents.sh" --refresh-baseline "$LIB"
assert_eq 2 "$STATUS" "refresh-baseline refuses before writing"
assert_eq "" "$(find "$KIT" -path '*/.prdkit*' -print)" "nothing written into the kit checkout"

finish
