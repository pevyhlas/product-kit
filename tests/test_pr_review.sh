#!/usr/bin/env bash
# Synthetic transport around the REAL integrated native gate. Nothing contacts a live host.
# Instrumentation is confined to disposable source/tools; production has no override interface.
# shellcheck disable=SC2016,SC2034 # generated fixture scripts and extracted selector inputs
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
source "$PK_ROOT/scripts/common.sh"
source "$PK_ROOT/scripts/spec-lib.sh"
source "$PK_ROOT/scripts/review-fingerprint-lib.sh"
STATUS=0
PROJ="$(make_inited_project)"; track_tmp "$PROJ"
cd "$PROJ" || exit 1
cat >> .prdkit/memory/config.md <<'EOF'

## Configuration
- review-host: github
- review-publishers: bot:1001
- review-owner: user:1003
- review-publisher-isolation: required
- review-t0-paths: docs/
- review-integration-branches: origin/integration
EOF
printf '\n## Review registry\n| Identity | Role |\n|---|---|\n| code | reviewer |\n' >> .prdkit/memory/agents.md
git add -A; git commit -qm policy
BASE="$(git rev-parse HEAD)"
git branch -f main "$BASE"
git branch integration "$BASE"
git checkout -qb feat/carrier
mkdir -p specs/changes docs
printf '# Carrier\n**Tier**: T0\n## State\n' > specs/changes/001-carrier.md
printf 'guide\n' > docs/guide.md
git add -A; git commit -qm carrier
HEAD_SHA="$(git rev-parse HEAD)"
use_gh_stub
FIX="$(mktemp -d)"; track_tmp "$FIX"
mkdir "$FIX/bin" "$FIX/scratch"
REAL_GIT="$(command -v git)"
REAL_RM="$(command -v rm)"
REAL_BASH=/bin/bash
EXPECTED_BASH="$("$REAL_BASH" --noprofile --norc -c 'printf "%s" "$BASH_VERSION"')"
printf 'launcher interpreter: %s %s (%s)\n' "$REAL_BASH" "$EXPECTED_BASH" "$(uname -s)"
if [ "$(uname -s)" = Darwin ]; then
    case "$EXPECTED_BASH" in 3.2.*) _ok 'native macOS supervisor is Bash 3.2' ;; *) _no 'native system Bash 3.2 required' "$EXPECTED_BASH" ;; esac
fi
ORIGINAL_PATH="$PATH"
# The fake gh embeds its own fixture custody, rather than exposing a production environment knob.
{
    printf '#!/bin/bash\nexport GH_STUB_DIR=%q\n' "$GH_STUB_DIR"
    printf 'exec %q "$@"\n' "$GH_STUB_DIR/bin/gh"
} > "$FIX/bin/gh"
# Only the HTTPS fetch is routed to an owned synthetic repository. All object reads, full-history
# selection, trusted extraction, fingerprints, receipt parsing and native evaluation are real.
{
    printf '#!/bin/bash\n'
    printf 'for a in "$@"; do\n'
    printf '  if [ "$a" = fetch ]; then\n'
    printf '    [ ! -e %q ] || { sleep 60 & echo $! > %q; wait; }\n' "$FIX/hang" "$FIX/descendant"
    printf '    [ ! -e %q ] || exit 1\n' "$FIX/fetch-fail"
    printf '    args=(); for arg in "$@"; do\n'
    printf '      case "$arg" in https://github.com/owner/repo.git) arg=%q ;; esac\n' "$PROJ"
    printf '      args+=("$arg"); done\n'
    printf '    exec %q -c protocol.file.allow=always "${args[@]}"\n' "$REAL_GIT"
    printf '  fi\n'
    printf 'done\n'
    printf 'exec %q "$@"\n' "$REAL_GIT"
} > "$FIX/bin/git"
{
    printf '#!/bin/bash\n'
    printf 'if [ -f %q ] && [ "$#" = 3 ] && [ "$1" = -rf ] && [ "$2" = -- ]; then\n' "$FIX/cleanup-fail"
    printf '  case "$3" in %q/prdkit-pr.*) exit 1 ;; esac\nfi\n' "$FIX/scratch"
    printf 'exec %q "$@"\n' "$REAL_RM"
} > "$FIX/bin/rm"
chmod +x "$FIX/bin/"*
instrument() {
    # Fixed source substitutions, never installed or committed as production options.
    sed -e "s|^PATH=.*|PATH=$FIX/bin:/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin|" \
        -e "s|mktemp -d /tmp/prdkit-pr.XXXXXXXX|mktemp -d $FIX/scratch/prdkit-pr.XXXXXXXX|" \
        -e "/^set -euo pipefail/a\\
printf '%s\\\\n' \"\\\$BASH_VERSION\" > \"$FIX/interpreter\"
" \
        "$PK_ROOT/scripts/check-pr-review.sh" > "$FIX/launcher"
}
instrument
bindings() { # head [branch] [target]
    local h="$1" b="${2:-feat/carrier}" t="${3:-main}" p tip
    p="$(git rev-parse main)"; tip="$(git rev-parse "$t")"
    fx_pr 7 "$h" "$(jq -cn --arg branch "$b" --arg target "$t" --arg tip "$tip" '
        {head:{ref:$branch,repo:{id:42}},base:{ref:$target,sha:$tip,repo:{id:42,full_name:"owner/repo"}}}')"
    git update-ref refs/pull/7/head "$h"
    jq -n --slurpfile pr "$GH_STUB_DIR/pulls/7.json" \
        '{action:"synchronize",number:7,repository:{id:42,full_name:"owner/repo"},pull_request:$pr[0]}' > "$FIX/event"
    printf '{"id":42,"full_name":"owner/repo","default_branch":"main"}\n' > "$GH_STUB_DIR/routes/repos_owner_repo.json"
    jq -n --arg sha "$p" '{ref:"refs/heads/main",object:{type:"commit",sha:$sha}}' \
        > "$GH_STUB_DIR/routes/git_ref_heads_main.json"
    jq -n --arg sha "$tip" --arg ref "refs/heads/$t" '{ref:$ref,object:{type:"commit",sha:$sha}}' \
        > "$GH_STUB_DIR/routes/git_ref_heads_${t}.json"
}
invoke_launcher() {
    if env -i PATH="$ORIGINAL_PATH" GH_TOKEN=synthetic-read-token GITHUB_EVENT_NAME=pull_request \
        GITHUB_REPOSITORY=owner/repo GITHUB_REPOSITORY_ID=42 \
        "$@" \
        "$REAL_BASH" --noprofile --norc "$FIX/launcher" --repository owner/repo --event "$FIX/event" \
        > "$FIX/stdout" 2>"$FIX/stderr"; then STATUS=0; else STATUS=$?; fi
    OUTPUT="$(cat "$FIX/stdout")"
}
launch() {
    invoke_launcher "$@"
    assert_eq "$EXPECTED_BASH" "$(cat "$FIX/interpreter")" 'actual nested supervisor interpreter'
    assert_eq 1 "$(printf '%s' "$OUTPUT" | jq -s length)" 'one structured stdout object'
    assert_eq '' "$(find "$FIX/scratch" -mindepth 1 -print)" 'owned scratch cleaned'
}
assert_terminated() {
    local state
    if [[ ! "$1" =~ ^[1-9][0-9]*$ ]]; then _no "$2" "missing or invalid fixture PID"; return; fi
    state="$(ps -o stat= -p "$1" 2>/dev/null || true)"
    state="${state//[[:space:]]/}"
    if [[ -z "$state" || "$state" =~ ^Z[+\<NsL]*$ ]]; then _ok "$2"; else _no "$2" "$state"; fi
}
await_fixture() { # explicit fixture readiness, including on a loaded runner
    local pid="$1" first="$2" second="${3:-$2}" end=$((SECONDS+120))
    while [ "$SECONDS" -lt "$end" ]; do
        if [ -s "$first" ] && [ -s "$second" ]; then return 0; fi
        kill -0 "$pid" 2>/dev/null || return 1
        sleep 0.1
    done
    return 1
}
arm_fixture_deadline() { # capture basename, readiness file, bounded's deadline variable
    # Keep the normal deadline as a fallback if the fixture never starts. Once
    # ready, shorten only the selected clock and let the real check expire it.
    awk -v capture="$1" -v ready="$FIX/$2" -v clock="$3" '
        { print }
        /^    while \[ ! -f "\$operation\/work.status" \]; do$/ {
            print "        if [ \"$out\" = \"$root/" capture "\" ] && [ -s \"" ready "\" ] && [ -z \"${fixture_armed:-}\" ]; then"
            print "            local fixture_armed=1; " clock "=$((SECONDS+2))"
            print "        fi"
        }
    ' "$FIX/launcher" > "$FIX/short"
    mv "$FIX/short" "$FIX/launcher"
}
bindings "$HEAD_SHA"

