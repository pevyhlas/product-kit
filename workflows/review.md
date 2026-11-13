# Review, merge and closing

**Inputs**: a built change with its acceptance results, its record, PR and diff, the spec it
touches, the reviewers registered in `.prdkit/memory/agents.md`, and project policy.
**Writes**: the review package, reports on the PR, `**Review**:` lines in State, the final PR
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
tool run is not a product FAIL and an absent reviewer is not approval. Post each report on the PR
once one exists: it is the durable review record, since the record is deleted on close and the
cache is local. Record each verdict with `.prdkit/scripts/bash/record-review.sh <change-id>
--reviewer <id> --verdict PASS|FAIL --counts <c>,<h>,<m>,<l> --link <report> --head <reviewed sha>`,
using an eligible identity registered in `.prdkit/memory/agents.md`. It appends one State line,
bound to content fingerprints it computes (never typed, never edited), and prints the receipt
for the report comment. A later line supersedes the same reviewer's earlier one, whatever its
round:

```text
**Review**: round 2 · start..fp1:<64 hex> · <registered reviewer identity> · PASS · 0 critical, 0 high, 1 medium, 0 low · <report link>
```

`start` is the empty change; `fp1:` names the change's content (its delta from where it leaves the
trusted base, outside the record and the log). Re-review only changed source, scoped to the fix:
the package's `--since <previous reviewed head>` keeps a focused delta alongside the full diff, and
`record-review.sh --since <previous reviewed head>` records the narrow range. Any commit with that
content works, also one a rebase or squash left behind. BASE must be the change's current merge
base with a trusted integration branch (`origin/HEAD`, or one named by
`review-integration-branches` in its committed config, as `check-review.sh` reads them), or the
package script refuses `--since`; after a base merge, pass the new merge base. Never dispatch a
round when no source changed since the last verdict (`record-review.sh` refuses an empty range).
Map findings to fixes and affected obligations, preserving unaffected approvals and evidence;
re-open a concern only when its source, bounds or evidence applicability changed. The recorded
range is the range actually inspected. Required reviewers and the final-head check still apply.
A T3 change also records the owner's verdict, `--reviewer owner` without `--since` (counts
optional, not read), linking their words; it binds the L0/L1 spec only, so a code fix or a rebase
keeps it and any later L0 or L1 edit needs the owner again:

```text
**Review**: round 1 · start..fp1:<64 hex> · owner · PASS · <link to the owner's words>
```

Register identities on the trusted integration branch before using them (the check reads its
current registry); maker, unregistered and
ambiguous identities cannot count as independent verdicts or coverage. Preserve standing FAILs
while reconciling older records. Registry eligibility is not proof that a fresh context ran. The
offline gate leaves report links unverified; `check-review.sh --verify-reports --pr <GitHub PR
URL> <change-id>` optionally compares them with the recorded metadata and needs `gh`, `jq` and
readable reports on that exact PR head. Each linked comment, the owner's included, then carries
the one receipt `record-review.sh` printed for that line; the owner's has no counts:

```text
<!-- prdkit-review
{"schema":"prdkit.review.v2","reviewer":"owner","from":"start","to":"fp1:<64 hex>","head":"<full approved head sha>","verdict":"PASS"}
-->
```

Lines recorded before fingerprints (`<base sha>..<head sha>`, v1 receipts) stay readable while
their commits are here: each end reads as that commit's content.

## Merge

Merge only when the required checks pass and `.prdkit/scripts/bash/check-review.sh --head <sha>
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

After PASS, only verdict metadata, record deletion and the log change: commit the final Review
line, then run `.prdkit/scripts/bash/close-change.sh <id> "<intent> — <IDs> — <disposition;
runtime unknown if relevant> — <PR>"`, which writes the log entry `specs/log/<id>.md` and deletes
the record once `check-review.sh` passes. The text is at most 300 characters: carried findings and
follow-ups go to the parent's row or the spec, evidence stays on the PR. One file per closed
change means two branches that each close a change never conflict in the log; compaction folds
the entries into `specs/log.md` ([compact.md](compact.md)). Push both commits together, so
required checks run once on the closed head; the PR, not the record, carries any handoff to whoever merges. Do not change scope,
acceptance or policy after review without reviewing the affected changes. Later defects use
ordinary linked fix changes, which inherit the failing outcome's attempts, limits and holds
([protocol.md](protocol.md)); they never retroactively turn an unknown into a PASS or erase a
known unmet obligation. Never reopen a completed transaction merely to clear working files. A
change merged with its record still open (status flags it) closes in the next relevant PR, whose
record is its review carrier; never fabricate acceptance or open a cleanup-only PR. After merge
run `.prdkit/scripts/bash/cleanup-change.sh <id>` from the main checkout; it keeps the worktree's
evidence, retrospectives and ledger events before removing the worktree. A repository with
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
`check-review.sh` for the carrier at the exact final head; do not start mutually dependent
post-review updates to two records. An inherited approval is not fresh coverage for changed work.
