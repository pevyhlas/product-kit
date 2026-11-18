#!/bin/bash
# Trusted all-PR transport for the ONE native review gate. See docs/ci-gates.md.
# SECURITY: the registered immutable workflow must sanitize BEFORE starting this shell.
# This script cannot authenticate its own workflow registration or repair startup injection.
# shellcheck disable=SC2329 # finish is a trap; extract/select_carrier are bounded callbacks.
set -euo pipefail

# Fixed fresh-host tool locations, never the workspace/caller's PATH. Test transports instrument
# a disposable copy, not a production flag, environment switch, or alternate source argument.
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin
export PATH LC_ALL=C LANG=C
umask 077
set -m # each asynchronous child gets its own process group, including on Bash 3.2
phase=bootstrap; error_code=interrupted; root=""; child=""; watcher=""; overall=""
native=null; native_exit=null; transport=refused; status=1
deadline=$((SECONDS+600))

# All output is buffered until owned processes are gone and private scratch is deleted.
cancel_group() {
    local pid="$1" n=0
    [ -n "$pid" ] || return 0
    if kill -0 -- "-$pid" 2>/dev/null; then
        kill -TERM -- "-$pid" 2>/dev/null || true
        while kill -0 -- "-$pid" 2>/dev/null && [ "$n" -lt 5 ]; do
            sleep 1; n=$((n+1))
        done
        kill -KILL -- "-$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
}
stop_watcher() {
    [ -n "$watcher" ] || return 0
    # Only our trusted watchdog and its sleep live here; no grace period is needed.
    kill -KILL -- "-$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
    watcher=""
}
finish() {
    trap - EXIT INT TERM HUP ERR USR1
    cancel_group "$child"; stop_watcher
    if [ -n "$root" ] && { ! rm -rf -- "$root" || [ -e "$root" ]; }; then
        phase=cleanup; error_code=cleanup-failed; transport=refused; status=1
    fi
    if [ -n "$overall" ]; then
        kill -KILL -- "-$overall" 2>/dev/null || true
        wait "$overall" 2>/dev/null || true
    fi
    if [ "$transport" = complete ]; then
        printf '{"launcher":"complete","error":null,"native_exit":%s,"native":%s}\n' "$native_exit" "$native"
    else
        printf 'check-pr-review: %s/%s\n' "$phase" "$error_code" >&2
        printf '{"launcher":"refused","error":{"stage":"%s","code":"%s"},"native_exit":%s,"native":%s}\n' \
            "$phase" "$error_code" "$native_exit" "$native"
    fi
    exit "$status"
}
refuse() { phase="$1"; error_code="$2"; status="${3:-1}"; exit "$status"; }
trap finish EXIT
trap 'refuse "$phase" interrupted' INT TERM HUP
trap 'refuse "$phase" overall-timeout' USR1
trap 'refuse "$phase" command-failed' ERR

repository=""; event=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repository) [ "$#" -ge 2 ] && [ -z "$repository" ] || refuse bootstrap usage 2; repository="$2"; shift ;;
        --event) [ "$#" -ge 2 ] && [ -z "$event" ] || refuse bootstrap usage 2; event="$2"; shift ;;
        *) refuse bootstrap usage 2 ;;
    esac
    shift