it 'installed entrypoint and valid real integrated native T0 host control'
assert_file .prdkit/scripts/bash/check-pr-review.sh
launch
assert_eq 0 "$STATUS" "$OUTPUT $(cat "$FIX/stderr")"
assert_eq complete "$(printf '%s' "$OUTPUT" | jq -r .launcher)"
assert_eq host "$(printf '%s' "$OUTPUT" | jq -r .native.authority)"
assert_eq "$HEAD_SHA" "$(printf '%s' "$OUTPUT" | jq -r .native.diagnostics.head)"
assert_eq "$BASE" "$(printf '%s' "$OUTPUT" | jq -r .native.diagnostics.policy_at)"

it 'forks and drafts use the base repository numeric PR ref, never candidate clone URLs'
bindings "$HEAD_SHA"
jq '.head.repo.id=77|.head.repo.clone_url="https://untrusted.invalid/source"|.draft=true' \
    "$GH_STUB_DIR/pulls/7.json" > "$FIX/pr"
mv "$FIX/pr" "$GH_STUB_DIR/pulls/7.json"
jq --slurpfile p "$GH_STUB_DIR/pulls/7.json" '.pull_request=$p[0]|.action="converted_to_draft"' "$FIX/event" > "$FIX/new-event"
mv "$FIX/new-event" "$FIX/event"
launch; assert_eq 0 "$STATUS" "$OUTPUT"
bindings "$HEAD_SHA"

it 'real native T1 authenticated coverage passes, while an invalid receipt still blocks beside it'
git checkout -q --detach "$HEAD_SHA"
printf '# Carrier\n**Tier**: T1\n## State\n' > specs/changes/001-carrier.md
printf 'implementation\n' > source.txt
git add -A; git commit -qm 'T1 implementation'
T1_HEAD="$(git rev-parse HEAD)"
FP="$(review_fingerprint "$PROJ" 001-carrier "$BASE" "$T1_HEAD")"
bindings "$T1_HEAD"
PAYLOAD="$(jq -cn --arg head "$T1_HEAD" --arg base "$BASE" --arg fp "$FP" '
    {schema:"prdkit.review.v3",id:"00000000000000000000000000000001",repo:"owner/repo",pr:7,
     change:"001-carrier",reviewer:"code",from:"start",to:$fp,head:$head,since:"",
     base:"refs/remotes/origin/main",base_at:$base,verdict:"PASS",
     critical:0,high:0,medium:0,low:0,report:"https://example.invalid/report"}')"
