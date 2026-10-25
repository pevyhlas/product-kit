# CI gates for consumer repositories

Three installed helpers give one-line, read-only CI steps in dependency-free Bash: the adoption
gate checks the installed kit against its recorded contract, the review check checks a change's
recorded review verdicts, and strict doctor checks the spec and agent context. None needs
network access or model credentials.

## Adoption gate — `check-adoption.sh`

```
bash .prdkit/scripts/bash/check-adoption.sh
```

Verifies the reviewed adoption contract on every PR:

- the tracked kit submodule commit matches the recorded `adoption-pin`;
- `.prdkit/.manifest` exists, its `version:` matches the kit source `VERSION`, and its
  hash matches the recorded `adoption-manifest-sha256`;
- each configured harness carries exactly the kit's public commands, as regular
  copies under `mode: copy` or resolving symlinks under `mode: symlink`;
- no kit-internal bootstrap leaked into the install.
- every manifest-listed file exists, and kit-owned command/workflow/helper content matches
  its recorded hash; project-owned templates and policy may be customized;
- selected AGENTS.md/Codex targets have one intact managed entry section, whose hash is
  recorded separately so consumer text outside it remains project-owned;
- the agent tier map has no banned ids, reasonless overrides, or literal ids beside a
  shared baseline, and its vendored snapshot matches its recorded provenance (sha256 and
  library commit: this catches hand edits and baseline mismatch, not upstream origin). Once the map
  declares a `Tier baseline:`, every agent projection must exist and match the resolved
  model/variant and neutral body (`render-agents.sh --check` is the same check, and also
  runs on legacy literal maps when invoked directly).

Record the expected values in the `## Configuration` section of
`.prdkit/memory/config.md` and move them together on every kit bump:

```
- adoption-pin: <full 40-hex kit commit>
- adoption-manifest-sha256: <sha256 of .prdkit/.manifest>
```

Unset keys skip their check (the gate then still validates the manifest and command
surface). The gate is manifest-driven: the pin is read from the tracked gitlink and the
expected surface from the manifest, so a `mode: copy` install passes CI with no submodule
checkout at all (a `mode: symlink` install still needs the source present for its links
to resolve). When the kit source is readable, its VERSION and shipped command set are
cross-checked as well. `--json` emits `{result, checks, findings}`.

## Review check — `check-review.sh`

```
bash .prdkit/scripts/bash/check-review.sh [--json] [--head <rev>] [--base <rev>] [<change-id>]
```

Reviews are run by the worker, never by CI: the worker dispatches the tier's independent
reviewers (`protocol.md`), posts each report on the PR and appends one `**Review**:` line per
verdict, with the commit hashes the review package printed, to the change record's State
(`change.md`). Before merging, the merging agent runs the check on the exact head it merges
(`--head <sha>`, then `gh pr merge --match-head-commit <sha>`). It passes when:

- every recorded verdict, in any tier, is PASS with no critical or high finding (no medium
  either under `Rigor: full`, or when the constitution names no Rigor); a reviewer's later
  line supersedes its earlier one;
- no blocking line stands: a blocking line (a FAIL, or counts that block for the Rigor or
  cannot be read) stands until a later non-blocking PASS from the same reviewer, over a
  non-empty range, reaches its head; only then does its range link. A blocking head that is not
  a commit hash always stands (correct that line to the printed hash);
- the reviews cover the change: every non-blocking PASS range, superseded rounds included, is a
  link, and so is a resolved blocking range; a point is covered when links chain from it (each
  starting at or before a head already reached) to a head after which only the record and
  `specs/log.md` changed. Each
  reviewer's head, a commit hash in the merged head's history, must be covered, and for T1–T3
  so must the change's start (its merge base with `--base`), so scoped re-reviews of fixes
  chain while a gap fails. No range may be empty; without a default branch pass `--base`; a
  head already inside `--base` fails;
