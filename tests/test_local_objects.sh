#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$TESTS_DIR/install-fixture.sh"
REAL_GIT="$(command -v git)"; export REAL_GIT
source_fixture
CONTROL="$(mktemp -d)"; track_tmp "$CONTROL"
export LOCAL_PROBE="$CONTROL" SOURCE_REPO="$KIT"
export GIT_ALLOW_PROTOCOL=file
mkdir "$CONTROL/bin"
cat > "$CONTROL/upload-pack" <<'EOF'
#!/bin/sh
printf 'local upload-pack attempted\n' >> "$LOCAL_PROBE/upload"
exit 73
EOF
cat > "$CONTROL/bin/git" <<'EOF'
#!/bin/sh
if [ "$1" = version ] && [ "${PROBE_OLD_GIT:-false}" = true ]; then echo 'git version 2.44.0'; exit 0; fi
if [ "${PROBE_CONFIG_ERROR:-false}" = true ] && [ "$1" = -C ] && [ "$2" = "$SOURCE_REPO" ] && [ "$3" = config ]; then exit 128; fi
for arg in "$@"; do
    case "$arg" in
        fetch) printf 'fetch attempted\n' >> "$LOCAL_PROBE/fetch" ;;
        cat-file|ls-tree|rev-parse)
            if [ "$1" = -C ] && [ "$2" = "${CONSUMER_REPO:-}" ]; then printf 'consumer lookup\n' >> "$LOCAL_PROBE/consumer-reads"; fi
            [ "$arg" != rev-parse ] || continue
            if [ "$1" = -C ] && [ "$2" = "$SOURCE_REPO" ]; then printf 'source object read\n' >> "$LOCAL_PROBE/reads"; fi ;;
    esac
done
exec "$REAL_GIT" "$@"
EOF
chmod +x "$CONTROL/upload-pack" "$CONTROL/bin/git"
git clone -q --bare --no-hardlinks "$KIT" "$CONTROL/promisor" || exit 1
git -C "$KIT" config remote.origin.url "$CONTROL/promisor"
git -C "$KIT" config remote.origin.uploadpack "$CONTROL/upload-pack"
object="$(git -C "$KIT" rev-parse "$KIT_PIN:workflows/work.md")"
object_file="$KIT/.git/objects/${object:0:2}/${object:2}"
cp "$object_file" "$CONTROL/object"
git -C "$KIT" config remote.origin.promisor true
export PATH="$CONTROL/bin:$PATH"

clear_signals() { : > "$CONTROL/fetch"; : > "$CONTROL/upload"; : > "$CONTROL/reads"; : > "$CONTROL/trace"; : > "$CONTROL/consumer-reads"; }
guarded_check() {
    clear_signals
    before="$(fixture_snapshot "$FIXTURE")"
    run env GIT_TRACE="$CONTROL/trace" bash "$CHECKER" --require-source --json "$@"
    assert_eq 1 "$STATUS" 'missing local evidence fails closed'
    assert_contains "$OUTPUT" '"source_verification":"failed"' 'no verified result'
    assert_eq '' "$(cat "$CONTROL/fetch" "$CONTROL/upload")" 'no fetch/transport invocation'
    assert_not_contains "$(cat "$CONTROL/trace")" ' fetch ' 'no internal Git fetch'
    assert_eq "$before" "$(fixture_snapshot "$FIXTURE")" 'all project and Git state remains identical'
    [ ! -e "$object_file" ] && _ok 'missing object stays absent'
}

it 'local transport instrumentation observes an unguarded missing-object read'
rm "$object_file"
clear_signals
run bash -c 'unset GIT_NO_LAZY_FETCH; GIT_TRACE="$LOCAL_PROBE/trace" "$REAL_GIT" -C "$SOURCE_REPO" cat-file blob "$1"' _ "$object"
if [ "$STATUS" -ne 0 ]; then _ok 'sentinel prevents any transfer'; else _no 'local transport guard did not refuse'; fi
assert_contains "$(cat "$CONTROL/upload")" 'local upload-pack attempted' 'configured local transport is actually reached'
assert_contains "$(cat "$CONTROL/trace")" ' fetch ' 'missing-object read actually launches a fetch'
[ ! -e "$object_file" ] && _ok 'control transferred no source objects'

