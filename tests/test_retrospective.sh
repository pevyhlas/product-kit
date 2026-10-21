#!/usr/bin/env bash
# Behavioral guard for retrospective.sh (invoked from workflows/learn.md): it must turn the
# local ledger spool into a report under .prdkit/cache/retrospectives/, render the review
# history, summarize an out-of-band token/model enrichment file when present,
# and degrade to a clear "run the enricher" note (never a fabricated number)
# when it is absent.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

PROJ="$(make_inited_project)"; track_tmp "$PROJ"
PROJ="$(cd "$PROJ" && pwd -P)"
RS="$PROJ/.prdkit/scripts/bash/retrospective.sh"
FID="055-telemetry"
RETRO="$PROJ/.prdkit/cache/retrospectives/$FID.md"

mkdir -p "$PROJ/.prdkit/ledger" "$PROJ/.prdkit/retrospective"

# Fixture ledger: one feature, created → two task completions → two reviews
# (differing verdicts/agents/findings) → merged with a duration. A second
# feature's events and an unrelated-feature review must not leak in.
cat > "$PROJ/.prdkit/ledger/events.jsonl" <<'JSONL'
{"schema":"prdkit.ledger.v1","event":"feature.created","feature":{"id":"055-telemetry"},"actor":"a","ts":"2026-09-01T09:00:00Z","payload":{"title":"Telemetry rollout"},"event_id":"055-telemetry/feature.created"}
{"schema":"prdkit.ledger.v1","event":"task.state_changed","feature":{"id":"055-telemetry"},"actor":"a","ts":"2026-09-02T09:00:00Z","payload":{"changes":[{"task":"T001","from":"[ ]","to":"[x]"},{"task":"T002","to":"[ ]"}]}}
{"schema":"prdkit.ledger.v1","event":"task.state_changed","feature":{"id":"055-telemetry"},"actor":"a","ts":"2026-09-03T09:00:00Z","payload":{"changes":[{"task":"T002","to":"x"}]}}
{"schema":"prdkit.ledger.v1","event":"review.recorded","feature":{"id":"055-telemetry"},"actor":"a","ts":"2026-09-03T10:00:00Z","payload":{"scope":"task","task":"T001","round":1,"verdict":"FAIL","findings":{"critical":2,"high":1,"medium":2,"low":3},"agent":"code-reviewer"}}
{"schema":"prdkit.ledger.v1","event":"review.recorded","feature":{"id":"055-telemetry"},"actor":"a","ts":"2026-09-03T11:00:00Z","payload":{"scope":"task","task":"T001","round":2,"verdict":"PASS","agent":"build-agent"}}
{"schema":"prdkit.ledger.v1","event":"review.recorded","feature":{"id":"777-unrelated"},"actor":"a","ts":"2026-09-03T11:00:00Z","payload":{"scope":"task","round":9,"verdict":"FAIL","agent":"intruder"}}
{"schema":"prdkit.ledger.v1","event":"feature.merged","feature":{"id":"055-telemetry"},"actor":"a","ts":"2026-09-05T09:00:00Z","payload":{"tasks_total":2,"duration_days":6}}
JSONL

# ---------------------------------------------------------------------------
it "retrospective.sh builds the report with ledger-derived summary + review rows"
run bash "$RS" "$FID"
assert_eq 0 "$STATUS" "generator exits 0"
assert_file "$RETRO" "report written into the gitignored cache"
assert_eq "" "$(git -C "$PROJ" status --porcelain -- .prdkit/cache specs)" "nothing under specs/ or tracked"
CONTENT="$(cat "$RETRO")"
assert_contains "$CONTENT" "# Retrospective — $FID (Telemetry rollout)" "heading carries id + title"
assert_contains "$CONTENT" "Tasks completed: 2" "two distinct tasks reached [x]/x"
assert_contains "$CONTENT" "Review rounds: 2 total — PASS 1 · FAIL 1 · WAIVED 0" "review verdict tally"
assert_contains "$CONTENT" "Findings: 2 critical · 1 high · 2 medium · 3 low" "findings summed across reviews"
assert_contains "$CONTENT" "Duration: 6 days" "duration from feature.merged"
assert_contains "$CONTENT" "| 1 | task | code-reviewer | FAIL | 2 / 1 / 2 / 3 |" "round-1 review row"
assert_contains "$CONTENT" "| 2 | task | build-agent | PASS | 0 / 0 / 0 / 0 |" "round-2 review row"
assert_not_contains "$CONTENT" "intruder" "another feature's review did not leak in"

