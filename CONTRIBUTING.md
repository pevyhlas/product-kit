# Contributing to Product-Kit

Product-Kit is experimental and has one maintainer. Issues and draft pull requests are welcome;
the maintainer reviews them as time allows and is the only person who merges.

The Markdown commands/workflows/templates and portable Bash helpers are the product.
Start significant changes with a product outcome and a bounded change. Keep public entry
points small, operational contracts explicit, and examples generic.

## Before you start

- **Open an issue first** for anything beyond a small fix such as a typo, a broken link or an
  obvious one-line bug. Use the bug report or proposal template, and agree on the problem and
  the smallest useful change before you build it.
- **Never report a vulnerability in an issue or pull request.** Report it privately as
  [SECURITY.md](SECURITY.md) describes.
- Everyone taking part follows the [code of conduct](CODE_OF_CONDUCT.md).

## Pull requests

- **Open the pull request as a draft** and link its issue. Mark it ready for review when CI
  passes and you consider it done. Only the maintainer merges, and may close a pull request that
  does not fit the kit's direction, with a reason.
- **One concern per pull request.** Don't stack unrelated work onto an open branch.
- Note user-visible changes under `## [Unreleased]` in [CHANGELOG.md](CHANGELOG.md). Leave
  `VERSION` alone: the maintainer decides when a change is released, and as which version
  (see Releases).
- No secrets, private paths or private project data in code, docs, examples or tests.
- [CLAUDE.md](CLAUDE.md) carries the same guidance for Claude Code. You are responsible for an
  agent-written contribution as for any other.

## Sources of truth

- `commands/`: eight public entry points, indexed in README and docs/commands.md.
- `workflows/`: agent protocol, spec and change contracts, and operational behavior.
- `templates/`: project-owned spec, change and policy scaffolds installed into consumers.
- `scripts/`: deterministic helpers and the installer mapping. `scripts/maintainer/` holds
  kit-only tooling (releases) that the installer never ships to consumers.

The kit's own development records are kept privately and are not part of this repository.

Rules the tests enforce:

- **Stay generic.** No project-, product- or stack-specific vocabulary or hard-coded build
  commands in `commands/`, `workflows/` or `templates/`; they defer to the consumer's
  constitution (`.prdkit/memory/constitution.md`).
- **Consumer paths vs. repo paths.** Command files and workflows reference installed paths
  (`.prdkit/scripts/bash/…`, `.prdkit/templates/…`, `.prdkit/workflows/…`). `scripts/init.sh`
  maps this repository's files to them; keep it in sync when you add a file.
- **Adding or renaming a command** touches `commands/`, `docs/commands.md`, the README command
  table, the `EXPECTED` list in `tests/test_generalization.sh` and `CHANGELOG.md`.

Update affected installation mappings, catalog/wiring tests, examples, and changelog together.
Prefer behavioral assertions over tests that merely require a sentence to appear in a prompt.
Preserve license and upstream attribution.

## Validation

```bash
bash tests/run.sh
git diff --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD
find scripts tests -name '*.sh' -print0 | xargs -0 shellcheck --exclude=SC1091
```

The suite needs Bash, Git, standard utilities, and jq 1.6+ for enrichment tests; core helpers do
not need jq. CI lints with ShellCheck 0.11.0, so use that version locally. Helpers that run on
macOS stay portable to its `/bin/bash` 3.2 and BSD userland. Run relevant real-agent scenarios
locally for behavioral changes, recording driver/version and limitations. Mock-driver success
only establishes evaluation plumbing. See [test docs](tests/README.md).

**CI and the merge rule.** `CI` ([`ci.yml`](.github/workflows/ci.yml)) runs these three
commands on a GitHub-hosted Ubuntu 24.04 runner for every pull request and every push to main.
It also runs adoption-gate and doctor coverage with checksum-pinned legacy mawk (1.3.4 20200120);
newer mawk releases support intervals and would not exercise that compatibility boundary.
`CI (macOS)` ([`ci-macos.yml`](.github/workflows/ci-macos.yml)) runs the portable suites with
macOS's native Bash 3.2 and BSD userland, for every pull request and push to main and on demand.
Both must pass before a merge. Only `CI` decides releases: `CI (macOS)` neither triggers nor
gates one. Pull-request runs get a read-only token and no secrets, and a run from an outside
contributor waits for the maintainer's approval.

## License

