# Capability observation — 2026-10-28

This is a bounded observation, not a complete compatibility certification or cost benchmark.

## Provenance

- Base: Product Kit `589589aeae2791d7e509214b9fb82b014bd59f82`, VERSION `1.2.1`.
- Source: **dirty diagnostics candidate**, not an unmodified release or a final PR revision.
- Installed manifest SHA-256: `39aebb617c9f047fd8cf4de9b8ebec16038bdfd38aaeca2b01c829bfe5c5be43`.
- Driver: OpenCode `v2.0.26`, Linux, private server (`--standalone`), configured default model.
  Exact resolved model identity was not captured in the eval result: UNKNOWN.
- Scenario: `21-ready-execution`; run `20261028-113809-4117025`; completed
  `2026-10-28T10:40:12Z`; 123 seconds; driver exit 0.
- Invocation: `EVAL_TIMEOUT=300 EVAL_DRIVER_ARGS=--standalone bash tests/evals/run-evals.sh
  --driver opencode --scenario 21-ready-execution --keep` (results redirected to private evidence).

## Results by capability

| Capability | Result | Observation |
|---|---|---|
| Consumer installation | PASS | Scenario installed actual candidate files; manifest retained |
| Bounded agent execution | PASS | Scenario assertion: `settled feature executed and checked without redefining product intent` |
| Native slash-command loading | UNKNOWN | Prompt-driven eval did not independently invoke the native slash-command mechanism |
| Structured capture | PASS, partial coverage | All 67 output lines parse as JSON; 15 step starts, 14 step finishes, 35 tool uses, 3 text events. Start/finish coverage is unreconciled |
| Runtime events | UNKNOWN | No event-specific invocation trial |
| Independent review access | UNKNOWN | This execution scenario is not a fresh-context review-access trial |
| Complete token/cost attribution | UNKNOWN | Stream coverage unresolved; reported zero step cost is not a verified billed/allocated portfolio cost |
| Full delivery / comparative quality | UNKNOWN | One scenario is not full delivery or a paired experiment |

Original setup/assert outputs, transcript, result and manifest are retained in maintainer
evidence under the run identifier above. Private paths and raw transcripts are not published.
The assertion output quoted here is a summary, not a substitute for inspecting original evidence.
Deterministic consumer smoke separately tests all installation targets, repeated upgrades and
source-less helpers; its results do not fill the UNKNOWN runtime cells in this table.
