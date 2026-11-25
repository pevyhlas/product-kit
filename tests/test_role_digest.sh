#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project)" || exit 1
track_tmp "$PROJ"
cd "$PROJ" || exit 1
DIGEST="$PROJ/.prdkit/scripts/bash/role-digest.sh"
MEMORY=.prdkit/memory
CONSTITUTION="$MEMORY/constitution.md"
AGENTS="$MEMORY/agents.md"
CONFIG="$MEMORY/role-digest.conf"

it 'the freshly installed policy works before project customization'
run bash "$DIGEST" --help
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" 'Usage: role-digest.sh'
run bash "$DIGEST" 'intent owner'
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" "Section: $CONSTITUTION:"
assert_contains "$OUTPUT" "Section: $AGENTS:"
assert_contains "$OUTPUT" "absent"$'\t'"$CONFIG"

cat > "$CONSTITUTION" <<'MD'
# Policy
The leader and co_lead consult lead2.
## Decisions
Ask the LeAd.
## No match
The leader, co_lead, and lead2 are not matches.
## Other
### LEAD escalation
The same heading can appear in different locations.
## Unrelated
This must not be printed.
MD
cat > "$AGENTS" <<'MD'
# Responsibilities
| Role | Task |
|------|------|
| LEAD | Coordinate |

```text
## Fake heading
```
<!--
## Another fake heading
-->
MD
printf '# Root instructions\nLEAD\n' > AGENTS.md
printf '%s\n' '## Decisions' 'Ask the LeAd.' > "$_SCRATCH_CWD/section"
hash() { git hash-object --no-filters -- "$1"; }
section_hash="$(hash "$_SCRATCH_CWD/section")"
input_hash="$(hash "$CONSTITUTION")"

it 'multiple inputs give exact lines and blobs, with nearest-heading and whole-word matching'
run bash "$DIGEST" lead
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" "Section: $CONSTITUTION:3-4 | Decisions | content_blob=$section_hash"
assert_contains "$OUTPUT" $'## Decisions\nAsk the LeAd.\n'
assert_contains "$OUTPUT" "Section: $CONSTITUTION:8-9 | LEAD escalation |"
assert_contains "$OUTPUT" "Section: $AGENTS:1-11 | Responsibilities |"
assert_contains "$OUTPUT" "$input_hash"$'\t'"$CONSTITUTION"
assert_contains "$OUTPUT" "$(hash "$AGENTS")"$'\t'"$AGENTS"
assert_not_contains "$OUTPUT" 'Root instructions'
assert_not_contains "$OUTPUT" 'The leader'
assert_not_contains "$OUTPUT" 'This must not be printed'
assert_not_contains "$OUTPUT" '| Other |' 'a child citation does not select its parent'
assert_not_contains "$OUTPUT" '| Fake heading |'

it 'no whole-word citations is successful empty evidence'
run bash "$DIGEST" not-mentioned
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" 'Empty digest: no sections cite this role.'
assert_contains "$OUTPUT" "$input_hash"$'\t'"$CONSTITUTION"
assert_not_contains "$OUTPUT" 'Section:'

it 'non-ASCII punctuation is a word boundary without losing the source bytes'
printf '# Punctuation\nSay —LEAD— now.\n' > punctuation.md
run bash "$DIGEST" --extra punctuation.md lead
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" 'Section: punctuation.md:1-2 | Punctuation |'
assert_contains "$OUTPUT" 'Say —LEAD— now.'

it 'config then CLI additions have stable order and absent inputs are explicit'
printf '# A\nlead  \n' > 'with space.md'
printf '# B\nlead\n' > first.md
printf '# C\nlead\n' > last.md
printf '# D\nlead\n' > default.md
printf '# optional role context\n\nwith space.md\nconfig-absent.md\n' > custom.conf
printf 'default.md\n' > "$CONFIG"
run bash "$DIGEST" lead
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" 'Section: default.md:1-2 | D |'
run bash "$DIGEST" --extra first.md --config custom.conf --extra cli-absent.md --extra last.md lead
assert_eq 0 "$STATUS"
headers="$(printf '%s\n' "$OUTPUT" | sed -n 's/^Section: \(.*\) | content_blob=.*/\1/p')"
assert_eq "$(printf '%s\n' "$CONSTITUTION:3-4 | Decisions" "$CONSTITUTION:8-9 | LEAD escalation" \
    "$AGENTS:1-11 | Responsibilities" 'with space.md:1-2 | A' 'first.md:1-2 | B' 'last.md:1-2 | C')" "$headers"
inventory="${OUTPUT#*$'Inputs (working-tree Git blobs):\n'}"
assert_eq "$(printf '  %s\t%s\n' "$(hash "$CONSTITUTION")" "$CONSTITUTION" "$(hash "$AGENTS")" "$AGENTS" \
    "$(hash custom.conf)" custom.conf "$(hash 'with space.md')" 'with space.md' absent config-absent.md \
    "$(hash first.md)" first.md absent cli-absent.md "$(hash last.md)" last.md)" "$inventory"
assert_contains "$OUTPUT" $'# A\nlead  \n' 'section bytes retain trailing spaces'
assert_not_contains "$OUTPUT" 'default.md'

it 'equivalent runs are byte-identical and changed bytes change both relevant hashes'
old_hash="$(hash 'with space.md')"
bash "$DIGEST" --extra 'with space.md' lead > "$_SCRATCH_CWD/before"
assert_eq 0 "$?"
bash "$DIGEST" --extra 'with space.md' lead > "$_SCRATCH_CWD/again"
assert_eq 0 "$?"
run cmp -s "$_SCRATCH_CWD/before" "$_SCRATCH_CWD/again"
assert_eq 0 "$STATUS"
printf '# A\nlead changed\n' > 'with space.md'
run bash "$DIGEST" --extra 'with space.md' lead
assert_eq 0 "$STATUS"
new_hash="$(hash 'with space.md')"
assert_contains "$OUTPUT" "Section: with space.md:1-2 | A | content_blob=$new_hash"
assert_contains "$OUTPUT" "$new_hash"$'\twith space.md'
assert_not_contains "$OUTPUT" "Section: with space.md:1-2 | A | content_blob=$old_hash"
assert_not_contains "$OUTPUT" "$old_hash"$'\twith space.md'

it 'a refusal anywhere names the file, gives the raw hint, and prints no partial digest'
printf '# Unmatched\n\n> unsupported\n' > refused.md
bash "$DIGEST" --extra refused.md lead > "$_SCRATCH_CWD/out" 2> "$_SCRATCH_CWD/err"
assert_eq 2 "$?"
assert_eq '' "$(cat "$_SCRATCH_CWD/out")"
assert_contains "$(cat "$_SCRATCH_CWD/err")" 'refused.md: 3: Block quotes'
assert_contains "$(cat "$_SCRATCH_CWD/err")" '--raw'

it 'a missing constitution is an error; a missing registry or config is not'
mv "$AGENTS" "$_SCRATCH_CWD/agents"
run bash "$DIGEST" --config missing.conf lead
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" "absent"$'\t'"$AGENTS"
assert_contains "$OUTPUT" $'absent\tmissing.conf'
mv "$CONSTITUTION" "$_SCRATCH_CWD/constitution"
run bash "$DIGEST" lead
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" "Missing required input: $CONSTITUTION"

finish
