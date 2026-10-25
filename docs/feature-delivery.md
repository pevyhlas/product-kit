# From product intent to one PR

Product-Kit owns product intent, architecture and design. Its implementation flow executes that
definition; it does not produce another feature specification or rewrite promises to fit the code.
The operational sources are [planning](../workflows/planning.md),
[implementation](../workflows/implementation.md) and [change](../workflows/change.md).

## Discover work, then execute it

`/prdkit-target` combines journeys and requirements with design decisions, responsibilities,
interfaces, invariants and actual implementation. It groups missing behavior into bounded features
and necessary enabling work, with checks and dependency outcomes. Parts alone cannot tell you how
many features are required. Detail near-term work and distinguish required, later, optional and
unresolved candidates; a coverage table is a planning view, not another requirements hierarchy.

`/prdkit --plan <ready work>` records the scope, baseline, design references, tasks and checks
without implementing. `/prdkit --execute` or `continue` takes the next eligible work under existing
policy, verifies it and converges the diff against intent. No routine re-approval or redesign.
Ordinary code choices stay local; consequential product/design findings go back to their existing
decision process. A library limitation is evidence, not a new product requirement.

Small fixes keep tasks inline. Larger changes may use one ignored execution plan; useful context
and progress belong on the same PR, not solely in a local cache. No scheduler or task service is
needed. Projects supply commands, policy, actual reviewers and environments, not their own methodology.

## Example: requests through a durable queue

Suppose approved R-01 says a requester can submit and see a request; R-02 says a coordinator can
resolve it; Q-01 requires no lost or duplicate request after retry. The design routes P1 client
through P2 service to P3 store, whose P3.I-01 requires one persisted identity per request.

Discovery can produce:

| Work | Why / design | Dependency outcome | PR proof |
|------|--------------|--------------------|----------|
| Submit and see a request | R-01, Q-01; P1/P2/P3, P3.I-01 | approved identity contract | submit/read, access isolation, retry without duplication |
| Resolve and see the outcome | R-02; P1/P2 transition contract | compatible submission interface merged | transition/readback, invalid transition rejected |

Deduplication is necessary enabling work for the first feature, not a third product requirement.
Notifications are not required just because the system has a queue. Each PR preserves applicable
bounds; unfinished resolution can stay explicitly planned until the second PR realizes it.

Within the first change, tasks cover the persisted retry-safe path, its client-visible result and
negative/cross-part checks, each tied to the same acceptance. The implementation may choose local
function structure. If the selected store cannot preserve identity across retries, it reports that
design conflict; it cannot replace Q-01 with “duplicates are allowed” or add a convenient user limit.

## Finalize on the same PR

Before final review, the PR contains canonical scope/design references, useful approach and task/check
mapping, verification at actual revisions/environments, review evidence and explicit remaining
observations. The diff contains code/tests and only approved canonical changes. Remove tracked
auxiliary execution files before that review. After PASS, commit review metadata, then commit the
log entry and record deletion on the same branch/PR. Ignored scratch is disposable once useful
context is durable; intermediate commits alone may disappear under squash merge.

| Situation | Outcome |
|-----------|---------|
| Tiny fix | Inline tasks, proportional checks/review, same-PR finalization. |
| Medium feature | Optional execution detail; one bounded change/PR. |
| Several PRs | Bounded children where useful; integrated programme outcome is not inferred from child merges. Update/finalize the parent in relevant child PRs. |
| Non-gating production observation unavailable | Record “unverified,” its next check/trigger and owner where known on the PR; finish required PR work. No cleanup PR. |
| Existing live gate or required behavior fails | Remains blocking; no silent reclassification. Owner disposition must be explicit. |
| Post-merge defect | Ordinary linked fix with inherited attempts/holds for the failing outcome. |

Concretely, a project may accept local/CI retry and crash tests for the PR while scheduling a
production observation after deployment. The PR can then finish with production behavior explicitly
unverified. A project requiring a staging replay before merge must still perform that replay.
Neither disposition promotes a hypothesis, claims deployment or proves user value.

If a child PR also finalizes its programme, the child record carries the combined required
acceptance, unresolved findings, limits/holds and review tier/concerns. Preserve the parent's context
on the PR, then log/delete the parent before the combined final review. After PASS only the child
record's verdict metadata/deletion and log change. The review helper checks that carrier at the
final head. This avoids circular reviews of two records without losing integrated acceptance or
owner approval; an old unresolved review FAIL cannot be dropped in the transfer.

On resume, compare relevant spec/code/dependency baselines and revalidate only affected work. Two
mergeable PRs can still conflict semantically; coordinate shared contracts and data writers.
Known remaining required work needs a durable follow-up and explicit disposition, not disappearance
with scratch. Cancellation reconciles unfinished planned markers without implying delivery.

For older open changes, acceptance rows keep their existing meaning. Do not erase a gate by
upgrading the kit. Resolve remaining work or owner disposition in the next relevant PR; the new
default does not require cleanup-only PRs or fabricate acceptance for old work.

## Relationship to Spec Kit and orchestration

The execution discipline follows the useful plan/tasks/consistency/implementation/convergence
pattern in [Spec Kit](https://github.com/github/spec-kit), adapted to Product-Kit's existing spec,
decision and review ownership. No second constitution, branch allocator or feature-spec layer.

A future task-system adapter can queue bounded changes or PR-sized work, rather than every internal
task. That integration must preserve canonical scope, dependency outcomes and evidence; task state
cannot grant authority or declare product validation. This workflow does not add such an adapter.
