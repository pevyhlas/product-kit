# Migrating to 2.0

2.0 reads verdicts from authenticated pull-request reviews, not `**Review**:` lines in a
record. **No 1.x PASS is converted into a receipt.** Open PRs need fresh reviews; historical
FAILs remain enforceable. The transition flag acknowledges this change, not a data conversion.
Pin the kit to `v2.0.0` for this transition; kit sources older than 2.0 reject the flag.

## 1. Merge policy first, under 1.x

In a separate policy PR, add these keys to `.prdkit/memory/config.md`, under
`## Configuration`, and merge them to the default branch:

```text
- review-host: github
- review-publishers: bot:1001
- review-owner: user:1003
- review-publisher-isolation: required
```

The ids above are examples: use your publisher's and owner's numeric GitHub account ids.
Publishers may be `bot:` or `user:` entries; owners must be `user:` entries. Comma-separated
lists are supported. Find an id with `gh api users/<login> --jq .id`, or
`gh api 'users/<slug>[bot]' --jq .id` for an App. Never list the shared
`github-actions[bot]` account: a branch can add a workflow using it.

`required` rejects a publisher that also authored the PR. It proves account separation, not
machine or reviewer independence. Prefer a reviewer-controlled App credential on a separate
host, OS account or CI job, or an independent human publisher. An owner-reviewed `shared`
setting permits the author as publisher, with a standing warning about that limitation.
Run publication from trusted kit scripts against a fetch-only clone; never execute candidate
scripts with the publisher credential. See [the review workflow](../workflows/review.md).
The publisher must be operational before the upgrade PR needs native receipts.

The default branch's constitution must also hold exactly one Rigor line, for example:

```text
- **Rigor**: full — medium blocks
```

Only `light` or `full`, followed by a space or the end of the line, is accepted. No line, two
lines, `light/full`, `full:`, `full,` and `fullx` are invalid. Change `full: medium blocks` to
`full — medium blocks`, and merge that fix in this policy PR, not the upgrade PR. The installer
uses the gate's unchanged Rigor parser and reads policy at the trusted default branch's tip,
never a branch-local proposed fix. 1.x ignores the new receipt policy keys.

## 2. Make an upgrade PR without changing records

Start a branch from the default branch. Fetch its complete history and establish
`origin/HEAD` beforehand. Select `v2.0.0` and commit its pin before running
the installer: a dirty source pin is still a dirty checkout.

```bash
# Read-only preview; jq is required. gh adds the open-PR portion.
bash .product-kit/scripts/init.sh --upgrade --migrate-reviews --dry-run
bash .product-kit/scripts/init.sh --upgrade --migrate-reviews --dry-run --json

# Print the report and install 2.0.
bash .product-kit/scripts/init.sh --upgrade --migrate-reviews
```

Preflight refuses before any target mutation unless:

- The target has a 1.x or 2.0 manifest and a clean Git status, including staged, unstaged and
  untracked files.
- Rigor and all four receipt policy keys are well formed at the trusted default tip.
- Every `specs/changes/` path at HEAD equals that tip; the upgrade branch carries no record edits.
- The full planned overwrite/delete set is safe. Ignored or committed customizations to commands,
  scripts, workflows or managed text are not permission to replace them. Reconcile them first.
  Project-owned customized templates and memory stay preserved; `--force` does not bypass this
  2.0 upgrade protection. Text outside the AGENTS managed section is preserved, including when
  `AGENTS.md` resolves to another root file inside the project.

The report reads default-branch records at the trusted tip, naming blockers by reviewer, raw
line number and reason, and counting PASS lines that stop counting. It lists open PRs targeting
trusted integration branches, their blockers and reviewers owing fresh reviews. Totals give
default-branch records with blockers, default-branch blockers per reviewer, open PRs and distinct
reviewers owed per PR. JSON uses schema `prdkit.review-transition.v1` with `policy_at`, `records`,
`open_prs`, `notes` and `totals`.

Missing `gh` or an unavailable API leaves an explicit note; the upgrade proceeds. PR heads and
their history must already be local: the report never fetches. A missing head/history is marked
`scan_available: false`, not presented as proof of no blockers. The report is informational:
blockers do not prevent installing. **Neither preview nor installation posts a review or edits
or creates a change record.** The upgrade diff contains kit installation files and the manifest,
not record changes. Review and gate the upgrade PR normally, under the scripts CI actually runs.

