# Optional execution ledger and retrospective enrichment

`.prdkit/scripts/bash/ledger-emit.sh <event>` reads a `prdkit.ledger.v1` JSON envelope
from stdin. Events append locally to `.prdkit/ledger/events.jsonl`; external delivery runs
only when `.prdkit/memory/task-ledger.md` selects a backend. The default is `none`.
The installer ignores the local spool in Git. Spools are not rotated automatically.
Emission validates one JSON object before writing. Missing top-level event metadata is
injected from the CLI name; nested keys do not suppress it. Invalid/ambiguous envelopes
fail without changing the spool. Original top-level attribution is preserved.

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
`blocker.resolved` and `feature.merged` (after the closing PR merges). The 0.x events
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

An external adapter may provide `.prdkit/retrospective/<change-id>.enrich.json`:

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
