# Agent workflow guide

The operational source is [protocol.md](../workflows/protocol.md), then only the operation
needed from the [operation index](../workflows/README.md). The playbooks install under
`.prdkit/workflows/` for every harness; public command wrappers route there.

## Context

Read project instructions and the constitution first, then the spec top-down: L0, the parts
table in L1, the part files a change touches, then code. Read a document over 32 KB by
section. Agent context files (`CLAUDE.md`, `AGENTS.md`) load on every turn: they hold stable
orientation and pointers, never change narrative or evidence.

## Spec edits

[spec.md](../workflows/spec.md) defines the levels, the line test (a line stays only if it rules
out meaningful wrong implementations and rejects no valid real input), the layout, IDs, markers
and reading budgets. Edits that claim built behavior ship with code and tests. Owner-approved,
unbuilt intent can land in a spec-only PR under the [`planned:` rule](../workflows/spec.md#elements);
undecided intent stays in the change record.
L0 edits carry the owner's quote. One-way doors wait for the owner's answer.

## Changes

[planning.md](../workflows/planning.md) discovers bounded work from L0/L1/L2 together. Ready work
uses [implementation.md](../workflows/implementation.md): execution planning, concrete tasks,
consistency analysis and convergence. It consumes design rather than defining product requirements
from implementation choices. Material findings return to Product-Kit's existing decision process.

[change.md](../workflows/change.md) runs a change from `new-change.sh` through the same PR: intent
with inbox dispositions, spec edits, approach, tasks, checks, acceptance and State. State is
the only status prose an agent writes and is updated before every stop. Attempts are counted
per acceptance item and per blocker across tasks, PRs and sessions; after three, or two
without new information, the agent writes an alternatives note and reports NEEDS_DECISION
through the inbox.

Programmes also keep an [outcome checkpoint](../workflows/planning.md#protect-the-outcome)
in the existing State: goal, critical path, lane allocation, evidenced progress and next selection.
Repeated successful changes without a milestone/dependency advance prompt reassessment too.
Handoffs preserve cumulative accounting; temporary repairs explain their contribution and removal.

Review is proportional to the tier in the protocol and runs per
[review.md](../workflows/review.md), which also covers merge and closing; the reviewer is a fresh
context that did not implement the change and receives the full diff, never only a summary.
`build-review-package.sh` captures committed work into `.prdkit/cache/evidence/`, and reviewers submit normal GitHub approvals for the commit they inspected.

## Delivery and closing

Authority is resolved per action (commit, push, PR, merge, release, deploy, spend) from
explicit user authorization or the constitution's action policy; a hold wins until its issuer
lifts it. `check-delivery.sh --json` observes whether a checkpoint is remotely available; a
matching SHA proves availability, not acceptance. Closing removes built `planned` markers,
keeps lasting decisions in L1/L2 and preserves useful context and evidence on the PR; after the
current head passes, `close-change.sh --pr <url>` checks the host, writes one row of at most
200 characters to `.prdkit/history/log/<id>.md` and deletes the record. Push the closing
commit and obtain its tier's required approvals on that new SHA before merge. Non-gating
runtime observations stay unverified and later findings use linked fixes, not cleanup PRs.
`cleanup-change.sh <id>` removes the worktree after merge, and `cleanup-change.sh --closed` every
closed change's worktree at once (branches are kept). See [feature delivery](feature-delivery.md).

## Helpers

`status.sh` and `doctor.sh` give mechanical observations in text or JSON from local files and
Git only; `bounds.sh <change>` lists the constraints, non-goals and qualities in a change's
scope. Label semantic judgments and keep them apart from what a helper observed. No helper
evaluates product usefulness.

[`check-review.sh`](ci-gates.md) verifies the tier’s required GitHub approvals on the PR’s exact head.