- the tier's minimum is recorded: one independent verdict for T1–T3, plus the owner's for T3,
  and no L0 or L1 spec edit since the head the owner approved. Which concerns a T2 change
  needed is the worker's call; the check sees only what is recorded.

A closing commit that deletes the record is checked against the record's last committed
version. Finalize new implementation changes in their own PR, retaining context and evidence on
that PR before deleting the record; no cleanup-only PR is required. Auxiliary tracked plans are
ordinary reviewed paths: removing them after PASS invalidates coverage. Remove them before final
review, or use ignored execution scratch with useful context on the PR.

For compatibility, a pull request that carries only the record and the log since `--base` (default:
the first of `origin/HEAD`, `origin/main`, `origin/master`, `main`, `master`), including an old change's
explicit disposition, skips the coverage rules. Its start must
be on the default branch, or `--base` must name a remote-tracking branch other than the
change's own (such as `origin/develop`), so a commit or local branch inside the change's own
history cannot hide code. `--base` is otherwise taken as given: name the branch the pull request
merges into. Each range is trusted as recorded; a range starting at a commit no round reviewed
is not detected. The change id defaults to the current branch.

It checks recorded verdicts; it does not review, and it never grants merge authority. Where the
plan offers no branch protection, the merging agent's run is the gate. CI can run it as a
visible status, with the branch history fetched. It applies to change branches only: a branch
not named after a change has no record to check. Pin each action to a full commit SHA with its
version as a comment, as the kit's own workflows do.

```yaml
- uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1
  with: { fetch-depth: 0, ref: "${{ github.event.pull_request.head.sha }}" }
- name: Recorded review covers the head
  env:
    HEAD_REF: ${{ github.head_ref }}
    HEAD_SHA: ${{ github.event.pull_request.head.sha }}
    BASE_REF: ${{ github.base_ref }}
  run: |
    case "$HEAD_REF" in
      [0-9][0-9][0-9]-*) bash .prdkit/scripts/bash/check-review.sh --head "$HEAD_SHA" --base "origin/$BASE_REF" "$HEAD_REF" ;;
      *) echo "Not a change branch; no review record to check." ;;
    esac
```

It replaces the 0.x `check-signoff.sh`, but not one for one. The 0.x gate ran on every pull
request touching `gated-paths` and required a `readiness.md` with fingerprinted evidence; 1.0
drops that record, the fingerprint and `evidence-fingerprint.sh`, and checks change branches
against their own record. `init.sh --upgrade` warns while `signoff-requirements.md` still lists
`gated-paths:`; replace the CI step and fold the review policy into the constitution's `Review
and checks` at the cutover.

## Spec and context advisories — `doctor.sh --strict`

```
bash .prdkit/scripts/bash/doctor.sh --strict
```

Doctor always fails on malformed or duplicate IDs, malformed records, installation drift,
agent definition or tier-map findings, and a change record deleted in history without its
`specs/log.md` line (`check-review.sh` fails the same at close).
It reports, as advisories: a 0.x layout or two canons, a `specs/archive/` folder on main, a
`specs/archive.md` whose base commit or last 0.x feature cannot be read, agent context naming
removed 0.x paths, spec files over their reading budgets,
cited IDs that are undefined or retired (in spec files and tests), expired holds and waivers,
open inbox items and their age, inbox items in the old one-line form, local machine paths in
specs and agent context, links to missing files in the spec and `specs/archive.md`, spec files
that no chain of links from
`product.md` or `architecture.md` reaches (1.1 layout; retired files exempt) and `observed.md`
pieces it does not link, a lifecycle stage naming no environment that
`specs/architecture/environments.md` lists, raw evidence under `specs/`, a stale worktree
registration, and
agent context files (`CLAUDE.md`, `AGENTS.md`, ...) over `context-budget-bytes` (default
16384; 0 disables) in the `## Configuration` section of `.prdkit/memory/config.md`.
`--strict` promotes advisories to failing findings, which makes it an opt-in CI gate; `--json`
reports `{result, findings, advisories, strict, ...}`.
