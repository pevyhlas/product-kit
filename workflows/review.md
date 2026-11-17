# Review, merge and closing

**Inputs**: a built change with its acceptance results, its record, PR and diff, the spec it
touches, the reviewers registered in `.prdkit/memory/agents.md`, and project policy.
**Writes**: the review package, reports and publisher-authored receipts on the PR, the final PR
context, the log entry (`specs/log/<id>.md`) and the record's deletion.
**Result**: a closed change whose exact head may merge, or review pending or a recorded blocker.

Read this before dispatching review, merging or closing. [change.md](change.md) opens and builds
the change; the tier is in [protocol.md](protocol.md).

## Review

The reviewer is a fresh context that did not implement the change. Reviews are run by the worker,
not CI. Send `.prdkit/templates/review-prompt-template.md`, the change record, the spec sections
it touches (plus a readable `specs/` at the head, to search), the PR's context and the full diff,
never only the implementer's summary. Before dispatch, confirm the reviewer's allowed read paths,
shell/network access and report channel; without shell access, supply the captured `bounds.sh`
output with its input revision/hashes.

For committed work run `.prdkit/scripts/bash/build-review-package.sh <change-id> <base> [head]`,
adding `--context <path>` for selected tracked canon/policy/record files and `--evidence <path>`
for completed local results. The helper checks structural accessibility, not semantic
completeness: verify the index covers each review obligation, prior findings, acceptance results
and unknowns. Every result names its command, revision, environment, completion/exit status and
limits; running logs are not completed evidence. Copy required sibling/remote evidence into the
checkout first with original source provenance, then attach or place the package inside the
reviewer's actual access boundary. Verify access before a costly review round. For uncommitted
work send the tracked diff plus the untracked file contents, with their hashes. Without a
trustworthy package, review is pending.

Critical and high findings block, medium blocks under `Rigor: full`, low is advisory. A failed
tool run is not a product FAIL and an absent reviewer is not approval. Preserve each report
verbatim on the PR; the change record will be deleted on close and the local cache is not its
durable public home. End the review report with `Verdict: PASS|FAIL` and then
`Counts: <n> critical, <n> high, <n> medium, <n> low`, exactly as the review prompt specifies.

An authorized **publisher**, not the maker or a pasted block, authenticates the verdict:

Run `publish-review.sh` and its libraries from the trusted default branch or a pinned kit
install, **never from a PR checkout**. `--repo` points at a fetch-only clone used for Git objects,
not code execution. A publisher CI job must never run PR-controlled code with the publisher key
(for example a `pull_request` job with secrets).

```bash
bash /trusted-install/.prdkit/scripts/bash/publish-review.sh <change-id> --repo <fetch-only-clone> --pr <url> --reviewer <registry-id> \
  --verdict PASS --counts 0,0,0,0 --report <report-url> --head <reviewed-sha> --from-report <file>
```

It computes the content tokens and random id, posts one v3 JSON block in a submitted COMMENT
review (not an issue comment), and reads back the author, body and edit markers through GraphQL.
It writes no verdict into the record. `--dry-run` prints the block without host access; it needs
jq for JSON encoding. The publisher posts it; never paste it yourself. Submitted reviews cannot
be deleted, but anyone with pull-request write access can edit them: **any edit invalidates the
receipt and blocks**, even if the author, commit and submission time are unchanged.

`start` is the empty change; `fp1:` names the change's delta from its trusted base, outside its
own record and log. Re-review only changed source, scoped to the fix: use the package's
`--since <previous reviewed head>` and the publisher's same flag. A rebase or squash may leave
that head outside the current ancestry; equal reviewed content still works. BASE must be the
current merge base with a trusted integration branch for a focused package; after a base merge,
use the new merge base. Never dispatch a round with no source change. The range is the range
actually inspected. Map findings to fixes and affected obligations, preserving unaffected review.

Trusted default-branch policy names `review-host: github`, numeric `review-publishers`, personal
numeric `review-owner` ids, and `review-publisher-isolation: required|shared`. Register eligible
reviewer identities there too; a branch cannot register itself. Bot and User account types plus
database ids authenticate publishers; logins and report text do not. Obtain ids with
`gh api users/<login> --jq .id` or `gh api 'users/<slug>[bot]' --jq .id`.
Never list `github-actions[bot]`: a maker can add a workflow using that shared identity.

Prefer a dedicated publisher App whose key exists only on a reviewer-controlled user/host/CI
job, or a human publisher. `required` rejects a publisher that authored this PR; account
separation alone does not prove separate machines or credentials. Explicit `shared` warns that
receipts bind content, order and counts, not reviewer independence.
Removing an id from `review-publishers` drops that publisher's receipts, **FAILs included**,
on both current and closed source PRs. Reconcile its standing verdicts before rotating the id.

