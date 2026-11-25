#!/usr/bin/env bash
# Local scaffold provenance, report grammar, severity policy, and normalization.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project)" || exit 1
track_tmp "$PROJ"
HELPER="$PROJ/.prdkit/scripts/bash/review-report.sh"
MAP="$PROJ/.prdkit/memory/agents.md"
CONSTITUTION="$PROJ/.prdkit/memory/constitution.md"
DEF="$PROJ/.prdkit/agents/example-review.md"
INPUT="$PROJ/saved report.md"
ORIGINAL="$PROJ/original scaffold.md"
mkdir -p "$PROJ/.prdkit/agents" "$PROJ/.prdkit/agent-library" "$PROJ/.opencode/agents" || exit 1

cat > "$MAP" <<'EOF'
# Capabilities

## Review registry

<!--
| Identity | Role |
|----------|------|
| commented | reviewer |
-->
~~~markdown
| Identity | Role |
|----------|------|
| tilde-example | reviewer |
~~~
```markdown
| Identity | Role |
|----------|------|
| backtick-example | reviewer |
```

| Identity | Role |
|----------|------|
| example-review | reviewer |
| maker-review | reviewer |
| maker-review | maker |

## Tier map

Tier baseline: agent-library tiers.json@1234567

| Local tier | Library tier |
|------------|--------------|
| local-review | shared-review |

| Scope | Harness | Model | Variant | Reason |
|-------|---------|-------|---------|--------|
| agent:example-review | opencode | test/override | | Fixture tests override precedence |
EOF
cat > "$DEF" <<'EOF'
---
name: example-review
tier: local-review
harnesses: [claude, opencode]
---
EOF
printf -- '---\nmodel: ignored-projection\n---\n' > "$PROJ/.opencode/agents/example-review.md"
snapshot="$PROJ/.prdkit/agent-library/tiers.json"
printf '%s\n' '{"shared-review":{"opencode":{"model":"test/base"},"claude":{"model":"test/other"}}}' > "$snapshot"
# Use the same cross-platform hash helpers as the vendored snapshot writer.
source "$PROJ/.prdkit/scripts/bash/install-lib.sh"
printf 'library-ref: 1234567\nsha256: %s\n' "$(install_hash_stream < "$snapshot")" > "$snapshot.ref"

scaffold() {
    "$BASH" "$HELPER" scaffold --reviewer "$1" --harness "$2" --base base-sha --head head-sha \
        --scope 'Check two paths' "${@:3}"
}
lint() { "$BASH" "$HELPER" lint "$@" "$INPUT"; }
normalize() { "$BASH" "$HELPER" normalize "$INPUT"; }
trailer() { printf 'Verdict: %s\nCounts: %s critical, %s high, %s medium, %s low\n' "$@"; }
finding() { printf '\n- %s: path with spaces/file.md:42\n  Scenario: Observable result.\n  Evidence: Replayed the check.\n' "$1"; }
report() { if [ -n "$HEADER" ]; then printf '%s\n' "$HEADER"; fi; }

it "lint help distinguishes stamp verification from standalone lint"
run "$BASH" "$HELPER" lint --help
assert_eq 0 "$STATUS"
help_text="$(printf '%s' "$OUTPUT" | tr '\n' ' ' | tr -s ' ')"
assert_contains "$help_text" 'Neither an optional standalone header nor a lint pass without --scaffold verifies stamp values'
assert_contains "$help_text" "only --scaffold against the coordinator's saved original does"

it "scaffold stamps the installed registry, review range, scope and resolved model"
run scaffold example-review opencode --since previous-sha
assert_eq 0 "$STATUS"
expected='# Review report

Reviewer: example-review
Base: base-sha
Head: head-sha
Since: previous-sha
Scope: Check two paths
Model: test/override

## Findings'
assert_eq "$expected" "$OUTPUT" "fixed header, override wins instead of projection or baseline"
HEADER="$OUTPUT"
printf '%s\n' "$HEADER" > "$ORIGINAL"
run scaffold example-review claude
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" 'Since: initial'
assert_contains "$OUTPUT" 'Model: test/other' "harness and mapped baseline tier select the model"
assert_not_contains "$OUTPUT" 'Verdict:' "scaffold never chooses a verdict"

