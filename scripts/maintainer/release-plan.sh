#!/usr/bin/env bash
#
# Product-Kit maintainer tooling: decide, without network access, whether one commit on main
# is a release. .github/workflows/release.yml runs it through release-github.sh; the process is
# described in CONTRIBUTING.md ("Releases"). Not installed into consumer projects: init.sh
# installs only scripts/*.sh, not this directory.
#
# Usage:
#   release-plan.sh --sha SHA [--repo DIR] [--main-ref REF] [--notes-file PATH] [--allow-backfill]
#                   [--ci-run-url URL] [--pr-url URL] [--release-run-url URL]
#   release-plan.sh --check-worktree [--repo DIR]
#
# --sha takes 7-40 hex digits, never a ref name, and must lie on the first-parent history of
# --main-ref (default origin/main). The commit is a release when its VERSION differs from its
# first parent's and is a greater X.Y.Z, no tag v<VERSION> exists, the version is greater than
# every existing vX.Y.Z tag (unless --allow-backfill), and the first CHANGELOG.md section other
# than [Unreleased] is headed `## [X.Y.Z] — YYYY-MM-DD — subtitle` for that version. An existing
# tag is reported and never moved: decision=skip with tag_state at-sha or elsewhere.
# backfill is not-needed, allowed or refused: refused means a newer vX.Y.Z tag exists and
# --allow-backfill was not given. An untagged release commit that is valid in every other respect
# is then skipped, and release-github.sh fails on that skip rather than passing silently; it does
# the same for a tag on this SHA whose valid release is missing on GitHub. section is valid or
# invalid: whether the CHANGELOG section for VERSION can make release notes.
# ensure_release=true means the tag already marks this valid release commit (the newest one,
# unless --allow-backfill), so a missing GitHub release may still be created for it.
#
# With --notes-file, a release (or ensure_release) writes the CHANGELOG section, from its
# heading to the line before the next `## [` heading, then a Verification block (merged commit
# and the given URLs). --check-worktree validates the working tree's VERSION and top CHANGELOG
# section the same way, so a malformed release heading fails in pull-request CI.
#
# Output: key=value lines on stdout (decision, reason, sha, version, tag, tag_state, tag_target,
# bump, backfill, section, title, latest, ensure_release, notes_file); diagnostics on stderr.
# Exit 0: plan computed (release or skip). Exit 1: the commit bumps VERSION but is not a valid
# release. Exit 2: refused input (usage, unknown commit, commit not on main's first-parent
# history).

set -euo pipefail
export LC_ALL=C

usage() { sed -n '2,/^$/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
die() { printf 'release-plan: %s\n' "$1" >&2; exit "${2:-1}"; }
emit() { printf '%s=%s\n' "$1" "$2"; }

REPO="."
MAIN_REF="origin/main"
SHA_IN=""
NOTES_FILE=""
CI_RUN_URL=""
PR_URL=""
RELEASE_RUN_URL=""
CHECK_WORKTREE=false
ALLOW_BACKFILL=false
DASH=' — '   # space, U+2014 EM DASH, space: the CHANGELOG heading separator
NL='
'
SEMVER_RE='^[0-9]+[.][0-9]+[.][0-9]+$'
DATE_RE='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'
SHA_RE='^[0-9a-f]{7,40}$'

while [ $# -gt 0 ]; do
    case "$1" in
        --sha|--repo|--main-ref|--notes-file|--ci-run-url|--pr-url|--release-run-url)
            [ $# -ge 2 ] || die "$1 requires a value" 2
            case "$1" in
                --sha) SHA_IN="$2" ;;
                --repo) REPO="$2" ;;
                --main-ref) MAIN_REF="$2" ;;
                --notes-file) NOTES_FILE="$2" ;;
                --ci-run-url) CI_RUN_URL="$2" ;;
                --pr-url) PR_URL="$2" ;;
                --release-run-url) RELEASE_RUN_URL="$2" ;;
            esac
            shift
            ;;
        --check-worktree) CHECK_WORKTREE=true ;;
        --allow-backfill) ALLOW_BACKFILL=true ;;
        -h|--help) usage; exit 0 ;;
        *) die "unknown argument '$1' (use --help)" 2 ;;
    esac
    shift
