#!/usr/bin/env bash
# Automatic release tooling (scripts/maintainer/, .github/workflows/release.yml): the offline
# plan decides from a local Git history and one SHA; the GitHub side (both jobs verify CI on their
# own) runs against a fake gh that records every call. Installer coverage is in test_init.sh.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PLAN="$PK_ROOT/scripts/maintainer/release-plan.sh"
GHS="$PK_ROOT/scripts/maintainer/release-github.sh"

new_repo() { # → an empty repository on branch main
    local d; d="$(mktemp -d)" || return 1
    [ -n "$d" ] && [ -d "$d" ] || return 1
    git -C "$d" init -q
    git -C "$d" symbolic-ref HEAD refs/heads/main
    git -C "$d" config user.email t@example.com
    git -C "$d" config user.name test
    git -C "$d" config commit.gpgsign false
    git -C "$d" config tag.gpgsign false
    echo "$d"
}
commit() { # REPO MESSAGE → full SHA of the new commit
    git -C "$1" add -A >/dev/null
    git -C "$1" commit -q -m "$2" >/dev/null
    git -C "$1" rev-parse HEAD
}
# release REPO VERSION HEADING BODY: VERSION plus a new top section below a non-empty [Unreleased].
release() {
    { printf '%s\n\n%s\n\n' "$3" "$4"; cat "$1/.git/sections" 2>/dev/null; } > "$1/.git/sections.new"
    mv "$1/.git/sections.new" "$1/.git/sections"
    { printf '# Changelog\n\nIntro.\n\n## [Unreleased]\n\n- pending note that is not released\n\n'
      cat "$1/.git/sections"; } > "$1/CHANGELOG.md"
    printf '%s\n' "$2" > "$1/VERSION"
}
plan() { run bash "$PLAN" --repo "$REPO" --main-ref main "$@"; }
val() { # KEY → its value in the last OUTPUT
    printf '%s\n' "$OUTPUT" | awk -v k="$1" 'index($0, k "=") == 1 && !done { print substr($0, length(k) + 2); done = 1 }'
}

# --- Fixture: one main history holding each plan scenario -------------------------------------
REPO="$(new_repo)"; track_tmp "$REPO"
release "$REPO" 0.1.0 '## [0.1.0] — 2026-01-01 — first release' '- initial'
C1="$(commit "$REPO" 'release 0.1.0')"
git -C "$REPO" tag -a v0.1.0 -m 'v0.1.0 — first release' "$C1"
release "$REPO" 0.2.0 '## [0.2.0] — 2026-02-01 — second release' "### Added

- one change
  wrapped continuation

- another change

### Adoption

Upgrade normally."
C2="$(commit "$REPO" 'release 0.2.0')"
printf 'docs\n' > "$REPO/README.md"
C3="$(commit "$REPO" 'docs only')"
printf '0.3.0\n' > "$REPO/VERSION"
C4="$(commit "$REPO" 'bump without a changelog section')"
release "$REPO" 0.3.1 '## [0.3.1] — 2026-03-02' '- no subtitle'
C5="$(commit "$REPO" 'heading without subtitle')"
release "$REPO" 0.3.2 '## [0.3.2] — 2026-3-2 — bad date' '- date without zero padding'
C5B="$(commit "$REPO" 'heading with a malformed date')"
release "$REPO" 0.4.0 '## [0.4.0] — 2026-04-01 —   parts + canon — pilot readiness   ' '- inner dash'
C6="$(commit "$REPO" 'release 0.4.0')"
release "$REPO" 0.3.9 '## [0.3.9] — 2026-04-02 — backwards' '- lower'
C7="$(commit "$REPO" 'version goes down')"
git -C "$REPO" checkout -q -b side "$C3"
printf 'side\n' > "$REPO/side.txt"
SIDE="$(commit "$REPO" 'side branch work')"
git -C "$REPO" checkout -q main

# --- Plan --------------------------------------------------------------------------------------
it "a VERSION bump with a matching CHANGELOG section is a release"
NOTES="$REPO/.git/notes-c2.md"
plan --sha "$C2" --notes-file "$NOTES" --ci-run-url https://github.com/acme/kit/actions/runs/101 \
    --pr-url https://github.com/acme/kit/pull/7
assert_eq 0 "$STATUS" "plan succeeds"
assert_eq release "$(val decision)" "decision"
assert_eq "$C2" "$(val sha)" "exact SHA"
assert_eq 0.2.0 "$(val version)" "version"
assert_eq v0.2.0 "$(val tag)" "tag name"
assert_eq absent "$(val tag_state)" "tag absent"
assert_eq true "$(val bump)" "bump detected"
assert_eq "Product Kit - v0.2.0" "$(val title)" "title names the product and version"
assert_eq true "$(val latest)" "highest semver is latest"
assert_eq not-needed "$(val backfill)" "no backfill"
assert_eq valid "$(val section)" "section valid"
assert_eq "$NOTES" "$(val notes_file)" "notes file reported"

it "release notes are the exact section plus the Verification block"
expected="## [0.2.0] — 2026-02-01 — second release

### Added

- one change
  wrapped continuation

- another change

### Adoption

Upgrade normally.

### Verification

