#!/usr/bin/env bash
# Installed version and layout are independent observations, not integrity verdicts.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
version="$(cat "$PK_ROOT/VERSION")"

check_adoption() { # layout mixed [installed version; empty means unknown]
    local script observed expected before doctor_json='' status_json=''
    expected="$(jq -cn --arg version "${3-$version}" --arg layout "$1" --argjson mixed "$2" \
        '{installed_version: (if $version == "" then null else $version end), spec_layout: $layout, mixed_spec_forms: $mixed}')"
    before="$(git status --porcelain --untracked-files=all)"
    for script in doctor status; do
        run bash ".prdkit/scripts/bash/$script.sh" --json
        if [ "$script" = doctor ]; then doctor_json="$OUTPUT"; else status_json="$OUTPUT"; fi
        observed="$(printf '%s\n' "$OUTPUT" | jq -c .adoption)"
        assert_eq "$expected" "$observed" "$script: $_CURRENT"
    done
    run jq -e '.layout == .adoption.spec_layout and .mixed_spec_forms == .adoption.mixed_spec_forms' <<< "$status_json"
    assert_eq 0 "$STATUS" 'existing status fields remain consistent'
    run jq -e 'has("configuration") | not' <<< "$doctor_json"
    assert_eq 0 "$STATUS" 'summary does not require the full inventory'
    assert_eq "$before" "$(git status --porcelain --untracked-files=all)" 'diagnosis leaves working tree and index unchanged'
}

it 'a fresh installation records the installed version and no spec'
check_adoption none false

it 'an unsupported layout is a finding, even if current canon exists'
mkdir -p specs/features/001-old
printf '# Old feature\n' > specs/features/001-old/spec.md
printf '# Product\n' > specs/product.md
run bash .prdkit/scripts/bash/doctor.sh --json
assert_eq 1 "$STATUS"
assert_eq unsupported "$(jq -r .adoption.spec_layout <<< "$OUTPUT")"
assert_contains "$OUTPUT" 'specs/changes/<id>.md records'
run bash .prdkit/scripts/bash/status.sh --json
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'specs/changes/<id>.md records'
rm specs/features/001-old/spec.md

it 'the current layout is distinct from the version'
fill_seeded_policy "$PROJ" || exit 1
check_adoption 1.0 false
run bash .prdkit/scripts/bash/doctor.sh --json --strict --inventory
assert_eq 0 "$STATUS" 'summary adds no advisory to a clean current spec'
run jq -e --arg version "$version" '.findings == [] and .advisories == [] and .configuration.version == $version and .adoption.installed_version == .configuration.version' <<< "$OUTPUT"
assert_eq 0 "$STATUS" 'inventory and ordinary version agree; no new findings'

it 'competing current spec forms remain incomplete'
printf '# Spec\n' > specs/SPEC.md
check_adoption 1.0 true
rm specs/product.md
check_adoption 1.0 false

it 'source version is never substituted for installed version'
printf '99.0.0\n' > .product-kit/VERSION
check_adoption 1.0 false
mv .product-kit source-unavailable
check_adoption 1.0 false

it 'missing, empty and duplicate manifest versions stay unknown'
cp .prdkit/.manifest manifest-backup
for metadata in missing empty duplicate; do
    sed '/^version: /d' manifest-backup > .prdkit/.manifest
    case "$metadata" in
        empty) printf 'version: \n' >> .prdkit/.manifest ;;
        duplicate) printf 'version: %s\nversion: %s\n' "$version" "$version" >> .prdkit/.manifest ;;
    esac
    check_adoption 1.0 false ''
done
rm .prdkit/.manifest
check_adoption 1.0 false ''
for script in doctor status; do
    run bash ".prdkit/scripts/bash/$script.sh"
    assert_contains "$OUTPUT" 'Installed kit version (manifest): unknown' 'missing manifest is explicit in text'
done

it 'manifest strings are safely JSON-escaped observations'
sed '/^version: /d' manifest-backup > .prdkit/.manifest
printf 'version: custom "build" \\ tag\n' >> .prdkit/.manifest
check_adoption 1.0 false 'custom "build" \ tag'
finish