done

# URLs end up in Markdown release notes: plain https URLs only (empty means "not known").
for url in "$CI_RUN_URL" "$PR_URL" "$RELEASE_RUN_URL"; do
    case "$url" in
        '') ;;
        *[[:space:]]*|*'('*|*')'*|*'<'*|*'>'*) die "URL contains whitespace or Markdown punctuation: $url" 2 ;;
        https://?*) ;;
        *) die "URL must start with https://: $url" 2 ;;
    esac
done
[ -d "$REPO" ] || die "repository directory not found: $REPO" 2

is_semver() { [[ $1 =~ $SEMVER_RE ]]; }

# semver_gt A B: true when version A is greater than version B (both X.Y.Z).
semver_gt() {
    local a1 a2 a3 b1 b2 b3 rest
    a1="${1%%.*}"; rest="${1#*.}"; a2="${rest%%.*}"; a3="${rest#*.}"
    b1="${2%%.*}"; rest="${2#*.}"; b2="${rest%%.*}"; b3="${rest#*.}"
    if [ "$a1" -ne "$b1" ]; then [ "$a1" -gt "$b1" ]; return; fi
    if [ "$a2" -ne "$b2" ]; then [ "$a2" -gt "$b2" ]; return; fi
    [ "$a3" -gt "$b3" ]
}

# first_line_version TEXT: the first line with all whitespace removed (as tests/test_version.sh).
first_line_version() {
    local raw="${1%%"$NL"*}"
    printf '%s' "$raw" | tr -d '[:space:]'
}

# version_at COMMIT: VERSION at that commit; empty when the file is absent.
version_at() {
    local raw
    raw="$(git -C "$REPO" show "$1:VERSION" 2>/dev/null)" || return 0
    first_line_version "$raw"
}

# top_section TEXT: the first `## [` section other than [Unreleased], heading included, up to the
# line before the next `## [` heading, without CRs or trailing blank lines. awk drains its input
# (no early exit), so the writer never sees SIGPIPE under pipefail.
top_section() {
    printf '%s\n' "$1" | awk '
        { sub(/\r$/, "") }
        /^## \[/ {
            if (state == 1) { state = 2 }
            else if (state == 0 && $0 !~ /^## \[Unreleased\]/) { state = 1 }
        }
        state == 1 {
            if ($0 ~ /^[ \t]*$/) { pending = pending "\n"; next }
            printf "%s%s\n", pending, $0
            pending = ""
        }'
}

# validate_section CHANGELOG_TEXT VERSION: sets SECTION, SUBTITLE and TITLE and returns 0, or
# sets SECTION_ERROR and returns 1.
validate_section() {
    local heading hv rest date expected
    SECTION=""; SUBTITLE=""; TITLE=""; SECTION_ERROR=""
    expected="\"## [$2]${DASH}YYYY-MM-DD${DASH}subtitle\""
    SECTION="$(top_section "$1")"
    if [ -z "$SECTION" ]; then
        SECTION_ERROR="CHANGELOG.md has no release section below [Unreleased]"; return 1
    fi
    heading="${SECTION%%"$NL"*}"
    rest="${heading#\#\# \[}"
    hv="${rest%%]*}"
    if [ "$hv" != "$2" ]; then
        SECTION_ERROR="CHANGELOG.md top release section is [$hv] but VERSION is $2; add the release section in the release PR"
        return 1
    fi
    rest="${rest#*]}"
    case "$rest" in
        "$DASH"*"$DASH"*) ;;
        *) SECTION_ERROR="CHANGELOG.md heading must read $expected: $heading"; return 1 ;;
    esac
    rest="${rest#"$DASH"}"
    date="${rest%%"$DASH"*}"
    SUBTITLE="${rest#*"$DASH"}"
    SUBTITLE="${SUBTITLE#"${SUBTITLE%%[![:space:]]*}"}"   # trim leading whitespace
    SUBTITLE="${SUBTITLE%"${SUBTITLE##*[![:space:]]}"}"   # trim trailing whitespace
    if ! [[ $date =~ $DATE_RE ]] || [ -z "$SUBTITLE" ]; then
        SECTION_ERROR="CHANGELOG.md heading must read $expected: $heading"; return 1
    fi
    TITLE="v$2$DASH$SUBTITLE"
    return 0
}