fx_review 7 "$(printf '<!-- prdkit-review\n%s\n-->\n' "$PAYLOAD")"
launch; assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 1 "$(printf '%s' "$OUTPUT" | jq -r .native.receipts)"
fx_review 7 '<!-- prdkit-review
{"schema":"invalid"}
-->'
launch; assert_eq 1 "$STATUS"
assert_eq complete "$(printf '%s' "$OUTPUT" | jq -r .launcher)"
assert_eq 1 "$(printf '%s' "$OUTPUT" | jq -r .native.invalid_receipts)"
printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
git checkout -q --detach "$HEAD_SHA"
bindings "$HEAD_SHA"

assert_owner_barrier() { # state reason; all other native requirements must be clean
    assert_eq 1 "$STATUS" "$MODE owner barrier refuses"
    assert_eq complete "$(jq -r .launcher "$FIX/stdout")"
    assert_eq 1 "$(jq -r .native_exit "$FIX/stdout")" 'actual native refusal, not a transport failure'
    assert_eq host "$(jq -r .native.authority "$FIX/stdout")"
    assert_eq "$1" "$(jq -r '.native.owner.barriers[0].state' "$FIX/stdout")"
    assert_contains "$OUTPUT" "$2"
    assert_eq 1 "$(jq '.native.problems|length' "$FIX/stdout")" 'only the specific owner barrier blocks'
    assert_eq '["owner"]' "$(jq -c .native.diagnostics.problem_classes "$FIX/stdout")"
    assert_eq 0 "$(jq .native.invalid_receipts "$FIX/stdout")"
    assert_eq "$OWNER_AT" "$(jq -r .native.diagnostics.head "$FIX/stdout")"
    assert_eq "$OWNER_POLICY" "$(jq -r .native.diagnostics.policy_at "$FIX/stdout")"
    assert_eq "$OWNER_POLICY" "$(jq -r .native.diagnostics.base_at "$FIX/stdout")"
    assert_eq "$([ "$MODE" = record-only ] && echo true || echo false)" \
        "$(jq -r .native.record_only "$FIX/stdout")"
}
it 'integrated native owner barriers and same-actor clearing survive T0 and record-only exemptions'
for MODE in docs record-only; do
    git checkout -q --detach "$BASE"
    sed 's/review-owner: user:1003/review-owner: user:1003, user:1004/' \
        .prdkit/memory/config.md > "$FIX/config"
    cp "$FIX/config" .prdkit/memory/config.md
    git add -A; git commit -qm 'trusted two-owner policy'
    OWNER_POLICY="$(git rev-parse HEAD)"; git branch -f main "$OWNER_POLICY"
    if [ "$MODE" = docs ]; then OWNER_AT="$HEAD_SHA"
    else
        git checkout -q --detach "$BASE"
        mkdir -p specs/changes
        printf '# Carrier\n**Tier**: T1\n## State\n' > specs/changes/001-carrier.md
        git add -A; git commit -qm 'record-only carrier'
        OWNER_AT="$(git rev-parse HEAD)"
    fi
    bindings "$OWNER_AT"
    printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
    printf '[]\n' > "$GH_STUB_DIR/activity.json"
    fx_activity 0000000000000000000000000000000000000000 "$OWNER_AT" \
        '{"ref":"refs/heads/feat/carrier","activity_type":"branch_creation","timestamp":"2026-01-01T12:00:00Z"}'
    launch; assert_eq 0 "$STATUS" "$MODE event-free real-native control: $OUTPUT"
    assert_eq '[]' "$(jq -c .native.problems "$FIX/stdout")"
    fx_owner_review 7 CHANGES_REQUESTED "$OWNER_AT"
    launch; assert_owner_barrier CHANGES_REQUESTED 'changes requested, not PASS'
    assert_eq user:1003 "$(jq -r '.native.owner.barriers[0].actor' "$FIX/stdout")"
    fx_owner_review 7 APPROVED "$OWNER_AT" '{"author":{"databaseId":1004},"submittedAt":"2026-01-03T00:00:00Z"}'
    launch; assert_owner_barrier CHANGES_REQUESTED 'changes requested, not PASS'
    assert_eq user:1004 "$(jq -r .native.owner.actor "$FIX/stdout")" 'another owner cannot clear the issuer'
    fx_owner_review 7 APPROVED aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa '{"submittedAt":"2026-01-04T00:00:00Z"}'
    launch; assert_owner_barrier CHANGES_REQUESTED 'later review'
    assert_contains "$OUTPUT" 'cannot be confirmed as the PR head' 'invalid same-actor approval cannot clear'
    fx_owner_review 7 APPROVED "$OWNER_AT" '{"submittedAt":"2026-01-05T00:00:00Z"}'
    launch; assert_eq 0 "$STATUS" "$MODE valid same-issuer clearing: $OUTPUT"
    assert_eq '[]' "$(jq -c .native.owner.barriers "$FIX/stdout")"
    assert_eq '[]' "$(jq -c .native.reviews "$FIX/stdout")" 'owner clearing is not independent coverage'
    fx_owner_review 7 DISMISSED "$OWNER_AT" '{"author":{"databaseId":1004},"submittedAt":"2026-01-06T00:00:00Z"}'
    launch; assert_owner_barrier DISMISSED 'latest owner review was dismissed'
    assert_eq user:1004 "$(jq -r '.native.owner.barriers[0].actor' "$FIX/stdout")"
    assert_not_contains "$OUTPUT" 'changes requested, not PASS' 'dismissal has its own revocation reason'
    fx_owner_review 7 APPROVED "$OWNER_AT" '{"submittedAt":"2026-01-07T00:00:00Z"}'
    launch; assert_owner_barrier DISMISSED 'latest owner review was dismissed'
    fx_owner_review 7 APPROVED "$OWNER_AT" '{"author":{"databaseId":1004},"submittedAt":"2026-01-08T00:00:00Z"}'
    launch; assert_eq 0 "$STATUS" "$MODE dismissal cleared only by its issuer: $OUTPUT"
    assert_eq '[]' "$(jq -c .native.problems "$FIX/stdout")"
