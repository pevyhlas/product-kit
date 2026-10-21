#!/usr/bin/env bash
#
# Product-Kit maintainer tooling: the GitHub side of automatic releases. The decision itself is
# the offline release-plan.sh; this script verifies CI, reads remote tag/release state and
# performs the tag and release with gh. Run by .github/workflows/release.yml; the process is
# described in CONTRIBUTING.md ("Releases"). Not installed into consumer projects.
#
# Usage:
#   release-github.sh gate    --sha SHA [--ci-run-id ID] [--allow-backfill] [--repo DIR]
#                             [--main-ref REF]
#   release-github.sh publish --sha SHA [--ci-run-id ID] [--allow-backfill]
#                             [--release-run-url URL] [--repo DIR] [--main-ref REF]
#
# Both commands verify that CI run ID, or without --ci-run-id the newest successful one, is a
# completed, successful push run of .github/workflows/ci.yml on main for exactly SHA in this
# repository; find the merged pull request whose merge commit is SHA; and run the plan, whose
# reported commit must be SHA. Neither trusts the other's output.
# gate needs only read access (contents, actions, pull-requests) and checks the remote tag and
#   release. Prints key=value lines: action (create | release-only | none), reason, sha,
#   version, tag, ci_run_id, ci_run_url, pr_url. A release commit fails when its tag exists
#   elsewhere. Without --allow-backfill, when a newer vX.Y.Z tag exists, it also fails if it is
#   untagged, or if its tag is on SHA but its valid release is missing on GitHub; the error names
#   the allow_backfill dispatch that releases it. A tagged older commit whose release exists, or
#   whose CHANGELOG section cannot make release notes, stays a green skip.
# publish also needs contents: write. It creates the annotated tag object and refs/tags/vX.Y.Z
#   on exactly SHA unless the tag exists (an existing tag is never moved or recreated), then
#   creates the GitHub release if it is missing. Re-running is safe. It fails like gate when its
#   own plan refuses a backfill, for example after a newer release overtook this one.
#
# SHA must be the full 40-hex commit. --allow-backfill lets the plan release a version older than
# the newest vX.Y.Z tag. Environment: GH_REPO=owner/name (required); gh reads GH_TOKEN. Exit 0:
# done or nothing to do. Exit 1: verification or publication failed. Exit 2: usage error.

set -euo pipefail
export LC_ALL=C GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 NO_COLOR=1

SCRIPT_DIR="$(CDPATH="" cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLAN="$SCRIPT_DIR/release-plan.sh"
CI_WORKFLOW=".github/workflows/ci.yml"
MAIN_BRANCH="main"
TAGGER_NAME="github-actions[bot]"
TAGGER_EMAIL="41898282+github-actions[bot]@users.noreply.github.com"
SHA_RE='^[0-9a-f]{40}$'
REPO_RE='^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'release-github: %s\n' "$1" >&2; exit "${2:-1}"; }
log() { printf 'release-github: %s\n' "$1" >&2; }
emit() { printf '%s=%s\n' "$1" "$2"; }

[ $# -gt 0 ] || { usage >&2; exit 2; }
CMD="$1"; shift
case "$CMD" in
    gate|publish) ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown command '$CMD' (gate or publish)" 2 ;;
esac

SHA=""; CI_RUN_ID=""; CI_RUN_URL=""; PR_URL=""; RELEASE_RUN_URL=""; ALLOW_BACKFILL=false
REPO="."; MAIN_REF="origin/main"
while [ $# -gt 0 ]; do
    case "$1" in
        --sha|--ci-run-id|--release-run-url|--repo|--main-ref)
            [ $# -ge 2 ] || die "$1 requires a value" 2
            case "$1" in
                --sha) SHA="$2" ;;
                --ci-run-id) CI_RUN_ID="$2" ;;
                --release-run-url) RELEASE_RUN_URL="$2" ;;
                --repo) REPO="$2" ;;
                --main-ref) MAIN_REF="$2" ;;
            esac
            shift
            ;;
        --allow-backfill) ALLOW_BACKFILL=true ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument '$1' (use --help)" 2 ;;
    esac
    shift
done
[ "$CMD" = publish ] || [ -z "$RELEASE_RUN_URL" ] || die "--release-run-url applies to publish only" 2

[[ $SHA =~ $SHA_RE ]] || die "--sha must be a full 40-hex commit SHA, got '$SHA'" 2
[[ ${GH_REPO:-} =~ $REPO_RE ]] || die "GH_REPO must be owner/name, got '${GH_REPO:-}'" 2
case "$CI_RUN_ID" in *[!0-9]*) die "--ci-run-id must be numeric, got '$CI_RUN_ID'" 2 ;; esac
command -v gh >/dev/null 2>&1 || die "the GitHub CLI (gh) is required on the runner"

