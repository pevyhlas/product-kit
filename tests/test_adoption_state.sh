#!/usr/bin/env bash
# Installed version and layout are independent observations, not migration certification.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
version="$(cat "$PK_ROOT/VERSION")"

check_adoption() { # layout mixed migration [installed version; empty means unknown]
    local script observed expected before doctor_json='' status_json=''
    expected="$(jq -cn --arg version "${4-$version}" --arg layout "$1" --argjson mixed "$2" --arg migration "$3" \
        '{installed_version: (if $version == "" then null else $version end), spec_layout: $layout, mixed_spec_forms: $mixed, migration_state: $migration}')"
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

it 'a fresh installation has a known kit version but unknown migration state'
check_adoption none false unknown

it 'a current installed kit with legacy specs still needs migration'
mkdir -p specs/product-spec
printf '# Legacy product\n' > specs/product-spec/overview.md
check_adoption 0.x false required
for script in doctor status; do
    run bash ".prdkit/scripts/bash/$script.sh"
    assert_eq 0 "$STATUS" 'legacy layout remains advisory'
    assert_contains "$OUTPUT" "Installed kit version (manifest): $version" 'version is visible without inventory'
    assert_contains "$OUTPUT" 'Spec layout: legacy (0.x)' 'legacy layout is distinct from installed version'
    assert_contains "$OUTPUT" 'Migration state: required' 'migration requirement is explicit'
done
run bash .prdkit/scripts/bash/doctor.sh --strict --json
assert_eq 1 "$STATUS" 'existing strict legacy advisory still fails'

it 'legacy and current canons indicate incomplete migration'
printf '# Product\n' > specs/product.md
check_adoption both false incomplete

it 'current layout does not certify migration completion'
rm specs/product-spec/overview.md
touch specs/product-spec/.gitkeep
check_adoption 1.0 false not-indicated
for script in doctor status; do
    run bash ".prdkit/scripts/bash/$script.sh"
    assert_contains "$OUTPUT" 'Spec layout: current (1.x)' 'layout family is named separately'
    assert_contains "$OUTPUT" 'Migration state: not-indicated' 'current layout state'
    assert_contains "$OUTPUT" 'completion not verified' 'no inferred completion'
done
run bash .prdkit/scripts/bash/doctor.sh --json --strict --inventory
assert_eq 0 "$STATUS" 'summary adds no advisory to a clean current spec'
run jq -e --arg version "$version" '.findings == [] and .advisories == [] and .configuration.version == $version and .adoption.installed_version == .configuration.version' <<< "$OUTPUT"
assert_eq 0 "$STATUS" 'inventory and ordinary version agree; no new findings'

it 'competing current spec forms remain incomplete'
printf '# Spec\n' > specs/SPEC.md
check_adoption 1.0 true incomplete
rm specs/product.md
check_adoption 1.0 false not-indicated

it 'ignored legacy leftovers do not indicate a pending cutover'
printf 'specs/features/\n' > .gitignore
mkdir -p specs/features/001-old
printf '# Old feature\n' > specs/features/001-old/spec.md
check_adoption 1.0 false not-indicated

it 'tracked legacy feature leftovers do indicate an incomplete cutover'
git add -f specs/features/001-old/spec.md
check_adoption both false incomplete
git rm -qf specs/features/001-old/spec.md

it 'source version is never substituted for installed version'
printf '99.0.0\n' > .product-kit/VERSION
check_adoption 1.0 false not-indicated
mv .product-kit source-unavailable
check_adoption 1.0 false not-indicated

it 'missing, empty and duplicate manifest versions stay unknown'
cp .prdkit/.manifest manifest-backup
for metadata in missing empty duplicate; do
    sed '/^version: /d' manifest-backup > .prdkit/.manifest
    case "$metadata" in
        empty) printf 'version: \n' >> .prdkit/.manifest ;;
        duplicate) printf 'version: %s\nversion: %s\n' "$version" "$version" >> .prdkit/.manifest ;;
    esac
    check_adoption 1.0 false not-indicated ''
done
rm .prdkit/.manifest
check_adoption 1.0 false not-indicated ''
for script in doctor status; do
    run bash ".prdkit/scripts/bash/$script.sh"
    assert_contains "$OUTPUT" 'Installed kit version (manifest): unknown' 'missing manifest is explicit in text'
done

it 'manifest strings are safely JSON-escaped observations'
sed '/^version: /d' manifest-backup > .prdkit/.manifest
printf 'version: custom "build" \\ tag\n' >> .prdkit/.manifest
check_adoption 1.0 false not-indicated 'custom "build" \ tag'
finish
