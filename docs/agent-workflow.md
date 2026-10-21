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
and reading budgets. Spec edits
land in the PR whose code and tests realize them; undecided intent stays in the change record.
L0 edits carry the owner's quote. One-way doors wait for the owner's answer.

## Changes

[change.md](../workflows/change.md) runs a change from `new-change.sh` to its closing PR: intent
with inbox dispositions, spec edits, approach, tasks, checks, acceptance and State. State is
the only status prose an agent writes and is updated before every stop. Attempts are counted
per acceptance item and per blocker across tasks, PRs and sessions; after three, or two
without new information, the agent writes an alternatives note and reports NEEDS_DECISION
through the inbox.

Review is proportional to the tier in the protocol; the reviewer is a fresh context that
did not implement the change and receives the full diff, never only a summary.
`build-review-package.sh` captures committed work into `.prdkit/cache/evidence/`.

## Delivery and closing

Authority is resolved per action (commit, push, PR, merge, release, deploy, spend) from
explicit user authorization or the constitution's action policy; a hold wins until its issuer
lifts it. `check-delivery.sh --json` observes whether a checkpoint is remotely available; a
matching SHA proves availability, not acceptance. Closing removes built `planned` markers,
promotes lasting choices into L1 or L2, appends one line to `specs/log.md` and deletes the
record; `cleanup-change.sh` removes the worktree after merge.

## Helpers

`status.sh` and `doctor.sh` give mechanical observations in text or JSON from local files and
Git only; `bounds.sh <change>` lists the constraints, non-goals and qualities in a change's
scope. Label semantic judgments and keep them apart from what a helper observed. No helper
evaluates product usefulness.
