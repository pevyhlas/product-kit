# Optional execution ledger and retrospective enrichment

`.prdkit/scripts/bash/ledger-emit.sh <event>` reads a `prdkit.ledger.v1` JSON envelope
from stdin. Events append locally to `.prdkit/ledger/events.jsonl`; external delivery runs
only when `.prdkit/memory/task-ledger.md` selects a backend. The default is `none`.
The installer ignores the local spool in Git. Spools are not rotated automatically.
Emission validates one JSON object before writing. Missing top-level event metadata is
injected from the CLI name; nested keys do not suppress it. Invalid/ambiguous envelopes
fail without changing the spool. Original top-level attribution is preserved.

New emissions also capture `observed_context`: capture time, credential-free network-origin
host/path, Git head/branch, installed manifest version and exact manifest/emitter Git blob IDs.
Absent or unrecognizable data is `unknown`; no local paths or remote credentials are recorded.
These fields are observations from the installed emitter's checkout, including linked worktrees,
not inferred from a mutable session tag. They are snapshots, not signed attestations: the manifest's
version does not prove installation integrity or identify which kit a long-running session loaded.
Git head does not capture uncommitted source. For version-specific analysis, retain adoption-gate
evidence and installed input hashes too.

`observed_context` is emitter-owned; supplying it to `ledger-emit.sh` fails before spooling rather
than overwriting history or accepting stale observations. Replay a stored event directly through
the configured adapter, which preserves this context. Legacy events remain valid without it and
must not be backfilled from today's checkout. Declared `project`, `feature` and session IDs remain
unchanged even when they conflict with observations; collectors flag/quarantine that assignment
instead of silently attributing its usage. A branch name alone does not identify a feature.

The [configuration template](../templates/task-ledger-template.md) describes filtering,
best-effort/strict adapter behavior, and optional Git operator attribution. Adapters are
repository-contained executable files, never symlinks, and own credentials/network access.

The kit ships one ready-made adapter: `command: .prdkit/scripts/bash/ledger-spool-adapter.sh`
mirrors every event into a durable per-host central spool
(`${XDG_DATA_HOME:-~/.local/share}/prdkit/ledger/<project>/events.jsonl`, one directory per
project, name derived from the Git origin with a `PRDKIT_PROJECT` override) so events
survive worktree deletion and a host collector can aggregate them across repositories.
It is local-only: no credentials, no network.

## Event contract

Schemas live in [schemas/prdkit.ledger.v1](../schemas/prdkit.ledger.v1/). The envelope carries
schema, event, stable feature-qualified event_id, feature identity/revision, actor, timestamp,
and payload. In 1.0 the `feature` object identifies the change: its id is the change id.
Optional operator attribution is project-configured. Re-emission with the same
event ID represents the same occurrence; retrospective delivery summaries deduplicate last-wins.
Review finding counts use critical/high/medium/low. Private pre-redesign exports using
other severity names must be translated once before the current reporter consumes them.

```json
{"schema":"prdkit.ledger.v1","event":"feature.created","event_id":"042-export/feature.created","feature":{"id":"042-export","branch":"042-export","sha":"abc1234"},"actor":"change","ts":"2026-09-21T12:00:00Z","payload":{"title":"Export"}}
```

The [configuration template](../templates/task-ledger-template.md) names the boundary of each
event 1.0 emits: `feature.created`, `review.recorded`, `evidence.recorded`, `blocker.opened`,
`blocker.resolved` and `feature.merged` (after the implementation PR merges, not proof of runtime
acceptance). The 0.x events
`tasks.generated`, `task.state_changed`, `phase.changed`, `readiness.changed` and
`exploration.converged` stay schema-valid in existing spools; 1.0 workflows do not emit them.
Events are diagnostics; the change record's acceptance and the original review reports are
the evidence.

## Delivery retrospective

```bash
.prdkit/scripts/bash/retrospective.sh 042-export
```

The helper takes a change id (default: the current branch), reads its local events, and
atomically writes `.prdkit/cache/retrospectives/<change-id>.md`, never under `specs/`. It
reports review rounds, findings, blockers, and optional usage. No ledger
or enrichment means an explicit lack of observations, not fabricated results.

## Optional enrichment contract

An external adapter may provide `.prdkit/retrospective/<change-id>.enrich.json`. The file stays
local: the installer ignores `.prdkit/retrospective/` in Git, because it can name agents, costs,
sources and free-text notes, and change cleanup keeps it like evidence. Share usage data
deliberately, outside the repository.

```json
{
  "schema": "prdkit.retrospective.enrich.v1",
  "feature": "042-export",
  "tokens": {"total": 12000},
  "source": "project-selected usage export",
  "coverage": "Only sessions linked to this change",
  "cost_estimate_usd": null
}
```

Required: schema, feature, tokens.total. Optional: tokens.by_type, by_model, by_effort,
by_agent (objects of counts), sessions, source, generated_at, coverage, notes (string array),
cost_estimate_usd. Counts are nonnegative integers no greater than 999999999999. Cost is a
nonnegative number in that range or null. Numeric strings are rejected. Metadata names
the coverage and source so incomplete observations remain interpretable.

Enrichment uses jq 1.6+; ledger-only reports need Bash and standard utilities. Missing jq or
invalid enrichment fails clearly without replacing the previous report. The kit installs
no dependencies and requires no private monitoring host. Usage analysis is not product-value
validation; see [learning](../workflows/learn.md).

## Versioned usage attribution

At dispatch and each event boundary, validate the declared project/change against the actual work
assignment, checkout and installed kit; re-tag an incorrectly assigned session before new work.
Keep session/parent IDs, reviewer concern, model and range in the event payload when available.
Collectors join event-time observations and message-level usage by explicit IDs/time intervals;
latest session tags are only hints. Split mixed-project/version sessions only with verified message
boundaries; otherwise report them as mixed/unattributed. Exclude missing counters from totals and
state coverage, rather than counting absence as zero or treating a sample as a project total.

Report uncached input, cache-read, cache-write, output and reasoning separately using the provider's
definitions. Reasoning may be included in output; avoid double counting. Cached and uncached input
are not interchangeable cost units. A monetary estimate needs the applicable model, rate/date and
cache treatment; token volume alone establishes neither waste nor a before/after efficiency gain.
