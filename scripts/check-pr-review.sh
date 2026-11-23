#!/bin/bash
# Trusted all-PR transport for the ONE native review gate. See docs/ci-gates.md.
# SECURITY: the registered immutable workflow must sanitize BEFORE starting this shell.
# This script cannot authenticate its own workflow registration or repair startup injection.
#
# Invariants:
# Bind the event and fetched objects to the live repository, PR head, target and default
# policy tip. Run the native gate and its helpers from that policy tip, not candidate files.
# Accept only a consistent host pass for the exact checked head and unchanged final
# bindings. Invalid output, timeout, cancellation or cleanup failure cannot pass.
#
# Threat model:
# Include untrusted candidate PR contents (forks included), concurrent host ref changes
# and interrupted work; bound execution and clean up owned processes and scratch.
# Trust the registered launcher, pre-shell setup and runner. A hostile writer on the
# runner or a caller controlling shell startup is outside this script's boundary.
# shellcheck disable=SC2329,SC2016 # trap/callbacks; positional arguments expanded in the bounded Bash.
set -euo pipefail

# Fixed fresh-host tool locations, never the workspace/caller's PATH. Test transports instrument
# a disposable copy, not a production flag, environment switch, or alternate source argument.
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin
export PATH LC_ALL=C LANG=C
umask 077
phase=bootstrap; error_code=interrupted; root=""; operation=""
work=""; reader_out=""; reader_err=""
finishing=false; pending_signal=""; groups_verified=true
native=null; native_exit=null; transport=refused; status=1
deadline=$((SECONDS+600))

# All output is buffered until owned processes are gone and private scratch is deleted.
check_signal() {
    if ! $finishing; then
        [ -z "$pending_signal" ] || refuse "$phase" "$pending_signal"
        [ "$SECONDS" -lt "$deadline" ] || refuse "$phase" overall-timeout
    fi
    return 0
}
request_signal() {
    [ -n "$pending_signal" ] || pending_signal="$1"
    # Never exit from a signal trap, including the entry to an EXIT trap before finish has
    # set its flags. Explicit safe checkpoints handle cancellation after ownership is known.
    return 0
}
remove_scratch() {
    if [ -n "$root" ] && { ! rm -rf -- "$root" || [ -e "$root" ]; }; then return 1; fi
}
finish() {
    finishing=true
    trap - EXIT ERR
    # Queue, rather than default or exit on, repeated catchable signals during teardown.
    trap 'request_signal interrupted' INT TERM HUP
    trap 'request_signal overall-timeout' USR1
    [ -z "$operation" ] || collect_operation 2>>"$root/guard.err" || groups_verified=false
    # Cancellation can arrive after the native gate produced complete JSON.
    # Keep that diagnostic after verified cleanup without inventing a native exit.
    if $groups_verified && [ "$native" = null ] && [ -n "$root" ] && [ -f "$root/native.json" ]; then
        if one_object "$root/native.json"; then native="$(cat "$root/native.json")"; fi
    fi
    if ! $groups_verified || ! remove_scratch; then
        phase=cleanup; error_code=cleanup-failed; transport=refused; status=1
    fi
    # Teardown is now complete. Close the catchable-signal window before the final decision
    # and buffered emission; signals queued during teardown must still prevent success.
    trap '' INT TERM HUP USR1
    if [ "$transport" = complete ]; then
        if [ "$SECONDS" -ge "$deadline" ] && [ -z "$pending_signal" ]; then pending_signal=overall-timeout; fi
        if [ -n "$pending_signal" ]; then
            phase=cleanup; error_code="$pending_signal"; transport=refused; status=1
        fi
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
trap 'request_signal interrupted' INT TERM HUP
trap 'request_signal overall-timeout' USR1
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
check_signal
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

# Embedded in W's validated launcher, never loaded from a checkout.
cat > "$root/group-guard" <<'GUARD'
set -eu
set +m
op=$1 role=$2; shift 2
pgid="$(ps -o pgid= -p "$$")"
[[ ${pgid//[[:space:]]/} == "$$" ]] || exit 1
# The inherited duplex FD prevents either side blocking during open. Close it
# after obtaining a read-only FD: only the launcher keeps the write side.
exec 7<"$op/$role.control" 6<&-

record() {
    printf '%s\n' "$1" > "$op/$role.tmp" && mv "$op/$role.tmp" "$op/$role.status"
}
if [ "$role" = work ]; then
    (
        # Keep the status relay through TERM, without passing SIG_IGN to the
        # actual command. KILL may prevent a status from being recorded.
        trap ':' TERM
        rc=0; "$@" || rc=$?
        record "$rc"
    ) >"$op/out.pipe" 2>"$op/err.pipe" 7<&- &
else
    (
        rc=0
        head -c 4194304 < "$op/$role.pipe" > "$1" || rc=$?
        if [ "$rc" -eq 0 ]; then
            size="$(wc -c < "$1")" || rc=$?
            if [ "$rc" -eq 0 ] && [ "$size" -ge 4194304 ]; then : > "$op/overflow"; fi
        fi
        record "$rc"
    ) 7<&- &
fi
trap '' TERM HUP INT USR1
: > "$op/$role.ready"

# This is the only group signaler. This fresh Bash is the actual, live group
# leader; $$ is not a remembered child PID (nor a Bash subshell's inherited $$).
# A late FIFO message cannot make a dead guard signal a recycled group.
sent_term=false
while IFS= read -r request <&7; do
    case "$request" in
        release) exit 0 ;;
        term)
            if ! $sent_term; then
                [ ! -e "$op/$role.sealed" ] || exit 1
                sent_term=true
                kill -TERM -- "-$$" || exit 1
                # Relative kernel timer, independent of changes to wall clock.
                if IFS= read -r -t 5 request <&7; then
                    [ "$request" = release ] && exit 0
                    exit 1
                fi
                # Bash 3.2 does not distinguish timeout from EOF in $?. On EOF
                # the next read exits without any signal, even with grace set.
                : > "$op/$role.grace"
            fi ;;
        kill)
            [ -f "$op/$role.grace" ] && [ ! -e "$op/$role.sealed" ] || exit 1
            kill -KILL -- "-$$"
            exit 1 ;; # no retry, even if the syscall failed
        *) exit 1 ;;
    esac