WORK="$(mktemp -d)" || die "cannot allocate a temporary directory"
[ -n "$WORK" ] && [ -d "$WORK" ] || die "cannot allocate a temporary directory"
trap 'rm -rf "$WORK"' EXIT

# api ARGS...: gh api with stdout as the (--jq filtered) body. Returns 0 on success, 4 on HTTP
# 404, 3 on HTTP 422 and 1 otherwise; error text goes to stderr except for a 404.
api() {
    local rc=0
    gh api "$@" >"$WORK/api.out" 2>"$WORK/api.err" || rc=$?
    if [ "$rc" -eq 0 ]; then cat "$WORK/api.out"; return 0; fi
    if grep -q '(HTTP 404)' "$WORK/api.err"; then return 4; fi
    cat "$WORK/api.err" >&2
    if grep -q '(HTTP 422)' "$WORK/api.err"; then return 3; fi
    return 1
}

# kv TEXT KEY: the value of the first KEY=value line in TEXT.
kv() {
    local line
    while IFS= read -r line; do
        case "$line" in "$2="*) printf '%s' "${line#*=}"; return 0 ;; esac
    done <<EOF
$1
EOF
    return 0
}

# verify_ci_run: sets CI_RUN_ID and CI_RUN_URL for a successful CI push run on main at SHA.
verify_ci_run() {
    local info key expected actual
    if [ -z "$CI_RUN_ID" ]; then
        CI_RUN_ID="$(api "repos/$GH_REPO/actions/workflows/${CI_WORKFLOW##*/}/runs?head_sha=$SHA&event=push&branch=$MAIN_BRANCH&status=success&per_page=1" \
            --jq '.workflow_runs[0].id // ""')" || die "could not list CI runs for $SHA"
        [ -n "$CI_RUN_ID" ] || die "no successful CI run for a push to $MAIN_BRANCH at $SHA; CI must pass on main before a release"
        case "$CI_RUN_ID" in *[!0-9]*) die "unexpected CI run id '$CI_RUN_ID'" ;; esac
    fi
    info="$(api "repos/$GH_REPO/actions/runs/$CI_RUN_ID" --jq '
        "path=\(.path)", "event=\(.event)", "head_branch=\(.head_branch)", "head_sha=\(.head_sha)",
        "status=\(.status)", "conclusion=\(.conclusion)", "repository=\(.repository.full_name)",
        "head_repository=\(.head_repository.full_name)", "html_url=\(.html_url)"')" \
        || die "could not read CI run $CI_RUN_ID"
    for key in path event head_branch head_sha status conclusion repository head_repository; do
        case "$key" in
            path) expected="$CI_WORKFLOW" ;;
            event) expected=push ;;
            head_branch) expected="$MAIN_BRANCH" ;;
            head_sha) expected="$SHA" ;;
            status) expected=completed ;;
            conclusion) expected=success ;;
            repository|head_repository) expected="$GH_REPO" ;;
        esac
        actual="$(kv "$info" "$key")"
        [ "$actual" = "$expected" ] \
            || die "CI run $CI_RUN_ID does not gate this release: $key is '$actual', expected '$expected'"
    done
    CI_RUN_URL="$(kv "$info" html_url)"
    # URLs reach $GITHUB_OUTPUT and the release notes: one plain https URL each.
    case "$CI_RUN_URL" in
        *[[:space:]]*) die "unexpected CI run URL '$CI_RUN_URL'" ;;
        https://*/actions/runs/"$CI_RUN_ID") ;;
        *) die "unexpected CI run URL '$CI_RUN_URL'" ;;
    esac
    log "CI run $CI_RUN_URL passed for a push to $MAIN_BRANCH at $SHA"
}

# find_pr: sets PR_URL to the merged pull request into main whose merge commit is SHA (or empty).
find_pr() {
    PR_URL="$(api "repos/$GH_REPO/commits/$SHA/pulls" --jq \
        "[.[] | select(.merged_at != null and .base.ref == \"$MAIN_BRANCH\" and .merge_commit_sha == \"$SHA\") | .html_url][0] // \"\"")" \
        || die "could not look up the pull request for $SHA"
    case "$PR_URL" in
        *[[:space:]]*) die "unexpected pull request URL '$PR_URL'" ;;
        ''|https://*/pull/[0-9]*) ;;
        *) die "unexpected pull request URL '$PR_URL'" ;;
    esac
}