it "scaffold refuses unregistered, hidden example and maker identities"
for name in not-listed commented tilde-example backtick-example maker-review; do
    run scaffold "$name" opencode
    assert_eq 2 "$STATUS"
    assert_contains "$OUTPUT" 'expected one reviewer entry'
done
run scaffold example-review 'claude opencode'
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" '--harness must be one of:'
run scaffold example-review opencode --model not-from-map
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'unknown scaffold option'
run scaffold example-review opencode --since $'prior\nModel: injected'
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'single-line value'
run scaffold example-review opencode --since x --since y
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'supply --since only once'
cp "$snapshot" "$snapshot.saved" || exit 1
printf ' ' >> "$snapshot"
run scaffold example-review opencode
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'sha256 mismatch'
mv "$snapshot.saved" "$snapshot" || exit 1

it "scaffold ignores an override after a shorter tilde run inside a longer fence"
cp "$MAP" "$MAP.saved" || exit 1
cat >> "$MAP" <<'EOF'

~~~~markdown
~~~
| Scope | Harness | Model | Variant | Reason |
|-------|---------|-------|---------|--------|
| agent:example-review | opencode | test/hidden | | Fenced example only |
~~~~
EOF
run scaffold example-review opencode
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" 'Model: test/override'
assert_not_contains "$OUTPUT" 'test/hidden'
mv "$MAP.saved" "$MAP" || exit 1

it "scaffold only closes a fence with the same character and no info string"
cp "$MAP" "$MAP.saved" || exit 1
cat >> "$MAP" <<'EOF'

~~~~markdown
````
| Scope | Harness | Model | Variant | Reason |
|-------|---------|-------|---------|--------|
| agent:example-review | opencode | test/wrong-char | | Fenced example only |
~~~~text
| Scope | Harness | Model | Variant | Reason |
|-------|---------|-------|---------|--------|
| agent:example-review | opencode | test/extra-info | | Fenced example only |
EOF
run scaffold example-review opencode
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" 'Model: test/override'
cp "$MAP" "$MAP.open" || exit 1
for trailing in '  ' $'\t'; do
    # Change the registry example closer as well as the tier-map example closer.
    awk -v trailing="$trailing" '$0 == "~~~" { $0 = $0 trailing } { print }' "$MAP.open" > "$MAP" || exit 1
    { printf '~~~~~%s\n\n' "$trailing"; cat <<'EOF'
| Scope | Harness | Model | Variant | Reason |
|-------|---------|-------|---------|--------|
| agent:example-review | opencode | test/after-fence | | A real override after the fence |
EOF
    } >> "$MAP"
    run scaffold example-review opencode
    assert_eq 0 "$STATUS"
    assert_contains "$OUTPUT" 'Model: test/after-fence'
done
mv "$MAP.saved" "$MAP" || exit 1

it "strict lint checks every stamp against the original scaffold"
{ report; trailer PASS 0 0 0 0; } > "$INPUT"
run lint --strict --scaffold "$ORIGINAL"
assert_eq 0 "$STATUS"
assert_eq '' "$OUTPUT"
for label in Reviewer Base Head Since Scope Model; do
    { report | sed "s/^$label:.*/$label: altered/"; trailer PASS 0 0 0 0; } > "$INPUT"
    run lint --strict --scaffold "$ORIGINAL"
    assert_eq 1 "$STATUS"
    assert_contains "$OUTPUT" "preserve the original scaffold line for $label:"
done
{ printf '## Findings\n'; trailer PASS 0 0 0 0; } > "$INPUT"
run lint --strict
assert_eq 0 "$STATUS" "standalone reports need no tier-map stamps"
run lint --strict --scaffold "$ORIGINAL"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'preserve the original scaffold line for Reviewer:'
assert_contains "$OUTPUT" 'preserve the original scaffold line for Model:'
{ report | sed '/^Since:/d'; trailer PASS 0 0 0 0; } > "$INPUT"
run lint --strict --scaffold "$ORIGINAL"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'preserve the original scaffold line for Since:'
{ report | sed 's/^Model:.*/Head: repeated/'; trailer PASS 0 0 0 0; } > "$INPUT"
run lint --strict --scaffold "$ORIGINAL"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'preserve the original scaffold line for Model:'
run lint --strict
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'expected the Model: field at this position'
run lint --scaffold "$ORIGINAL"
assert_eq 0 "$STATUS" "default lint still reports issues without strict status"
assert_contains "$OUTPUT" 'preserve the original scaffold line for Model:'
{ report | sed '/^Model:/p'; trailer PASS 0 0 0 0; } > "$INPUT"
run lint --strict
assert_eq 1 "$STATUS" "the fixed header has no room for a repeated stamp"
assert_contains "$OUTPUT" 'line 9: expected a blank line in the scaffold header'
run lint --strict --scaffold "$ORIGINAL.missing"
assert_eq 2 "$STATUS"
printf 'not a scaffold\n' > "$ORIGINAL.invalid"
run lint --strict --scaffold "$ORIGINAL.invalid"
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'must be the original unedited scaffold output'