Native owner barriers are PR-wide, independent of coverage: CHANGES_REQUESTED blocks at every
tier, including T0, record-only closure and a renamed/deleted/missing carrier. DISMISSED is a
distinct revocation barrier, not a request for changes. Each configured personal numeric actor
keeps its own barrier; another owner's approval cannot clear it. COMMENTED, PENDING, record
text and tier edits do not clear either state. An event-free otherwise exempt PR needs no new
positive owner approval. Future coverage exemptions must retain this pre-coverage check.

Only a later valid APPROVED review by the issuer clears its barrier. Invalid or unwitnessed
approval leaves the earlier negative standing. Positive approval is still required for
substantive T3 and owner/unnamed legacy clearance, not for every tier. T3 uses the latest
decisive native review, with no standing owner barrier. The approved commit's L0/L1 slice must
match the checked head. A code fix or rebase can keep it; an L0/L1 edit needs approval again. The gate
confirms the commit was the head strictly before submission using all activity types and the
deciding window's continuity. Same-second ties or aged-out/missing activity fail closed: push
a commit (record-only is enough), then approve again. Retention is not known. Owner text,
receipts and record lines never approve; an owner-authored T3 PR needs a different PR author.
Missing identities, duplicate review ids, unknown states and incomplete enumeration are
unavailable authority, never an event-free exemption. Native barriers belong to the current
repository/PR; they grant no cross-PR PASS authority or automatic legacy-history clearance.

### Repairing an edited or invalid receipt

Keep the publisher log outside every working tree, under the absolute Git common directory:
`$(git -C <fetch-clone> rev-parse --git-common-dir)/prdkit/receipts/<pr>/<receipt-id>.json`.
It must **never be maker-writable**; protect it with the publisher credential. Symlinked log
components are refused. Old `.prdkit/cache/receipts/` logs are never read or migrated.
Only the original review author's typename and numeric id may restate it. Restate the **full
original verdict**, never reconstruct it from a corrupted, maker-editable host body:

```bash
bash /trusted-install/.prdkit/scripts/bash/publish-review.sh --repo <fetch-only-clone> --pr <posting-pr-url> \
  --restates <invalid-review-id> --receipt-id <original-32-hex-id> [--restates-pr <origin-pr>]
```

On a later PR, `pr` names the posting PR and `restates_pr` names the origin; omit `restates_pr`
on the origin PR itself (closed PRs accept COMMENT reviews). The other fields stay original.
A repair keeps the original host position and PR scope; a repaired old PASS grants no coverage
on the new PR. Repairs survive a closed or merged carrier. A lost log can leave a permanent
blocker; preserve it outside the maker's reach along with the publisher credential.

### PR scope and legacy blockers

Only this PR's checked-change receipts grant coverage. All blocking receipts on this PR count,
even for a renamed, deleted or sibling change. Standing blockers carry from closed, unmerged
PRs of the same head branch; merged PRs contribute only repairs. An unreadable source is
unavailable, not empty. Renaming the branch to escape carry remains a residual risk.

1.x PASS lines grant nothing and are never converted. The blocker-only Git history scan keeps
FAIL, blocking-count and unreadable State lines, including lines removed with a carrier record.
They clear only through the same reviewer's clean native full PASS on this PR for the origin
or checked change, whose reviewed head/base_at history includes the blocker. Owner and unnamed
blockers need the owner's valid native approval with the same historical-inclusion check.
For genuinely empty content, `--clears-legacy` permits that reviewer's clean full PASS only
when the scan finds its blocker; it creates no coverage edge. Added content expires that
clearance, not the receipt: a later clean full PASS can clear normally. Rewriting pre-merge
branch history to erase a newly introduced line remains a residual; inherited default-branch
lines stay protected. The scan lasts through 2.x. The transition installs no converted PASS.

## Merge

Merge only when the required checks pass and `.prdkit/scripts/bash/check-review.sh --pr <url> --head <sha>
<change-id>` passes on the exact head being merged, then merge that head (`gh pr merge
--match-head-commit <sha>` on GitHub). It passes when every reviewer's latest verdict is PASS with
nothing blocking, the recorded verdicts chain by content from `start` and from each reviewer's
reviewed content to this head's content, and the tier's minimum is recorded: one independent
verdict from T1, the owner's for T3. A FAIL stands until a later clean PASS from the same
reviewer either re-reviews from `start` or continues from the failed content through that
reviewer's own later rounds; returning to earlier content or rewriting history never clears it.
It does not know which concerns a T2 change needed; the reviewer list is the worker's call. It
checks recorded verdicts, never grants merge authority, and is the gate where the plan has no
branch protection.