done
GUARD

# A leader row must disappear (Bash reaps its own children asynchronously).
# Plain, unambiguously dead non-child zombies do not hold files. In particular
# Linux Zl can contain a live thread; unusual or exiting states never pass.
group_view() {
    ps -axo pid=,pgid=,stat= | awk -v group="$1" '
        NF != 3 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ { bad=1 }
        $1 == group {
            if (leader || $2 != group) bad=1
            leader=1
            if ($3 ~ /^[IRS][+<NsLl]*$/) guard=1
        }
        $2 == group && $1 != group && $3 !~ /^Z[+<NsL]*$/ { other=1 }
        END {
            if (!NR || bad) exit 1
            if (!leader && !other) print "gone"
            else if (guard) print other ? "busy" : "alone"
            else print "unconfirmed"
        }
    '
}
probe_group() { # pid timeout (whole seconds, supported by Bash 3.2)
    # One private inventory channel per operation. If ps or awk stalls, stop
    # using this channel; a delayed answer must not be read as a later snapshot.
    $probe_ok || return 1
    (
        if state="$(group_view "$1")"; then
            printf '%s\n' "$state"
        else
            printf 'unconfirmed\n'
        fi
    ) 3<&- 4<&- 5<&- >&8 &
    if IFS= read -r -t "$2" state <&8; then return 0; fi
    probe_ok=false
    return 1
}
guard_request() {
    # Linux and Darwin let a FIFO opened read/write hold both endpoints. Only
    # two tiny messages per group are possible, so writing cannot fill the pipe
    # or block waiting for a reader, even if the guard is already gone.
    printf '%s\n' "$1" >&"$2"
}
stop_guard() { # role pid control-fd
    local role="$1" pid="$2" fd="$3" state="" sent="" i end ready remaining
    [ -n "$pid" ] || return 0
    end=$((SECONDS+8))
    for ((i=0; i<80 && SECONDS<end; i++)); do
        # Observe registration before the snapshot, never combine a pre-launch
        # "alone" snapshot with a readiness file that appeared during the scan.
        ready=false
        if [ -f "$operation/$role.ready" ]; then ready=true; fi
        remaining=$((end-SECONDS))
        [ "$remaining" -gt 0 ] || break
        if [ "$remaining" -gt 3 ]; then remaining=3; fi
        probe_group "$pid" "$remaining" || break
        [ "$SECONDS" -lt "$end" ] || break
        case "$state:$sent" in
            gone:*) return 0 ;;
            alone:|alone:term)
                if $ready; then
                    guard_request release "$fd" || break
                    break
                fi ;;
            busy:)
                if $ready; then
                    guard_request term "$fd" || break
                    sent=term
                fi ;;
            busy:term)
                if [ -f "$operation/$role.grace" ]; then
                    guard_request kill "$fd" || break
                    break
                fi ;;
        esac
        sleep 0.1
    done
    # After release or KILL, there are no more signal requests; never call a
    # blocking wait. Require the guard and every live member to be absent from
    # fresh inventories, otherwise refuse and retain the scratch that they may use.
    end=$((SECONDS+5))
    for ((i=0; i<50 && SECONDS<end; i++)); do
        remaining=$((end-SECONDS))
        [ "$remaining" -gt 0 ] || break
        if [ "$remaining" -gt 3 ]; then remaining=3; fi
        probe_group "$pid" "$remaining" || break
        if [ "$state" = gone ]; then return 0; fi
        sleep 0.1
    done
    : > "$operation/$role.sealed"
    return 1
}