done
printf '[]\n' > "$GH_STUB_DIR/reviews/7.json"
printf '[]\n' > "$GH_STUB_DIR/activity.json"
git branch -f main "$BASE"
git checkout -q --detach "$HEAD_SHA"
bindings "$HEAD_SHA"

it 'pre-shell constructor removes shell injection; launcher drops inherited Git/config/proxy state'
printf 'touch %q\n' "$FIX/sentinel" > "$FIX/startup"
env BASH_ENV="$FIX/startup" "$REAL_BASH" -c ':'
assert_file "$FIX/sentinel" 'startup poison is armed without the clean constructor'
rm "$FIX/sentinel"
mkdir -p "$FIX/hooks" "$FIX/hook-control"
printf '#!/bin/sh\nprintf "%%s\\n" "$1" >> %q\n' "$FIX/hook-sentinel" > "$FIX/hooks/reference-transaction"
chmod +x "$FIX/hooks/reference-transaction"
printf '[core]\n hooksPath = %s\n' "$FIX/hooks" > "$FIX/gitconfig"
"$REAL_GIT" -C "$FIX/hook-control" init -q
env GIT_CONFIG_GLOBAL="$FIX/gitconfig" "$REAL_GIT" -C "$FIX/hook-control" fetch -q --no-tags \
    "$PROJ" '+refs/pull/7/head:refs/prdkit/control'
assert_file "$FIX/hook-sentinel" 'global configuration arms a hook on the actual fetch/ref-update operation'
rm "$FIX/hook-sentinel"
env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0="$FIX/hooks" \
    "$REAL_GIT" -C "$FIX/hook-control" update-ref refs/prdkit/second "$HEAD_SHA"
assert_file "$FIX/hook-sentinel" 'injected configuration also arms the ref-update hook'
rm "$FIX/hook-sentinel"
export BASH_ENV="$FIX/startup"
launch GIT_CONFIG_GLOBAL="$FIX/gitconfig" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath \
    GIT_CONFIG_VALUE_0="$FIX/hooks" GIT_OBJECT_DIRECTORY="$FIX/missing" GIT_ALTERNATE_OBJECT_DIRECTORIES="$PROJ/.git/objects" \
    GIT_DIR="$PROJ/.git" GIT_WORK_TREE="$PROJ" GIT_REPLACE_REF_BASE=refs/spoof/ HTTPS_PROXY=http://127.0.0.1:1
unset BASH_ENV
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq absent "$([ -e "$FIX/sentinel" ] && echo present || echo absent)"
assert_eq absent "$([ -e "$FIX/hook-sentinel" ] && echo present || echo absent)"

it 'target and policy are separate authenticated tips, with policy-configured literal trust'
git checkout -q --detach "$BASE"
printf 'integration work\n' > target.txt; git add target.txt; git commit -qm 'target only'
TARGET="$(git rev-parse HEAD)"
git branch -f integration "$TARGET"
git checkout -q --detach "$BASE"
# Test-only trusted P bytes record both early parser and native-gate sourcing. H/T retain the
# unmodified real helper, so neither can manufacture this marker or the native decision.
printf '\nprintf "loaded\\n" >> %q\n' "$FIX/p-navigation" >> .prdkit/scripts/bash/spec-navigation-lib.sh
git add -A; git commit -qm 'trusted policy navigation witness'
git branch -f main HEAD
POLICY="$(git rev-parse HEAD)"
git checkout -q feat/carrier
bindings "$HEAD_SHA" feat/carrier integration
launch
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq "$TARGET" "$(printf '%s' "$OUTPUT" | jq -r .native.diagnostics.base_at)"
assert_eq "$POLICY" "$(printf '%s' "$OUTPUT" | jq -r .native.policy_at)"
assert_eq "$POLICY" "$(printf '%s' "$OUTPUT" | jq -r .native.diagnostics.policy_at)"
assert_eq $'loaded\nloaded' "$(cat "$FIX/p-navigation")" 'both parser and native gate source navigation only from P'
git branch -f main "$BASE"
bindings "$HEAD_SHA"

it 'candidate gate, library and workflow spoof bytes are never executed'
mkdir -p .github/workflows
printf '#!/bin/bash\ntouch %q\nexit 0\n' "$FIX/sentinel" > .prdkit/scripts/bash/check-review.sh
printf 'touch %q\n' "$FIX/sentinel" > .prdkit/scripts/bash/common.sh
printf 'touch %q\n' "$FIX/sentinel" > .prdkit/scripts/bash/spec-navigation-lib.sh
"$REAL_BASH" --noprofile --norc -c 'source "$1"' _ .prdkit/scripts/bash/spec-navigation-lib.sh
assert_file "$FIX/sentinel" 'candidate navigation spoof is armed'
rm "$FIX/sentinel"
printf 'spoof\n' > .github/workflows/spoof.yml
git add -A; git commit -qm 'candidate spoof'
SPOOF="$(git rev-parse HEAD)"
bindings "$SPOOF"; launch
assert_eq 1 "$STATUS"
assert_eq complete "$(printf '%s' "$OUTPUT" | jq -r .launcher)"
assert_contains "$OUTPUT" 'T0 is docs only'
assert_eq absent "$([ -e "$FIX/sentinel" ] && echo present || echo absent)"
git checkout -q --detach "$HEAD_SHA"

