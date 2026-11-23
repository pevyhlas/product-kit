#!/usr/bin/env bash
# Exercise the installed gate with committed policy and real native-review fixtures.
# shellcheck disable=SC2016 # Backticks in Markdown fixture text are literal.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
project="$(make_inited_project)"; track_tmp "$project"; cd "$project" || exit 1
registry=.prdkit/memory/agents.md
config=.prdkit/memory/config.md
record=specs/changes/001-reviewed.md
ref=refs/remotes/origin/main
cat >> "$registry" <<'EOF'

## Review registry
| Identity | Role |
|---|---|
| code | reviewer |
| design | reviewer |
| implementation | maker |
EOF
git add .; git commit -qm baseline
base="$(git rev-parse HEAD)"
git update-ref "$ref" "$base"; git symbolic-ref refs/remotes/origin/HEAD "$ref"
use_gh_stub
policy() {
    { printf '%s\n' '## Configuration' '- review-host: github' '- review-owner: user:1003' "$@"; } |
        trusted_edit "$ref" "$config"
}
tier() {
    git checkout -q --detach "$base"
    mkdir -p specs/changes
    printf '**Tier**: %s\n' "$1" > "$record"
    git add .; git commit -qm "$1 record"
    head="$(git rev-parse HEAD)"; fx_pr 7 "$head"
    printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
}
gate() { run bash .prdkit/scripts/bash/check-review.sh --json --pr https://github.com/owner/repo/pull/7 001-reviewed; }
review() { fx_review 7 'Review.' "{\"state\":\"$1\",\"author\":{\"databaseId\":$2}}"; }
separate='- review-lenses: code=bot:1001, design=user:1004|user:1006'
it 'T0 needs no area approval; T1 needs any mapped non-author publisher'
policy "$separate"
tier T0; gate; assert_eq 0 "$STATUS" "$OUTPUT"
tier T1; review APPROVED 1009; gate; assert_eq 1 "$STATUS" 'unmapped account cannot approve'
review APPROVED 1004; gate; assert_eq 0 "$STATUS" "$OUTPUT"

it 'one bundled approval covers each mapped concern using the same review ID'
tier T2
policy '- review-lenses: code=bot:1001, design=bot:1001'
review APPROVED 1001; gate
assert_eq 0 "$STATUS" "$OUTPUT"
rid="$(jq -r 'last.fullDatabaseId' "$GH_STUB_DIR/reviews/7.json")"
assert_eq "code:1001:$rid design:1001:$rid" "$(jq -r '[.areas[]|"\(.area):\(.reviewer):\(.review)"]|join(" ")' <<< "$OUTPUT")"

it 'T2 retains the 2.x minimum but never credits a different area'
policy "$separate" '- review-publishers: user:1006, user:1004, bot:1001'
gate; assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq '[{"area":"design","reviewer":null,"review":null}]' "$(jq -c '[.areas[]|select(.area=="design")]' <<< "$OUTPUT")"
review APPROVED 1006; gate
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq '1001,1006' "$(jq -r '[.areas[].reviewer|tostring]|join(",")' <<< "$OUTPUT")"

it 'design and a distinct owner must approve T3, and an unrelated area can block'
tier T3
policy "$separate"
review APPROVED 1001; review APPROVED 1003; gate
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'approval for the design area'
policy '- review-lenses: design=user:1003'
gate; assert_eq 1 "$STATUS" 'owner-only mapping does not satisfy design'
policy '- review-lenses: code=bot:1001'
gate; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'requires a review-lenses mapping for design'
policy "$separate"
printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
review APPROVED 1004; gate
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'also requires a review-owner'
review APPROVED 1003; gate; assert_eq 0 "$STATUS" "$OUTPUT"
review CHANGES_REQUESTED 1001; gate
assert_eq 1 "$STATUS"; assert_eq '1001' "$(jq -r '.blocking[].reviewer' <<< "$OUTPUT")"

it 'formatting cannot turn a T3 lenses policy into a legacy approval'
tier T3; review APPROVED 1001; review APPROVED 1003
publishers='- review-publishers: bot:1001,user:1004,user:1006'
mapping="${separate#*: }"
for key in '-  review-lenses:' '- REVIEW-LENSES:' $'-\treview-lenses:' \
    '- review-lenses   :' '- review-lenses =' '-review-lenses:' \
    $'- review-lenses\302\240:' $'- review-lenses\342\200\207:' $'- review-lenses\342\200\257:' \
    '- `review-lenses`:' '- review-lenses' '* review-lenses:' '+ review-lenses:' \
    '1. Review-`Lenses` maps these areas'; do
    policy "$publishers" "$key $mapping"; gate
    assert_eq 1 "$STATUS" "reject '$key'"; assert_contains "$OUTPUT" 'Invalid review-lenses key'
    assert_contains "$OUTPUT" 'config.md line 5'
done
policy "$publishers" "$separate   "; gate
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'approval for the design area'

it 'only assignments affect policy; prose leaves a valid legacy gate alone'
policy "$publishers" '- review-lenses are optional.'; gate
assert_eq 0 "$STATUS" "$OUTPUT"; assert_not_contains "$OUTPUT" '"areas":'
it 'raw lens policy rejects comment and fence markers, even when they look like prose'
for marker in 'A literal `<!--` starts a comment.' '    ~~~' '```text' '-->' $'\342\200\257~~~'; do
    policy "$publishers" "$marker" "$separate"; gate
    assert_eq 1 "$STATUS" "reject '$marker' before mapping"
    assert_contains "$OUTPUT" 'comments and fenced blocks are not allowed'
done
policy "$publishers" '<!--' "$separate" '-->'; gate
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'comments and fenced blocks are not allowed'
policy "$publishers" 'The `Review-Lenses` setting is optional.' '<!-- note -->'; gate
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'comments and fenced blocks are not allowed'

it 'publisher-only policy also rejects comment and fence markers'
policy "$publishers" '<!--' '- review-publishers: bot:42' '-->' \
    '```text' '- review-owner: user:42' '```' 'A literal `<!--` is harmless.'; gate
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'config.md line 5'
policy 'A literal `<!--` is harmless.' "$publishers"; gate
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'config.md line 4'

it 'the shipped template keeps examples outside the raw policy section'
awk -v pub="$publishers" -v lenses="$separate" '
    { print } /^## Configuration$/ {
        print "- review-host: github\n- review-owner: user:1003"; print pub; print lenses
    }' "$PK_ROOT/templates/config-template.md" | trusted_edit "$ref" "$config"