guard_status() {
    local rc
    read -r rc < "$operation/$1.status" &&
        [[ "$rc" =~ ^[0-9]{1,3}$ ]] && [ "$rc" -le 255 ] || return 1
    printf '%s\n' "$rc"
}
collect_operation() {
    local i failed=false out_status err_status probe_ok=true
    stop_guard work "$work" 3 || failed=true
    if [ -f "$operation/work.status" ]; then
        bounded_exit="$(guard_status work)" || failed=true
        if [ "$phase" = native ] && [ "$native_exit" = null ]; then native_exit="$bounded_exit"; fi
    fi
    # Writers are gone (or unverified). Let readers drain ordinary EOF, then
    # retire their own groups even when workload shutdown could not be proved.
    if ! $failed; then
        for ((i=0; i<50; i++)); do
            if [ -f "$operation/out.status" ] && [ -f "$operation/err.status" ]; then break; fi
            sleep 0.1
        done
    fi
    stop_guard out "$reader_out" 4 || failed=true
    stop_guard err "$reader_err" 5 || failed=true
    out_status="$(guard_status out 2>/dev/null)" || out_status=missing
    err_status="$(guard_status err 2>/dev/null)" || err_status=missing
    if [ "$out_status:$err_status" != 0:0 ]; then failed=true; fi
    if [ -e "$operation/overflow" ]; then bounded_limit=overflow; fi
    exec 3>&- 4>&- 5>&- 8>&-
    operation=""; work=""; reader_out=""; reader_err=""
    ! $failed
}