it 'closed unnumbered carrier is recovered by the native gate, including its log'
git rm -q specs/changes/001-carrier.md
mkdir -p specs/log
printf -- '- 2026-01-01 001-carrier: closed\n' > specs/log/001-carrier.md
git add -A; git commit -qm close
CLOSED="$(git rev-parse HEAD)"
bindings "$CLOSED"; launch
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 001-carrier "$(printf '%s' "$OUTPUT" | jq -r .native.change)"
git checkout -q --detach "$HEAD_SHA"
git rm -q specs/changes/001-carrier.md
git commit -qm 'close without log'
bindings "$(git rev-parse HEAD)"; launch
assert_eq 1 "$STATUS"
assert_contains "$OUTPUT" 'has no'

it 'numbered branch selects its exact carrier, not a prefix-stripped ID'
bindings "$HEAD_SHA" 001-carrier; launch
assert_eq 0 "$STATUS" "$OUTPUT"
bindings "$HEAD_SHA" 999-absent; launch
assert_eq 1 "$STATUS"
assert_eq 999-absent "$(printf '%s' "$OUTPUT" | jq -r .native.change)"
bindings "$HEAD_SHA" feat/001-carrier; launch
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq 001-carrier "$(printf '%s' "$OUTPUT" | jq -r .native.change)"

it 'event/head/repository/base/default binding mismatches refuse, never fall back offline'
bindings "$HEAD_SHA"
for mutation in '.repository.id=43' '.pull_request.head.sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' \
    '.pull_request.base.ref="other"' '.pull_request.head.ref="feature\u0000"' '.action="closed"' '.number=0'; do
    cp "$FIX/event" "$FIX/event.save"
    jq "$mutation" "$FIX/event.save" > "$FIX/event"
    launch; assert_eq 1 "$STATUS"
    assert_eq refused "$(printf '%s' "$OUTPUT" | jq -r .launcher)"
    mv "$FIX/event.save" "$FIX/event"
done
printf '{"id":43,"full_name":"owner/repo","default_branch":"main"}\n' > "$GH_STUB_DIR/routes/repos_owner_repo.json"
launch; assert_eq 1 "$STATUS"
bindings "$HEAD_SHA"
jq '.object.sha="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' "$GH_STUB_DIR/routes/git_ref_heads_main.json" > "$FIX/route"
mv "$FIX/route" "$GH_STUB_DIR/routes/git_ref_heads_main.json"
launch; assert_eq fetched-commit "$(printf '%s' "$OUTPUT" | jq -r .error.code)"
bindings "$HEAD_SHA"

it 'unapproved target and failed acquisition refuse before native evaluation'
git branch other "$BASE"
bindings "$HEAD_SHA" feat/carrier other
launch; assert_eq unapproved-target "$(printf '%s' "$OUTPUT" | jq -r .error.code)"
bindings "$HEAD_SHA"
touch "$FIX/fetch-fail"; launch; rm "$FIX/fetch-fail"
assert_eq acquisition "$(printf '%s' "$OUTPUT" | jq -r .error.code)"

it 'partial native pagination is unavailable, not an empty successful host response'
printf '{"incomplete":' > "$GH_STUB_DIR/routes/graphql_PrdkitReviews-7.json"
launch
assert_eq 1 "$STATUS"
assert_eq unavailable "$(printf '%s' "$OUTPUT" | jq -r .native.authority)"
assert_eq complete "$(printf '%s' "$OUTPUT" | jq -r .launcher)"
rm "$GH_STUB_DIR/routes/graphql_PrdkitReviews-7.json"

it 'unsafe and missing owner/navigation closure entries refuse; both regular modes are accepted'
for helper in review-owner-lib.sh spec-navigation-lib.sh; do
for mode in missing symlink gitlink regular; do
    git checkout -q --detach "$BASE"
    case "$mode" in
        missing) git rm -q ".prdkit/scripts/bash/$helper" ;;
        symlink) rm ".prdkit/scripts/bash/$helper"; ln -s common.sh ".prdkit/scripts/bash/$helper"; git add -A ;;
        gitlink)
            git rm -q ".prdkit/scripts/bash/$helper"
            git update-index --add --cacheinfo "160000,$BASE,.prdkit/scripts/bash/$helper" ;;
        regular) chmod -x ".prdkit/scripts/bash/$helper"; git add -A ;;
    esac
    git commit -qm "$mode $helper closure"
    git branch -f main HEAD
    bindings "$HEAD_SHA"; launch
    if [ "$mode" = regular ]; then assert_eq 0 "$STATUS" "$helper mode100644 real-native control: $OUTPUT"
    else
        assert_eq 1 "$STATUS" "$mode $helper refuses"
        assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
        assert_eq extract "$(jq -r .error.stage "$FIX/stdout")"
        assert_eq closure "$(printf '%s' "$OUTPUT" | jq -r .error.code)"
        assert_eq null "$(jq .native_exit "$FIX/stdout")" 'unsafe closure refuses before native execution'
    fi
done
done
git branch -f main "$BASE"

it 'the real native gate preserves unknown fields; malformed/inconsistent output cannot pass'
git checkout -q --detach "$BASE"
sed 's/printf '\''}\\n'\''/printf '\'' , "extension": {"keep":[null,17,true]}}\\n'\''/' \
    .prdkit/scripts/bash/check-review.sh > "$FIX/gate"
