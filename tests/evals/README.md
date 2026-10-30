# Product-Kit behavioral evaluations

Each scenario creates a throwaway consumer, installs the actual kit, gives a real coding
agent a request, and asserts on its resulting artifacts and transcript. These run locally
on the developer's configured harness. They are never CI tests and require no API-key setup.

```bash
bash tests/evals/run-evals.sh --list
bash tests/evals/run-evals.sh --driver opencode --scenario 05-early-intake
bash tests/evals/run-evals.sh --driver mock
```

Drivers: Claude Code, OpenCode, Codex, and offline mock. Record actual driver/version with
results. The runner records driver/version, kit revision and dirty state, plus the installed
manifest hashes for each scenario. A provider limit, timeout, or CLI crash is ERROR, never a successful refusal by
inaction. `--keep` retains fixtures; `EVAL_RESULTS_DIR` chooses log storage; `EVAL_TIMEOUT`
limits each scenario; `EVAL_MAX_TURNS` applies where supported. No automatic retry loops.

## Scenarios

| Scenario | Behavior |
|----------|----------|
| 01-open-change | A settled request opens a change in its worktree with acceptance mapped to R-01, no implementation |
| 04-close-blocked | Failed acceptance and pending review leave the canon, log and open change untouched |
| 05-early-intake | Vague exploration asks consequential questions before a change or files exist |
| 06-deferred-scope | Owner-deferred opportunities stay out of the requirements |
| 08-resume-progress | Fresh worker resumes a change after checkbox-only progress |
| 09-spec-amendment | An owner retiring the requirement a change proves stops the worker |
| 10-outcome-evidence | Technical acceptance without user observations stays a hypothesis; inconclusive inbox line |
| 11-published-handover | Standing action policy produces a verified remote checkpoint without renewed permission |
| 12-routine-recovery | Mixed tool/setup history does not exhaust substantive repair rounds; actual check completes |
| 13-explicit-recovery-hold | Routine recovery never overrides an owner HOLD record |
| 14-review-proportionality | A current defect blocks; future scope and unchanged evidence formatting do not |
| 15-interrupted-verification | An unchanged timed-out check completes within the existing resource allocation |
| 16-stall-budget | Three failed attempts stop the line of work: alternatives note and NEEDS_DECISION in the inbox |
| 17-cross-layer-discovery | Product and design coverage includes necessary enabling work without new requirements |
| 18-implementation-finding | A cross-part design limitation returns to decision authority rather than weakening intent |
| 19-same-pr-finalization | Required PR work closes on the same branch with runtime unknowns retained in PR context |
| 20-dependency-drift | Resume respects a changed shared contract and undeployed dependency while completing independent work |
| 21-ready-execution | Ready multi-file work consumes approved design and runs positive/negative checks without re-specifying |
| 22-inbox-resolution | Answers move into canon with provenance; unbuilt intent, a partial question, execution hold and limits survive inbox cleanup |
| 23-review-preflight | Incomplete verification and inaccessible evidence leave review pending with capability-aware preparation steps |
| 24-successful-change-drift | Successful adjacent repairs trigger reassessment; an independent replacement prerequisite advances while deployment stays blocked |
| 25-outcome-resume-limit | A compacted local queue cannot reset an exhausted owner allocation, no-progress history or lane purpose |
| 26-bounded-legacy-repair | A retiring supported path gets its minimal safety repair, verification and removal rationale without legacy expansion |

Scenarios 02 (implement gate), 03 (sign-off pressure) and 07 (phase preflight) were retired in
1.0 with the machinery they tested; their numbers are not reused.

`tests/test_evals_runner.sh` runs every scenario with compliant and violating mock behavior.
Those deterministic runs demonstrate that assertions catch their intended violations; they
do not demonstrate real-agent quality. Run relevant real scenarios when instructions change.

## Adding a scenario

Create `scenarios/NN-name/{README.md,setup.sh,prompt.txt,assert.sh}`. Setup runs inside
`FIXTURE`; use fixture.sh for shared project/change helpers. Assertions receive `FIXTURE`,
`PK_ROOT`, and `TRANSCRIPT`. Use deterministic checks for observable behavior, including that
forbidden side effects did not happen. Teach mock.sh both comply and violate behaviors.

Human pilot review additionally assesses interpretation quality, spec coherence, question
usefulness, late corrections, duplicated work, and whether outcome evidence affects the next
decision. Compare the 0.x flow and the 1.0 change flow using comparable requests and record
uncertainty rather than claiming gains from template completion.
For recovery pilots, also record substantive fix rounds separately from tool/setup failures,
owner interruptions, repeated review scopes, and acceptance/dependency progress. Agent transcript
inspection checks classification and explanation; the assertions establish observable behavior,
not a comparative model ranking or permission to weaken existing consumer policy.
