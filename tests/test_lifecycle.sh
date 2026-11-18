#!/usr/bin/env bash
# Project-owned stage ordering, validated through installed consumers, including upgrade.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
SCRIPTS="$PROJ/.prdkit/scripts/bash"
mkdir -p specs/product/journeys specs/product/lifecycle
cat > specs/product.md <<'MD'
# Demo

| Area | Idea (now) | Experimental | Stable |
|------|------------|--------------|--------|
| Use | | J-01 | J-02 |

[Lifecycle](product/lifecycle.md), [qualities](product/qualities.md),
[journeys](product/journeys/j-01-try.md), [share](product/journeys/j-02-share.md).
MD
printf '# J-01 Try (hypothesis, from: experimental)\n' > specs/product/journeys/j-01-try.md
printf '# J-02 Share (hypothesis, from: stable)\n' > specs/product/journeys/j-02-share.md
printf '# Qualities\n\n- **Q-01 Reliable** (hypothesis, from: Stable): measurable.\n' > specs/product/qualities.md
cat > specs/product/lifecycle.md <<'MD'
# Demo — lifecycle

**Stages**: Idea > Experimental > Stable
**Now**: Idea since 2026-11-01 · **Next**: Experimental

## Stable

[Detail](lifecycle/stable.md).
MD
printf '# Stable\n\n**Now**: Not a canonical declaration\n' > specs/product/lifecycle/stable.md

it "three owner-selected stages drive status, bounds and doctor from the same order"
run bash "$SCRIPTS/doctor.sh"
assert_eq 0 "$STATUS" "custom lifecycle is accepted"
assert_not_contains "$OUTPUT" "names no stage" "custom from: markers are known"
assert_not_contains "$OUTPUT" "Q-01 at" "future quality needs no current allocation"
assert_not_contains "$OUTPUT" "shows J-" "custom journey columns agree"
run bash "$SCRIPTS/status.sh"
assert_eq 0 "$STATUS" "custom status succeeds"
assert_contains "$OUTPUT" "Stage: Idea; next: Experimental" "current and next preserve names"
assert_contains "$OUTPUT" "J-01 (experimental)" "experimental is later than idea"
assert_contains "$OUTPUT" "Q-01 (stable)" "stable is later than idea"
run bash "$SCRIPTS/bounds.sh" --all
assert_eq 0 "$STATUS" "custom bounds succeeds"
assert_contains "$OUTPUT" $'Qualities:\n- none\nLater stages' "the future quality is not current"
assert_contains "$OUTPUT" "Q-01 Reliable (from: stable;" "bounds keeps the stage marker"

it "owner transitions change classification without renaming source vocabulary"
cat > specs/product/lifecycle.md <<'MD'
# Demo — lifecycle
**Stages**: Idea > Experimental > Stable
**Now**: Experimental (since 2026-11-02)
**Next**: Stable
MD
run bash "$SCRIPTS/status.sh"
assert_eq 0 "$STATUS" "experimental status succeeds"
assert_contains "$OUTPUT" "Stage: Experimental; next: Stable" "separate fields work"
assert_not_contains "$OUTPUT" "J-01 (experimental)" "experimental is now reached"
assert_contains "$OUTPUT" "Q-01 (stable)" "stable is still later"
printf '**Stages**: Idea > Experimental > Stable\n**Now**: Stable\n' > specs/product/lifecycle.md
run bash "$SCRIPTS/bounds.sh" --all
assert_eq 0 "$STATUS" "terminal stage can omit Next"
assert_contains "$OUTPUT" $'Qualities:\n- Q-01 Reliable (specs/product/qualities.md)' "stable quality is current"
assert_not_contains "$OUTPUT" "Later stages" "nothing is after the last stage"

