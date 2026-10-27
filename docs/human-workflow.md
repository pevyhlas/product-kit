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
- `specs/inbox.md`: questions waiting for you, each with numbered options and a recommendation
  (answer with a number or your own words), and direction awaiting incorporation. The agent folds
  your answer into the spec or policy with its words, date and source, tracks remaining work and
  holds, then removes the answered item without waiting for implementation or merge. Partial
  answers keep only the unresolved question open. Declines and deferrals live with the relevant
  spec decision and revisit trigger. Words relayed verbatim by another session count as yours;
  an agent's summary of them does not.
- `/prdkit-status`: what is true now, what is in flight, what is live, holds and waivers, what
  waits on you, and the longest pole. It is generated, never written as prose.

The summary and architecture read in minutes; journeys are where your attention pays most. Files
past their reading budgets are tightened or split, never trimmed of items.

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