Plain `--upgrade` to 2.0 refuses while any trusted-tip or checkout record has active 1.x lines,
pointing to `--migrate-reviews`; it works without the flag when none exist. Plain upgrade also
requires a committed install, a clean checkout, a local trusted default ref and a safe set of
overwrite/delete destinations. Malformed Rigor is a warning on plain upgrade and `--check`, but a
migration prerequisite. `--migrate-reviews` without
`--upgrade`, or on a kit source older than 2.0, is usage error 2. `--json` requires `--dry-run`.

Before merging, remove calls to the retired execution ledger and retrospective and update
any log tooling to read both `specs/log/<id>.md` and `specs/log.md`. Select `--with agent-tiers`
if you want the renderer and aren't already using agent tiers. Move the adoption pin and
manifest hash together if your project records them. See the [release notes](../CHANGELOG.md)
for the full breaking-change checklist and the work deferred to 2.1.

### Interrupted installation

Keep the same source revision and `.prdkit/.install-state`, inspect `--check`, and rerun the
same command. The retained marker must name that source version. The installer renders expected
content in temporary storage and accepts dirty installer-owned paths only when the index still
equals HEAD and working-tree bytes, type and Git mode equal HEAD or the rendered result. AGENTS
text outside the managed section must still equal HEAD. Unrelated edits, staged work and edited
commands still refuse, and records must always be clean. The exception works with plain upgrade
too. A write lock left after an untrappable kill requires explicit inspection before removal;
there is no guessed-stale-lock cleanup or global rollback.

## 3. Merge the default branch into each open PR, then review afresh

After the upgrade merges, each open PR merges the default branch and obtains fresh native
receipts. Only `check-review.sh --pr <url>` can authorize merging, in every tier, T0 and
record-only included. It needs `gh`, `jq` and complete host reads. Offline or snapshot checks
are previews: a would-be pass exits 3, not 0. T3 needs the owner's latest valid native approval,
not an owner State line, relay or receipt. Native owner changes requests and dismissals block
before coverage exemptions; only the issuing owner can clear their barrier with a valid later
approval. Closing now needs `close-change.sh --pr <url>`. See [CI gates](ci-gates.md).

### What stops counting, and what remains enforced

- All 1.x PASS lines stop granting coverage, including owner lines. They may stay as historical
  text. Native coverage is PR-scoped: an earlier delivery's receipt cannot cover a new PR.
- A legacy FAIL, blocking counts or an unreadable verdict/count still blocks. The scan uses raw
  Git trees/blobs and complete branch history, not diff text. Deleting the line, moving or deleting
  its record, or transferring to a different carrier does not drop the blocker.
- That reviewer's clean native full PASS on this PR must include the blocker in its reviewed
  history. Another reviewer's PASS, a narrow review or a 1.x PASS cannot clear it. Owner and
  unnamed blockers require valid native owner approval with the same historical proof.
- Closing a merged-open record is not exempt. For genuinely empty content, the matching reviewer
  publishes a full PASS with `publish-review.sh --clears-legacy`; no artificial delta is needed
  and the receipt grants no coverage edge.

**Review cost:** a default-branch record holding a 1.x FAIL still requires its reviewer's native
full PASS on any PR changing or deleting that record, even if a later 1.x PASS cleared the FAIL
under 1.x. It continues until a qualifying PR removes the old line. Usually that reviewer already
owes the fresh full review. The transition report names each affected record and reviewer.
`init.sh --check` and `doctor.sh` list remaining blocker records; the scan stays through 2.x.

The transition is not an authentication shortcut. Standing receipts carry from closed, unmerged
PRs of the same branch; renaming that branch can escape carry. Rewriting pre-merge history can
erase a newly introduced legacy FAIL, but inherited default-branch lines stay protected. The
ordinary gate does not authenticate its execution source. The trusted all-PR launcher carries
the same native gate; immutable workflow registration, a clean pre-shell bootstrap and proof
on the consumer host are still required for enforcement. Host unavailability delays merging, edited
receipts block until the publisher restates them from its retained log, and aged-out owner push
activity needs a new push and re-approval. These residuals are detailed in the
[CHANGELOG](../CHANGELOG.md) and [review workflow](../workflows/review.md).