done
[[ "$repository" =~ ^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$ ]] || refuse bootstrap usage 2
case "${repository#*/}" in .|..|*.git) refuse bootstrap usage 2 ;; esac
[ -n "$event" ] && [ -f "$event" ] && [ ! -L "$event" ] || refuse bootstrap usage 2
case "$event" in /*) ;; *) event="$PWD/$event" ;; esac
[ "${GITHUB_EVENT_NAME:-}" = pull_request ] &&
    [ "${GITHUB_REPOSITORY:-}" = "$repository" ] &&
    [[ "${GITHUB_REPOSITORY_ID:-}" =~ ^[1-9][0-9]*$ ]] || refuse bootstrap context
[ -n "${GH_TOKEN:-}" ] || refuse bootstrap credential

# Defense in depth AFTER the mandatory pre-shell constructor. Do not inherit Git configuration,
# caller credential helpers, proxies or language/loader options into any child.
for variable in $(compgen -v); do
    case "$variable" in
        GIT_*|GH_*|GITHUB_TOKEN|BASH_ENV|ENV|CDPATH|LD_*|DYLD_*|PYTHON*|PERL*|RUBY*|NODE_*|\
        http_proxy|https_proxy|all_proxy|no_proxy|HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|NO_PROXY)
            [ "$variable" = GH_TOKEN ] || unset "$variable" ;;
    esac
done
root="$(mktemp -d /tmp/prdkit-pr.XXXXXXXX)" || refuse bootstrap scratch
# Independent whole-invocation deadline, not just an elapsed-time check between acquisitions.
# USR1 interrupts the parent's wait builtin; its trap cancels/reaps the currently owned groups.
parent=$$
(
    set +m
    sleep "$((deadline-SECONDS))"
    kill -USR1 "$parent" 2>/dev/null || true
) >/dev/null 2>&1 &
overall=$!
HOME="$root/home"; GH_CONFIG_DIR="$root/gh"; XDG_CONFIG_HOME="$root/xdg"; TMPDIR="$root/tmp"
export HOME GH_CONFIG_DIR XDG_CONFIG_HOME TMPDIR
mkdir -p "$HOME" "$GH_CONFIG_DIR" "$XDG_CONFIG_HOME" "$TMPDIR" "$root/template" "$root/trusted"
cd "$root"
export GH_HOST=github.com GH_PROMPT_DISABLED=1 GH_PAGER=cat PAGER=cat
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_GLOBAL=/dev/null
export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 GIT_TERMINAL_PROMPT=0
export GIT_ATTR_NOSYSTEM=1 GIT_OPTIONAL_LOCKS=0
for tool in git gh jq; do command -v "$tool" >/dev/null || refuse bootstrap tools; done
# Parser diagnostics may quote input. Keep them private too; public stderr is phase/code only.
jq() { command jq "$@" 2>>"$root/json.err"; }

# Every external acquisition/evaluation (and the selection/extraction work) has an independent
# group watchdog. File-size hard limits also bound native gate internal capture and fast writers;
# stdout/stderr/history overflow is a refusal, never a truncated successful response.
bounded() { # seconds output error command...
    local seconds="$1" out="$2" err="$3" remaining rc
    shift 3
    bounded_exit=null; bounded_limit=""
    remaining=$((deadline-SECONDS))
    if [ "$remaining" -le 0 ]; then bounded_limit=timeout; return 124; fi
    [ "$seconds" -le "$remaining" ] || seconds="$remaining"
    rm -f "$root/limit"
    (
        set +m
        ulimit -f 4096
        "$@"
    ) >"$out" 2>"$err" &
    child=$!
    (
        set +m
        sleep "$seconds"
        printf 'timeout\n' > "$root/limit"
        kill -TERM -- "-$child" 2>/dev/null || true
        sleep 5
        kill -KILL -- "-$child" 2>/dev/null || true
    ) >/dev/null 2>&1 &
    watcher=$!
    if wait "$child"; then rc=0; else rc=$?; fi
    bounded_exit="$rc"
    cancel_group "$child"; child=""
    stop_watcher
    if [ -f "$root/limit" ]; then bounded_limit=timeout; return 124; fi
    # BSD ulimit's units can differ; use a conservative common byte ceiling too.
    if [ "$(wc -c < "$out")" -ge 4194304 ] || [ "$(wc -c < "$err")" -ge 4194304 ]; then
        bounded_limit=overflow; return 125
    fi
    return "$rc"
}
one_object() {
    local size kept
    [ -f "$1" ] || return 1
    size="$(wc -c < "$1")"
    kept="$(tr -d '\000' < "$1" | wc -c)"
    [ "$size" = "$kept" ] || return 1
    jq -e -s 'length == 1 and (.[0] | type == "object")' "$1" >/dev/null
}
api() { # endpoint output
    bounded 120 "$2" "$root/api.err" gh api --hostname github.com "$1" || refuse binding host-unavailable
    one_object "$2" || refuse binding host-json
}
sha() { [[ "$1" =~ ^[0-9a-f]{40}$ ]]; } # GitHub's native SHA-1 commit format
branch() {
    [[ "$1" != *[[:cntrl:]]* ]] && [ "$1" != HEAD ] &&
        git check-ref-format "refs/heads/$1" >/dev/null 2>&1
}

# REST resources are singular, not lists: there is no pagination to silently truncate here.
# The native adapter owns complete receipt, activity and closed-source pagination.
read_bindings() {
    local prefix="$1" default_encoded target_encoded
    api "repos/$repository" "$root/$prefix.repo"
    jq -e --arg repo "$repository" --arg rid "$GITHUB_REPOSITORY_ID" \
        '.full_name == $repo and (.id|tostring) == $rid and (.default_branch|type) == "string" and
         (.default_branch|test("[\u0000-\u001f\u007f]")|not)' \
        "$root/$prefix.repo" >/dev/null || refuse binding repository
    api "repos/$repository/pulls/$pr" "$root/$prefix.pr"
    jq -e --arg repo "$repository" --arg rid "$GITHUB_REPOSITORY_ID" --argjson pr "$pr" \
        '.number == $pr and .state == "open" and .merged_at == null and
         .base.repo.full_name == $repo and (.base.repo.id|tostring) == $rid and
         (.head.ref|type) == "string" and (.base.ref|type) == "string" and
         (.head.ref|test("[\u0000-\u001f\u007f]")|not) and
         (.base.ref|test("[\u0000-\u001f\u007f]")|not) and
         (.head.sha|test("^[0-9a-f]{40}$")) and
         (.head.repo.id|type) == "number" and .head.repo.id > 0 and
         (.head.repo.id|floor) == .head.repo.id' \
        "$root/$prefix.pr" >/dev/null || refuse binding pr
    default_branch="$(jq -r .default_branch "$root/$prefix.repo")"
    target_branch="$(jq -r .base.ref "$root/$prefix.pr")"
    head_branch="$(jq -r .head.ref "$root/$prefix.pr")"
    head="$(jq -r .head.sha "$root/$prefix.pr")"
    if ! branch "$default_branch" || ! branch "$target_branch" || ! branch "$head_branch" || ! sha "$head"; then
        refuse binding ref
    fi
    default_encoded="$(printf '%s' "$default_branch" | jq -sRr @uri)"
    target_encoded="$(printf '%s' "$target_branch" | jq -sRr @uri)"
    api "repos/$repository/git/ref/heads/$default_encoded" "$root/$prefix.policy"
    api "repos/$repository/git/ref/heads/$target_encoded" "$root/$prefix.target"
    jq -e --arg ref "refs/heads/$default_branch" \
        '.ref == $ref and .object.type == "commit" and (.object.sha|test("^[0-9a-f]{40}$"))' \
        "$root/$prefix.policy" >/dev/null || refuse binding policy
    jq -e --arg ref "refs/heads/$target_branch" \
        '.ref == $ref and .object.type == "commit" and (.object.sha|test("^[0-9a-f]{40}$"))' \
        "$root/$prefix.target" >/dev/null || refuse binding target
    policy="$(jq -r .object.sha "$root/$prefix.policy")"
    target="$(jq -r .object.sha "$root/$prefix.target")"
    if ! sha "$policy" || ! sha "$target"; then refuse binding commit; fi
    # Compare identity/ref/object fields, not irrelevant mutable title/body or review metadata.
    jq -cn --arg default "$default_branch" --arg target "$target_branch" --arg head "$head" \
        --arg policy "$policy" --arg tip "$target" --slurpfile p "$root/$prefix.pr" \
        '[$default,$target,$head,$policy,$tip,$p[0].head.ref,$p[0].head.repo.id]' > "$root/$prefix.binding"
}
phase=binding
bounded 120 "$root/event" "$root/event.err" cat -- "$event" || refuse binding event-read
one_object "$root/event" || refuse binding event-json
jq -e --arg repo "$repository" --arg rid "$GITHUB_REPOSITORY_ID" '
    (.action == "opened" or .action == "reopened" or .action == "synchronize" or
     .action == "edited" or .action == "ready_for_review" or .action == "converted_to_draft") and
    (.number|type) == "number" and .number > 0 and (.number|floor) == .number and
    .number == .pull_request.number and .repository.full_name == $repo and
    (.repository.id|tostring) == $rid and .pull_request.base.repo.full_name == $repo and
    (.pull_request.base.repo.id|tostring) == $rid and
    (.pull_request.head.ref|type) == "string" and (.pull_request.base.ref|type) == "string" and
    (.pull_request.head.ref|test("[\u0000-\u001f\u007f]")|not) and
    (.pull_request.base.ref|test("[\u0000-\u001f\u007f]")|not) and
    (.pull_request.head.sha|test("^[0-9a-f]{40}$")) and
    (.pull_request.base.sha|test("^[0-9a-f]{40}$"))
' "$root/event" >/dev/null || refuse binding event
pr="$(jq -r .number "$root/event")"
[[ "$pr" =~ ^[1-9][0-9]*$ ]] || refuse binding pr
sha "$(jq -r .pull_request.base.sha "$root/event")" || refuse binding event-base
read_bindings before
jq -e --slurpfile p "$root/before.pr" '
    .pull_request.head.sha == $p[0].head.sha and .pull_request.head.ref == $p[0].head.ref and
    .pull_request.head.repo.id == $p[0].head.repo.id and .pull_request.base.ref == $p[0].base.ref
' "$root/event" >/dev/null || refuse binding event-mismatch

phase=fetch
objects="$root/objects"
git init -q --template="$root/template" "$objects" >/dev/null 2>"$root/git.err" || refuse fetch init
# No caller config/template, object store, alternates, hooks, attributes, worktree or remotes.
git -C "$objects" config core.hooksPath "$root/template"
git -C "$objects" config credential.helper ''
git -C "$objects" config protocol.allow never
git -C "$objects" config protocol.https.allow always
git -C "$objects" config http.followRedirects false
git -C "$objects" config fetch.recurseSubmodules false
git -C "$objects" config maintenance.auto false
git -C "$objects" config gc.auto 0
cat > "$root/askpass" <<'ASKPASS'
#!/bin/bash
case "$1" in
    *Username*) printf '%s\n' x-access-token ;;
    *Password*) printf '%s\n' "$GH_TOKEN" ;;
    *) exit 1 ;;
esac
ASKPASS
chmod 700 "$root/askpass"
export GIT_ASKPASS="$root/askpass"
canonical="refs/remotes/origin/$target_branch"
url="https://github.com/$repository.git"
bounded 120 "$root/fetch.out" "$root/fetch.err" git -C "$objects" fetch --no-tags --no-recurse-submodules \
    --no-auto-maintenance "$url" \
    "+refs/pull/$pr/head:refs/prdkit/head" \
    "+refs/heads/$target_branch:$canonical" \
    "+refs/heads/$default_branch:refs/remotes/origin/$default_branch" || refuse fetch acquisition
[ "$(git -C "$objects" rev-parse refs/prdkit/head)" = "$head" ] &&
    [ "$(git -C "$objects" rev-parse "$canonical")" = "$target" ] &&
    [ "$(git -C "$objects" rev-parse "refs/remotes/origin/$default_branch")" = "$policy" ] || refuse binding fetched-commit
[ "$(git -C "$objects" rev-parse --is-shallow-repository)" = false ] &&
    [ ! -e "$objects/.git/objects/info/alternates" ] &&
    [ ! -e "$objects/.git/shallow" ] || refuse fetch incomplete
git -C "$objects" symbolic-ref refs/remotes/origin/HEAD "refs/remotes/origin/$default_branch"
# No URL/remote remains from which a native object read could implicitly acquire objects.
unset GIT_ASKPASS
rm "$root/askpass"
bounded 120 "$root/fsck.out" "$root/fsck.err" git -C "$objects" fsck --full --no-reflogs \
    "$head" "$target" "$policy" || refuse fetch incomplete

extract() {
    local file entry mode kind blob path
    for file in check-review.sh common.sh spec-lib.sh review-policy-lib.sh review-fingerprint-lib.sh \
        review-coverage-lib.sh review-receipts-lib.sh review-owner-lib.sh review-legacy-lib.sh; do
        path=".prdkit/scripts/bash/$file"
        entry="$(git -C "$objects" ls-tree "$policy" -- "$path")" || return 1
        read -r mode kind blob path <<< "$entry"
        case "$mode:$kind:$path" in
            "100644:blob:.prdkit/scripts/bash/$file"|"100755:blob:.prdkit/scripts/bash/$file") ;;
            *) return 1 ;;
        esac
        git -C "$objects" cat-file blob "$blob" > "$root/trusted/$file" || return 1
    done
}
phase=extract
bounded 120 "$root/extract.out" "$root/extract.err" extract || refuse extract closure
# Source ONLY the two enumerated, policy-bound native parsers; never adjacent caller files.
source "$root/trusted/common.sh"
source "$root/trusted/spec-lib.sh"
spec_trusted_refs "$objects" > "$root/approved"
grep -qxF "$canonical" "$root/approved" || refuse binding unapproved-target

select_carrier() {
    local start path id bases
    bases="$(git -C "$objects" merge-base --all "$target" "$head")" || return 1
    sha "$bases" || return 1 # exactly one complete merge base; embedded newline is invalid
    start="$bases"
    if is_change_id "$head_branch"; then printf '%s\n' "$head_branch"; return 0; fi
    # Capability failure is fatal. --full-history includes side branches; combined diffs include
    # merge-created additions, but not imports from a parent. NUL paths never enter line parsing.
    git -C "$objects" diff --no-renames --no-ext-diff --no-textconv --diff-filter=A \
        --name-only -z "$start" "$head" -- specs/changes/ > "$root/net" || return 1
    git -C "$objects" log --full-history --diff-merges=combined --no-renames --no-ext-diff \
        --no-textconv --diff-filter=A --name-only -z --format= "$start..$head" \
        -- specs/changes/ > "$root/history" || return 1
    git -C "$objects" ls-tree -r -z --name-only "$start" -- specs/changes/ > "$root/baseline" || return 1
    : > "$root/existing"; : > "$root/introduced"
    while IFS= read -r -d '' path; do
        case "$path" in specs/changes/*.md)
            id="${path#specs/changes/}"; id="${id%.md}"
            if is_change_id "$id"; then printf '%s\n' "$id" >> "$root/existing"; fi ;;
        esac
    done < "$root/baseline"
    cat "$root/net" "$root/history" > "$root/additions" || return 1
    while IFS= read -r -d '' path; do
        case "$path" in specs/changes/*.md)
            id="${path#specs/changes/}"; id="${id%.md}"
            if is_change_id "$id" && ! grep -qxF "$id" "$root/existing"; then
                printf '%s\n' "$id" >> "$root/introduced"
            fi ;;
        esac
    done < "$root/additions"
    sort -u "$root/introduced" > "$root/unique" || return 1
    [ "$(wc -l < "$root/unique")" -eq 1 ] || return 1
    cat "$root/unique"
}
phase=select
bounded 120 "$root/selected" "$root/select.err" select_carrier || refuse select assignment
selected="$(cat "$root/selected")"
is_change_id "$selected" || refuse select assignment

phase=native
if bounded 180 "$root/native.json" "$root/native.err" /bin/bash --noprofile --norc \
    "$root/trusted/check-review.sh" --json --diagnostics --repo "$objects" \
    --base "$canonical" --head "$head" --pr "https://github.com/$repository/pull/$pr" "$selected"; then
    : # The actual child exit, distinct from watchdog/capture classification, is kept below.
fi
native_exit="$bounded_exit"
if one_object "$root/native.json"; then native="$(cat "$root/native.json")"
elif [ -z "$bounded_limit" ]; then refuse native invalid-json; fi
[ -z "$bounded_limit" ] || refuse native execution-limit
jq -e '
    (.problems|type) == "array" and (.authority|type) == "string" and
    (.result == "pass" or .result == "fail" or .result == "preview")
' "$root/native.json" >/dev/null || refuse native result-shape
if [ "$native_exit" -eq 0 ]; then
    jq -e --arg id "$selected" --arg pr "https://github.com/$repository/pull/$pr" \
        --arg h "$head" --arg ref "$canonical" --arg p "$policy" --arg t "$target" '
        .result == "pass" and .authority == "host" and .problems == [] and .change == $id and
        .pr == $pr and .head == $h and .pr_head == $h and .head_is_pr_head == true and
        .base == $ref and .base_trusted == true and .policy_at == $p and
        .diagnostics.head == $h and .diagnostics.base_ref == $ref and .diagnostics.base_at == $t and
        .diagnostics.policy_at == $p and .diagnostics.receipt_ready == true and
        .diagnostics.host_content_bound == true
    ' "$root/native.json" >/dev/null || refuse native inconsistent-result
else
    jq -e --argjson rc "$native_exit" '
        (.result == "fail" and .authority == "host" and (.problems|length) > 0 and $rc == 1) or
        (.result == "preview" and .authority != "host" and
            (($rc == 1) or ($rc == 3 and .problems == [])))
    ' "$root/native.json" >/dev/null || refuse native inconsistent-result
fi
phase=binding
read_bindings after
cmp -s "$root/before.binding" "$root/after.binding" || refuse binding context-moved
transport=complete; status=1
[ "$native_exit" -ne 0 ] || status=0
exit "$status"