write_notes() {
    {
        printf '%s\n\n### Verification\n\n' "$SECTION"
        # shellcheck disable=SC2016 # the backticks are Markdown code formatting, not a command substitution
        printf -- '- Merged commit: `%s`\n' "$SHA"
        if [ -n "$CI_RUN_URL" ]; then printf -- '- Gating CI run (push to main): %s\n' "$CI_RUN_URL"; fi
        if [ -n "$PR_URL" ]; then printf -- '- Release PR: %s\n' "$PR_URL"; fi
        if [ -n "$RELEASE_RUN_URL" ]; then printf -- '- Tagged and published by: %s\n' "$RELEASE_RUN_URL"; fi
    } > "$NOTES_FILE"
    emit notes_file "$NOTES_FILE"
}

# --- Pre-merge check of the working tree -------------------------------------------------------
if $CHECK_WORKTREE; then
    [ -z "$SHA_IN" ] || die "--check-worktree takes no --sha" 2
    [ -f "$REPO/VERSION" ] || die "VERSION not found in $REPO"
    [ -f "$REPO/CHANGELOG.md" ] || die "CHANGELOG.md not found in $REPO"
    VERSION="$(first_line_version "$(cat "$REPO/VERSION")")"
    is_semver "$VERSION" || die "VERSION must be X.Y.Z, got '$VERSION'"
    validate_section "$(cat "$REPO/CHANGELOG.md")" "$VERSION" || die "$SECTION_ERROR"
    emit version "$VERSION"
    emit tag "v$VERSION"
    emit title "$TITLE"
    exit 0
fi

# --- Resolve the commit and prove it is on main ------------------------------------------------
[ -n "$SHA_IN" ] || die "--sha is required (use --help)" 2
[[ $SHA_IN =~ $SHA_RE ]] || die "--sha must be 7-40 lowercase hex digits, not a ref name: '$SHA_IN'" 2
# Git is needed only from here on: the worktree check above also runs on a source export.
git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || die "not a git repository: $REPO" 2
SHA="$(git -C "$REPO" rev-parse -q --verify "$SHA_IN^{commit}" 2>/dev/null)" \
    || die "unknown or ambiguous commit: $SHA_IN" 2
git -C "$REPO" rev-parse -q --verify "$MAIN_REF^{commit}" >/dev/null 2>&1 \
    || die "main ref not found: $MAIN_REF (fetch it first)" 2
if ! git -C "$REPO" rev-list --first-parent "$MAIN_REF" \
        | awk -v s="$SHA" '$0 == s { found = 1 } END { exit found ? 0 : 1 }'; then
    die "$SHA is not on the first-parent history of $MAIN_REF; only commits merged to main are released" 2
fi
emit sha "$SHA"

VERSION="$(version_at "$SHA")"
PARENT="$(git -C "$REPO" rev-parse -q --verify "$SHA^1^{commit}" 2>/dev/null)" || PARENT=""
PARENT_VERSION=""
if [ -n "$PARENT" ]; then PARENT_VERSION="$(version_at "$PARENT")"; fi
BUMP=true
if [ -n "$PARENT" ] && [ "$VERSION" = "$PARENT_VERSION" ]; then BUMP=false; fi

skip() { emit decision skip; emit reason "$1"; emit bump "$BUMP"; exit 0; }

[ -n "$VERSION" ] || skip "no VERSION file at this commit"
if ! is_semver "$VERSION"; then
    $BUMP || skip "VERSION is unchanged from the first parent; not a release commit"
    die "VERSION must be X.Y.Z, got '$VERSION'"