# remote_tag_commit TAG: the commit the remote tag peels to; empty when the tag is absent.
remote_tag_commit() {
    local info rc=0 type obj
    info="$(api "repos/$GH_REPO/git/ref/tags/$1" --jq '"\(.object.type) \(.object.sha)"')" || rc=$?
    case "$rc" in 0) ;; 4) return 0 ;; *) die "could not read refs/tags/$1" ;; esac
    type="${info%% *}"; obj="${info#* }"
    if [ "$type" = tag ]; then
        info="$(api "repos/$GH_REPO/git/tags/$obj" --jq '"\(.object.type) \(.object.sha)"')" \
            || die "could not read the tag object of $1"
        type="${info%% *}"; obj="${info#* }"
    fi
    [ "$type" = commit ] || die "refs/tags/$1 does not resolve to a commit ($info)"
    printf '%s' "$obj"
}

# release_exists TAG: 0 when a GitHub release exists for TAG, 1 when it does not.
release_exists() {
    local rc=0
    api "repos/$GH_REPO/releases/tags/$1" --jq '.id' >/dev/null || rc=$?
    case "$rc" in 0) return 0 ;; 4) return 1 ;; *) die "could not read the release for $1" ;; esac
}

# run_plan ARGS...: runs release-plan.sh for SHA and sets PLAN_OUT; a failing plan, or one that
# evaluated any other commit, fails here.
run_plan() {
    local rc=0 planned
    if $ALLOW_BACKFILL; then set -- "$@" --allow-backfill; fi
    PLAN_OUT="$(bash "$PLAN" --repo "$REPO" --main-ref "$MAIN_REF" --sha "$SHA" "$@")" || rc=$?
    [ "$rc" -eq 0 ] || die "release plan for $SHA failed (exit $rc)"
    printf '%s\n' "$PLAN_OUT" | sed 's/^/release-plan: /' >&2
    planned="$(kv "$PLAN_OUT" sha)"
    [ "$planned" = "$SHA" ] || die "the plan evaluated '$planned', not $SHA"
    DECISION="$(kv "$PLAN_OUT" decision)"
    REASON="$(kv "$PLAN_OUT" reason)"
    VERSION="$(kv "$PLAN_OUT" version)"
    TAG="$(kv "$PLAN_OUT" tag)"
    TAG_STATE="$(kv "$PLAN_OUT" tag_state)"
    BUMP="$(kv "$PLAN_OUT" bump)"
    BACKFILL="$(kv "$PLAN_OUT" backfill)"
    SECTION="$(kv "$PLAN_OUT" section)"
    TITLE="$(kv "$PLAN_OUT" title)"
    LATEST="$(kv "$PLAN_OUT" latest)"
    ENSURE_RELEASE="$(kv "$PLAN_OUT" ensure_release)"
}

# refuse_overtaken: a valid release commit that the plan skipped only because a newer vX.Y.Z tag
# exists fails the run (never a silent green skip) and names the recovery, when it is untagged or
# when its tag is on SHA but its GitHub release is missing (e.g. publication failed and a newer
# release landed before the re-run). A tagged commit whose release exists stays green.
refuse_overtaken() {
    local msg
    if [ "$DECISION" != skip ] || [ "$BACKFILL" != refused ]; then return 0; fi
    case "$TAG_STATE" in
        absent) msg="$SHA bumps VERSION to $VERSION but $REASON" ;;
        at-sha)
            if [ "$SECTION" != valid ] || release_exists "$TAG"; then return 0; fi
            msg="$SHA is tagged $TAG but its GitHub release is missing, and VERSION $VERSION is older"
            msg="$msg than the newest vX.Y.Z tag (backfill needs explicit input)"
            ;;
        *) return 0 ;;
    esac
    msg="$msg; to release it anyway (never as latest), run:"
    msg="$msg gh workflow run release.yml -f sha=$SHA -f allow_backfill=true"
    summary failed "$msg"
    die "$msg"
}

