# Accepted-change token and cost benchmark

The unit is **portfolio cost per independently accepted change**, not tokens per successful
transcript. This is optional local research tooling using the suite's jq 1.6+ dependency;
the installer does not ship it and consumer helpers gain no dependency. It never calls a
provider or invents rates. The example is synthetic and is always labelled `kind: fixture`.

```bash
bash tests/benchmarks/report.sh tests/benchmarks/example.json
bash tests/test_accepted_change_benchmark.sh
```

The report validates the whole input before emitting a single JSON object. Redirect stdout
to a new evidence file; invalid input exits nonzero with diagnostics on stderr. Do not overwrite
an earlier report before checking the new command's result. `report.jq` is the executable v1
contract; `example.json` illustrates every input level.

## Collect an observed study

1. Freeze a task set outside worker access, with positive/negative acceptance checks and a
   blind review rubric. Include a tiny reversible fix, an interrupted/resumed feature, and a
   cross-interface change. Existing eval scenarios 21 (ready execution), 08 (resume), and 20
   (dependency drift) are useful seeds, not an interchangeable workload set or economic baseline.
   Retain setup and checks by revision/digest. Agents must not edit acceptance.
2. Predeclare tasks, repetitions, permissions, environment, review policy and budgets. Run a
   no-kit arm, Product-Kit, and optionally another kit at pinned source revisions. First study
   idiomatic defaults; use a **separate study** for matched review/acceptance obligations.
   Freeze model, effort, harness version, resolved instructions and tools. Store their digest
   in `instructions_digest`, with the original configuration in evidence. Use the same task
   order randomization/seed and budget in each arm. Keep adoption separate from steady-state.
3. Run workers in isolated consumers. Use the existing eval runner where its scenario fits:
   `EVAL_RESULTS_DIR=<evidence> EVAL_TIMEOUT=300 bash tests/evals/run-evals.sh --driver <driver>
   --scenario <scenario> --keep`. Its PASS is **not** independent acceptance. Preserve ERROR,
   failed, abandoned and interrupted attempts; do not silently rerun and keep only the winner.
4. Check final artifacts with frozen tests, then have a fresh reviewer inspect that exact
   revision without knowing the study arm where practical. Include the review session's
   usage. Record `accepted` only with both checks and independent review evidence on the final
   revision. Changed source requires fresh review evidence. A reviewer error is not approval.
5. Normalize original provider/harness usage into the contract below. This step is explicit:
   there is no universal automatic import or reliable cost inference from transcript length.
   Keep raw exports, normalizer version, pricing reference and unknown coverage. Compare
   message totals against the harness/session ledger so omitted actors do not disappear.
6. Set `kind: observed`, retain every planned matrix cell (failures count as runs), and execute
   `report.sh`. Inspect `matrix_complete`, matched harness/model, per-arm coverage and cost
   bases before comparisons. The reporter never ranks arms or asserts statistical superiority.

Real-agent runs use the developer's configured harness, local-only; they are not CI tests.
Record owner minutes, p50/p95 wall-clock latency, regressions and reopened changes alongside
the report. `summed_attempt_seconds` deliberately sums roles, including parallel work; it is
not elapsed portfolio wall-clock time. For a confidence interval, bootstrap whole paired tasks,
not individual messages, and publish the sample/seed and uncertainty. Do not claim significance
from the illustrative one-repetition fixture.

## Normalized study contract (schema_version 1)

Top level: `study_id`, `kind` (`fixture`/`observed`), `phase` (`adoption`/`steady-state`),
`task_set_revision`, `acceptance_policy`, `review_policy`, `permissions`, `environment`,
`currency`, unique `tasks`, positive integer `repetitions`, `arms`, and `runs`.

Each arm has a unique `id`, `kit_revision` (`none` for the baseline), `harness`,
`harness_version`, `model`, and `instructions_digest`. A description of defaults alone is
insufficient provenance: retain resolved instructions and the permission/model configuration.

Each run identifies `arm`, `task`, and `replicate` (1-based). Exactly one run may occupy a cell;
put retries/repairs/resumes in its `attempts`, not extra successful-looking cells. `outcome` is
`accepted`, `failed`, `abandoned` or `error`. Retain `final_revision` even for failure (use an
explicit unavailable identifier for failures before checkout); accepted revisions must resolve
to the reviewed artifact in retained evidence. Nonaccepted runs have `acceptance: null`.

Accepted runs require `acceptance.result: pass`, `revision` equal to `final_revision`,
`reviewer`, `checks_evidence` and `review_evidence`. The reviewer must appear as a reviewer
attempt and differ from implementation agents/contexts. These checks validate recorded claims;
they cannot prove that identities are truthful or that a review was competent.

Each attempt records unique-within-run `id`, `agent`, `session`, `role`, `transcript`, integer
`elapsed_s`, `usage_status`, and `messages`. Include researcher, worker, reviewer, repair and
resumed contexts. `usage_status` is:

- `complete`: capture claims every model call, with at least one message;
- `partial`: some calls/counters were captured, with known gaps;
- `unknown`: coverage is unknown, even if some messages are available;
- `none`: explicitly no model calls (for example a manual check); messages must be empty.

A message has a globally unique `meter_id`, original `evidence`, `tokens` and `cost`.
Namespace the meter with provider/request identity; resumed exports must preserve it. A replayed
meter is rejected rather than counted twice. Do not include a provider's session total beside
its component messages. For aggregate-only exports, use one explicit aggregate meter and never
also include its component calls; record the limited granularity in evidence.

Token counters are **disjoint**, nonnegative integers or `null`:
`uncached_input`, `cache_read`, `cache_write`, `output`, `reasoning`.
Provider meanings differ. Subtract included cache categories from total input where appropriate;
if output already includes reasoning, split it only when the provider gives that breakdown.
Otherwise retain unknown components as `null` and document the source aggregate separately.
Do not count cache writes twice, sum cumulative snapshots, or treat a missing field as zero.
`0` means measured/known absence. Categories sum to this study's normalized token count, not
necessarily the provider's invoice unit. Never add input and a cached subset unchanged.

Cost is `{amount, basis, reference}` in the study currency. `amount` is nonnegative or `null`;
known bases are `billed`, `estimated`, `subscription-allocated`; absent amounts use `unknown`.
Known amounts require the original billing/pricing/allocation reference. Zero subscription
marginal charges do not mean zero allocated economic cost; keep those studies/bases distinct.
Do not convert currency or estimate prices silently.

## Reading the result

- All runs/roles enter the numerator, including failures, abandoned work and reviewers.
- `observed_tokens` and `observed_cost` sum known values only; with gaps they are incomplete
  observations, **not total cost**. Known estimated prices remain estimates, not billed dollars.
- `total_tokens`/`total_cost` and per-accepted-change metrics are null if their coverage is
  incomplete. No accepted changes also makes per-accepted metrics null, never zero.
- Token and cost completeness are separate: a billing total can be known despite missing
  token breakdown, or vice versa. Cost bases remain explicit in `cost_bases`/`cost_by_basis`.
- `declared_complete_attempts` counts capture declarations, not percentage of actual tokens
  covered; counters and prices can still be unknown within them. Omitted sessions cannot be
  detected without the independent roster/ledger reconciliation above.
- `matrix_complete` checks expected arm × task × repetition coverage. Partial experiments may
  be reported descriptively; do not treat an easy subset as a matched comparison.

Keep original outputs in durable evidence, with public summaries redacted. Do not commit private
transcripts, credentials, machine paths or provider account metadata. An observed benchmark
requires actual runs; the committed fixture and CI assertions establish accounting only.
