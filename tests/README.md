# Product-Kit validation

```bash
bash tests/run.sh
```

The suite uses Bash, standard utilities, Git, and jq 1.6+. Core helpers remain usable without
jq. CI also runs ShellCheck 0.11.0. Tests create disposable consumer
projects. The separate `CI (macOS)` workflow additionally exercises installer, upgrade, change,
status, doctor and adoption-gate behavior on macOS for every pull request and
push to main; it must pass before a merge but never gates a release.

Linux CI also reruns the adoption-gate and doctor suites with Debian 12's mawk 1.3.4 20200120
first on `PATH`. This older version lacks regex intervals; testing only a current mawk is not
equivalent. The CI step verifies the downloaded package checksum and the missing capability.

## Coverage

The cleanup and close suites use Python 3.11+ (`python3 -I`, standard library only)
for generated Git states. Without it they print a `SKIP` and run the existing Bash
cases. CI runs a fixed corpus and seed. For additional combinations, run e.g.
`PRDKIT_EXTRA_STATES=20 bash tests/test_cleanup_change.sh`; use `test_close_change.sh`
for close. Set `PRDKIT_STATE_SEED` to replay the seed in a failure (keep the same
extra count). The on-demand `CI (macOS)` run adds 12 random cases per suite.
`python3 -I tests/lib/states.py plan cleanup` prints the cases.
To inspect a single layout, build it in a **new** directory:

```bash
python3 -I tests/lib/states.py build ./state-example cleanup ./scripts 701 9 dirty untracked intent force crlf
```

Neither the generator nor its Bash helper is installed in consumer projects.

`test_review_gate.sh` exercises the native approval rule, exact SHA, trusted account IDs,
review supersession and fail-closed pagination. `test_pr_review.sh` exercises the trusted
all-PR launcher with the real gate.

Host-adapter tests use `use_gh_stub` from `tests/lib.sh`; it installs `tests/gh-stub.sh`
as `gh` on `PATH` and selects an isolated `GH_STUB_DIR`. The stub never invokes the real host.
`fx_pr`, `fx_review` and `fx_owner_review` build generic PR/review fixtures. Their optional
last argument accepts JSON overrides. Every call and page is recorded in `requests`.
`GH_STUB_OFFLINE`, `GH_STUB_FAIL` and `GH_STUB_PARTIAL` inject transport failures;
`GH_STUB_PAGE_SIZE=1` exercises cursor paging. Override `routes/graphql_PrdkitReviews-7.json`
for malformed or non-advancing pages on PR 7.

`test_new_change_linked.sh` forces overlapping automatic allocations from two linked worktrees.
Its private-copy negative control replaces the common lock with a per-worktree lock and must
reproduce the duplicate number; synchronization markers avoid a scheduler-dependent race test.

| Area | Suites |
|------|--------|
| Public catalog, neutral operations, installed references | catalog_sync, generalization, wiring, workflow_doc_coverage, workflow_contracts |
| Installer ownership, harness targets, customization preservation, retired files, malformed manifest rejection | init |
| Partial copy/storage/managed-block/manifest failures, TERM/KILL, overlapping writes and coherent retry | upgrade_recovery |
| Optional subsystems: agent tiers only on request, recorded choice, kept when used, `--without` | optional_subsystems |
| Source-less adoption integrity, managed harness entries, kit pins | adoption_gate |
| Agent tier resolution, shared baseline/overrides, projection rendering and drift | agent_tiers |
| Change numbering across checkouts, worktrees, `planned:` markers and compacted logs; no overwrites; dirty-tree refusal | new_change |
| Worktree teardown and stale registrations | cleanup_change |
| Shell escaping, path-escaping IDs, JSON safety | script_safety |
| Generated status: markers, change State and Acceptance, records, inbox, longest pole | status |
| Inbox identities/options, stale answers, format rejection and owner/agent queue separation | inbox |
| Outcome checkpoint projection: successful-change stalls, unknown/malformed accounting, worktree provenance and read-only reporting | outcome_progress |
| Diagnostics: IDs, records, layout, ceilings, citations, inbox, evidence, example spec | doctor |
| Effective provenance, ownership, winning model rules and explicit runtime unknowns | diagnostics_inventory |
| Installed version versus spec layout, unsupported inputs, unknown metadata and source-less diagnostics | adoption_state |
| Current-source consumer installation, repeated upgrades, customization and source-less helpers | consumer_smoke |
| Change bounds: constraints, non-goals and qualities in scope for a change's parts and journeys, ranges, later-stage items | bounds |
| Explicit lifecycle orders, whole multiword names, transitions, invalid classifications, single-file canon and upgrade preservation | lifecycle |
| Merge gate: record format, trusted reviewer areas and native exact-head approvals | check_review, review_record_format, review_lenses, review_gate, pr_review |
| Immutable review packages and bounded round allocation | review_package |
| Remote checkpoint observation | delivery_checkpoint |
| Context-budget advisories and strict doctor | context_budget |
| Generated navigation: shared budget/compact reader, retained authored citations, malformed footers, byte/line provenance and upgrade preservation | spec_navigation |
| Evaluation runner comply/violate behavior | evals_runner |
| Accepted-change economics, missing telemetry, independent acceptance and duplicate meters | accepted_change_benchmark |
| Version and documentation links | version, doc_links |
| Automatic release planning, CI gating and idempotent tag/release publication (maintainer tooling) | release |

Prose contracts are tested structurally only where wiring/invariants matter. Actual behavior
is exercised by [local agent evals](evals/README.md); a mock result validates runner plumbing,
not whether a real model follows the protocol. Product usefulness needs consumer pilot evidence.

[Accepted-change benchmarks](benchmarks/README.md) aggregate normalized real-run evidence locally.
Their fixture tests prove accounting behavior, not comparative model/kit performance.