summary() {
    [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
    {
        printf '### Release %s: %s\n\n' "$CMD" "$1"
        # shellcheck disable=SC2016 # the backticks are Markdown code formatting, not a command substitution
        printf -- '- Commit: `%s`\n- Version: %s\n- Reason: %s\n' "$SHA" "${VERSION:-n/a}" "$2"
        if [ -n "$CI_RUN_URL" ]; then printf -- '- Gating CI run: %s\n' "$CI_RUN_URL"; fi
        if [ -n "$PR_URL" ]; then printf -- '- Pull request: %s\n' "$PR_URL"; fi
    } >> "$GITHUB_STEP_SUMMARY"
}

cmd_gate() {
    local action=none reason target
    verify_ci_run
    find_pr
    run_plan
    refuse_overtaken
    reason="$REASON"
    if [ "$DECISION" = release ]; then
        target="$(remote_tag_commit "$TAG")"
        if [ -z "$target" ]; then
            action=create
        elif [ "$target" = "$SHA" ]; then
            if release_exists "$TAG"; then reason="tag $TAG and its release already exist"
            else action=release-only; reason="tag $TAG points at this SHA; its release is missing"
            fi
        else
            die "tag $TAG already exists on the remote at $target, not $SHA; tags are never moved"
        fi
    elif [ "$TAG_STATE" = elsewhere ] && [ "$BUMP" = true ]; then
        die "$SHA bumps VERSION to $VERSION but $REASON; release a new version instead"
    elif [ "$TAG_STATE" = at-sha ] && [ "$ENSURE_RELEASE" = true ]; then
        if release_exists "$TAG"; then reason="$REASON; its release exists"
        else action=release-only; reason="$REASON; its release is missing"
        fi
    fi
    emit action "$action"
    emit reason "$reason"
    emit sha "$SHA"
    emit version "$VERSION"
    emit tag "$TAG"
    emit ci_run_id "$CI_RUN_ID"
    emit ci_run_url "$CI_RUN_URL"
    emit pr_url "$PR_URL"
    summary "$action" "$reason"
}

create_tag() {
    local obj rc=0 target
    obj="$(api "repos/$GH_REPO/git/tags" -X POST \
        -f "tag=$TAG" -f "message=$TITLE"$'\n' -f "object=$SHA" -f type=commit \
        -f "tagger[name]=$TAGGER_NAME" -f "tagger[email]=$TAGGER_EMAIL" \
        -f "tagger[date]=$(date -u +%Y-%m-%dT%H:%M:%SZ)" --jq '.sha')" \
        || die "could not create the tag object for $TAG"
    [[ $obj =~ $SHA_RE ]] || die "unexpected tag object id '$obj'"
    api "repos/$GH_REPO/git/refs" -X POST -f "ref=refs/tags/$TAG" -f "sha=$obj" --jq '.ref' >/dev/null || rc=$?
    if [ "$rc" -ne 0 ]; then
        # Another run may have created the tag first; accept it only if it marks this commit.
        target="$(remote_tag_commit "$TAG")"
        [ "$target" = "$SHA" ] \
            || die "could not create refs/tags/$TAG, which now resolves to '${target:-nothing}', not $SHA"
        log "refs/tags/$TAG was created concurrently at $SHA"
        return 0
    fi
    log "created annotated tag $TAG on $SHA (tagger $TAGGER_NAME)"
}

cmd_publish() {
    local target rc=0
    # Re-verify instead of trusting the gate job: the write token acts only on what it checked.
    verify_ci_run
    find_pr
    run_plan --notes-file "$WORK/notes.md" --ci-run-url "$CI_RUN_URL" --pr-url "$PR_URL" \
        --release-run-url "$RELEASE_RUN_URL"
    refuse_overtaken
    if [ "$DECISION" != release ]; then
        if [ "$TAG_STATE" = elsewhere ] && [ "$BUMP" = true ]; then die "$REASON"; fi
        if [ "$TAG_STATE" != at-sha ] || [ "$ENSURE_RELEASE" != true ]; then
            log "nothing to publish: $REASON"; summary none "$REASON"; return 0
        fi
    fi
    target="$(remote_tag_commit "$TAG")"
    if [ -z "$target" ]; then
        [ "$DECISION" = release ] || die "tag $TAG exists locally but not on the remote; refusing to recreate it"
        create_tag
    elif [ "$target" != "$SHA" ]; then
        die "tag $TAG exists on the remote at $target, not $SHA; tags are never moved"
    else
        log "tag $TAG already points at $SHA"
    fi
    if release_exists "$TAG"; then
        log "release $TAG already exists; nothing to do"; summary none "release $TAG already exists"; return 0
    fi
    gh release create "$TAG" --verify-tag --title "$TITLE" --notes-file "$WORK/notes.md" \
        --latest="$LATEST" >&2 || rc=$?
    if [ "$rc" -ne 0 ]; then
        release_exists "$TAG" || die "could not create release $TAG"
        log "release $TAG was created concurrently"
    fi
    log "published release $TAG ($TITLE), latest=$LATEST"
    summary published "release $TAG ($TITLE), latest=$LATEST"
}

case "$CMD" in
    gate) cmd_gate ;;
    publish) cmd_publish ;;
esac