cp "$FIX/gate" .prdkit/scripts/bash/check-review.sh
git add -A; git commit -qm 'future native diagnostic field'
git branch -f main HEAD
bindings "$HEAD_SHA"; launch
assert_eq 0 "$STATUS" "$OUTPUT"
assert_eq '[null,17,true]' "$(printf '%s' "$OUTPUT" | jq -c .native.extension.keep)"
NATIVE="$(printf '%s' "$OUTPUT" | jq -c .native)"
# Synthetic NEGATIVE output-contract tests, not replacements for the real-native positive control.
for fault in multiple malformed nul binding preview wrong-type exit-result overflow timeout; do
    git checkout -q --detach "$BASE"
    case "$fault" in
        multiple) printf '#!/bin/bash\nprintf '\''{}\\n{}\\n'\''\n' > "$FIX/gate" ;;
        malformed) printf '#!/bin/bash\nprintf '\''{"result":'\''\n' > "$FIX/gate" ;;
        nul) printf '#!/bin/bash\nprintf '\''{}\\000'\''\n' > "$FIX/gate" ;;
        overflow) printf '#!/bin/bash\nyes x\n' > "$FIX/gate" ;;
        timeout) printf '#!/bin/bash\nsleep 60 &\necho $! > %q\nwait\n' "$FIX/native-descendant" > "$FIX/gate" ;;
        *)
            filter=.; rc=0
            case "$fault" in
                binding) filter='.head="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"' ;;
                preview) filter='.result="preview"|.authority="snapshot"'; rc=3 ;;
                wrong-type) filter='.head_is_pr_head="true"' ;;
                exit-result) rc=1 ;;
            esac
            {
                printf '#!/bin/bash\nrepo=""; while [ "$#" -gt 0 ]; do\n'
                printf '  case "$1" in --repo) shift; repo="$1" ;; esac; shift; done\n'
                printf 'p="$(git -C "$repo" rev-parse origin/HEAD)"\nt="$(git -C "$repo" rev-parse refs/remotes/origin/main)"\n'
                printf 'jq --arg p "$p" --arg t "$t" '\''.policy_at=$p|.diagnostics.policy_at=$p|.diagnostics.base_at=$t'\'' <<'\''JSON'\''\n%s\nJSON\nexit %s\n' \
                    "$(printf '%s' "$NATIVE" | jq -c "$filter")" "$rc"
            } > "$FIX/gate" ;;
    esac
    cp "$FIX/gate" .prdkit/scripts/bash/check-review.sh
    git add -A; git commit -qm "negative $fault output"
    git branch -f main HEAD
    bindings "$HEAD_SHA"
    if [ "$fault" = timeout ]; then
        arm_fixture_deadline native.json native-descendant end
    fi
    launch
    instrument
    assert_eq 1 "$STATUS" "$fault cannot authorize"
    if [ "$fault" = preview ]; then
        assert_eq 3 "$(printf '%s' "$OUTPUT" | jq -r .native_exit)"
        assert_eq snapshot "$(printf '%s' "$OUTPUT" | jq -r .native.authority)"
        assert_eq complete "$(printf '%s' "$OUTPUT" | jq -r .launcher)"
    else assert_eq refused "$(printf '%s' "$OUTPUT" | jq -r .launcher)"; fi
    if [ "$fault" = timeout ]; then
        assert_eq execution-limit "$(printf '%s' "$OUTPUT" | jq -r .error.code)"
        case "$(printf '%s' "$OUTPUT" | jq -r .native_exit)" in
            143|137) _ok 'actual signalled native exit preserved, not synthetic watchdog 124' ;;
            *) _no 'actual native timeout exit lost' "$OUTPUT" ;;
        esac
        assert_terminated "$(cat "$FIX/native-descendant")" 'native descendant terminated'
    fi
done
git branch -f main "$BASE"
bindings "$HEAD_SHA"

it 'cancellation after complete native output retains object and actual child exit'
rm -f "$FIX/native-ready" "$FIX/native-descendant"
git checkout -q --detach "$BASE"
{
    # Synthetic NEGATIVE transport: a valid diagnostic object then an intentional hang.
    printf '#!/bin/bash\ncat <<'\''JSON'\''\n%s\nJSON\n' "$NATIVE"
    printf 'sleep 60 &\necho $! > %q\necho ready > %q\nwait\n' "$FIX/native-descendant" "$FIX/native-ready"
} > .prdkit/scripts/bash/check-review.sh
git add -A; git commit -qm 'negative interrupted native transport'
git branch -f main HEAD
bindings "$HEAD_SHA"
env -i PATH="$ORIGINAL_PATH" GH_TOKEN=synthetic GITHUB_EVENT_NAME=pull_request \
    GITHUB_REPOSITORY=owner/repo GITHUB_REPOSITORY_ID=42 \
    "$REAL_BASH" "$FIX/launcher" --repository owner/repo --event "$FIX/event" \
    > "$FIX/stdout" 2>"$FIX/stderr" &
LAUNCHER_PID=$!
await_fixture "$LAUNCHER_PID" "$FIX/native-ready" "$FIX/native-descendant" || :
assert_file "$FIX/native-ready"
kill -TERM "$LAUNCHER_PID" 2>/dev/null || :
if wait "$LAUNCHER_PID"; then STATUS=0; else STATUS=$?; fi
assert_eq 1 "$STATUS"
assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
assert_eq interrupted "$(jq -r .error.code "$FIX/stdout")"
assert_eq pass "$(jq -r .native.result "$FIX/stdout")" 'native diagnostic object survives cancellation'
case "$(jq -r .native_exit "$FIX/stdout")" in
    143|137) _ok 'actual native cancellation exit preserved' ;;
    *) _no 'actual native cancellation exit lost' "$(cat "$FIX/stdout")" ;;