fi
TAG="v$VERSION"
emit version "$VERSION"
emit tag "$TAG"

TAG_TARGET="$(git -C "$REPO" rev-parse -q --verify "refs/tags/$TAG^{commit}" 2>/dev/null)" || TAG_TARGET=""
if [ -z "$TAG_TARGET" ]; then TAG_STATE=absent
elif [ "$TAG_TARGET" = "$SHA" ]; then TAG_STATE=at-sha
else TAG_STATE=elsewhere
fi
emit tag_state "$TAG_STATE"
emit tag_target "$TAG_TARGET"

$BUMP || skip "VERSION $VERSION is unchanged from the first parent; not a release commit"
[ "$TAG_STATE" != elsewhere ] \
    || skip "tag $TAG already exists and points at $TAG_TARGET, not this SHA; tags are never moved"

# latest: this version is greater than every other vX.Y.Z tag. Tag names cannot contain glob
# characters, so the unquoted list splits safely. Releasing (or completing) an older version is a
# backfill and needs --allow-backfill: a stray dispatch must not mint a permanent old release.
LATEST=true
HIGHEST=""
for t in $(git -C "$REPO" tag -l 'v*'); do
    v="${t#v}"
    if ! is_semver "$v" || [ "$v" = "$VERSION" ]; then continue; fi
    if ! semver_gt "$VERSION" "$v"; then LATEST=false; fi
    if [ -z "$HIGHEST" ] || semver_gt "$v" "$HIGHEST"; then HIGHEST="$v"; fi
done
BACKFILL=not-needed
BACKFILL_REFUSED=""
if ! $LATEST && $ALLOW_BACKFILL; then
    BACKFILL=allowed
elif ! $LATEST; then
    BACKFILL=refused
    BACKFILL_REFUSED="VERSION $VERSION is older than the latest release v$HIGHEST; backfill needs explicit input (--allow-backfill)"
fi
emit backfill "$BACKFILL"

SECTION_OK=true
if ! CHANGELOG="$(git -C "$REPO" show "$SHA:CHANGELOG.md" 2>/dev/null)"; then
    SECTION_OK=false; SECTION_ERROR="CHANGELOG.md is missing at this commit"
elif ! validate_section "$CHANGELOG" "$VERSION"; then
    SECTION_OK=false
fi
if $SECTION_OK; then emit section valid; else emit section invalid; fi

if [ "$TAG_STATE" = at-sha ]; then
    # The tag already marks this release commit: nothing to tag. The caller may still create a
    # missing GitHub release, but only from a valid section and, without --allow-backfill, only
    # for the newest version.
    emit decision skip
    emit reason "tag $TAG already exists and points at this SHA"
    emit bump "$BUMP"
    if [ -n "$BACKFILL_REFUSED" ]; then
        emit ensure_release false
        printf 'release-plan: no release for the existing tag: %s\n' "$BACKFILL_REFUSED" >&2
    elif $SECTION_OK; then
        emit title "$TITLE"
        emit latest "$LATEST"
        emit ensure_release true
        if [ -n "$NOTES_FILE" ]; then write_notes; fi
    else
        emit ensure_release false
        printf 'release-plan: no release notes for the existing tag: %s\n' "$SECTION_ERROR" >&2
    fi
    exit 0
fi

if [ -n "$PARENT_VERSION" ] && is_semver "$PARENT_VERSION" && ! semver_gt "$VERSION" "$PARENT_VERSION"; then
    die "VERSION $VERSION does not increase on the first parent's $PARENT_VERSION"
fi
$SECTION_OK || die "$SECTION_ERROR"
# Valid in every other respect: refused only because a newer version is already tagged.
[ -z "$BACKFILL_REFUSED" ] || skip "$BACKFILL_REFUSED"

emit decision release
emit reason "VERSION ${PARENT_VERSION:-(none)} -> $VERSION and no tag $TAG exists"
emit bump "$BUMP"
emit title "$TITLE"
emit latest "$LATEST"
emit ensure_release false
if [ -n "$NOTES_FILE" ]; then write_notes; fi