A verdict holds while the reviewed content is unchanged: record and log commits, an edit later
reverted, a rebase, a squash and a base merge that does not overlap keep it. A real fix or an
overlapping base merge voids it. Overlapping means the base's own changes touch a line the change
adds or removes, or one of the 3 unchanged context lines around it the reviewer saw (a clean
merge more than 3 lines away keeps it), or base and change both touch a binary file, a symlink, a
submodule, a file the change adds or deletes, or a mode; where the edited lines' surroundings
repeat in the file, the file is bound to its exact objects. A conflict resolved by keeping the
reviewed lines still voids it: those lines now replace the base's. Integration tests and
baseline/contract revalidation still apply. Coverage and record-only closure trust only
`origin/HEAD` or `review-integration-branches` read from that default branch's committed config,
never an arbitrary `--base` or a change-local config edit. Without `origin/HEAD` the check fails:
it has no policy to read, so establish the remote default first.

## Closing

A PR-scoped change closes in that same PR when its required acceptance and review pass, or by
explicit owner disposition. Whatever deletes a record, an owner-disposed cancellation included,
adds its log entry in the same PR. Required live gates still block. Non-gating runtime
observations need no cleanup PR, and no permanent task archive is required.

Before final review: reconcile the approved spec delta with actual behavior. Remove only built
`planned` markers; preserve unbuilt intent and hypotheses. Known unmet required work needs an
explicit disposition and durable follow-up reference; never erase it with the plan. Cancellation
withdraws, defers or rebinds unfinished planned intent instead of making it look built. Post
scope/design references, useful implementation context, actual verification/review evidence and
unknowns on the same PR using `.prdkit/templates/pr-summary-template.md`; do not depend on
intermediate commits surviving squash. Remove any tracked auxiliary execution files before this
review; ordinary review coverage applies to their changes/deletions. Ignored scratch may be
discarded after useful context is durable. A child PR updates only its row and the checkpoint in
its parent, and never copies its plan, findings or evidence there.

After PASS, only record deletion and the log change: publish the final receipts,
then run `.prdkit/scripts/bash/close-change.sh --pr <url> <id> "<intent> — <IDs> — <disposition;
runtime unknown if relevant> — <PR>"`, which writes the log entry `specs/log/<id>.md` and deletes
the record once `check-review.sh` passes. The text is at most 300 characters: carried findings and
follow-ups go to the parent's row or the spec, evidence stays on the PR. One file per closed
change means two branches that each close a change never conflict in the log; compaction folds
the entries into `specs/log.md` ([compact.md](compact.md)). Push both commits together, so
required checks run on the closed head; the helper accepts an unpushed closing commit only when
it descends from the PR head and its fingerprint equals it, and refuses an offline preview.
JSON `result` is `preview` whenever authority is not `host`, including unavailable or blocked
previews; inspect authority, problems and the exit code (1 failure, 3 would-pass preview).
The PR, not the record,
carries any handoff to whoever merges. Do not change scope,
acceptance or policy after review without reviewing the affected changes. Later defects use
ordinary linked fix changes, which inherit the failing outcome's attempts, limits and holds
([protocol.md](protocol.md)); they never retroactively turn an unknown into a PASS or erase a
known unmet obligation. Never reopen a completed transaction merely to clear working files. A
change merged with its record still open (status flags it) closes in the next relevant PR, whose
record is its review carrier; never fabricate acceptance or open a cleanup-only PR. After merge
run `.prdkit/scripts/bash/cleanup-change.sh <id>` from the main checkout; it keeps the worktree's
evidence before removing the worktree. A repository with
submodules needs no `--force`: the script retries a clean worktree that git refuses only for its
submodules, and refuses any removal that would delete a submodule commit nothing else holds.
`cleanup-change.sh --closed` sweeps every `.worktrees/<id>` on branch `<id>` whose change is closed
on the trusted integration branch (record gone, log entry present), skipping dirty or locked ones
and leaving branches alone; run it after merges so finished worktrees do not pile up.

A `--no-branch` record closes the same way, through the project's authorized delivery route; its
shared checkout stays, so skip `cleanup-change.sh`. A detached HEAD can hold a record, but
publishing needs an authorized named branch.

## Review carrier

Finalize a programme parent in the last relevant PR when its required outcomes pass or the owner
disposes of it, keeping non-gating observations explicit; no separate cleanup PR. When one PR also
finalizes a parent or older change, its implementation record is the **review carrier**. Before
final review, bring the other record's remaining required acceptance, unresolved findings, attempts,
holds and disposition into the carrier, labelled with their origin. Preserve verdict/report
history; unresolved FAILs need a clean later verdict from the same registered reviewer, not
disappearance during transfer. The carrier takes the combined scope's highest applicable tier and
all required reviewer concerns, including owner approval where required. Post the other record's
useful context/evidence on this PR, add its log disposition and delete it **before** the carrier's
final review. That review covers the combined diff and integrated outcomes, including these
deletions. Only the carrier's verdict metadata/deletion and log may change after PASS. Run
`check-review.sh --pr <url>` for the carrier at the exact final head; do not start mutually dependent
post-review updates to two records. An inherited approval is not fresh coverage for changed work.
