#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
project="$(make_project)"; track_tmp "$project"
remote="$(mktemp -d)"; track_tmp "$remote"
git init --bare -q "$remote"
git -C "$project" remote add origin "$remote"
git -C "$project" checkout -qb 901-delivery
mkdir -p "$project/specs/changes"
printf 'checkpoint\n' > "$project/specs/changes/901-delivery.md"
git -C "$project" add specs && git -C "$project" commit -qm checkpoint
feature="$project/specs/changes"
helper="$PK_ROOT/scripts/check-delivery.sh"

it "unpublished source is not remote-ready"
run bash "$helper" --json "$feature"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" '"transport":"BLOCKED"'
assert_contains "$OUTPUT" 'absent or could not be queried'

it "an explicit local-only observation does not claim remote availability"
run bash "$helper" --json --local-only "$feature"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '"transport":"LOCAL_ONLY"'
assert_contains "$OUTPUT" '"remote_revision":""'

it "a clean exact remote checkpoint passes"
git -C "$project" push -q origin HEAD
before="$(git -C "$project" status --porcelain; git -C "$project" show-ref)"
run bash "$helper" --json "$feature"
assert_eq 0 "$STATUS"
assert_contains "$OUTPUT" '"transport":"REMOTE_READY"'
run bash -c 'cd "$1" && bash "$2" --json' _ "$project" "$helper"
assert_eq 0 "$STATUS" 'the checkout defaults to the current directory'
assert_contains "$OUTPUT" '"transport":"REMOTE_READY"'
assert_contains "$OUTPUT" "\"remote_revision\":\"$(git -C "$project" rev-parse HEAD)\""
assert_eq "$before" "$(git -C "$project" status --porcelain; git -C "$project" show-ref)" 'observation does not change local refs or tree'

it "read-only observation does not refresh index stat metadata"
sleep 1
touch "$feature/901-delivery.md"
index_before="$(git -C "$project" hash-object .git/index)"
run bash "$helper" --json "$feature"
assert_eq 0 "$STATUS"
assert_eq "$index_before" "$(git -C "$project" hash-object .git/index)" 'index bytes are unchanged'

it "new untracked evidence prevents a clean handover claim"
printf 'pending\n' > "$feature/pending.md"
run bash "$helper" --json "$feature"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'pending.md'
git -C "$project" add specs && git -C "$project" commit -qm evidence

it "cached remote tracking cannot hide an unpublished commit"
run bash "$helper" --json "$feature"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'does not match local HEAD'

it "submodule ignore settings cannot hide unpublished nested work"
module="$(make_project)"; track_tmp "$module"
git -C "$project" -c protocol.file.allow=always submodule add -q "$module" deps/demo
git -C "$project" add -A && git -C "$project" commit -qm module
git -C "$project" push -q origin HEAD
git -C "$project" config submodule.deps/demo.ignore all
printf 'unpublished nested work\n' > "$project/deps/demo/.gitkeep"
run bash "$helper" --json "$feature"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'deps/demo'
assert_contains "$OUTPUT" 'Uncommitted paths remain'
git -C "$project/deps/demo" restore -- .gitkeep
git -C "$project" config --unset submodule.deps/demo.ignore

it "fresh remote changes are detected without fetching"
git -C "$project" push -q origin HEAD
peer="$(mktemp -d)"; track_tmp "$peer"
git clone -q --branch 901-delivery "$remote" "$peer"
git -C "$peer" -c user.name=test -c user.email=t@example.com commit --allow-empty -qm remote-change
git -C "$peer" push -q origin HEAD
run bash "$helper" --json "$feature"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'does not match local HEAD'

it "detached checkpoints are not falsely available as a branch"
git -C "$project" checkout -q --detach
run bash "$helper" --json "$feature"
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'Detached HEAD'
finish