Product-Kit is released under the [MIT License](LICENSE). By contributing, you agree that your
contribution is licensed under the same license (inbound = outbound). Keep LICENSE the plain MIT
text, and the upstream Spec Kit notice in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) intact.

## Releases

Releases are automatic and come only from main. The maintainer makes the release pull request;
merging one that bumps `VERSION` is the release decision. Do not create release tags or GitHub
releases by hand.

1. The release PR bumps `VERSION` and adds the matching section directly below
   `## [Unreleased]`, headed `## [X.Y.Z] — YYYY-MM-DD — subtitle`. That section becomes the
   release body, so consumer adoption notes belong in it (for example under `### Adoption`).
   `tests/test_version.sh` and `tests/test_release.sh` fail the PR when VERSION, section and
   heading disagree. Merge it as its own push to main: only the commit CI ran for is evaluated.
2. `CI` runs for the push to main (`ci.yml`; `CI (macOS)` neither triggers nor
   gates a release). When that run succeeds,
   [`.github/workflows/release.yml`](.github/workflows/release.yml) evaluates exactly the
   commit CI verified, never whatever main points at by then. If that commit changed `VERSION`
   against its first parent and tag `vX.Y.Z` does not exist, the workflow creates the annotated
   tag `vX.Y.Z` on that commit, with message `Product Kit - vX.Y.Z`, and a GitHub release with
   the same title. The body is the CHANGELOG section plus a generated Verification block: merged
   commit, gating CI run, release PR and publishing run. The release is marked latest only if
   it is the highest semver tag.
3. Any other push to main (docs, CI, a fix without a version bump) releases nothing. An
   existing tag is never moved or recreated. A release commit whose tag already points
   elsewhere fails the workflow; release a new version instead. A release commit whose version
   is lower than the newest `vX.Y.Z` tag is a backfill, which happens when a newer release
   overtakes it (for example, two release merges whose CI finishes out of order). The workflow
   then fails, instead of skipping, for an older release commit whose CHANGELOG section can make
   release notes and that is either untagged or tagged without its GitHub release (for example,
   its publication failed and a newer release landed before the re-run). The error names the
   only way to release it: a dispatch with `allow_backfill` (see Recovery). An older tagged
   commit stays green when its release exists or its section cannot make notes. A backfill is
   never marked latest.

The tagger and release author are `github-actions[bot]`, not the owner.

**Jobs.** Both jobs run on fresh GitHub-hosted Ubuntu 24.04 runners. The `gate` job holds a
read-only token (contents, actions, pull-requests). It verifies the CI run, plans, and decides
whether the `release` job starts. The `release` job is the only one with `contents: write`. It
takes the SHA and CI run from the triggering event and re-verifies the CI run, pull request and
plan itself rather than trusting the gate. Neither job persists the token: there is no
`gh auth login` and no Git credential configuration, `GH_TOKEN` is set only in the two script
steps' environment, and the checkouts use `persist-credentials: false`.

`workflow_run` also fires when CI finishes for a pull request, forks included. GitHub always
runs `release.yml` from the default branch, and the gate starts only for a successful CI push
run on main in this repository, so pull-request code never reaches a job with a write token. A
dispatch needs write access and runs only main's copy.

**Recovery.** If CI on main failed or was blocked, re-run it (`gh run rerun <run-id>`); its
success triggers the release while that version is still the newest. Otherwise run the workflow
from main for one commit: `gh workflow run release.yml -f sha=<full merge SHA>` (add
`-f dry_run=true` to only report the decision). A dispatch first requires a successful CI push
run on main for that SHA. Re-running is safe: if the tag is on that SHA but the release is
missing, only the release is created (for a version older than the newest tag, only with
`allow_backfill`).

Once a newer `vX.Y.Z` tag exists, an older release commit that is untagged, or tagged without
its GitHub release, is released only by
`gh workflow run release.yml -f sha=<full merge SHA> -f allow_backfill=true`, and not as
latest. A CI re-run, a plain dispatch or a re-run of its release run fails with that
instruction when the commit's CHANGELOG section can make release notes; otherwise it stays
green. This also recovers a release job cancelled by the concurrency group: the group
keeps one pending job, so a third queued release cancels the pending one. That run shows
"cancelled" rather than failed; re-running it fails and names the dispatch, because the release
that ran instead is normally the newer version.

**Preview locally.** `bash scripts/maintainer/release-plan.sh --sha <sha>` prints the decision
and, with `--notes-file <path>`, the notes, from a clone with `origin/main` and tags fetched.
`release-github.sh` performs the GitHub side with `gh`.
