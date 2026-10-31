# Working with Product-Kit

## Your role

Describe the outcome, users, constraints and what matters. You can start vaguely. The agent
reads the spec and code, offers an interpretation and asks only about choices that would
materially change scope, behavior, investment or authority. Every question comes with a
recommendation and, when the choice can be undone, the default it will apply if you don't
answer. You do not write the spec yourself unless you want to.

## What you read

- `specs/product.md` (L0): one page: the stage the product is in, the pains and the journeys
  that solve them, who it is for, the core loop, journeys by stage and the bet. You move the
  stage in `specs/product/lifecycle.md` (Idea, Demo, MVP, Private preview, Public preview, GA,
  Sunset, Retired); agents build for the stage it is in. Then `specs/product/`: the journeys (who, intent, scenario,
  variations, success) first, then requirements, qualities, constraints and non-goals, which
  bind every change. The agent edits L0 only with your words, quoted. Only you promote a hypothesis to
  validated.
- `specs/architecture.md` (L1): one page: the system diagram, its parts and the journeys each
  serves, the core loop's path, the key decisions, key areas such as security and observability,
  and the risks. Then `specs/architecture/`: decisions and one file per topic, including why the
  design works, with the alternatives it rejected and when to revisit them.
- `specs/inbox.md`: questions waiting for your answer, clarification or observation. Each has a
  stable ID, topic tags and an answer field; choices have stable keys as well as numbers. Use
  `/prdkit-inbox` to review them one at a time, optionally naming tags or IDs. Select an option,
  answer in your own words, ask for context or skip. You can also edit **Answer** directly.
  The agent records known date/source/revision, updates the actual governing spec or policy,
  reconciles contradictory wording, preserves remaining work/holds and verifies the result
  before removing the item. It gives you the canonical destination, not just "recorded."
  **To incorporate** temporarily holds answers awaiting agent processing; these are not questions
  for you to answer again. Partial answers leave only the remaining question. Declines and
  deferrals live with the relevant decision and revisit trigger. Verbatim relays count as your
  words; an agent's summary does not.
- `/prdkit-status`: what is true now, what is in flight, what is live, holds and waivers, what
  waits on you, and the longest pole. It is generated, never written as prose.

The summary and architecture read in minutes; journeys are where your attention pays most. Files
past their reading budgets are tightened or split, never trimmed of items.

### Where answers are kept

Keep the operative answer, qualifications, concise rationale, date/source and inbox ID beside
the canonical decision. The full question and old options can leave the working tree once that
decision and its remaining obligations are verified. Git retains committed inbox history; the
agent must preserve answers from chat in the canonical edit even if no inbox version was committed.
A separate answer archive is normally redundant and can become stale. Use one only for an explicit
audit/retention need, with the spec remaining authoritative.

Existing inboxes are reconciled by `/prdkit-inbox`, not by deleting everything labelled folded.
Upgrading the kit leaves `specs/` untouched, so ask the command to review legacy entries after
adoption. A preview shows the proposed routing without editing files.

## During a change

Exploration discusses options. Product/programme planning combines intent, journeys and requirements
with architecture/design to discover justified features and enabling work. Ready work gets a
proportional execution plan and tasks; it does not repeat product discovery. Execution performs the
bounded work under your project's action policy. Say which you want when it matters; an
uncertain idea does not become a branch and code.

The agent returns for consequential choices, missing authority, a hold, an owner gate or a
stall. If the same acceptance item or blocker fails three times, or twice without new
information, it stops and brings you alternatives (one managed or off-the-shelf, one that
relaxes or drops what forces the work) instead of trying again. Only you grant more attempts,
lift a hold or change scope, investment or limits; no agent grants these to itself or another
agent.

To pause work, ask for a hold; it is recorded in `specs/records.md` and wins until you lift it.
Say `/prdkit continue` after an interruption; the agent resumes from the change's State and
the actual repository.

## Completion and learning

Merged is not live, and live is not validated. A bounded implementation change finalizes in its
own PR once required acceptance/review pass, or by your explicit disposition. Runtime observations
that are not PR gates stay unknown on that PR; later findings use ordinary linked fixes. Existing
required checks, including live gates, cannot be silently downgraded. No cleanup PR is needed.
Passing tests is not evidence of user value.
`/prdkit-learn` compares what users actually did with the thesis and proposes promotions,
revisions or retirements through the inbox; inconclusive is a valid answer.

See [feature delivery](feature-delivery.md), [the request-service example](../examples/request-service/README.md) and the
[public commands](commands.md).