it "lint requires the original title and blank lines around the stamp block"
for line in 1 2 9; do
    { report | awk -v n="$line" 'NR == n { $0 = $0 " " } { print }'; trailer PASS 0 0 0 0; } > "$INPUT"
    run lint --strict --scaffold "$ORIGINAL"
    assert_eq 1 "$STATUS" "extra byte in scaffold line $line"
    assert_contains "$OUTPUT" "line $line: preserve the original scaffold title and blank lines"
done

it "reports take stamps only from the opening block"
{
    head -n 9 "$ORIGINAL"
    cat <<'EOF'
**Model**: text quoted from a test
Head: another revision discussed as context
`git log | head`

## Findings

- Low: docs/example.md:3
  Scenario: A sample row is printed.
  Evidence: Rows are printed as `id | model | status`.
EOF
    trailer APPROVED 0 0 0 1
} > "$INPUT"
normalize > "$INPUT.normalized" || exit 1
sed 's/^Verdict: APPROVED$/Verdict: PASS/' "$INPUT" > "$INPUT.expected"
if cmp -s "$INPUT.expected" "$INPUT.normalized"; then _ok "normalize changes only the verdict"; else _no "normalize changes only the verdict"; fi
mv "$INPUT.normalized" "$INPUT" || exit 1
run lint --strict --scaffold "$ORIGINAL"
assert_eq 0 "$STATUS" "context and evidence do not change a stamp"
assert_eq '' "$OUTPUT"
run lint --strict
assert_eq 0 "$STATUS" "standalone lint likewise ignores later stamp-like content"
assert_eq '' "$OUTPUT"

it "lint sees the trailer after a fence closer with trailing spaces or a tab"
for trailing in '  ' $'\t'; do
    {
        head -n 9 "$ORIGINAL"
        printf '%s\n' '~~~~markdown' '~~~' '## Findings'
        printf '~~~~%s\n\n' "$trailing"
        printf '## Findings\n'
        trailer PASS 0 0 0 0
    } > "$INPUT"
    run lint --strict --scaffold "$ORIGINAL"
    assert_eq 0 "$STATUS"
    assert_eq '' "$OUTPUT"
done

it "zero findings and valid nonblocking findings lint cleanly"
{ report; trailer PASS 0 0 0 0; } > "$INPUT"
run lint --strict
assert_eq 0 "$STATUS"
assert_eq '' "$OUTPUT"
{ report; finding Medium; finding Low; trailer PASS 0 0 1 1; } > "$INPUT"
run lint --strict
assert_eq 0 "$STATUS" "the seeded constitution is light"
assert_eq '' "$OUTPUT"
run lint --strict --rigor full
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'PASS is inconsistent with blocking findings'
printf '%s\n' '- **Rigor**: full' > "$CONSTITUTION"
run lint --strict
assert_eq 1 "$STATUS" "the installed policy also controls medium findings"
run lint --strict --rigor light
assert_eq 0 "$STATUS" "caller can supply the trusted policy instead"
printf '%s\n' '# Missing rigor' > "$CONSTITUTION"
run lint --strict
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'supply --rigor from trusted policy'
{ report; finding Low; trailer PASS 0 0 0 1; } > "$INPUT"
run lint --strict --rigor full
assert_eq 0 "$STATUS" "low remains advisory under full rigor"

