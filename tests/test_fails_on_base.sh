#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
driver="$PK_ROOT/scripts/maintainer/fails-on-base.sh"
[ -f "$driver" ] || { echo 'Cannot run: missing snapshot driver' >&2; exit 1; }
root=$PWD
mkdir -p base/tests head/tests || exit 1
suite='tests/test_with space.sh'
second=tests/test_always.sh
printf '%s\0' "$suite" "$second" > plan.z

it "run records the actual exit status, harness summary and bounded failure excerpt"
cat > "base/$suite" <<'SUITE'
echo 'MUST NOT LEAK: start of long log'
for ((i=0; i<30; i++)); do printf '%0500d\n' "$i"; done
echo '<failure reason>'
echo 'FAIL: 1 failed, 3 passed'
exit 17
SUITE
printf "echo 'PASS: 4 assertion(s)'\n" > "head/$suite"
# A suite reading stdin must not consume the remaining plan.
printf 'cat >/dev/null\nexit 0\n' > "base/$second"
cp "base/$second" "head/$second"
snapshot() ( cd "$1" && bash "$driver" run "$root/plan.z" "$root/$1.json" )
for side in base head; do
    run snapshot "$side"; assert_eq 0 "$STATUS" "$side produced a complete result"
done
assert_eq '[17,0]' "$(jq -c 'map(.status)' base.json)"
assert_eq 'FAIL: 1 failed, 3 passed' "$(jq -r '.[0].summary' base.json)"
assert_eq 'PASS: 4 assertion(s)' "$(jq -r '.[0].summary' head.json)"
assert_eq true "$(jq '.[0].excerpt | utf8bytelength <= 4096 and (split("\n")|length) <= 13' base.json)"
assert_not_contains "$(cat base.json)" 'MUST NOT LEAK'
assert_eq '""' "$(jq '.[0].excerpt' head.json)"

it "required and advisory titles use the same results but enforce different policies"
compare() { bash "$driver" compare plan.z "$@"; }
run compare base.json head.json 'fix(scope)!: ordinary retry'
assert_eq 0 "$STATUS"; assert_contains "$OUTPUT" '1 of 2'
assert_contains "$OUTPUT" 'Base: FAIL (exit 17); Head: PASS'
assert_contains "$OUTPUT" '<failure reason>'
for title in 'fix: no reproduction' 'fix!: no reproduction'; do
    run compare head.json head.json "$title"
    assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" '0 of 2'
done
run compare base.json base.json 'fix: fails on both'; assert_eq 1 "$STATUS"
run compare head.json base.json 'feat: report only'; assert_eq 0 "$STATUS"; assert_contains "$OUTPUT" '0 of 2'

it "missing, malformed and incomplete evidence fails even for advisory titles"
invalid() {
    run compare "$1" "$2" 'docs: advisory'
    assert_eq 2 "$STATUS" "$3"
    assert_contains "$OUTPUT" 'INCONCLUSIVE'
}
invalid missing head.json 'missing base'
printf '[' > bad.json
invalid base.json bad.json 'malformed head'
jq -cS '.[0:1]' base.json > bad.json
invalid bad.json bad.json 'same omitted suite on both sides'
jq -cS '.[1] = .[0]' base.json > bad.json
invalid bad.json head.json 'duplicate rows'
jq -cS '.[1].status = "0"' head.json > bad.json
invalid base.json bad.json 'wrong exit type'
jq -cS 'del(.[1].excerpt)' head.json > bad.json
invalid base.json bad.json 'missing diagnostic field'
cat head.json head.json > bad.json
invalid base.json bad.json 'multiple documents'
jq -cS '.[0].status = 1' base.json > one.json
sed 's/"status":1,/"status":01,/' one.json > bad.json
invalid bad.json head.json 'invalid leading zero'
sed 's/"status":1,/"status":0,"status":1,/' one.json > bad.json
invalid bad.json head.json 'duplicate status'
jq -cS '.[0].excerpt = ("x\n" * 13)' base.json > bad.json
invalid bad.json head.json '13 terminated lines'
jq -cS '.[0].excerpt |= rtrimstr("\n")' bad.json > extra.json
invalid extra.json head.json '13 lines without trailing newline'
jq -cS '.[0].status = 0' base.json > bad.json
invalid base.json bad.json 'success cannot retain the failure excerpt'
jq -cS '.[0].excerpt = ("é" * 2048)' base.json > limit.json
run compare limit.json head.json 'fix: boundary'
assert_eq 0 "$STATUS" '4096 UTF-8 bytes are valid'
jq -cS '.[0].excerpt += "!"' limit.json > bad.json
invalid bad.json head.json '4097 UTF-8 bytes on base'
invalid base.json bad.json '4097 UTF-8 bytes on head'
printf '%s' "$suite" > plan.z
invalid base.json head.json 'truncated plan'

it "producer keeps only complete characters at the byte boundary"
printf '%s\0' "$suite" > plan.z
cat > "base/$suite" <<'SUITE'
printf 'é%04095d' 0
exit 1
SUITE
snapshot base || exit 1
assert_eq true "$(jq '.[0].excerpt == ("0" * 4095)' base.json)" 'no split character or replacement bytes'

it "multiline names and embedded code fences remain literal Markdown"
suite=$'tests/test_[link](#a)``new`\n\n# name heading\t.sh'
printf '%s\0' "$suite" > plan.z
cat > "base/$suite" <<'SUITE'
printf '```\n\n# excerpt heading\n\n```\n'
exit 1
SUITE
printf 'exit 0\n' > "head/$suite"
for side in base head; do snapshot "$side" || exit 1; done
run compare base.json head.json 'fix: summary'
assert_eq 0 "$STATUS"
# shellcheck disable=SC2016 # Backticks are literal Markdown delimiters.
assert_contains "$OUTPUT" '- ```tests/test_[link](#a)``new`\n\n# name heading\t.sh``` — Base:'
assert_contains "$OUTPUT" $'\n````\n```\n\n# excerpt heading\n\n```\n````\n'
finish
