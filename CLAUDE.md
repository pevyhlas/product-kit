# Product-Kit — contributor guidance

Product-Kit is a spec-driven development toolkit: the `/prdkit-*` slash-command
definitions, markdown templates, and portable bash scripts that install
into consumer projects via `scripts/init.sh`. There is no application code here —
the docs, templates, and scripts *are* the product.

## Validate before any PR

```bash
bash tests/run.sh                                                  # full suite; jq 1.6+ for enrichment tests
git diff --check 4b825dc642cb6eb9a060e54bf8d69288fbee4904 HEAD      # no whitespace errors in any tracked file
find scripts tests -name '*.sh' -print0 | xargs -0 shellcheck --exclude=SC1091   # ShellCheck 0.11.0, as in CI
```

CI runs exactly these three on a GitHub-hosted Ubuntu 24.04 runner, with a pinned,
checksum-verified ShellCheck 0.11.0. CI also checks jq availability. Optional retrospective
enrichment requires jq; opt-in GitHub report verification requires gh and jq. Ledger-only
reports and offline review checks retain their Bash/standard-utilities contract.
Linux CI additionally runs the adoption-gate and doctor suites with checksum-pinned Debian 12
mawk (1.3.4 20200120), whose regex engine lacks interval-expression support.
Installer, upgrade, change, status, doctor, retrospective, adoption-gate and spool-adapter suites
also run on macOS (system bash 3.2 + BSD userland — keep those scripts portable) in the
separate `CI (macOS)` workflow, for every pull request and push to main. Both checks must pass
before a merge; only `CI` gates releases (CONTRIBUTING.md, "CI and the merge rule").

## Invariants the tests enforce (and how to not fight them)

- **`commands/` owns public entry points; `workflows/` owns agent operations.** Public
  wrappers reference the installed playbooks; human docs explain rather than duplicate rules.
- **Adding or renaming a command** touches all of: `commands/`, the index
  `docs/commands.md`, the README command table, the `EXPECTED` list in
  `tests/test_generalization.sh`, and `CHANGELOG.md`.
- **Stay generic.** No project-, game-, or stack-specific vocabulary or
  hardcoded build commands in `commands/`, `workflows/`, or `templates/` — they must defer to
  the consumer's constitution (`.prdkit/memory/constitution.md`).
- **Consumer paths vs. repo paths.** Command files reference installed paths
  (`.prdkit/scripts/bash/…`, `.prdkit/templates/…`, `.prdkit/workflows/…`).
  The mapping from this repo's `scripts/`, `templates/`, `commands/`, `workflows/` to those
  locations lives in `scripts/init.sh` — keep it in sync when adding files.

## Repo conventions

- Never push to `main` directly. Open an issue first for anything beyond a small fix, then a
  **draft** PR that links it; only the maintainer merges. CI runs the same validation commands
  above.
- One concern per branch/PR — don't stack unrelated work onto an open PR branch.
- Note user-visible changes under `## [Unreleased]` in `CHANGELOG.md` and leave `VERSION`
  alone; the maintainer cuts releases.
- Releases are automatic: after CI passes on `main` for a merged PR that bumps `VERSION` and
  adds its `## [X.Y.Z] — YYYY-MM-DD — subtitle` CHANGELOG section, `.github/workflows/release.yml`
  tags and releases that exact commit. Never tag or release by hand; recovery is in
  CONTRIBUTING.md ("Releases"). `scripts/maintainer/` is kit-only tooling init.sh never installs.
- Workflows run on GitHub-hosted runners only, with actions pinned by full commit SHA plus a
  version comment, least-privilege permissions and no `pull_request_target`
  (`tests/test_release.sh` enforces this).
- Vulnerabilities are reported privately (SECURITY.md), never in an issue or PR.
- Contributions are licensed under the repository's MIT License (inbound = outbound).
- No secrets or private operational details in docs, comments, or templates.