gate; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'approval for the design area'
review APPROVED 1004; gate; assert_eq 0 "$STATUS" "$OUTPUT"

it 'a hidden heading cannot supply required host and owner policy'
for mapping_line in '' "$separate"; do
    printf '%s\n' '```text' '## Configuration' '- review-host: github' \
        '- review-owner: user:1003' "$publishers" "$mapping_line" | trusted_edit "$ref" "$config"
    gate; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'config.md line 1'
done
# Previous visible credentials must not compensate for an ambiguous later heading.
for fence in '```text' '~~~text'; do
    policy "$publishers" '## Meaning' "$fence" '## Configuration' "$separate"; gate
    assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'config.md lines 1 and 7'
done
printf '%s\n' '## Configuration' "$separate" '## Meaning' '- review-host: github' \
    '- review-owner: user:1003' | trusted_edit "$ref" "$config"
gate; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'review-host: github'

it 'a shorter backtick marker cannot expose policy inside a longer fence'
heading_fixture() {
    local lens_line="$1"; shift
    printf '%s\n' "$@" '## Configuration' '- review-host: github' '- review-owner: user:1003' \
        "$publishers" "$lens_line" | trusted_edit "$ref" "$config"
}
for mapping_line in "$separate" ''; do
    for opener in '````text' '~~~~text'; do
        heading_fixture "$mapping_line" "$opener" "${opener:0:3}"
        gate; assert_eq 1 "$STATUS" 'example credentials must not authorize T3'
        assert_contains "$OUTPUT" 'config.md line 1'
    done
    for closer in '````' '~~~'; do
        heading_fixture "$mapping_line" '```text' "$closer"
        gate; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'config.md line 1'
    done
done

it 'fence indentation and pairing cannot confer authority on later fields'
for closer in '```' '   ```' '    ```'; do
    heading_fixture "$separate" '```text' '~~~' "$closer"
    gate; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'config.md line 1'
done