- Merged commit: \`$C2\`
- Gating CI run (push to main): https://github.com/acme/kit/actions/runs/101
- Release PR: https://github.com/acme/kit/pull/7"
assert_eq "$expected" "$(cat "$NOTES")" "notes content"

it "an abbreviated SHA resolves to the full commit"
plan --sha "$(printf '%s' "$C2" | cut -c1-10)"
assert_eq 0 "$STATUS" "abbreviated SHA accepted"
assert_eq "$C2" "$(val sha)" "full SHA reported"

it "a merge that does not change VERSION releases nothing"
plan --sha "$C3"
assert_eq 0 "$STATUS" "skip is not an error"
assert_eq skip "$(val decision)" "docs-only merge skipped"
assert_eq false "$(val bump)" "no bump"
assert_contains "$(val reason)" "unchanged from the first parent" "reason names the missing bump"

it "a bump without its CHANGELOG section fails"
plan --sha "$C4"
assert_eq 1 "$STATUS" "mismatch fails"
assert_contains "$OUTPUT" "top release section is [0.2.0] but VERSION is 0.3.0" "mismatch explained"
assert_not_contains "$OUTPUT" "decision=release" "no release decision"

it "a release heading without the subtitle fails"
plan --sha "$C5"
assert_eq 1 "$STATUS" "malformed heading fails"
assert_contains "$OUTPUT" "YYYY-MM-DD — subtitle" "expected format named"

it "a release heading with a malformed date fails"
plan --sha "$C5B"
assert_eq 1 "$STATUS" "unpadded date fails"
assert_contains "$OUTPUT" "YYYY-MM-DD" "date format named"
assert_not_contains "$OUTPUT" "decision=release" "no release decision"

it "a subtitle with inner dashes is valid and its heading opens the notes verbatim"
plan --sha "$C6" --notes-file "$REPO/.git/notes-c6.md"
assert_eq 0 "$STATUS" "plan succeeds"
assert_eq valid "$(val section)" "subtitle parsed"
assert_eq "Product Kit - v0.4.0" "$(val title)" "title leaves the subtitle out"
assert_eq "## [0.4.0] — 2026-04-01 —   parts + canon — pilot readiness   " \
    "$(head -n 1 "$REPO/.git/notes-c6.md")" "heading copied verbatim"
assert_contains "$(cat "$REPO/.git/notes-c6.md")" "- inner dash" "section body included"
assert_not_contains "$(cat "$REPO/.git/notes-c6.md")" "pending note" "[Unreleased] excluded"
assert_not_contains "$(cat "$REPO/.git/notes-c6.md")" "## [0.3.1]" "next section excluded"
assert_not_contains "$(cat "$REPO/.git/notes-c6.md")" "Gating CI run" "no CI line without a URL"

it "a version older than the newest tag is a backfill and needs explicit input"
git -C "$REPO" tag v0.10.0 "$C1"
plan --sha "$C6" --notes-file "$REPO/.git/notes-c6-backfill.md"
assert_eq 0 "$STATUS" "refusal is a skip, not an error"
assert_eq skip "$(val decision)" "0.4.0 beside v0.10.0 (numeric, not lexical) is not released"
assert_eq refused "$(val backfill)" "backfill refused"
assert_eq absent "$(val tag_state)" "no tag of its own"
assert_contains "$(val reason)" "older than the latest release v0.10.0; backfill needs explicit input" "reason"
if [ -e "$REPO/.git/notes-c6-backfill.md" ]; then _no "no notes for a refused backfill"; else _ok "no notes for a refused backfill"; fi
plan --sha "$C6" --allow-backfill
assert_eq 0 "$STATUS" "explicit backfill plans"
assert_eq release "$(val decision)" "explicit backfill is a release"
assert_eq false "$(val latest)" "a backfill is never latest"
assert_eq allowed "$(val backfill)" "backfill allowed"
git -C "$REPO" tag -d v0.10.0 >/dev/null

it "a release overtaken by a newer tagged one is refused only when it is otherwise valid"
git -C "$REPO" tag -a v0.4.0 -m 'v0.4.0 — parts + canon — pilot readiness' "$C6"
plan --sha "$C2"
assert_eq 0 "$STATUS" "the plan itself reports the refusal as a skip"
assert_eq skip "$(val decision)" "0.2.0 after v0.4.0 is not released"
assert_eq refused "$(val backfill)" "refused as a backfill"
assert_contains "$(val reason)" "older than the latest release v0.4.0" "reason names the newer release"
plan --sha "$C5"
assert_eq 1 "$STATUS" "an invalid release commit fails as invalid, not as a backfill"
assert_contains "$OUTPUT" "YYYY-MM-DD — subtitle" "section error reported"
plan --sha "$C2" --allow-backfill
assert_eq release "$(val decision)" "explicit backfill is a release"
assert_eq false "$(val latest)" "not latest beside v0.4.0"
git -C "$REPO" tag -d v0.4.0 >/dev/null

it "a VERSION that does not increase fails"
plan --sha "$C7"
assert_eq 1 "$STATUS" "decrease fails"
assert_contains "$OUTPUT" "does not increase" "decrease explained"

it "an existing tag on the commit is reported, not recreated"
git -C "$REPO" tag -a v0.2.0 -m 'v0.2.0 — second release' "$C2"
plan --sha "$C2" --notes-file "$REPO/.git/notes-c2-again.md"
assert_eq 0 "$STATUS" "skip is not an error"
assert_eq skip "$(val decision)" "tag exists: skip"
assert_eq at-sha "$(val tag_state)" "tag state"
assert_eq "tag v0.2.0 already exists and points at this SHA" "$(val reason)" "reason"
assert_eq true "$(val ensure_release)" "a missing release may still be created"
assert_eq "Product Kit - v0.2.0" "$(val title)" "title still computed"
assert_file "$REPO/.git/notes-c2-again.md" "notes still written"
git -C "$REPO" tag v0.10.0 "$C1"
plan --sha "$C2"
assert_eq false "$(val ensure_release)" "an older tagged version gets no release without explicit input"
assert_eq refused "$(val backfill)" "reported as a refused backfill"
assert_contains "$OUTPUT" "no release for the existing tag: VERSION 0.2.0 is older" "refusal explained"
plan --sha "$C2" --allow-backfill
assert_eq true "$(val ensure_release)" "explicit backfill may complete its release"
assert_eq false "$(val latest)" "backfilled release is not latest"
git -C "$REPO" tag -d v0.10.0 >/dev/null

it "an existing tag elsewhere is reported and never moved"
git -C "$REPO" tag v0.4.0 "$C3"
plan --sha "$C6"
assert_eq 0 "$STATUS" "skip is not an error"
assert_eq skip "$(val decision)" "tag elsewhere: skip"
assert_eq elsewhere "$(val tag_state)" "tag state"
assert_eq "$C3" "$(val tag_target)" "current tag target"
assert_contains "$(val reason)" "not this SHA; tags are never moved" "reason"
assert_eq true "$(val bump)" "bump still reported"
assert_eq "$C3" "$(git -C "$REPO" rev-parse 'v0.4.0^{commit}')" "tag untouched"
git -C "$REPO" tag -d v0.4.0 >/dev/null

it "a tag on a commit with an invalid section yields no release, title or notes"
git -C "$REPO" tag v0.3.1 "$C5"
plan --sha "$C5" --notes-file "$REPO/.git/notes-c5.md"
assert_eq 0 "$STATUS" "skip is not an error"
assert_eq skip "$(val decision)" "tag exists: skip"
assert_eq at-sha "$(val tag_state)" "tag state"
assert_eq false "$(val ensure_release)" "no release from an invalid section"
assert_eq invalid "$(val section)" "section reported invalid"
assert_not_contains "$OUTPUT" "title=" "no title"
if [ -e "$REPO/.git/notes-c5.md" ]; then _no "no notes file"; else _ok "no notes file"; fi
assert_contains "$OUTPUT" "no release notes for the existing tag" "reason on stderr"
git -C "$REPO" tag -d v0.3.1 >/dev/null

it "commits off main, unknown commits, ref names and unsafe URLs are refused"
plan --sha "$SIDE"
assert_eq 2 "$STATUS" "side-branch commit refused"
assert_contains "$OUTPUT" "not on the first-parent history of main" "refusal explained"
plan --sha 0123456789abcdef0123456789abcdef01234567
assert_eq 2 "$STATUS" "unknown commit refused"
plan --sha main
assert_eq 2 "$STATUS" "ref name refused"
plan --sha HEAD
assert_eq 2 "$STATUS" "HEAD refused"
plan --sha "$C2" --main-ref no-such-ref
assert_eq 2 "$STATUS" "missing main ref refused"
plan --sha "$C2" --ci-run-url 'javascript:alert(1)'
assert_eq 2 "$STATUS" "non-https URL refused"

it "a commit merged in from a side branch is not on main's first-parent history"
git -C "$REPO" checkout -q -b integration "$C7"
git -C "$REPO" merge -q --no-ff -m 'merge side' side >/dev/null 2>&1
git -C "$REPO" checkout -q main
assert_eq 0 "$(git -C "$REPO" merge-base --is-ancestor "$SIDE" integration && echo 0)" "side commit is an ancestor"
plan --sha "$SIDE" --main-ref integration
assert_eq 2 "$STATUS" "second-parent commit refused"

it "the worktree check validates VERSION against the top CHANGELOG section before merge"
run bash "$PLAN" --check-worktree --repo "$REPO"
assert_eq 0 "$STATUS" "valid worktree"
assert_contains "$OUTPUT" "title=Product Kit - v0.3.9" "title reported"
printf '0.5.0\n' > "$REPO/VERSION"
run bash "$PLAN" --check-worktree --repo "$REPO"
assert_eq 1 "$STATUS" "VERSION without its section fails"
git -C "$REPO" checkout -q -- VERSION
run bash "$PLAN" --check-worktree --repo "$PK_ROOT"
assert_eq 0 "$STATUS" "Product-Kit's own VERSION and CHANGELOG plan cleanly"
assert_contains "$OUTPUT" "title=Product Kit - v$(head -n 1 "$PK_ROOT/VERSION" | tr -d '[:space:]')" "own release title"

it "the worktree check needs no Git repository, so the suite also runs on a source export"
EXPORT="$(mktemp -d)"; track_tmp "$EXPORT"
cp "$REPO/VERSION" "$REPO/CHANGELOG.md" "$EXPORT/"
run bash "$PLAN" --check-worktree --repo "$EXPORT"
assert_eq 0 "$STATUS" "worktree check in a directory without .git"
assert_contains "$OUTPUT" "title=Product Kit - v0.3.9" "title reported"
run bash "$PLAN" --repo "$EXPORT" --main-ref main --sha "$C2"
assert_eq 2 "$STATUS" "planning a commit still needs a repository"
assert_contains "$OUTPUT" "not a git repository" "and says so"

it "the workflow pins actions, isolates the write job and keeps expressions out of scripts"
WF="$PK_ROOT/.github/workflows/release.yml"
job_key() { # JOB KEY → that job-level key's line plus its more-indented continuation lines
    awk -v want_job="$1" -v want_key="$2" '/^jobs:/ { injobs = 1; next }
        !injobs { next }
        { match($0, /^ */); indent = RLENGTH }
        /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:.*/, "", job); inkey = 0; next }
        inkey && $0 !~ /^[ \t]*$/ && indent <= 4 { inkey = 0 }
        indent == 4 && job == want_job && index($0, want_key ":") == 5 { inkey = 1 }
        inkey { print }' "$WF"
}
assert_file "$WF" "release workflow exists"
assert_contains "$(cat "$WF")" "permissions: {}" "no default token permissions"
assert_eq "" "$(grep -n 'pull_request_target' "$WF" || true)" "no pull_request_target"
assert_eq "" "$(grep -nE 'uses:' "$WF" | grep -vE '@[0-9a-f]{40}( |$)' || true)" "actions pinned by full SHA"
# Both jobs run on a fresh GitHub-hosted runner of one named Ubuntu release. A self-hosted runner
# would give the write token to a machine that also runs pull-request code.
runners="$(awk '/^jobs:/ { jobs = 1; next }
    jobs && /^  [A-Za-z0-9_-]+:$/ { name = $1; sub(/:$/, "", name) }
    jobs && /^    runs-on:/ { sub(/^    runs-on: */, ""); print name "=" $0 }' "$WF")"
assert_eq "gate=ubuntu-24.04
release=ubuntu-24.04" "$runners" "both jobs on GitHub-hosted Ubuntu 24.04"
# Each job checks out its own commit, then runs one script step. The comparison leaves out the
# pinned SHA and version, so a Dependabot update of the action keeps this green.
step_heads() {
    job_key "$1" steps | awk '/^      - / { sub(/^      - /, ""); print }' \
        | sed -E 's/@[0-9a-f]{40} # v[0-9.]+$/@<sha> # <version>/'
}
assert_eq "uses: actions/checkout@<sha> # <version>
name: Verify CI and plan the release" "$(step_heads gate)" "gate steps: checkout, plan"
assert_eq "uses: actions/checkout@<sha> # <version>
name: Verify CI again, then tag and publish the release" "$(step_heads release)" "release steps: checkout, publish"
assert_eq "" "$(grep -n 'continue-on-error' "$WF" || true)" "no step or job may fail without failing the run"
assert_eq "    if: >-
    if: >-" "$(grep -E '^[[:space:]]*(- )?if:' "$WF")" "if: only on the two jobs"
assert_eq "" "$(grep -nE '^[[:space:]]*(- )?env:' "$WF" | grep -vE '^[0-9]+:        env:$' || true)" "env: only at step level"
assert_eq 2 "$(grep -cxE '        env:' "$WF" || true)" "and only in the two script steps"
# The token never goes to disk or into later steps: no gh auth login or setup-git, no git
# credential configuration or token URLs, nothing exported through GITHUB_ENV, no secrets, and
# GH_TOKEN only in the two script steps' own env (no workflow- or job-level env).
assert_eq "" "$(grep -nE 'gh auth|credential\.|credential-|extraheader|netrc|x-access-token|GITHUB_ENV|git config|git -c |secrets\.' \
    "$WF" "$PK_ROOT"/scripts/maintainer/*.sh || true)" "no token written to disk or exported"
# shellcheck disable=SC2016 # '${{' is the literal GitHub expression marker, not a shell expansion
assert_eq 2 "$(grep -cxF '          GH_TOKEN: ${{ github.token }}' "$WF" || true)" "GH_TOKEN in exactly the two script steps"
assert_eq 2 "$(grep -c 'GH_TOKEN' "$WF" || true)" "GH_TOKEN nowhere else"
assert_eq 2 "$(grep -c 'github\.token' "$WF" || true)" "the token expression nowhere else"
assert_eq "" "$(grep -nE '^(    )?env:' "$WF" || true)" "no workflow- or job-level env"
writers="$(awk '/^  [A-Za-z0-9_-]+:$/ { name = $1; sub(/:$/, "", name) }
    /^      contents: write$/ { print name }' "$WF")"
assert_eq release "$writers" "only the release job holds contents: write"
assert_eq "" "$(grep -n 'contents: write' "$WF" | grep -vE '^[0-9]+:      contents: write$' || true)" "write only at job level"
# No blanket grants, and no write scope of any kind outside the release job (workflow level
# included): a flow-style map or a new permission must not bring a write token back to the gate.
assert_eq "" "$(grep -nE '^[^#]*(write-all|read-all)' "$WF" || true)" "no write-all or read-all"
other_writes="$(awk '/^[ \t]*#/ { next }
    /^jobs:/ { injobs = 1; job = ""; next }
    injobs && /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:.*/, "", job) }
    /:[ \t]*write([^-A-Za-z0-9_]|$)/ && job != "release" { print NR ": " $0 }' "$WF")"
assert_eq "" "$other_writes" "no write permission outside the release job"
assert_eq "    permissions:
      contents: read
      actions: read
      pull-requests: read" "$(job_key gate permissions)" "the gate's exact read-only scopes"
assert_eq "    permissions:
      contents: write
      actions: read
      pull-requests: read" "$(job_key release permissions)" "the release job's exact scopes"
# The write job's ordering and checkout carry its correctness and isolation: one release at a
# time, never cancelled midway, every tag fetched, no persisted token, and the tooling from this
# workflow's own commit (no ref: or repository: override). Dispatch runs only main's copy.
assert_eq "    concurrency:
      group: product-kit-release
      cancel-in-progress: false" "$(job_key release concurrency)" "release jobs run one at a time and are never cancelled midway"
for job in gate release; do
    steps="$(job_key "$job" steps)"
    assert_eq 1 "$(printf '%s\n' "$steps" | grep -c 'uses: actions/checkout@' || true)" "$job: one checkout"
    assert_eq 1 "$(printf '%s\n' "$steps" | grep -cE '^ +fetch-depth: 0( |$)' || true)" "$job: full history and all tags"
    assert_eq 1 "$(printf '%s\n' "$steps" | grep -cE '^ +persist-credentials: false( |$)' || true)" "$job: token not persisted"
done
assert_eq 2 "$(grep -cE '^ +fetch-depth:' "$WF" || true)" "no other fetch-depth"
assert_eq 2 "$(grep -cE '^ +persist-credentials:' "$WF" || true)" "no other persist-credentials"
assert_eq "" "$(grep -nE '^[[:space:]]+(ref|repository):' "$WF" || true)" "checkouts take neither ref: nor repository:"
assert_eq "    if: >-
      (github.event_name == 'workflow_run'
        && github.event.workflow_run.conclusion == 'success'
        && github.event.workflow_run.event == 'push'
        && github.event.workflow_run.head_branch == 'main'
        && github.event.workflow_run.head_repository.full_name == github.repository)
      || (github.event_name == 'workflow_dispatch' && github.ref == 'refs/heads/main')" \
    "$(job_key gate if)" "gate runs only for a green CI push to main here, or a dispatch from main"
# shellcheck disable=SC2016 # '${{' is the literal GitHub expression marker, not a shell expansion
assert_eq "" "$(grep -nE '^[[:space:]]*(- )?run:.*\$\{\{' "$WF" || true)" "no expression on a run: line"
# shellcheck disable=SC2016 # '${{' is the literal GitHub expression marker, not a shell expansion
in_blocks="$(awk '{ match($0, /^ */); indent = RLENGTH }
    inrun && $0 !~ /^[ \t]*$/ && indent <= runindent { inrun = 0 }
    inrun && index($0, "${{") { print NR ": " $0 }
    /^[ \t]*(- )?run:[ \t]*[|>]/ { inrun = 1; runindent = indent }' "$WF")"
assert_eq "" "$in_blocks" "no expression inside a run block scalar"
# shellcheck disable=SC2016 # '${{' is the literal GitHub expression marker, not a shell expansion
assert_eq "" "$(grep -nF '${{' "$WF" | grep -vE '^[0-9]+: +[A-Za-z_-]+: .*\$\{\{' || true)" "expressions only in key values"
for script in "$PK_ROOT"/scripts/maintainer/*.sh; do
    if bash -n "$script"; then _ok "$(basename "$script") syntax"; else _no "$(basename "$script") syntax"; fi
done

it "both jobs take their inputs from the event, and only the gate's action crosses between them"
# shellcheck disable=SC2016 # '${{' is the literal GitHub expression marker, not a shell expansion
for line in 'SHA: ${{ github.event.workflow_run.head_sha || inputs.sha }}' \
    'CI_RUN_ID: ${{ github.event.workflow_run.id }}' 'ALLOW_BACKFILL: ${{ inputs.allow_backfill }}' \
    'if [ -n "$CI_RUN_ID" ]; then set -- "$@" --ci-run-id "$CI_RUN_ID"; fi' \
    'if [ "$ALLOW_BACKFILL" = true ]; then set -- "$@" --allow-backfill; fi'; do
    assert_eq 2 "$(grep -cxF "          $line" "$WF" || true)" "once per job: $line"
done
# shellcheck disable=SC2016 # '${{' is the literal GitHub expression marker, not a shell expansion
assert_eq '    outputs:
      action: ${{ steps.gate.outputs.action }}' "$(job_key gate outputs)" "the gate exports only its action"
assert_eq "" "$(job_key release outputs)" "the release job exports nothing"
release_if="$(job_key release if)"
assert_eq 2 "$(grep -o 'needs\.gate\.outputs\.' "$WF" | wc -l | tr -d ' ')" "gate outputs read twice in the file"
assert_eq 2 "$(printf '%s\n' "$release_if" | grep -o 'needs\.gate\.outputs\.' | wc -l | tr -d ' ')" "both reads in the release job's if:"
assert_contains "$release_if" "(needs.gate.outputs.action == 'create' || needs.gate.outputs.action == 'release-only')" "release starts only for create or release-only"
assert_contains "$release_if" "&& inputs.dry_run != true" "a dry run never reaches the release job"
assert_eq 2 "$(grep -cE '^[[:space:]]*(- )?run:[[:space:]]*[^[:space:]]' "$WF" || true)" "two run steps: the gate and publish scripts"

it "the run steps pass the event inputs through and accept only a known gate action"
# Each run block executes as GitHub runs it (bash --noprofile --norc -eo pipefail) against a stub
# release-github.sh that records its arguments and prints canned gate output.
run_block() { # N → the body of the Nth `run: |` block in the workflow
    awk -v n="$1" '{ match($0, /^ */); indent = RLENGTH }
        inrun && $0 !~ /^[ \t]*$/ && indent <= runindent { inrun = 0 }
        inrun { print }
        /^[ \t]*(- )?run:[ \t]*\|[ \t]*$/ { c++; if (c == n) { inrun = 1; runindent = indent } }' "$WF"
}
WFRUN="$(mktemp -d)"; track_tmp "$WFRUN"
mkdir -p "$WFRUN/scripts/maintainer"
cat > "$WFRUN/scripts/maintainer/release-github.sh" <<'STUB'
printf '%s\n' "$*" > "$STUB_ARGS"
printf '%s\n' "$STUB_OUT"
STUB
run_block 1 > "$WFRUN/gate.sh"
run_block 2 > "$WFRUN/release.sh"
STEP_URL=https://github.com/acme/kit/actions/runs/900
step() { # SCRIPT STUB_OUT SHA CI_RUN_ID ALLOW_BACKFILL → run one extracted step in $WFRUN
    : > "$WFRUN/output"; : > "$WFRUN/args"
    # shellcheck disable=SC2016 # the inner shell expands its own positional parameters
    run env -i PATH="$PATH" STUB_ARGS="$WFRUN/args" STUB_OUT="$2" SHA="$3" CI_RUN_ID="$4" \
        ALLOW_BACKFILL="$5" RELEASE_RUN_URL="$STEP_URL" GITHUB_OUTPUT="$WFRUN/output" \
        bash -c 'cd "$1" && bash --noprofile --norc -eo pipefail "$2"' _ "$WFRUN" "$WFRUN/$1"
}
step gate.sh "$(printf 'action=create\nreason=r')" abc 77 true
assert_eq 0 "$STATUS" "gate step passes"
assert_eq "gate --sha abc --ci-run-id 77 --allow-backfill" "$(cat "$WFRUN/args")" "workflow_run id and backfill passed"
assert_eq "action=create" "$(cat "$WFRUN/output")" "action exported"
step gate.sh action=none abc "" ""
assert_eq "gate --sha abc" "$(cat "$WFRUN/args")" "no id, no backfill for a plain dispatch"
assert_eq "action=none" "$(cat "$WFRUN/output")" "none exported"
step gate.sh action=release-only abc 77 false
assert_eq "gate --sha abc --ci-run-id 77" "$(cat "$WFRUN/args")" "allow_backfill=false passes no flag"
assert_eq "action=release-only" "$(cat "$WFRUN/output")" "release-only exported"
step gate.sh action=publish-everything abc 77 ""
assert_eq 1 "$STATUS" "an unknown gate action fails the gate"
assert_contains "$OUTPUT" "unexpected gate action 'publish-everything'" "unknown action named"
assert_eq "" "$(cat "$WFRUN/output")" "an unknown action is never exported"
step gate.sh "reason=no action line" abc 77 ""
assert_eq 1 "$STATUS" "a missing gate action fails the gate"
assert_eq "" "$(cat "$WFRUN/output")" "nothing exported"
step release.sh "" abc 77 true
assert_eq 0 "$STATUS" "release step passes"
assert_eq "publish --sha abc --release-run-url $STEP_URL --ci-run-id 77 --allow-backfill" \
    "$(cat "$WFRUN/args")" "publish gets the event's SHA, CI run and backfill flag"
step release.sh "" abc "" false
assert_eq "publish --sha abc --release-run-url $STEP_URL" "$(cat "$WFRUN/args")" "dispatch without backfill"

it "releases gate on the CI workflow alone; every job runs on a GitHub-hosted runner"
# Releases need only CI (ci.yml); the macOS check runs beside it and never gates a release.
CIWF="$PK_ROOT/.github/workflows/ci.yml"
MACWF="$PK_ROOT/.github/workflows/ci-macos.yml"
assert_eq "name: CI" "$(head -n 1 "$CIWF")" "the gating workflow is named CI"
assert_eq "name: CI (macOS)" "$(head -n 1 "$MACWF")" "the macOS workflow has a name of its own"
assert_eq "" "$(grep -h '^name:' "$PK_ROOT"/.github/workflows/*.yml | sort | uniq -d)" "workflow names are unique"
assert_eq "    workflows: [CI]" "$(grep -E '^ +workflows:' "$WF")" "release.yml is triggered by CI alone"
assert_eq 1 "$(grep -cxF 'CI_WORKFLOW=".github/workflows/ci.yml"' "$GHS" || true)" "verify_ci_run pins the ci.yml path"
# Pull requests from forks bring their own workflow files, so a self-hosted runner would run their
# code on the host. Every job names one GitHub-hosted image, and no file names a self-hosted label.
hosted="$(for f in "$PK_ROOT"/.github/workflows/*.yml; do
    awk -v f="${f##*/}" '/^[ \t]*runs-on:/ { sub(/^[ \t]*runs-on:[ \t]*/, ""); print f ": " $0 }' "$f"
done | LC_ALL=C sort)"
assert_eq "ci-macos.yml: macos-15
ci.yml: ubuntu-24.04
release.yml: ubuntu-24.04
release.yml: ubuntu-24.04" "$hosted" "every job on a named GitHub-hosted image"
assert_eq "" "$(grep -rniE 'self-hosted|runs-on:[ \t]*\[' "$PK_ROOT/.github" || true)" "no self-hosted runner label in .github"
# ci.yml is what releases key on: a missing push trigger would stop releases silently, and a
# condition or continue-on-error could let a red suite conclude success. Pull requests run both
# checks whatever their base branch.
on_block() { awk '/^on:/ { f = 1 } f && /^[^ #]/ && !/^on:/ { f = 0 } f' "$1"; }
assert_eq "on:
  pull_request:
  push:
    branches: [main]" "$(on_block "$CIWF")" "CI runs for every pull request and for pushes to main"
assert_eq "on:
  pull_request:
  push:
    branches: [main]
  workflow_dispatch:" "$(on_block "$MACWF")" "the macOS check runs for pull requests, pushes to main and on demand"
triggers() { on_block "$1" | awk '/^  [A-Za-z_]+:/ { sub(/^  /, ""); sub(/:.*/, ""); print }'; }
assert_eq "workflow_run
workflow_dispatch" "$(triggers "$WF")" "release.yml runs only after CI or on dispatch"
for f in "$CIWF" "$MACWF"; do
    n="${f##*/}"
    assert_eq "permissions:
  contents: read" "$(awk '/^permissions:/ { f = 1 } f && /^[^ #]/ && !/^permissions:/ { f = 0 } f' "$f")" "$n reads contents only"
    assert_eq 1 "$(grep -cE '^[[:space:]]*permissions:' "$f" || true)" "no job-level permissions in $n"
    assert_eq 1 "$(grep -c 'uses: actions/checkout@' "$f" || true)" "one checkout in $n"
    assert_eq 1 "$(grep -cxE ' +persist-credentials: false' "$f" || true)" "and it persists no credentials"
done
assert_eq 1 "$(grep -cxF '          /bin/bash tests/test_release.sh' "$MACWF" || true)" "the macOS check runs this suite"
assert_eq "" "$(grep -nE '^[[:space:]]*(- )?if:' "$CIWF" "$MACWF" || true)" "no job or step in CI or the macOS check is conditional"
# CI lints with the pinned ShellCheck, checked against its published digest, never with the
# version the runner image ships.
assert_eq 1 "$(grep -cxF '          v=v0.11.0' "$CIWF" || true)" "CI installs ShellCheck 0.11.0"
assert_eq 1 "$(grep -cxF '          sum=8c3be12b05d5c177a04c29e3c78ce89ac86f1595681cab149b65b97c4e227198' "$CIWF" || true)" "pinned to its sha256"
assert_eq 1 "$(grep -cF 'sha256sum -c -' "$CIWF" || true)" "and verifies the download"
assert_eq 1 "$(grep -cxF "          shellcheck --version | grep -qx 'version: 0.11.0'" "$CIWF" || true)" "and lints only with that version"

it "every workflow pins its actions and holds no write scope outside the release job"
for f in "$PK_ROOT"/.github/workflows/*.yml; do
    n="${f##*/}"
    assert_eq "" "$(grep -nE 'uses:' "$f" | grep -vE '@[0-9a-f]{40} # v[0-9]+(\.[0-9]+)*$' || true)" "$n: actions pinned by full SHA, with a version comment"
    assert_eq "" "$(grep -n 'pull_request_target' "$f" || true)" "$n: no pull_request_target"
    assert_eq "" "$(grep -nE '^[^#]*(write-all|read-all)' "$f" || true)" "$n: no write-all or read-all"
    assert_eq "" "$(grep -n 'continue-on-error' "$f" || true)" "$n: no continue-on-error"
    writes="$(awk -v n="$n" '/^[ \t]*#/ { next }
        /^jobs:/ { injobs = 1; job = ""; next }
        injobs && /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:.*/, "", job) }
        /:[ \t]*write([^-A-Za-z0-9_]|$)/ && !(n == "release.yml" && job == "release") { print NR ": " $0 }' "$f")"
    assert_eq "" "$writes" "$n: no write scope (only release.yml's release job writes)"
done
others=""
for f in "$PK_ROOT"/.github/workflows/* "$PK_ROOT"/.github/workflows/.[!.]*; do
    case "$f" in *.yml|*'/.[!.]*') ;; *) others="$others ${f##*/}" ;; esac
done
assert_eq "" "$others" "every workflow file is a .yml that the loop covers"

# --- GitHub side against a fake gh -------------------------------------------------------------
if ! command -v jq >/dev/null 2>&1; then
    echo "  skip: jq not installed; the fake gh needs it to apply --jq filters"
    finish
fi

GHREPO="$(new_repo)"; track_tmp "$GHREPO"
release "$GHREPO" 0.1.0 '## [0.1.0] — 2026-01-01 — first release' '- initial'
G1="$(commit "$GHREPO" one)"
git -C "$GHREPO" tag -a v0.1.0 -m 'v0.1.0 — first release' "$G1"
release "$GHREPO" 0.2.0 '## [0.2.0] — 2026-02-01 — second release' '- change'
R="$(commit "$GHREPO" two)"
printf 'docs\n' > "$GHREPO/README.md"
D="$(commit "$GHREPO" docs)"
release "$GHREPO" 0.3.0 '## [0.3.0] — 2026-03-01 — third release' '- newer change'
R3="$(commit "$GHREPO" three)"
release "$GHREPO" 0.3.1 '## [0.3.1] — 2026-03-02' '- heading without subtitle'
R5="$(commit "$GHREPO" four)"

BIN="$(mktemp -d)"; track_tmp "$BIN"
cat > "$BIN/gh" <<'GH'
#!/usr/bin/env bash
# Fake gh: canned GitHub state under $FAKE_GH; every call is appended to $FAKE_GH/calls.log.
set -u
S="$FAKE_GH"
printf '%s\n' "$*" >> "$S/calls.log"
notfound() { printf '{"message":"Not Found"}\n'; echo 'gh: Not Found (HTTP 404)' >&2; exit 1; }
out() { # JSON → stdout through the --jq filter, as gh applies it
    if [ -n "$jq" ]; then printf '%s\n' "$1" | jq -r "$jq"; else printf '%s\n' "$1"; fi
}
field() { awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }' "$S/req.fields"; }
if [ "$1" = release ] && [ "$2" = create ]; then
    tag="$3"; shift 3
    printf '%s\n' "$@" > "$S/release-create.args"
    while [ $# -gt 0 ]; do
        case "$1" in --notes-file) cp "$2" "$S/release-notes.md"; shift ;; esac
        shift
    done
    if [ -e "$S/fail-release-create" ]; then echo 'gh: release create failed' >&2; exit 1; fi
    printf '{"id": 9}\n' > "$S/releases/$tag"
    echo "https://github.com/acme/kit/releases/tag/$tag"
    exit 0
fi
[ "$1" = api ] || { echo "fake gh: unsupported $*" >&2; exit 64; }
shift
method=GET; jq=""; path=""; : > "$S/req.fields"
while [ $# -gt 0 ]; do
    case "$1" in
        -X) method="$2"; shift ;;
        --jq) jq="$2"; shift ;;
        -f) printf '%s\n' "$2" >> "$S/req.fields"; shift ;;
        *) path="$1" ;;
    esac
    shift
done
path="${path#repos/acme/kit/}"
case "$method $path" in
    "GET actions/runs/"*)
        f="$S/runs/${path#actions/runs/}.json"; [ -f "$f" ] || notfound; out "$(cat "$f")" ;;
    "GET actions/workflows/ci.yml/runs?"*)
        printf '%s\n' "$path" > "$S/runs-query"; out "$(cat "$S/runs-list.json")" ;;
    "GET commits/"*"/pulls")
        out "$(cat "$S/pulls.json")" ;;
    "GET git/ref/tags/"*)
        f="$S/refs/${path#git/ref/tags/}"; [ -f "$f" ] || notfound; out "$(cat "$f")" ;;
    "GET git/tags/"*)
        f="$S/tagobjs/${path#git/tags/}.json"; [ -f "$f" ] || notfound; out "$(cat "$f")" ;;
    "GET releases/tags/"*)
        if [ -e "$S/releases-500" ]; then echo 'gh: Server Error (HTTP 500)' >&2; exit 1; fi
        f="$S/releases/${path#releases/tags/}"; [ -f "$f" ] || notfound; out "$(cat "$f")" ;;
    "POST git/tags")
        cp "$S/req.fields" "$S/tag-request"
        obj="ab$(printf '%038d' "$(wc -l < "$S/calls.log" | tr -d ' ')")"
        printf '{"sha":"%s","object":{"type":"commit","sha":"%s"}}\n' "$obj" "$(field object)" > "$S/tagobjs/$obj.json"
        out "{\"sha\":\"$obj\"}" ;;
    "POST git/refs")
        cp "$S/req.fields" "$S/ref-request"
        tag="$(field ref)"; tag="${tag#refs/tags/}"
        if [ -f "$S/race-ref" ]; then cp "$S/race-ref" "$S/refs/$tag"; fi
        if [ -f "$S/refs/$tag" ]; then echo 'gh: Reference already exists (HTTP 422)' >&2; exit 1; fi
        printf '{"object":{"type":"tag","sha":"%s"}}\n' "$(field sha)" > "$S/refs/$tag"
        out "{\"ref\":\"refs/tags/$tag\"}" ;;
    *) echo "fake gh: unexpected $method $path" >&2; exit 65 ;;
esac
GH
chmod +x "$BIN/gh"

# run_json STATE ID SHA EVENT BRANCH CONCLUSION WORKFLOW_PATH [STATUS] [REPOSITORY]
#          [HEAD_REPOSITORY] [HTML_URL]: one canned CI run (defaults: completed, acme/kit twice,
#          the run's own URL).
run_json() {
    printf '{"id":%s,"path":"%s","event":"%s","head_branch":"%s","head_sha":"%s","status":"%s","conclusion":"%s","html_url":"%s","repository":{"full_name":"%s"},"head_repository":{"full_name":"%s"}}\n' \
        "$2" "$7" "$4" "$5" "$3" "${8:-completed}" "$6" "${11:-https://github.com/acme/kit/actions/runs/$2}" \
        "${9:-acme/kit}" "${10:-acme/kit}" > "$1/runs/$2.json"
}
# new_state → fresh fake GitHub state: green CI runs 101 (R) and 106 (D); PR 7 merged R into
# main, listed after decoys a correct filter must skip (wrong base, other merge commit, unmerged).
new_state() {
    local s; s="$(mktemp -d)" || return 1
    [ -n "$s" ] && [ -d "$s" ] || return 1
    mkdir -p "$s/runs" "$s/refs" "$s/tagobjs" "$s/releases"
    : > "$s/calls.log"
    run_json "$s" 101 "$R" push main success .github/workflows/ci.yml
    run_json "$s" 106 "$D" push main success .github/workflows/ci.yml
    printf '{"workflow_runs":[{"id":101}]}\n' > "$s/runs-list.json"
    printf '[%s,%s,%s,%s]\n' \
        "{\"html_url\":\"https://github.com/acme/kit/pull/4\",\"merged_at\":\"2026-02-01T00:00:00Z\",\"base\":{\"ref\":\"release\"},\"merge_commit_sha\":\"$R\"}" \
        "{\"html_url\":\"https://github.com/acme/kit/pull/5\",\"merged_at\":\"2026-02-01T00:00:00Z\",\"base\":{\"ref\":\"main\"},\"merge_commit_sha\":\"$D\"}" \
        "{\"html_url\":\"https://github.com/acme/kit/pull/6\",\"merged_at\":null,\"base\":{\"ref\":\"main\"},\"merge_commit_sha\":\"$R\"}" \
        "{\"html_url\":\"https://github.com/acme/kit/pull/7\",\"merged_at\":\"2026-02-01T00:00:00Z\",\"base\":{\"ref\":\"main\"},\"merge_commit_sha\":\"$R\"}" \
        > "$s/pulls.json"
    echo "$s"
}
gh_run() { # STATE ARGS... → release-github.sh inside the fixture with the fake gh first on PATH
    local s="$1"; shift
    # shellcheck disable=SC2016 # the inner shell expands its own positional parameters
    run env PATH="$BIN:$PATH" FAKE_GH="$s" GH_REPO=acme/kit GITHUB_STEP_SUMMARY="$s/summary.md" \
        bash -c 'cd "$1" && shift && bash "$@"' _ "$GHREPO" "$GHS" "$@" --main-ref main
}
writes() { grep -c -e '-X POST' -e '^release create' "$1/calls.log" || true; }
creates() { grep -c '^release create' "$1/calls.log" || true; }
CI101=https://github.com/acme/kit/actions/runs/101
RUN900=https://github.com/acme/kit/actions/runs/900

it "gate verifies the gating CI run and finds the merged pull request"
ST="$(new_state)"; track_tmp "$ST"
gh_run "$ST" gate --sha "$R" --ci-run-id 101
assert_eq 0 "$STATUS" "gate passes"
assert_eq create "$(val action)" "a new release is planned"
assert_eq "$CI101" "$(val ci_run_url)" "CI run URL"
assert_eq https://github.com/acme/kit/pull/7 "$(val pr_url)" "merged into main as exactly R, not a decoy"
assert_eq 0 "$(writes "$ST")" "gate makes no writes"
assert_contains "$(cat "$ST/summary.md")" "Release gate: create" "job summary written"

it "gate and publish refuse CI runs that do not gate exactly this push to main"
run_json "$ST" 102 "$D" push main success .github/workflows/ci.yml
run_json "$ST" 103 "$R" pull_request main success .github/workflows/ci.yml
run_json "$ST" 104 "$R" push main failure .github/workflows/ci.yml
run_json "$ST" 105 "$R" push main success .github/workflows/other.yml
run_json "$ST" 107 "$R" push feature success .github/workflows/ci.yml
run_json "$ST" 108 "$R" push main success .github/workflows/ci.yml completed acme/kit fork/kit
run_json "$ST" 109 "$R" push main success .github/workflows/ci.yml completed other/kit acme/kit
run_json "$ST" 111 "$R" push main success .github/workflows/ci.yml in_progress
run_json "$ST" 114 "$R" push main success .github/workflows/ci-macos.yml
for id in 102 103 104 105 107 108 109 111 114; do
    gh_run "$ST" gate --sha "$R" --ci-run-id "$id"
    assert_eq 1 "$STATUS" "gate refuses CI run $id"
    assert_contains "$OUTPUT" "does not gate this release" "CI run $id refusal explained"
    gh_run "$ST" publish --sha "$R" --ci-run-id "$id"
    assert_eq 1 "$STATUS" "publish re-verifies and refuses CI run $id"
done
run_json "$ST" 110 "$R" push main success .github/workflows/ci.yml completed acme/kit acme/kit \
    https://github.com/acme/kit/actions/runs/999
gh_run "$ST" gate --sha "$R" --ci-run-id 110
assert_eq 1 "$STATUS" "a run URL that is not this run is refused"
assert_contains "$OUTPUT" "unexpected CI run URL" "URL refusal explained"
gh_run "$ST" gate --sha "$(printf '%s' "$R" | cut -c1-12)" --ci-run-id 101
assert_eq 2 "$STATUS" "abbreviated SHA refused on the GitHub side"
run env PATH="$BIN:$PATH" FAKE_GH="$ST" GH_REPO= bash "$GHS" gate --sha "$R"
assert_eq 2 "$STATUS" "GH_REPO required"
assert_eq 0 "$(writes "$ST")" "refusals make no writes"

it "recovery dispatch without a run id finds a successful CI push run for the SHA"
gh_run "$ST" gate --sha "$R"
assert_eq 0 "$STATUS" "dispatch gate passes"
assert_eq create "$(val action)" "release planned"
assert_contains "$(cat "$ST/runs-query")" "head_sha=$R&event=push&branch=main&status=success" "query pins SHA, event, branch and success"
printf '{"workflow_runs":[]}\n' > "$ST/runs-list.json"
gh_run "$ST" gate --sha "$R"
assert_eq 1 "$STATUS" "no successful CI run: refused"
assert_contains "$OUTPUT" "CI must pass on main" "refusal explained"
gh_run "$ST" publish --sha "$R"
assert_eq 1 "$STATUS" "publish refuses without a successful CI run too"
assert_eq 0 "$(writes "$ST")" "no writes"
printf '{"workflow_runs":[{"id":101}]}\n' > "$ST/runs-list.json"

it "gate plans nothing for a merge without a VERSION bump"
gh_run "$ST" gate --sha "$D" --ci-run-id 106
assert_eq 0 "$STATUS" "gate passes"
assert_eq none "$(val action)" "nothing to release"

it "publish verifies CI itself, then tags exactly the SHA and creates the release"
gh_run "$ST" publish --sha "$R" --ci-run-id 101 --release-run-url "$RUN900"
assert_eq 0 "$STATUS" "publish succeeds"
tagreq="$(cat "$ST/tag-request")"
assert_contains "$tagreq" "tag=v0.2.0" "tag name"
assert_contains "$tagreq" "object=$R" "tag object targets the gating SHA"
assert_contains "$tagreq" "type=commit" "commit target"
assert_contains "$tagreq" "message=Product Kit - v0.2.0" "tag message is the title"
assert_contains "$tagreq" "tagger[name]=github-actions[bot]" "tagger is github-actions"
assert_contains "$(cat "$ST/ref-request")" "ref=refs/tags/v0.2.0" "tag ref created"
args="$(cat "$ST/release-create.args")"
assert_contains "$args" "--verify-tag" "release requires the existing tag"
assert_contains "$args" "Product Kit - v0.2.0" "release title"
assert_contains "$args" "--latest=true" "marked latest"
expected="## [0.2.0] — 2026-02-01 — second release

- change

### Verification

- Merged commit: \`$R\`
- Gating CI run (push to main): $CI101
- Release PR: https://github.com/acme/kit/pull/7
- Tagged and published by: $RUN900"
assert_eq "$expected" "$(cat "$ST/release-notes.md")" "notes carry the verified run and PR"
gh_run "$ST" publish --sha "$R" --ci-run-url https://evil.example/x
assert_eq 2 "$STATUS" "publish takes no caller-supplied CI or PR URL"
gh_run "$ST" gate --sha "$R" --ci-run-id 101 --release-run-url "$RUN900"
assert_eq 2 "$STATUS" "the release run URL applies to publish only"
assert_contains "$OUTPUT" "applies to publish only" "usage error explained"

it "re-running after a release is a no-op"
before="$(writes "$ST")"
gh_run "$ST" publish --sha "$R" --ci-run-id 101
assert_eq 0 "$STATUS" "re-run succeeds"
assert_eq "$before" "$(writes "$ST")" "no new writes"
assert_contains "$OUTPUT" "already exists" "says why"
gh_run "$ST" gate --sha "$R" --ci-run-id 101
assert_eq none "$(val action)" "gate sees tag and release"

it "a remote tag on the SHA without its release gets only the release"
ST2="$(new_state)"; track_tmp "$ST2"
cp "$ST/refs/v0.2.0" "$ST2/refs/v0.2.0"
cp "$ST"/tagobjs/*.json "$ST2/tagobjs/"
gh_run "$ST2" gate --sha "$R" --ci-run-id 101
assert_eq release-only "$(val action)" "gate asks for the release only"
gh_run "$ST2" publish --sha "$R" --ci-run-id 101
assert_eq 0 "$STATUS" "publish succeeds"
assert_eq 0 "$(grep -c -e '-X POST' "$ST2/calls.log" || true)" "no tag or ref writes"
assert_file "$ST2/release-create.args" "release created"

it "a fetched tag on the SHA without its release also gets only the release"
git -C "$GHREPO" tag -a v0.2.0 -m 'v0.2.0 — second release' "$R"
ST3="$(new_state)"; track_tmp "$ST3"
cp "$ST/refs/v0.2.0" "$ST3/refs/v0.2.0"
cp "$ST"/tagobjs/*.json "$ST3/tagobjs/"
gh_run "$ST3" gate --sha "$R" --ci-run-id 101
assert_eq release-only "$(val action)" "plan skip plus ensure_release becomes release-only"
gh_run "$ST3" publish --sha "$R" --ci-run-id 101
assert_eq 0 "$STATUS" "publish succeeds"
assert_eq 0 "$(grep -c -e '-X POST' "$ST3/calls.log" || true)" "no tag or ref writes"
assert_contains "$(cat "$ST3/release-notes.md")" "## [0.2.0] — 2026-02-01 — second release" "notes from the section"
ST4="$(new_state)"; track_tmp "$ST4"
gh_run "$ST4" publish --sha "$R"
assert_eq 1 "$STATUS" "a tag missing on the remote is not recreated from the local copy"
assert_eq 0 "$(writes "$ST4")" "no writes"
git -C "$GHREPO" tag -d v0.2.0 >/dev/null

it "a release commit whose fetched tag points elsewhere fails without writes"
git -C "$GHREPO" tag v0.2.0 "$D"
ST9="$(new_state)"; track_tmp "$ST9"
gh_run "$ST9" gate --sha "$R" --ci-run-id 101
assert_eq 1 "$STATUS" "gate fails loudly"
assert_contains "$OUTPUT" "release a new version instead" "gate explains"
gh_run "$ST9" publish --sha "$R" --ci-run-id 101
assert_eq 1 "$STATUS" "publish refuses"
assert_contains "$OUTPUT" "tags are never moved" "publish explains"
assert_eq 0 "$(writes "$ST9")" "no writes"
git -C "$GHREPO" tag -d v0.2.0 >/dev/null

it "a remote tag elsewhere is never moved"
ST5="$(new_state)"; track_tmp "$ST5"
printf '{"object":{"type":"commit","sha":"%s"}}\n' "$D" > "$ST5/refs/v0.2.0"
gh_run "$ST5" gate --sha "$R" --ci-run-id 101
assert_eq 1 "$STATUS" "gate fails loudly"
assert_contains "$OUTPUT" "never moved" "gate explains"
gh_run "$ST5" publish --sha "$R"
assert_eq 1 "$STATUS" "publish refuses"
assert_eq 0 "$(writes "$ST5")" "no writes"

it "a release overtaken by a newer one fails loudly and needs an explicit backfill"
# Release merges R (0.2.0) and R3 (0.3.0) land back to back; R3's CI and release finish first.
ST10="$(new_state)"; track_tmp "$ST10"
run_json "$ST10" 112 "$R3" push main success .github/workflows/ci.yml
gh_run "$ST10" gate --sha "$R" --ci-run-id 101
assert_eq create "$(val action)" "before the newer release exists, the older one is planned"
gh_run "$ST10" publish --sha "$R3" --ci-run-id 112 --release-run-url "$RUN900"
assert_eq 0 "$STATUS" "the newer release publishes first"
assert_contains "$(cat "$ST10/release-create.args")" "--latest=true" "the newer release is latest"
git -C "$GHREPO" tag -a v0.3.0 -m 'v0.3.0 — third release' "$R3" # what the next checkout fetches
before="$(writes "$ST10")"
recovery="gh workflow run release.yml -f sha=$R -f allow_backfill=true"
gh_run "$ST10" publish --sha "$R" --ci-run-id 101 --release-run-url "$RUN900"
assert_eq 1 "$STATUS" "the older release job, already gated as create, fails instead of skipping"
assert_contains "$OUTPUT" "$R bumps VERSION to 0.2.0 but VERSION 0.2.0 is older than the latest release v0.3.0" "publish explains"
assert_contains "$OUTPUT" "$recovery" "publish names the recovery"
gh_run "$ST10" gate --sha "$R" --ci-run-id 101
assert_eq 1 "$STATUS" "a later gate or re-run for the older release fails too"
assert_contains "$OUTPUT" "$recovery" "gate names the recovery"
assert_contains "$(cat "$ST10/summary.md")" "Release gate: failed" "the job summary shows the failure"
gh_run "$ST10" gate --sha "$R"
assert_eq 1 "$STATUS" "a plain dispatch fails the same way"
assert_eq "$before" "$(writes "$ST10")" "refusals make no writes"
gh_run "$ST10" gate --sha "$D" --ci-run-id 106
assert_eq 0 "$STATUS" "a merge without a bump stays a green skip"
assert_eq none "$(val action)" "nothing to release"
gh_run "$ST10" gate --sha "$R" --ci-run-id 101 --allow-backfill
assert_eq 0 "$STATUS" "explicit backfill passes the gate"
assert_eq create "$(val action)" "explicit backfill is planned"
gh_run "$ST10" publish --sha "$R" --ci-run-id 101 --allow-backfill
assert_eq 0 "$STATUS" "explicit backfill publishes"
assert_contains "$(cat "$ST10/tag-request")" "object=$R" "the backfill tags the older commit"
assert_contains "$(cat "$ST10/release-create.args")" "--latest=false" "a backfill is not marked latest"
git -C "$GHREPO" tag -d v0.3.0 >/dev/null

it "a tagged release whose publication failed and that a newer release overtook fails loudly"
# R's release job tags v0.2.0, then gh release create fails; R3's release lands before R is re-run.
ST12="$(new_state)"; track_tmp "$ST12"
run_json "$ST12" 112 "$R3" push main success .github/workflows/ci.yml
: > "$ST12/fail-release-create"
gh_run "$ST12" publish --sha "$R" --ci-run-id 101 --release-run-url "$RUN900"
assert_eq 1 "$STATUS" "the failed publication fails the run"
assert_file "$ST12/refs/v0.2.0" "but its tag was created"
mv "$ST12/fail-release-create" "$ST12/fail-release-create.off"
git -C "$GHREPO" tag -a v0.2.0 -m 'v0.2.0 — second release' "$R" # fetched by later checkouts
gh_run "$ST12" publish --sha "$R3" --ci-run-id 112 --release-run-url "$RUN900"
assert_eq 0 "$STATUS" "the newer release lands"
git -C "$GHREPO" tag -a v0.3.0 -m 'v0.3.0 — third release' "$R3"
before="$(writes "$ST12")"
gh_run "$ST12" publish --sha "$R" --ci-run-id 101 --release-run-url "$RUN900"
assert_eq 1 "$STATUS" "re-running the failed release job fails instead of passing green"
assert_contains "$OUTPUT" "$R is tagged v0.2.0 but its GitHub release is missing" "publish explains"
assert_contains "$OUTPUT" "$recovery" "publish names the recovery"
gh_run "$ST12" gate --sha "$R" --ci-run-id 101
assert_eq 1 "$STATUS" "re-running the whole run, or its CI, fails too"
assert_contains "$OUTPUT" "$recovery" "gate names the recovery"
assert_contains "$(cat "$ST12/summary.md")" "Release gate: failed" "the job summary shows the failure"
assert_eq "$before" "$(writes "$ST12")" "refusals make no writes"
gh_run "$ST12" gate --sha "$R" --ci-run-id 101 --allow-backfill
assert_eq release-only "$(val action)" "explicit backfill completes only the release"
posts="$(grep -c -e '-X POST' "$ST12/calls.log" || true)"
gh_run "$ST12" publish --sha "$R" --ci-run-id 101 --allow-backfill
assert_eq 0 "$STATUS" "the release is created"
assert_eq "$posts" "$(grep -c -e '-X POST' "$ST12/calls.log" || true)" "no tag or ref writes"
assert_contains "$(cat "$ST12/release-create.args")" "--latest=false" "and not marked latest"
gh_run "$ST12" gate --sha "$R" --ci-run-id 101
assert_eq 0 "$STATUS" "with its release present, the older tagged commit is a green skip"
assert_eq none "$(val action)" "nothing to do"
gh_run "$ST12" publish --sha "$R" --ci-run-id 101
assert_eq 0 "$STATUS" "its release job is green too"
git -C "$GHREPO" tag -d v0.2.0 v0.3.0 >/dev/null

it "an older tag whose section cannot make release notes stays a green skip"
ST14="$(new_state)"; track_tmp "$ST14"
run_json "$ST14" 113 "$R5" push main success .github/workflows/ci.yml
git -C "$GHREPO" tag -a v0.3.1 -m 'v0.3.1' "$R5"
git -C "$GHREPO" tag v0.9.0 "$G1"
printf '{"object":{"type":"commit","sha":"%s"}}\n' "$R5" > "$ST14/refs/v0.3.1"
gh_run "$ST14" gate --sha "$R5" --ci-run-id 113
assert_eq 0 "$STATUS" "no allow_backfill demand when a backfill could not release it either"
assert_eq none "$(val action)" "nothing to release"
assert_contains "$OUTPUT" "section=invalid" "the plan reports the invalid section"
git -C "$GHREPO" tag -d v0.3.1 v0.9.0 >/dev/null

it "a concurrent tag creation is accepted only when it marks the same SHA"
ST6="$(new_state)"; track_tmp "$ST6"
printf '{"object":{"type":"commit","sha":"%s"}}\n' "$R" > "$ST6/race-ref"
gh_run "$ST6" publish --sha "$R"
assert_eq 0 "$STATUS" "race to the same SHA continues"
assert_contains "$OUTPUT" "created concurrently" "race reported"
assert_file "$ST6/release-create.args" "release created after the race"
ST7="$(new_state)"; track_tmp "$ST7"
printf '{"object":{"type":"commit","sha":"%s"}}\n' "$D" > "$ST7/race-ref"
gh_run "$ST7" publish --sha "$R"
assert_eq 1 "$STATUS" "race to another SHA fails"
if [ -e "$ST7/release-create.args" ]; then _no "no release after a lost race"; else _ok "no release after a lost race"; fi

it "release lookups and creation fail closed"
ST8="$(new_state)"; track_tmp "$ST8"
: > "$ST8/fail-release-create"
gh_run "$ST8" publish --sha "$R"
assert_eq 1 "$STATUS" "a failed creation fails the run"
assert_contains "$OUTPUT" "could not create release v0.2.0" "failure explained"
ST11="$(new_state)"; track_tmp "$ST11"
: > "$ST11/releases-500"
gh_run "$ST11" publish --sha "$R" --ci-run-id 101
assert_eq 1 "$STATUS" "a server error reading the release is not 'missing'"
assert_contains "$OUTPUT" "could not read the release for v0.2.0" "error explained"
assert_eq 0 "$(creates "$ST11")" "no release created on a lookup error"

finish
