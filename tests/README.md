# Product-Kit validation

```bash
bash tests/run.sh
```

The suite uses Bash, standard utilities, Git, and jq 1.6+ for enrichment tests. Core helpers
remain usable without jq. CI also runs ShellCheck 0.11.0. Tests create disposable consumer
projects. The separate `CI (macOS)` workflow additionally exercises installer, upgrade, change,
status, doctor, adoption-gate and retrospective behavior on macOS for every pull request and
push to main; it must pass before a merge but never gates a release.

## Coverage

| Area | Suites |
|------|--------|
| Public catalog, neutral operations, installed references | catalog_sync, generalization, wiring, workflow_doc_coverage, workflow_contracts |
| Installer ownership, harness targets, preservation, retired-file removal | init |
| 0.17 to 1.0 upgrade: retired files, untouched `specs/`, cutover message, gate warning, leftover features, a cutover that removes every 0.x folder, ignored leftovers, stale agent context | upgrade_1_0 |
| Source-less adoption integrity, managed harness entries, kit pins | adoption_gate |
| Agent tier resolution, shared baseline/overrides, projection rendering and drift | agent_tiers |
| Change numbering across checkouts, worktrees, `planned:` markers and retired 0.x numbers (folders, `specs/archive.md`, git history, shallow clones), never overwriting, dirty-tree refusal | new_change |
| Worktree teardown and stale registrations | cleanup_change |
| Shell escaping, path-escaping IDs, JSON safety | script_safety |
| Generated status: markers, change State and Acceptance, records, inbox, longest pole | status |
| Diagnostics: IDs, records, layout, ceilings, citations, inbox, evidence, example spec | doctor |
| Change bounds: constraints, non-goals and qualities in scope for a change's parts and journeys, ranges, later-stage items | bounds |
| Merge gate: recorded review verdicts cover the merged head, per tier and rigor | check_review |
| Immutable review packages and bounded round allocation | review_package |
| Remote checkpoint observation | delivery_checkpoint |
| Context-budget advisories and strict doctor | context_budget |
| Valid JSON envelopes, local/external ledger delivery and schema wiring | ledger_emit, ledger_schema |
| Durable central-spool attribution and path boundaries | spool_adapter |
| Retrospective input boundaries and optional enrichment | retrospective, retrospective_boundaries |
| Evaluation runner comply/violate behavior | evals_runner |
| Version and documentation links | version, doc_links |
| Automatic release planning, CI gating and idempotent tag/release publication (maintainer tooling) | release |

Prose contracts are tested structurally only where wiring/invariants matter. Actual behavior
is exercised by [local agent evals](evals/README.md); a mock result validates runner plumbing,
not whether a real model follows the protocol. Product usefulness needs consumer pilot evidence.