esac
assert_file "$FIX/native-descendant"
assert_terminated "$(cat "$FIX/native-descendant")" 'native cancellation terminates descendant'
assert_eq '' "$(find "$FIX/scratch" -mindepth 1 -print)" 'native cancellation cleans scratch'
git branch -f main "$BASE"
bindings "$HEAD_SHA"

it 'fresh final host bindings refuse a default movement after a useful native result'
cp "$FIX/bin/gh" "$FIX/gh.original"
{
    printf '#!/bin/bash\n'
    printf 'if [ "${*: -1}" = repos/owner/repo ]; then\n'
    printf '  n=0; [ ! -e %q ] || n="$(cat %q)"; n=$((n+1)); echo "$n" > %q\n' \
        "$FIX/reads" "$FIX/reads" "$FIX/reads"
    printf '  if [ "$n" -gt 1 ]; then printf '\''{"id":42,"full_name":"owner/repo","default_branch":"other"}\\n'\''; exit; fi\nfi\n'
    printf 'exec %q "$@"\n' "$FIX/gh.original"
} > "$FIX/bin/gh"
launch
assert_eq 1 "$STATUS"
assert_eq refused "$(printf '%s' "$OUTPUT" | jq -r .launcher)"
assert_eq pass "$(printf '%s' "$OUTPUT" | jq -r .native.result)"
cp "$FIX/gh.original" "$FIX/bin/gh"

# Exercise complete-history selection directly from the exact production function. This avoids
# pretending fixture host registration is real and makes the graph matrix fast on native macOS.
it 'complete selector histories use real Git, NUL paths and the production function'
sed -n '/^select_carrier() {/,/^}/p' "$PK_ROOT/scripts/check-pr-review.sh" > "$FIX/selector"
sed -n '/^capture_file() {/,/^}/p' "$PK_ROOT/scripts/check-pr-review.sh" > "$FIX/capture-helper"
source "$FIX/capture-helper"
source "$FIX/selector"
objects="$PROJ"; root="$FIX"
sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; }
head_branch=feat/carrier
select_at() {
    head="$1"; target="${2:-$BASE}"
    if OUTPUT="$(select_carrier 2>"$FIX/select.err")"; then STATUS=0; else STATUS=$?; fi
}
select_at "$HEAD_SHA"; assert_eq 001-carrier "$OUTPUT"
select_at "$CLOSED"; assert_eq 001-carrier "$OUTPUT"
select_at "$BASE"; assert_eq 1 "$STATUS" 'no assignment refuses'
git checkout -q --detach "$BASE"
mkdir -p specs/changes/nested
printf decoy > "specs/changes/008-not-carrier"$'\n'".md"
printf decoy > specs/changes/nested/009-also-not.md
git add -A; git commit -qm 'non-record paths'
select_at "$(git rev-parse HEAD)"; assert_eq 1 "$STATUS" 'NUL framing excludes newline/nested decoy IDs'
git checkout -q --detach "$HEAD_SHA"
printf '# Other\n' > specs/changes/002-other.md; git add -A; git commit -qm other
select_at "$(git rev-parse HEAD)"; assert_eq 1 "$STATUS" 'two surviving records refuse'
git rm -q specs/changes/002-other.md; git commit -qm delete
select_at "$(git rev-parse HEAD)"; assert_eq 1 "$STATUS" 'closed plus open remains ambiguous'
git checkout -q --detach "$HEAD_SHA"
git rm -q specs/changes/001-carrier.md; git commit -qm delete
mkdir -p specs/changes; printf '# Again\n' > specs/changes/001-carrier.md
git add -A; git commit -qm readd
select_at "$(git rev-parse HEAD)"; assert_eq 001-carrier "$OUTPUT" 'same ID deduplicates'
git checkout -q --detach "$BASE"
mkdir -p specs/changes; printf '# Old\n' > specs/changes/997-old.md
git add -A; git commit -qm old
OLD="$(git rev-parse HEAD)"
git rm -q specs/changes/997-old.md; git commit -qm delete
mkdir -p specs/changes; printf '# Old\n' > specs/changes/997-old.md
git add -A; git commit -qm readd
select_at "$(git rev-parse HEAD)" "$OLD"; assert_eq 1 "$STATUS" 'baseline re-add is not introduced'
git rm -q specs/changes/997-old.md
mkdir -p specs/changes
printf '# Own\n' > specs/changes/001-carrier.md; git add -A; git commit -qm sibling
select_at "$(git rev-parse HEAD)" "$OLD"; assert_eq 001-carrier "$OUTPUT" 'sibling closure is not the carrier'
git checkout -q --detach "$BASE"
mkdir -p specs/changes; printf '# Decoy\n' > specs/changes/998-decoy.md
git add -A; git commit -qm side
git rm -q specs/changes/998-decoy.md; git commit -qm delete
SIDE="$(git rev-parse HEAD)"
git checkout -q --detach "$HEAD_SHA"
git merge -q --no-ff --no-edit "$SIDE"
select_at "$(git rev-parse HEAD)"; assert_eq 1 "$STATUS" 'side-branch add/delete is included'
git checkout -q --detach "$BASE"
printf 'side\n' > side.txt; git add -A; git commit -qm side
SIDE="$(git rev-parse HEAD)"
git checkout -q --detach "$HEAD_SHA"
git merge -q --no-ff --no-commit "$SIDE" 2>/dev/null
printf '# Merge-created\n' > specs/changes/998-decoy.md
git add -A; git commit -qm merge
git rm -q specs/changes/998-decoy.md; git commit -qm delete
select_at "$(git rev-parse HEAD)"; assert_eq 1 "$STATUS" 'merge-created add/delete is included'
for disposition in closure rename; do
    git checkout -q --detach "$BASE"
    mkdir -p specs/changes; printf '# Imported\n' > specs/changes/995-import.md
    git add -A; git commit -qm imported
    FIRST="$(git rev-parse HEAD)"
    git checkout -q --detach "$HEAD_SHA"
    git merge -q --no-ff --no-edit "$FIRST"
    OWN="$(git rev-parse HEAD)"
    git checkout -q --detach "$FIRST"
    if [ "$disposition" = closure ]; then git rm -q specs/changes/995-import.md
    else git mv specs/changes/995-import.md specs/changes/994-renamed.md; fi
    git commit -qm "$disposition"
    SECOND="$(git rev-parse HEAD)"
    git checkout -q --detach "$OWN"
    git merge -q --no-ff --no-edit "$SECOND"
    select_at "$(git rev-parse HEAD)" "$SECOND"
    assert_eq 001-carrier "$OUTPUT" "repeated main imports across $disposition are not introduced"