it "multiword names, shared prefixes, digits and hyphens match whole names"
printf '**Stages**: Local > Local trial 2 > Long-term support\n**Now**: Local trial 2; since 2026-11-03 · **Next**: Long-term support\n' > specs/product/lifecycle.md
printf '# J-01 Try (hypothesis, from: LOCAL   trial 2)\n' > specs/product/journeys/j-01-try.md
printf '# J-02 Share (hypothesis, from: Long-term support)\n' > specs/product/journeys/j-02-share.md
printf '# Qualities\n\n- **Q-01 Reliable** (hypothesis, from: Long-term support): measurable.\n' > specs/product/qualities.md
run bash "$SCRIPTS/status.sh" --json
assert_eq 0 "$STATUS" "multiword JSON status succeeds"
assert_contains "$OUTPUT" 'Local trial 2' "longest whole name survives"
assert_contains "$OUTPUT" 'J-02 (long-term support)' "hyphenated custom name is ranked"
assert_not_contains "$OUTPUT" 'J-01 (local trial 2)' "case and whitespace normalize"
run bash "$SCRIPTS/bounds.sh" --all
assert_contains "$OUTPUT" 'Q-01 Reliable (from: long-term support;' "bounds uses the same name"

# Every invalid case must be visible in doctor and must stop both derived lists, including JSON.
invalid() {
    local expected="$1"
    run bash "$SCRIPTS/doctor.sh"
    assert_eq 1 "$STATUS" "doctor rejects $expected"
    assert_contains "$OUTPUT" "$expected" "doctor explains $expected"
    run bash "$SCRIPTS/status.sh" --json
    assert_eq 1 "$STATUS" "status rejects $expected"
    assert_contains "$OUTPUT" "Lifecycle classification unavailable" "status refuses classification"
    assert_not_contains "$OUTPUT" '"stage_now"' "no successful status JSON"
    run bash "$SCRIPTS/bounds.sh" --all
    assert_eq 1 "$STATUS" "bounds rejects $expected"
    assert_not_contains "$OUTPUT" "Qualities:" "no misleading current bounds"
}
it "malformed declarations and unknown values never fall back to defaults"
for declaration in '' 'Idea >' '> Stable' 'Idea >> Stable' 'Idea, Stable' 'Idea -> Stable' 'Idea > <Stable>'; do
    printf '**Stages**: %s\n**Now**: Idea\n' "$declaration" > specs/product/lifecycle.md
    invalid 'stage'
done
printf '**Stages**: Idea > Stable > idea\n**Now**: Idea\n' > specs/product/lifecycle.md
invalid 'duplicate stage'
printf '**Stages**: Local trial > local   TRIAL\n**Now**: Local trial\n' > specs/product/lifecycle.md
invalid 'duplicate stage'
printf '**Stages** = Idea > Stable\n**Now**: Idea\n' > specs/product/lifecycle.md
invalid 'needs **Stages**'
printf '**Stages**: Idea > Stable\n**Stages**: Idea > Stable\n**Now**: Idea\n' > specs/product/lifecycle.md
invalid 'declares Stages more than once'
printf '**Stages**: Idea > Stable\n**Now**: Idea extra\n' > specs/product/lifecycle.md
invalid "needs '**Now**"
printf '**Stages**: Idea > Stable\n**Now**: Idea\n**Next**: Unknown\n' > specs/product/lifecycle.md
invalid 'unknown Next stage'
printf '**Stages**: Idea > Stable\n**Now**: Stable · **Next**: Idea\n' > specs/product/lifecycle.md
invalid 'needs Next to follow Now'
printf '**Stages**: Idea > Stable\n**Now**: Idea · **Next**: Idea\n' > specs/product/lifecycle.md
invalid 'needs Next to follow Now'
printf '**Stages**: Idea > Stable\n**Now**: Idea · **Now**: Stable\n' > specs/product/lifecycle.md
invalid 'declares Now more than once'

