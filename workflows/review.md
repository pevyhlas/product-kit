# Review, merge and closing

**Inputs**: a built change with its acceptance results, its record, PR and diff, the spec it
touches, the reviewers registered in `.prdkit/memory/agents.md`, and project policy.
**Writes**: the review package, reports on the PR, `**Review**:` lines in State, the final PR
context, the `specs/log.md` line and the record's deletion.
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
cache is local. Append one State line per verdict, using an eligible identity registered in
`.prdkit/memory/agents.md`, never editing an earlier one except to correct a range to the printed
hashes; a later line supersedes the same reviewer's earlier one, whatever its round. The range
uses the package's resolved hashes (`BASE_SHA..HEAD_SHA`, or `SINCE_SHA..HEAD_SHA` for a scoped
verdict), never a name that moves (`HEAD`, a branch); the first round's base is where the change
leaves the default branch:

```text
**Review**: round 2 · <base sha>..<reviewed head sha> · <registered reviewer identity> · PASS · 0 critical, 0 high, 1 medium, 0 low · <report link>
```

Re-review only changed source, scoped to the fix: `--since <previous-reviewed-head>` keeps a
focused delta alongside the full diff. BASE must be the change's current merge base with a
trusted integration branch (`origin/HEAD`, or one named by `review-integration-branches` in its
committed config, as `check-review.sh` reads them), or the script refuses; there must be one to
use `--since`. After a base merge, pass the new merge base: the delta then leaves out what the
base brought, and the package index says what it covers. Never dispatch a
round when no source changed since the last verdict. Map findings to fixes and affected
obligations, preserving unaffected approvals and evidence; re-open a concern only when its source,
bounds or evidence applicability changed. The recorded range is the range actually inspected,
starting at or before that reviewer's prior head so the rounds chain; the full package range
alone is not a new full-review claim. Required reviewers and the final-head check still apply. A
T3 change also records the owner's verdict, reviewer `owner`, over the head the owner approved,
ending with a link to their words; counts may precede the link and are not read. A later L0 or
L1 edit needs the owner again:

```text
**Review**: round 1 · <base sha>..<approved head sha> · owner · PASS · <link to the owner's words>
```

Register identities on the integration baseline before using them; maker, unregistered and
ambiguous identities cannot count as independent verdicts or coverage. Preserve standing FAILs
while reconciling older records. Registry eligibility is not proof that a fresh context ran. The
offline gate leaves report links unverified; `check-review.sh --verify-reports --pr <GitHub PR
URL> <change-id>` optionally compares them with the recorded metadata and needs `gh`, `jq` and
readable reports on that exact PR head. Each linked comment, the owner's included, then carries
one receipt with the line's full hashes (`review-prompt-template.md`); the owner's needs no counts:

```text
<!-- prdkit-review
{"schema":"prdkit.review.v1","reviewer":"owner","base":"<full base sha>","head":"<full approved head sha>","verdict":"PASS"}
-->
```

## Merge

Merge only when the required checks pass and `.prdkit/scripts/bash/check-review.sh --head <sha>
<change-id>` passes on the exact head being merged, then merge that head (`gh pr merge
--match-head-commit <sha>` on GitHub). It passes when every reviewer's latest verdict is PASS with
nothing blocking (a FAIL stands until a later clean PASS from the same reviewer reaches its head),
the recorded ranges chain from the change's start and from each reviewer's head to the merged
head, and the tier's minimum is recorded: one independent verdict from T1, the owner's for T3. It
does not know which concerns a T2 change needed; the reviewer list is the worker's call. It checks
recorded verdicts, never grants merge authority, and is the gate where the plan has no branch
protection.

An update from the trusted integration base keeps review coverage only when the checker proves
the exact branch delta unchanged outside the record and log. Overlapping source changes, conflict
resolutions (choosing the old reviewed content included), extra edits and unverifiable ancestry
still need coverage, and integration tests and baseline/contract revalidation still apply. This
exemption and record-only closure trust only `origin/HEAD` or `review-integration-branches` read
from that default branch's committed config, never an arbitrary `--base` or a change-local config
edit. Without `origin/HEAD`, full review coverage applies; establish the remote default first.

## Closing

A PR-scoped change closes in that same PR when its required acceptance and review pass, or by
explicit owner disposition. Whatever deletes a record, an owner-disposed cancellation included,
adds its `specs/log.md` line in the same PR. Required live gates still block. Non-gating runtime
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
runtime unknown if relevant> — <PR>"`, which adds the `specs/log.md` line and deletes the record
once `check-review.sh` passes. Push both commits together, so required checks run once on the
closed head; the PR, not the record, carries any handoff to whoever merges. Do not change scope,
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
on the trusted integration branch (record gone, log line present), skipping dirty or locked ones
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
