# Change: <short name>

**Opened**: <date> · **Parts**: <P-ids> · **Journeys**: <J-ids> · **Tier**: <T0–T3> · **Parent**: none

<!-- Split large scope into independently shippable children (Parent: <id>), preserving the
parent's outcome, allocation and cumulative attempts/progress. Splitting never renews a budget. -->

## Intent

<Why now, for whom. Inbox lines addressed, one sentence of disposition each.>

## Spec edits

| Level | ID | Edit | Note |
|-------|----|------|------|

## Bounds

<!-- From `.prdkit/scripts/bash/bounds.sh <id>`: each constraint, non-goal or quality this change
could break, with how it holds; then "Others in scope: hold". A conflict goes to the owner inbox
with both sides, never resolved here. -->

- <C-01>: holds: <how>.

## Approach

<Approved design/contract references and spec/code baseline. Only real execution choices:
options, pick, why. Unsettled material product/design choices return to Product-Kit.>

## Tasks

- [ ] T001 <contribution/acceptance; paths; dependency outcome; check>

<!-- Tiny fixes stay inline. Optional detail: .prdkit/cache/implementation/<id>.md;
useful context/progress on the same PR. Product/programme discovery uses workflows/planning.md. -->

## Checks

<Line test, consistency with L0/L1, enforcement for new Q/I. A few lines.>

## Acceptance

<!-- Required PR obligations. Distinguish later non-gating runtime observations on the PR before
execution; existing required checks cannot be demoted to finish. Live-only claims need live proof.
Keep these five columns for status helpers, including on a parent programme. Result is exactly
NOT_RUN/PASS/FAIL/BLOCKED/NOT_APPLICABLE; evidence/revision/environment go in Check or below the table. -->

| Item | Proves | Check | Attempts | Result |
|------|--------|-------|----------|--------|
| A1 | <ID> | <test, CI job, live run or owner trial> | 0 | NOT_RUN |

## State

**Step**: intent
**Waiting on**: nothing
**Next**: <next action>
<!-- For a programme/continuing follow-up queue, fill the outcome checkpoint here (change.md).
Children link their parent's checkpoint. Do not initialize missing history to zero on resume.
### Outcome checkpoint
**Outcome**: <owner goal/source; intended architecture and stage>
**Milestone**: <next observable result and check; enabling checks in Tasks>
**Critical path**: <dependencies and actual blocker>
**Allocation**: <lane purposes; original start/deadline/bounds/consumption; authority>
**Progress**: <last evidenced advance, date/revision/link; or none/unknown>
**No-progress changes**: <integer or unknown>
**Progress limit**: 3
**Selection**: <next task, milestone contribution, why now; temporary-work disposition>
-->
<!-- One line per verdict (workflows/change.md, Review):
**Review**: round <n> · <base sha>..<reviewed head sha> · <registered reviewer identity> · PASS|FAIL · <n> critical, <n> high, <n> medium, <n> low · <link> -->