it "lint validates blocking severities without judging a valid FAIL"
{ report; finding Critical; finding High; finding Medium; finding Low; trailer FAIL 1 1 1 1; } > "$INPUT"
run lint --strict --rigor full
assert_eq 0 "$STATUS" "FAIL is a product verdict, not a lint finding"
assert_eq '' "$OUTPUT"
for severity in Critical High; do
    c=0 h=0
    case "$severity" in Critical) c=1 ;; High) h=1 ;; esac
    { report; finding "$severity"; trailer PASS "$c" "$h" 0 0; } > "$INPUT"
    run lint --rigor light
    assert_eq 0 "$STATUS" "default reports diagnostics but does not fail"
    assert_contains "$OUTPUT" 'PASS is inconsistent with blocking findings'
    run lint --strict --rigor light
    assert_eq 1 "$STATUS"
done

it "lint enforces the prompt severity ordering"
{ report; finding Low; finding High; trailer FAIL 0 1 0 1; } > "$INPUT"
run lint --strict
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'list findings in Critical, High, Medium, Low order'
assert_not_contains "$OUTPUT" 'last line must match the findings' "the count can still match"

it "lint diagnoses each malformed field and reconciles actual finding counts"
{
    report
    cat <<'EOF'
- Major: a.md:3
  Scenario: Context.
  Evidence: Actual output.
- High: missing-line.md
  Scenario:
  Evidence: Actual output.
- Low: a.md:0
  Scenario: Context.
  Evidence:
EOF
    trailer FAIL 1 0 0 0
} > "$INPUT"
run lint --strict
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'start a finding with - Critical:'
assert_contains "$OUTPUT" 'file:line location with a positive line number'
assert_contains "$OUTPUT" 'finding needs a nonblank Scenario:'
assert_contains "$OUTPUT" 'finding needs a nonblank Evidence:'
assert_contains "$OUTPUT" 'last line must match the findings: Counts: 0 critical, 1 high, 0 medium, 1 low'

it "lint requires exact visible final lines with no trailing blank or prose"
for bad in blank prose reversed whitespace extra-count; do
    {
        report
        case "$bad" in
            blank) trailer PASS 0 0 0 0; printf '\n' ;;
            prose) trailer PASS 0 0 0 0; printf 'Done.\n' ;;
            reversed) trailer PASS 0 0 0 0 | awk '{a[NR]=$0} END {print a[2]; print a[1]}' ;;
            whitespace) printf 'Verdict: PASS \nCounts: 0 critical, 0 high, 0 medium, 0 low\n' ;;
            extra-count) trailer PASS 00 0 0 0 ;;
        esac
    } > "$INPUT"
    run lint --strict
    assert_eq 1 "$STATUS" "$bad trailer refused"
done
{ report; printf '%s\n' '~~~'; trailer PASS 0 0 0 0; } > "$INPUT"
run lint --strict
assert_eq 1 "$STATUS" "a fenced trailer is not the verdict"
run normalize
assert_eq 2 "$STATUS"
# shellcheck disable=SC2016 # Literal Markdown code span.
{ printf '%s\n' '```literal```'; report; trailer PASS 0 0 0 0; } > "$INPUT"
run lint --strict
assert_eq 0 "$STATUS" "a backtick code span is not a fence opener"
run normalize
assert_eq 0 "$STATUS"
assert_eq "$(cat "$INPUT")" "$OUTPUT"

it "normalize changes only the explicit verdict, and never edits the file"
for value in '  lGtM ' 'ACCEPTED' 'passed' 'APPROVED' 'SOUND' 'FAIL' 'rejected' 'CHANGES_REQUESTED' 'CHANGES_REQUIRED' 'Request Changes'; do
    case "$value" in FAIL|rejected|CHANGES_REQUESTED|CHANGES_REQUIRED|'Request Changes') canonical=FAIL ;; *) canonical=PASS ;; esac
    { report; printf 'Verdict: %s\nCounts: keep this literal\n' "$value"; } > "$INPUT"
    before="$(cat "$INPUT")"
    run normalize
    assert_eq 0 "$STATUS"
    assert_eq "$(report; printf 'Verdict: %s\nCounts: keep this literal\n' "$canonical")" "$OUTPUT"
    assert_eq "$before" "$(cat "$INPUT")" "normalization does not rewrite the input"
