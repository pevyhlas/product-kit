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

it 'quotes, backslashes, dashes and regex metacharacters are literal at word boundaries'
literal_role='Lead-"ops"\v[1].*+?(v)$-guard'
cat > literal.md <<'MD'
# Literal
Ask (LEAD-"OPS"\v[1].*+?(v)$-GUARD).
# Prefixed
Ask xLead-"ops"\v[1].*+?(v)$-guard.
# Suffixed
Ask Lead-"ops"\v[1].*+?(v)$-guard_extra.
# Different bytes
Ask Lead-"ops"v1.*+?(v)$-guard.
MD
run bash "$DIGEST" --extra literal.md "$literal_role"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" 'Section: literal.md:1-2 | Literal |'
assert_not_contains "$OUTPUT" '| Prefixed |'
assert_not_contains "$OUTPUT" '| Suffixed |'
assert_not_contains "$OUTPUT" '| Different bytes |'

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

assert_refused() { # expected diagnostic, input path, digest arguments
    local diagnostic="$1" path="$2" err
    shift 2
    bash "$DIGEST" "$@" lead > "$_SCRATCH_CWD/out" 2> "$_SCRATCH_CWD/err"
    assert_eq 2 "$?" "$*: exit 2"
    assert_eq '' "$(cat "$_SCRATCH_CWD/out")" "$*: empty stdout"
    err="$(cat "$_SCRATCH_CWD/err")"
    assert_contains "$err" "$diagnostic" "$*: explains the refusal"
    assert_contains "$err" "$path" "$*: names the input"
}

assert_refused_extra_and_entry() { # diagnostic, input path
    printf '%s\n' "$2" > invalid-entry.conf
    assert_refused "$1" "$2" --extra "$2"
    assert_refused "$1" "$2" --config invalid-entry.conf
}

it 'both CLI extras and config entries refuse symlinks, dot components and absolute paths'
mkdir path-fixture || exit 1
printf '# File\nlead\n' > path-fixture/policy.md
ln -s path-fixture/policy.md symlink-leaf.md || exit 1
ln -s path-fixture symlink-parent || exit 1
assert_refused_extra_and_entry 'Symlink in input path' symlink-leaf.md
assert_refused_extra_and_entry 'Symlink in input path' symlink-parent/policy.md
assert_refused_extra_and_entry 'Not a plain repository-relative path' path-fixture/./policy.md
assert_refused_extra_and_entry 'Not a plain repository-relative path' path-fixture/../first.md
assert_refused_extra_and_entry 'Not a plain repository-relative path' "$PROJ/path-fixture/policy.md"

it 'a successful lookup whose inventory cannot reopen refuses instead of reporting absence'
mkdir "$_SCRATCH_CWD/find-shim" "$_SCRATCH_CWD/digest-tmp" || exit 1
real_find="$(command -v find)" || exit 1
cat > "$_SCRATCH_CWD/find-shim/find" <<'SH'
#!/bin/sh
"$DIGEST_REAL_FIND" "$@" || exit "$?"
case "$1" in
    */path-fixture/.)
        set -- "$TMPDIR"/prdkit-role-digest.??????/lookup
        if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
            printf 'find shim: expected exactly one role-digest lookup inventory under %s\n' "$TMPDIR" >&2
            exit 1
        fi
        rm "$1" || exit 1 ;;
esac
SH
chmod +x "$_SCRATCH_CWD/find-shim/find" || exit 1
PATH="$_SCRATCH_CWD/find-shim:$PATH" TMPDIR="$_SCRATCH_CWD/digest-tmp" DIGEST_REAL_FIND="$real_find" \
    assert_refused 'Cannot reopen lookup inventory' path-fixture/missing.md --extra path-fixture/missing.md

it 'a nonregular leaf or nondirectory parent is not absent'
assert_refused_extra_and_entry 'Not a regular input file' path-fixture
assert_refused 'Not a regular input file' path-fixture --config path-fixture
assert_refused_extra_and_entry 'Non-directory parent in input path' path-fixture/policy.md/child.md

it 'an unsearchable directory or unreadable file is not absent'
if [ "$EUID" -eq 0 ]; then
    echo '  SKIP permission-refusal tests: running as root'
else
    mkdir -m 0700 private || exit 1
    printf '# Private\nlead\n' > private/policy.md
    printf 'first.md\n' > private/paths.conf
    chmod 0600 private || exit 1
    assert_refused_extra_and_entry 'Cannot search parent directory' private/policy.md
    assert_refused 'Cannot search parent directory' private/paths.conf --config private/paths.conf
    chmod 0700 private || exit 1

    chmod 000 private/policy.md private/paths.conf || exit 1
    assert_refused_extra_and_entry 'Cannot read input' private/policy.md
    assert_refused 'Cannot read input' private/paths.conf --config private/paths.conf
    chmod 0600 private/policy.md private/paths.conf || exit 1

    chmod 0100 private || exit 1
    run bash "$DIGEST" --extra private/policy.md lead
    assert_eq 0 "$STATUS" 'known readable input needs no directory listing'
    assert_contains "$OUTPUT" 'Section: private/policy.md:'
    assert_refused 'Cannot determine whether input exists' private/missing.md --extra private/missing.md
    chmod 0700 private || exit 1
    run bash "$DIGEST" --extra private/missing/child.md lead
    assert_eq 0 "$STATUS" 'missing subtree in an accessible parent is optional'
    assert_contains "$OUTPUT" $'absent\tprivate/missing/child.md'
fi

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