it 'the fence check includes the selected policy section but ends before later documentation'
policy "$publishers" '```' '~~~~'; gate
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'config.md line 5'
policy "$publishers" "$separate" '## Meaning' '````text' '```'; gate
assert_eq 0 "$STATUS" "$OUTPUT"

it 'a heading inside a policy example cannot hide a subsequent design requirement'
tier T3; review APPROVED 1001; review APPROVED 1003
for marker in '```text' '<!--'; do
    if [ "$marker" = '<!--' ]; then closer='-->'; else closer='```'; fi
    policy "$publishers" "$marker" '## Example' "$closer" "$separate"; gate
    assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'config.md line 5'
done

it 'a second Configuration heading anywhere reports both locations'
for heading in '## Configuration' '   #### CONFIGURATION ##' $'Configuration\n   ---' $'Configuration\n==='; do
    policy "$publishers" '## Meaning' '```' "$heading" '```'; gate
    assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'config.md lines 1 and 7'
done

it 'level-two heading spelling and section boundaries use raw lines'
review APPROVED 1004
for heading in ' ## Configuration' '  ## configuration ###' $'   ##\tCONFIGURATION' $'Configuration\n---'; do
    for boundary in '# Notes' '  ## Notes' $'Notes\n===' $'Notes\n---'; do
        printf '%s\n' "$heading" '- review-host: github' '### Roles' '- review-owner: user:1003' \
            "$separate" "$boundary" '<!-- examples -->' '```' '- review-owner: user:42' '```' |
            trusted_edit "$ref" "$config"
        gate; assert_eq 0 "$STATUS" "$heading / $boundary: $OUTPUT"
    done
done

it 'a noncanonical publisher assignment cannot silently evade the union check'
review APPROVED 1004
for key in '-  review-publishers:' '- REVIEW-PUBLISHERS:' $'-\treview-publishers:' '- review-publishers =' \
    $'- review-publishers\302\240:' '- `review-publishers`:' '- review-publishers'; do
    policy "$separate" "$key bot:1001"; gate
    assert_eq 1 "$STATUS" "reject '$key'"; assert_contains "$OUTPUT" 'Invalid review-publishers key'
    assert_contains "$OUTPUT" 'config.md line 5'
done

it 'invalid, conflicting or unregistered mappings fail before host approval'
for invalid in '' 'code=bot:0' 'code=bot:1|' 'code=bot:1,' 'code=1' 'code=bot:1,code=user:2' \
    'code=bot:1,design=user:1' 'unknown=user:1004' 'implementation=user:1004'; do
    policy "- review-lenses: $invalid"; gate
    assert_eq 1 "$STATUS" "refuse '$invalid'"; assert_contains "$OUTPUT" 'review-lenses'
done
for extra in "$separate" '- review-publishers: user:1004' '- review-publishers: bot:1001,user:1004,user:1006,bot:1007' \
    '- review-publishers: user:1001,user:1004,user:1006'; do
    policy "$separate" "$extra"; gate
    assert_eq 1 "$STATUS" "refuse '$extra'"; assert_contains "$OUTPUT" 'review-lenses'
done
it 'candidate registry or mapping cannot authorize design'
policy "$separate"
git show "$base:$registry" | sed '/^| design | reviewer |/d' | trusted_edit "$ref" "$registry"
gate; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" "area 'design' must name one eligible reviewer"

it 'documentation cannot supply a T0 path or an additional trusted base'
tier T0
mkdir -p docs; echo note > docs/note; git add docs/note; git commit -qm 'document change'
fx_pr 7 "$(git rev-parse HEAD)"
git update-ref refs/remotes/origin/integration "$base"
policy "$publishers" '# Meaning' '- review-t0-paths: docs/' '- review-integration-branches: origin/integration'
gate; assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'lists no review-t0-paths'
run bash .prdkit/scripts/bash/check-review.sh --json --base origin/integration 001-reviewed
assert_eq 1 "$STATUS"; assert_contains "$OUTPUT" 'not a trusted integration branch'
policy "$publishers" '- review-t0-paths: docs/' '- review-integration-branches: origin/integration' '# Meaning'
gate; assert_eq 0 "$STATUS" "$OUTPUT"
run bash .prdkit/scripts/bash/check-review.sh --json --base origin/integration 001-reviewed
assert_eq 3 "$STATUS" 'configured base qualifies for structural preview'
finish