it 'required objects stay missing with a configured local promisor'
guarded_check
guarded_check --head HEAD
blob_file="$object_file"
for kind in commit tree; do
    object="$KIT_PIN"
    [ "$kind" != tree ] || object="$("$REAL_GIT" -C "$KIT" rev-parse "$KIT_PIN^{tree}")"
    object_file="$KIT/.git/objects/${object:0:2}/${object:2}"
    mv "$object_file" "$CONTROL/$kind"
    guarded_check
    guarded_check --head HEAD
    mv "$CONTROL/$kind" "$object_file"
done
object_file="$blob_file"

it 'the local-only assertion detects removal of the verifier protection'
if spec_objects_local "$KIT"; then
    cp "$FIXTURE/.prdkit/scripts/bash/install-source-lib.sh" "$CONTROL/library"
    sed 's/GIT_NO_LAZY_FETCH=1 //' "$CONTROL/library" > "$FIXTURE/.prdkit/scripts/bash/install-source-lib.sh"
    clear_signals
    run bash -c 'unset GIT_NO_LAZY_FETCH; GIT_TRACE="$LOCAL_PROBE/trace" bash "$1" --head HEAD --json' _ "$CHECKER"
    assert_contains "$(cat "$CONTROL/upload")" 'local upload-pack attempted' 'a disposable verifier mutation reaches the sentinel'
    cp "$CONTROL/library" "$FIXTURE/.prdkit/scripts/bash/install-source-lib.sh"
else
    guarded_check --head HEAD
    assert_contains "$OUTPUT" 'source Git cannot guarantee local-only object reads'
    assert_eq '' "$(cat "$CONTROL/reads")" 'legacy Git refuses before source object reads'
fi

it 'Git Boolean settings are interpreted consistently on unsupported Git'
export PROBE_OLD_GIT=true
for value in true yes on 1; do
    git -C "$KIT" config remote.origin.promisor "$value"
    guarded_check --head HEAD
    assert_contains "$OUTPUT" 'cannot guarantee local-only object reads' 'unsupported Git refuses before object reads'
    assert_eq '' "$(cat "$CONTROL/reads")" 'no source objects inspected on unsupported Git'
done
git -C "$FIXTURE" config remote.origin.url "$CONTROL/promisor"
git -C "$FIXTURE" config remote.origin.promisor yes
guarded_check --head HEAD
assert_contains "$OUTPUT" 'consumer Git cannot guarantee' 'consumer guard also refuses unsupported Git'
git -C "$FIXTURE" config --unset remote.origin.promisor
git -C "$KIT" config --unset remote.origin.promisor
export CONSUMER_REPO="$FIXTURE"
for repo in "$KIT" "$FIXTURE"; do
    git -C "$repo" config remote.origin.partialclonefilter blob:none
    guarded_check --head HEAD
    assert_contains "$OUTPUT" 'cannot guarantee local-only object reads' 'filter alone requires local-only support'
    assert_eq '' "$(cat "$CONTROL/reads")" 'filter-only guard precedes source object reads'
    if [ "$repo" = "$FIXTURE" ]; then
        assert_eq '' "$(cat "$CONTROL/consumer-reads")" 'filter-only consumer guard precedes revision lookup'
    fi
    git -C "$repo" config --unset remote.origin.partialclonefilter
done
cp "$CONTROL/object" "$object_file"
for value in false no off 0 ''; do
    git -C "$KIT" config remote.origin.promisor "$value"
    run spec_objects_local "$KIT"
    assert_eq 0 "$STATUS" "genuine false setting: $value"
done
git -C "$KIT" config remote.origin.promisor invalid
run spec_objects_local "$KIT"
assert_eq 1 "$STATUS" 'malformed Boolean setting is not complete evidence'
git -C "$KIT" config --unset remote.origin.promisor
export PROBE_CONFIG_ERROR=true
run spec_objects_local "$KIT"
assert_eq 1 "$STATUS" 'unreadable config fails closed'
unset PROBE_CONFIG_ERROR PROBE_OLD_GIT
finish