done
{ report; printf 'Verdict: approved\nCounts: 0 critical, 0 high, 0 medium, 0 low\n'; } > "$INPUT"
normalize > "$INPUT.normalized" || exit 1
run "$BASH" "$HELPER" lint --strict "$INPUT.normalized"
assert_eq 0 "$STATUS" "normalization produces a report that can be linted"

it "normalize refuses missing and unknown verdicts; unreadable input is not a lint finding"
for verdict in '' 'Verdict: pending' 'Verdict: PASS (conditional)' 'Verdict: SOUND with reservations' 'Verdict: CHANGES_REQUIRED or SOUND'; do
    { report; printf '%s\nCounts: 0 critical, 0 high, 0 medium, 0 low\n' "$verdict"; } > "$INPUT"
    rc=0
    normalize > "$INPUT.result" 2> "$INPUT.error" || rc=$?
    assert_eq 2 "$rc"
    assert_contains "$(cat "$INPUT.error")" 'expected a recognized Verdict: value'
    assert_eq 0 "$(wc -c < "$INPUT.result" | tr -d '[:space:]')" "refusal writes no report"
done
printf 'Verdict: PASS\nCounts: binary\000text\n' > "$INPUT"
run lint --strict
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" 'LF-terminated text file'
run "$BASH" "$HELPER" lint --strict "$INPUT.missing"
assert_eq 2 "$STATUS"
assert_contains "$OUTPUT" "$INPUT.missing"

it "normalize accepts exactly 1 MiB and refuses an oversized report without stdout"
{ report; trailer PASS 0 0 0 0; } > "$INPUT.body"
body_bytes="$(wc -c < "$INPUT.body")"
awk -v n="$((1048576 - body_bytes))" 'BEGIN {
    padding = sprintf("%1023s", "x")
    while (n >= 1024) { print padding; n -= 1024 }
    if (n) print substr(padding, 1, n - 1)
}' > "$INPUT" || exit 1
cat "$INPUT.body" >> "$INPUT"
assert_eq 1048576 "$(wc -c < "$INPUT" | tr -d '[:space:]')"
normalize > "$INPUT.result" || exit 1
if cmp -s "$INPUT" "$INPUT.result"; then _ok "limit is inclusive"; else _no "limit is inclusive"; fi
printf '\n' >> "$INPUT"
rc=0
normalize > "$INPUT.result" 2> "$INPUT.error" || rc=$?
assert_eq 2 "$rc"
assert_contains "$(cat "$INPUT.error")" 'exceeds the normalize limit'
assert_eq 0 "$(wc -c < "$INPUT.result" | tr -d '[:space:]')" "no partial output"

it "many short lines at the byte cap fit within a modest memory limit"
if [ "$(uname -s)" = Linux ] && (ulimit -v 131072) 2>/dev/null; then
    awk -v n="$((1048576 - body_bytes))" 'BEGIN { while (n-- > 0) print "" }' > "$INPUT" || exit 1
    cat "$INPUT.body" >> "$INPUT"
    rc=0
    (ulimit -v 131072 && normalize) > "$INPUT.result" || rc=$?
    assert_eq 0 "$rc"
    if cmp -s "$INPUT" "$INPUT.result"; then _ok "short lines are reproduced exactly"; else _no "short lines are reproduced exactly"; fi
fi

it "delivery failures override otherwise successful output"
if [ -c /dev/full ] && ! (printf 'x' > /dev/full) 2>/dev/null; then
    rc=0
    scaffold example-review opencode > /dev/full 2> "$INPUT.error" || rc=$?
    assert_eq 2 "$rc" "scaffold output write failure"
    assert_contains "$(cat "$INPUT.error")" 'cannot write report scaffold'
    { report; trailer APPROVED 0 0 0 0; } > "$INPUT"
    rc=0
    normalize > /dev/full 2> "$INPUT.error" || rc=$?
    assert_eq 2 "$rc" "normalize output write failure"
    assert_contains "$(cat "$INPUT.error")" 'cannot write normalize output'
    for flags in advisory strict; do
        rc=0
        if [ "$flags" = strict ]; then
            lint --strict > /dev/full 2> "$INPUT.error" || rc=$?
        else
            lint > /dev/full 2> "$INPUT.error" || rc=$?
        fi
        assert_eq 2 "$rc" "$flags lint output write failure"
        assert_contains "$(cat "$INPUT.error")" 'cannot write lint output'
    done
fi
finish