done
select_at "$HEAD_SHA" aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
assert_eq 1 "$STATUS" 'missing history refuses'
# Criss-cross merges with two best common ancestors, without depending on working tree merges.
A="$(git commit-tree "$(git rev-parse "$BASE^{tree}")" -p "$BASE" -m A)"
B="$(git commit-tree "$(git rev-parse "$BASE^{tree}")" -p "$BASE" -m B)"
AA="$(git commit-tree "$(git rev-parse "$BASE^{tree}")" -p "$A" -p "$B" -m AA)"
BB="$(git commit-tree "$(git rev-parse "$BASE^{tree}")" -p "$B" -p "$A" -m BB)"
select_at "$AA" "$BB"; assert_eq 1 "$STATUS" 'multiple merge bases refuse'

# Restore host control and short bounds only in disposable instrumentation.
it 'timeouts kill owned descendant groups and cleanup before emitting the result'
instrument
arm_fixture_deadline fetch.out descendant end
bindings "$HEAD_SHA"
rm -f "$FIX/descendant"
touch "$FIX/hang"; launch; rm "$FIX/hang"
assert_eq acquisition "$(printf '%s' "$OUTPUT" | jq -r .error.code)"
if [ -f "$FIX/descendant" ]; then
    PID="$(cat "$FIX/descendant")"
    # A zombie has terminated but can remain briefly until the host init reaps it.
    assert_terminated "$PID" 'descendant terminated'
else _no 'timeout reached owned descendant fixture'; fi

it 'the overall budget can cancel a subprocess before its per-operation limit'
instrument
arm_fixture_deadline fetch.out descendant deadline
rm -f "$FIX/descendant"
touch "$FIX/hang"; launch; rm "$FIX/hang"
assert_eq 1 "$STATUS"
assert_eq overall-timeout "$(printf '%s' "$OUTPUT" | jq -r .error.code)"
assert_file "$FIX/descendant" 'overall budget interrupted a running fetch'

it 'cancellation cleans owned groups before emitting refusal'
instrument
rm -f "$FIX/descendant"
touch "$FIX/hang"
env -i PATH="$ORIGINAL_PATH" GH_TOKEN=synthetic GITHUB_EVENT_NAME=pull_request \
    GITHUB_REPOSITORY=owner/repo GITHUB_REPOSITORY_ID=42 \
    "$REAL_BASH" "$FIX/launcher" --repository owner/repo --event "$FIX/event" \
    > "$FIX/stdout" 2>"$FIX/stderr" &
LAUNCHER_PID=$!
await_fixture "$LAUNCHER_PID" "$FIX/descendant" || :
assert_file "$FIX/descendant" 'fetch descendant ready before cancellation'
kill -TERM "$LAUNCHER_PID" 2>/dev/null || :
if wait "$LAUNCHER_PID"; then STATUS=0; else STATUS=$?; fi
rm "$FIX/hang"
assert_eq 1 "$STATUS"
assert_eq refused "$(jq -r .launcher "$FIX/stdout")"
assert_eq interrupted "$(jq -r .error.code "$FIX/stdout")"
assert_terminated "$(cat "$FIX/descendant")" 'fetch cancellation terminates descendant'
assert_eq '' "$(find "$FIX/scratch" -mindepth 1 -print)" 'cancellation cleans invocation scratch'

it 'scratch deletion failure prevents a valid native success'
instrument
touch "$FIX/cleanup-fail"
# The normal helper intentionally asserts cleanup; test the failure contract separately.
invoke_launcher
rm "$FIX/cleanup-fail"
assert_eq 1 "$STATUS"
assert_eq cleanup-failed "$(printf '%s' "$OUTPUT" | jq -r .error.code)"
assert_eq 0 "$(printf '%s' "$OUTPUT" | jq -r .native_exit)"
run jq -e --arg h "$HEAD_SHA" --arg p "$BASE" '
    .native.result == "pass" and .native.authority == "host" and .native.problems == [] and
    .native.change == "001-carrier" and .native.pr == "https://github.com/owner/repo/pull/7" and
    .native.head == $h and .native.pr_head == $h and .native.head_is_pr_head == true and
    .native.base == "refs/remotes/origin/main" and .native.base_trusted == true and
    .native.policy_at == $p and .native.diagnostics.base_at == $p and
    .native.diagnostics.base_ref == "refs/remotes/origin/main" and
    .native.diagnostics.policy_at == $p and .native.diagnostics.head == $h and
    .native.diagnostics.receipt_ready == true and .native.diagnostics.host_content_bound == true
' "$FIX/stdout"
assert_eq 0 "$STATUS" 'only final deletion fails after a fully bound real native success'
"$REAL_RM" -rf "$FIX/scratch/"*
source "$TESTS_DIR/pr-review-process-cases.sh"
finish