# Agent-effectiveness rollup: per-agent review outcomes are the evidence capability optimization aggregates.
assert_contains "$CONTENT" "## Agent effectiveness" "agent-effectiveness section present"
assert_contains "$CONTENT" "optional capability evaluation" "section names its purpose"
assert_contains "$CONTENT" "| code-reviewer | 1 | 0 | 1 | 0 | 2 / 1 / 2 / 3 |" "code-reviewer rollup: 1 FAIL, findings summed"
assert_contains "$CONTENT" "| build-agent | 1 | 1 | 0 | 0 | 0 / 0 / 0 / 0 |" "build-agent rollup: 1 PASS, no findings"

# ---------------------------------------------------------------------------
it "with an enrichment file, the token section renders model/effort/agent + null-cost wording"
cat > "$PROJ/.prdkit/retrospective/$FID.enrich.json" <<'JSON'
{
  "schema": "prdkit.retrospective.enrich.v1",
  "feature": "055-telemetry",
  "generated_at": "2026-09-12T08:00:00Z",
  "source": "opencode",
  "coverage": "6 of 6 sessions matched by branch",
  "sessions": 6,
  "tokens": {
    "total": 1200000,
    "by_type": {
      "input": 300000,
      "output": 150000,
      "reasoning": 600000,
      "cache_read": 120000,
      "cache_write": 30000
    },
    "by_model": {
      "openai/gpt-6-astra": 1100000,
      "openai/gpt-6-mini": 100000
    },
    "by_effort": {
      "high": 900000,
      "medium": 300000
    },
    "by_agent": {
      "build": 800000,
      "review": 400000
    }
  },
  "cost_estimate_usd": null,
  "notes": [
    "session_id dropped at ingest"
  ]
}
JSON
run bash "$RS" "$FID"
assert_eq 0 "$STATUS" "generator exits 0 with enrichment present"
CONTENT="$(cat "$RETRO")"
assert_contains "$CONTENT" "Total tokens:" "token total rendered"
assert_contains "$CONTENT" "openai/gpt-6-astra: 1100000" "by_model rendered"
assert_contains "$CONTENT" "high: 900000" "by_effort rendered"
assert_contains "$CONTENT" "build: 800000" "by_agent rendered"
assert_contains "$CONTENT" "unavailable — subscription auth, no authoritative price; token counts are exact" "null cost wording"
assert_contains "$CONTENT" "6 of 6 sessions matched by branch" "coverage note surfaced"

# ---------------------------------------------------------------------------
it "without an enrichment file, the token section degrades gracefully (no fabricated numbers)"
rm -f "$PROJ/.prdkit/retrospective/$FID.enrich.json"
run bash "$RS" "$FID"
assert_eq 0 "$STATUS" "generator exits 0 with no enrichment"
CONTENT="$(cat "$RETRO")"
assert_contains "$CONTENT" "No token/model enrichment found." "degradation note present"
assert_contains "$CONTENT" ".prdkit/retrospective/$FID.enrich.json" "points at the optional data contract"
assert_not_contains "$CONTENT" "Total tokens:" "no token figures without the enrichment file"

it "private-era finding keys are not silently reported as zero"
before="$(cat "$RETRO")"
echo '{"schema":"prdkit.ledger.v1","event":"review.recorded","feature":{"id":"055-telemetry"},"payload":{"scope":"task","verdict":"FAIL","findings":{"major":2}}}' >> "$PROJ/.prdkit/ledger/events.jsonl"
run bash "$RS" "$FID"
assert_eq 1 "$STATUS" "unsupported historical fields diagnosed"
assert_contains "$OUTPUT" 'translate the export' "one-off conversion explained"
assert_eq "$before" "$(cat "$RETRO")" "existing report preserved"

finish