# No inherited file-size limit constrains Git packs or native working files.
capture_file() { # destination command... (selector data, not Git object storage)
    local destination="$1" rc; shift
    if "$@" | head -c 4194304 > "$destination"; then rc=0; else rc=$?; fi
    [ "$(wc -c < "$destination")" -lt 4194304 ] || return 1
    return "$rc"
}
start_guard() { # launched asynchronously; exec preserves the job's leader PID
    local control="$1"; shift
    exec /bin/bash --noprofile "$root/group-guard" "$operation" "$@" \
        </dev/null >/dev/null 2>>"$root/guard.err" 6<&"$control" 3<&- 4<&- 5<&- 8<&-
}
bounded() { # seconds output error command...
    local seconds="$1" out="$2" err="$3" end
    shift 3
    check_signal
    bounded_exit=null; bounded_limit=""
    operation="$(mktemp -d "$root/op.XXXXXXXX")" || refuse cleanup cleanup-failed
    mkfifo "$operation/work.control" "$operation/out.control" "$operation/err.control" \
        "$operation/out.pipe" "$operation/err.pipe" "$operation/inventory" || refuse cleanup cleanup-failed
    exec 3<>"$operation/work.control" 4<>"$operation/out.control" 5<>"$operation/err.control" \
        8<>"$operation/inventory"
    # Traps only queue cancellation. They cannot retire partially registered groups.
    set -m # give each async guard its own PGID (also on Bash 3.2)
    start_guard 4 out "$out" &
    reader_out=$!
    start_guard 5 err "$err" &
    reader_err=$!
    start_guard 3 work "$@" &
    work=$!
    set +m
    end=$((SECONDS+seconds))
    while [ ! -f "$operation/work.status" ]; do
        if [ -e "$operation/overflow" ]; then bounded_limit=overflow; break; fi
        if [ -n "$pending_signal" ] || [ "$SECONDS" -ge "$deadline" ]; then break; fi
        if [ "$SECONDS" -ge "$end" ]; then bounded_limit=timeout; break; fi
        sleep 0.05
    done
    collect_operation 2>>"$root/guard.err" || { groups_verified=false; refuse cleanup cleanup-failed; }
    check_signal
    case "$bounded_limit" in overflow) return 125 ;; timeout) return 124 ;; esac
    [ "$bounded_exit" != null ] || refuse cleanup cleanup-failed
    return "$bounded_exit"
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
    for file in check-review.sh common.sh spec-lib.sh spec-navigation-lib.sh review-policy-lib.sh review-fingerprint-lib.sh \
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
bounded 120 "$root/extract.out" "$root/extract.err" /bin/bash --noprofile --norc -euc \
    "$(declare -f extract)"$'\n''objects="$1"; policy="$2"; root="$3"; extract' \
    _ "$objects" "$policy" "$root" || refuse extract closure
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
    capture_file "$root/net" git -C "$objects" diff --no-renames --no-ext-diff --no-textconv --diff-filter=A \
        --name-only -z "$start" "$head" -- specs/changes/ || return 1
    capture_file "$root/history" git -C "$objects" log --full-history --diff-merges=combined --no-renames --no-ext-diff \
        --no-textconv --diff-filter=A --name-only -z --format= "$start..$head" \
        -- specs/changes/ || return 1
    capture_file "$root/baseline" git -C "$objects" ls-tree -r -z --name-only "$start" -- specs/changes/ || return 1
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
bounded 120 "$root/selected" "$root/select.err" /bin/bash --noprofile --norc -euc \
    "$(declare -f select_carrier capture_file sha is_change_id)"$'\n'\
'objects="$1"; root="$2"; target="$3"; head="$4"; head_branch="$5"; set -o pipefail; select_carrier' \
    _ "$objects" "$root" "$target" "$head" "$head_branch" || refuse select assignment
selected="$(cat "$root/selected")"
is_change_id "$selected" || refuse select assignment

phase=native
if bounded 180 "$root/native.json" "$root/native.err" /bin/bash --noprofile --norc \
    "$root/trusted/check-review.sh" --json --diagnostics --repo "$objects" \
    --base "$canonical" --head "$head" --pr "https://github.com/$repository/pull/$pr" "$selected"; then
    : # Keep the observed command exit, distinct from timeout/capture classification.
fi
native_exit="$bounded_exit"
check_signal
if one_object "$root/native.json"; then native="$(cat "$root/native.json")"
elif [ -z "$bounded_limit" ]; then refuse native invalid-json; fi
case "$bounded_limit" in
    overflow) refuse native capture-limit ;;
    timeout) refuse native execution-limit ;;
esac
check_signal
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