it "unknown or empty markers stay visible instead of matching a valid prefix"
printf '**Stages**: Idea > Stable\n**Now**: Idea\n' > specs/product/lifecycle.md
printf '# J-01 Try (hypothesis, from: Stable extra)\n' > specs/product/journeys/j-01-try.md
invalid 'from: stable extra'
printf '# J-01 Try (hypothesis, from: )\n' > specs/product/journeys/j-01-try.md
invalid 'from: (empty)'

it "defaults and the General availability alias remain usable without a declaration"
printf '**Now**: MVP since 2026-11-01 · **Next**: General availability\n' > specs/product/lifecycle.md
printf '# J-01 Try (hypothesis, from: Paid preview)\n' > specs/product/journeys/j-01-try.md
printf '# J-02 Share (hypothesis, from: General availability)\n' > specs/product/journeys/j-02-share.md
printf '# Qualities\n\n- **Q-01 Reliable** (hypothesis, from: ga): measurable.\n' > specs/product/qualities.md
run bash "$SCRIPTS/status.sh"
assert_eq 0 "$STATUS" "default status succeeds"
assert_contains "$OUTPUT" "Stage: MVP; next: General availability" "default alias and date note"
assert_contains "$OUTPUT" "J-01 (paid preview)" "paid preview keeps its built-in place"
run bash "$SCRIPTS/bounds.sh" --all
assert_contains "$OUTPUT" "Q-01 Reliable (from: ga;" "default quality is later"

it "examples do not declare stages or current state"
cat > specs/product/lifecycle.md <<'MD'
# Demo — lifecycle
<!--
**Stages**: Invalid > Invalid
**Now**: Invalid
-->
````markdown
**Stages**: Invalid > Invalid
```
**Now**: Invalid
````
~~~markdown
**Stages**: Invalid > Invalid
**Now**: Invalid
~~~
    **Stages**: Invalid > Invalid
**Now**: MVP · **Next**: GA
MD
run bash "$SCRIPTS/status.sh"
assert_eq 0 "$STATUS" "comment and fence examples are ignored"
assert_contains "$OUTPUT" "Stage: MVP; next: GA" "real header wins"

it "single-file lifecycle uses the same canonical fields"
rm -r specs/product
rm specs/product.md
cat > specs/SPEC.md <<'MD'
# Demo
## Other topic
**Now**: Not a stage
## Lifecycle
**Stages**: Idea > Team trial > Supported
**Now**: Idea · **Next**: Team trial
### Team trial
**Now**: Not a header field
## Requirements
- **R-01 Share** (hypothesis, from: Team trial): share a result.
## Qualities
- **Q-01 Reliable** (hypothesis, from: Supported): measurable.
MD
run bash "$SCRIPTS/status.sh"
assert_eq 0 "$STATUS" "single-file status succeeds"
assert_contains "$OUTPUT" "R-01 (team trial)" "single-file custom markers are ranked"
run bash "$SCRIPTS/bounds.sh" --all
assert_contains "$OUTPUT" "Q-01 Reliable (from: supported;" "single-file bounds agree"

it "upgrade preserves the project-owned declaration and template"
before="$(git hash-object specs/SPEC.md)"
printf '\nOwner customization.\n' >> .prdkit/templates/lifecycle-template.md
template_before="$(git hash-object .prdkit/templates/lifecycle-template.md)"
run bash "$PK_ROOT/scripts/init.sh" --target "$PROJ" --upgrade
assert_eq 0 "$STATUS" "upgrade succeeds: $OUTPUT"
assert_eq "$before" "$(git hash-object specs/SPEC.md)" "upgrade never edits lifecycle source"
assert_eq "$template_before" "$(git hash-object .prdkit/templates/lifecycle-template.md)" "custom template remains"
run bash "$SCRIPTS/status.sh"
assert_eq 0 "$STATUS" "upgraded installed reader works"
assert_contains "$OUTPUT" "R-01 (team trial)" "custom ordering survives upgrade"
finish
