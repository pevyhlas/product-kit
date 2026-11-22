# CI gates for consumer repositories

Three installed helpers provide read-only CI checks: adoption validates the installed kit,
review validates eligible GitHub approvals on the exact head, and strict doctor checks the spec and
agent context. Online review gating needs `gh`, `jq` and host access in every tier. Adoption,
doctor and offline review previews need no host credential; no helper needs a model credential.

## Adoption gate — `check-adoption.sh`

```
bash .prdkit/scripts/bash/check-adoption.sh
```

The default lane checks copy integrity against the install manifest and the configured
adoption restrictions on every PR. It is **not pinned-source proof**:

- the tracked kit submodule commit matches the recorded `adoption-pin`;
- `.prdkit/.manifest` exists, its `version:` matches the kit source `VERSION`, and its
  hash matches the recorded `adoption-manifest-sha256`;
- each configured harness carries exactly the kit's public commands, as regular
  copies under `mode: copy` or resolving symlinks under `mode: symlink`;
- no kit-internal bootstrap leaked into the install.
- every manifest-listed file exists, and kit-owned command/workflow/helper content matches
  its recorded hash; project-owned templates and policy may be customized;
- selected AGENTS.md/Codex targets have one intact managed entry section, whose hash is
  recorded separately so consumer text outside it remains project-owned;
- the agent tier map has no banned ids, reasonless overrides, or literal ids beside a
  shared baseline, and its vendored snapshot matches its recorded provenance (sha256 and
  library commit: this catches hand edits and baseline mismatch, not upstream origin). Once the map
  declares a `Tier baseline:`, every agent projection must exist and match the resolved
  model/variant and neutral body (`render-agents.sh --check` is the same check, and also
  runs on legacy literal maps when invoked directly).

Consumers may impose additional restrictions in the `## Configuration` section of
`.prdkit/memory/config.md`:

```
- adoption-pin: <full 40-hex kit commit>
- adoption-manifest-sha256: <sha256 of .prdkit/.manifest>
```

Unset keys skip their restriction (the gate then still validates the manifest and command
surface). The gate is manifest-driven: the pin is read from the tracked gitlink and the
expected surface from the manifest, so a `mode: copy` install passes CI with no submodule
checkout at all (a `mode: symlink` install still needs the source present for its links
to resolve). When the kit source is readable, its VERSION and shipped command set are
cross-checked as well. `--json` includes `source_verification:"not-requested"` alongside
`result`, `checks` and `findings`; a pass in this lane must not be treated as source proof.

### Strict pinned-source installation proof

```bash
bash .prdkit/scripts/bash/check-adoption.sh --require-source --json
bash .prdkit/scripts/bash/check-adoption.sh --head HEAD --json
```

These select the **installation-only** proof lane, not the default agent-tier/projection
checks. Run the default lane too when those checks are required. The source path defaults to
`.product-kit` (`adoption-source` can name another normalized repo-relative path). The exact
source revision comes from that path's gitlink in the consumer's committed `HEAD`, never its
index or the source checkout's current revision. `--head <commit>` instead reads that
consumer commit's gitlink, manifest, configuration, installed blobs, Git modes and link text.
It ignores unrelated index and working-tree substitutions; it does not certify dirty bytes.
Without `--head`, installed files and restrictions come from the working tree.

The verifier uses only local Git objects from the initialized source repository at that path:
it does not fetch, initialize a submodule, install anything, or edit config, records or the
index. Missing source repositories, commits, trees or required blobs fail strict verification.
Git replacements are disabled. On Git versions that cannot suppress partial-clone lazy
fetches, partial-clone object reads are refused.

The shared installer mapping selects the expected paths from the pinned source tree, honoring
harnesses and `agent-tiers`. Kit-owned helpers, workflows, commands and managed-section data
must match those source blobs, independently of manifest hashes. Missing/extra kit paths,
wrong Git executable modes, duplicate/missing manifest entries and wrong command links fail.
Command symlinks must name the canonical relative source path; worktree proof also checks the
bytes the links actually serve. Committed proof checks link text, not a mutable source checkout.
The AGENTS.md managed section is compared with pinned data without executing source code;
in-repository aliases work, and bytes outside the section remain project-owned.

Customized memory/templates and customized retired conffiles remain project-owned. Expected
conffiles must still exist, but their bytes, modes and prior pristine hashes need not match
the new source. Retired kit-owned helpers/commands may not remain installed. Explicit
`adoption-pin` and `adoption-manifest-sha256` restrictions still reject drift; the installer
does not silently rewrite or ignore them.

Only exit **0** with `source_verification:"verified"` establishes this source proof.
JSON also reports `scope:"installation"`, `source_revision` and `consumer_revision`.
Failure reports `source_verification:"failed"` with findings. This establishes byte/mode/link
equality to the committed pin, **not** source provenance, publisher trust, review eligibility,
release approval or permission to merge. Execute the checker and its libraries from a trusted
installation when relying on its result; candidate-controlled verification code can lie.

Once policy, publisher, release/source and committed-record prerequisites are prepared, a
consumer without additional frozen pin/hash restrictions can apply an upgrade with one
`bash .product-kit/scripts/init.sh --upgrade` command and verify it without copying hashes.
This proof alone does not make the upgrade review-free or complete the release prerequisites.

## Review check — `check-review.sh`

```bash
bash .prdkit/scripts/bash/check-review.sh --pr <url> [--head <rev>] [--base <trusted-ref>] [--json] <change-id>
```

The **2.x tier minimums are unchanged**. The gate uses the effective record tier after
checking trusted policy, the tier floor and T0 paths. It enforces these minimums on the exact PR head:

| Tier | Qualifying `APPROVED` reviews |
| --- | --- |
| T0 | None required. The structural checks and complete live host read must still pass. |
| T1, T2 | At least one independent `review-publishers` account. |
| T3 | At least one independent `review-publishers` account **and** one `review-owner` account. |

The PR author counts for neither role. An account listed in both keys counts **only as owner**;
commit authorship is irrelevant. For approval, only the account’s latest submitted review
on the exact current head counts. A new SHA needs fresh approvals.

**As in 2.x, a push does not clear an objection.** An eligible account’s `CHANGES_REQUESTED`
on **any commit of this PR** blocks every tier, including T0. The gate reads all review pages
in submission order. The objector must submit a later `APPROVED` on the exact current head,
or an owner/maintainer must dismiss the **objecting review itself** on GitHub. A comment,
approval from another account, or dismissal of a different review cannot clear it.
Pending reviews have no effect.

The checked head must match the open PR and its base must match the trusted target. Incomplete
or inconsistent pages, missing `gh`/`jq`, or an API error fail the check. With `--json`, only
`result: pass`, `authority: host` and exit 0 mean success. A structural preview without `--pr`
needs no host tools; it exits 3 if it would otherwise pass, 1 on problems. `reviews` lists
qualifying approvals; `blocking` lists outstanding objections. Both identify the account,
review ID and policy role; each blocker also records the SHA on which it was submitted
in `commit`. Project review obligations and required checks still apply.

Policy comes from the current `origin/HEAD`, never the candidate or its merge base. Configure
`review-host: github`, numeric `review-publishers` and `review-owner` on the default branch.
`--base` must resolve to the default target or a listed `review-integration-branches` ref.
The gate checks the change record, closure log, trusted Rigor, tier floor and T0 path rules.
See [the configuration template](../templates/config-template.md) for key syntax.

### Trusted all-PR execution — `check-pr-review.sh`

The launcher authenticates inputs and transports **one** native evaluation; it does not review
or grant permission to merge. An ordinary candidate-controlled workflow or same-name successful
check is not enforcement. The consumer must register an authenticated required workflow with an
immutable repository/path/source identity, protect it without bypass, and verify registration and
source-spoof rejection on the actual host. An environment assertion, event file, arbitrary SHA or
this documentation cannot establish that registration. Without it enforcement is **BLOCKED**.

This is an integration contract, **not a runnable workflow** (there is intentionally no substitute
bootstrap action or registration API):

```text
host-registered immutable required workflow W
  pull_request: opened, synchronize, reopened
  every applicable PR, forks and drafts included; no path/numbered-branch skips
  fresh GitHub-hosted ubuntu-24.04 job; finite job timeout (at least 11 minutes)
  permissions: {} by default; this job: contents: read, pull-requests: read
  trusted pre-shell constructor -> absolute trusted /bin/bash --noprofile --norc
    W's validated regular-blob launcher:
    check-pr-review.sh --repository <fixed-owner/name> --event <private-host-event-path>
```

[GitHub ruleset workflows][events] support only `pull_request`, `pull_request_target` and
`merge_group`, using their default activity types. This integration uses only `pull_request`.
A **required workflow** identifies W; a **required status check** is a different
[ruleset rule][rules]. An ordinary Actions run on `pull_request_review` is not a new
attempt of W. The launcher can consume review events in other trusted integrations;
that capability does not make GitHub dispatch them to W.

#### Refresh the required verdict

1. After **any submitted review or dismissal**, the reviewer/dismisser alerts the
   merge owner and requests a **full rerun** of W. If they lack repository write
   access, the owner does it. Use the PR's required workflow details to select
   the **latest run of W for this PR, target and current head H**. Check W's trusted
   source and its recorded event `pull_request.number` and `pull_request.head.sha`
   against the live PR. Do not select a run by job name or branch alone.
2. With the operator's existing access, use **Re-run all jobs** on that run or
   `gh run rerun RUN_ID --repo OWNER/REPO` ([GitHub instructions][rerun]).
   A rerun uses the original event SHA/ref and original actor's privileges. W
   rechecks the event bindings and fetches the **live** reviews. This works for a
   previously green run too; do not use `--failed`, start a separate workflow or
   give a write credential to the launcher. Serialize attempts. If a review changes
   during a run, discard its result and rerun once the change is visible.
3. Immediately before each merge the owner repeats the full rerun, waits for its
   new attempt, and verifies the protected PR consumes **that attempt** with a
   host pass on the still-current H and target. If the head/target changed, the
   event no longer binds, the run cannot be rerun, or the ruleset still accepts an
   earlier green result, **hold the merge**. Never waive a failed or missing run.

**Threat model: a pass is a snapshot.** Dismissal after the last live review read
(even before the job finishes) can leave a stale green check until a rerun.
Owner-coordinated merges narrow that window; they do not make review and merge
atomic. Do not use unattended auto-merge with this procedure. A [merge queue][queue]
can request checks on a new group SHA, but this PR launcher checks an individual
PR head, not a group or its constituent PRs. Adding `merge_group` to W does not
implement that mapping or check their live approvals. Consumers requiring queue
support or protection against a concurrent dismissal must keep their existing
enforcement until they have a separately verified merge-time control. Prove the
rerun behavior with the [one-PR cutover test](migrating-to-3.0.md#prove-enforcement-on-one-pilot-pr).

[events]: https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/troubleshooting-rules#supported-ruleset-workflow-events
[rules]: https://docs.github.com/en/enterprise-cloud@latest/repositories/configuring-branches-and-merges-in-your-repository/managing-rulesets/available-rules-for-rulesets
[rerun]: https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs
[queue]: https://docs.github.com/en/repositories/configuring-branches-and-merges-in-your-repository/configuring-pull-request-merges/managing-a-merge-queue

#### Launcher contract

**Before any shell starts**, W's trusted parent must construct an allowlisted environment with a
fixed fresh-host tool PATH, C locale, private HOME/GH_CONFIG_DIR/XDG_CONFIG_HOME/TMPDIR and umask
077. Preserve only authenticated host invocation values (including GITHUB_EVENT_NAME,
GITHUB_REPOSITORY, GITHUB_REPOSITORY_ID), the read-scoped GH_TOKEN and necessary trusted platform
values. Retain W's immutable source, workflow/run/event identity and event in trusted run evidence.
Never infer W's authenticity from these environment variables. Validate launcher bytes as a
contained regular Git blob (100644 or 100755) from W; no symlink/gitlink or candidate copy.

Exclude BASH_ENV, ENV, SHELLOPTS, BASHOPTS, exported BASH_FUNC_* functions, loader/language injection,
caller proxies, credential helpers and **all** inherited GIT_* variables. Unsetting them in an
already-started poisoned shell is too late. The launcher's later defensive sanitization is not
this constructor. gh/jq/Git/core tools must be installed in trusted host tool locations, not the
workspace, caller bin directory, user configuration or gh extensions. Deliver the credential only
ephemerally; never a publisher write token, persisted login or credential-bearing URL.

No candidate checkout/build/artifact execution, self-hosted runner, mutable W source or
`pull_request_target`. Any bootstrap action must be pinned to its reviewed full commit SHA with a
version comment. Target edits require a new evaluation. The consumer retains stronger content
policy, deployment evidence and no-bypass controls; this entrypoint does not authorize wrapper,
test or ruleset removal.

The launcher checks the event/live repository IDs, PR number, open state, fork/head repository,
branch and exact commit H. It separately resolves current target T and default-policy P, fetches
their complete histories into new fetch-only objects, checks exact tips, and rechecks live
bindings before accepting a result. Event base SHA remains evidence, not current T. Candidate
clone URLs, local Git state, hooks, config, replacements, alternates and credentials are never
copied. Fetch is restricted to the bound github.com HTTPS repository; no tags, filters, submodules,
shallow history or implicit object acquisition.

The exact native gate/helper closure is extracted as regular blobs from P's installed
`.prdkit/scripts/bash/`, not from H or the old merge base: `check-review.sh`, `common.sh`,
`spec-lib.sh`, its required `spec-navigation-lib.sh`, and the `review-policy-lib.sh` and
`github-reviews-lib.sh` helpers. Every entry must be a contained regular
Git blob (mode 100644 or 100755); missing helpers, symlinks and gitlinks refuse before sourcing.
The navigation parser is required even for the launcher's early policy-ref parsing; it is not
loaded from adjacent candidate or workspace files. Native `spec_trusted_refs` at P must
approve the actual target's origin ref; a non-origin/unresolved mapping cannot alias another SHA
into trust. Unique merge base S stays distinct from T and P. An exact numbered branch selects its
ID, even when closed. Otherwise exactly one ID must be introduced by the union of net additions
and **complete** S..H history (side branches and merge-created additions included), minus IDs
present at S. Git 2.31+ combined-diff capability is required; incomplete history, no/multiple bases
or zero/multiple assignments refuse. The native gate owns record recovery, closure, tier and native review evaluation.

Bounds are 600 seconds overall, 120 per acquisition/selection/extraction and 180 for the native
gate, with five seconds TERM-to-KILL grace for owned process groups. Dedicated FIFO readers cap
stdout/stderr at 4 MiB each; reaching the ceiling refuses with `capture-limit`, never truncated
success. Selector history streams are separately capped. These capture limits do **not** impose
a file-size limit on Git packs/objects or native working files. Cancellation is deferred through
each launch-to-ownership registration. Teardown stops the overall watchdog first, queues repeated
catchable signals and allows up to five seconds for capture readers to drain after writers stop.
All owned processes are terminated/reaped before deleting only the invocation's scratch.
Cleanup failure refuses. Uncatchable runner termination can leave no complete result and is not
PASS. stdout is one buffered JSON object, newline-terminated:

```json
{"launcher":"complete","error":null,"native_exit":0,"native":{}}
```

`native` is the **entire** native object, including unknown fields/diagnostics, not the empty
illustration above. `complete` means transport completed, not approval: native failures and
preview exit 3 remain nonzero. A transport refusal uses `launcher:"refused"`,
`error:{"stage":"binding","code":"context-moved"}` (for example), actual `native_exit` or null, and
any valid captured native object or null. Error classes/phases on stderr are sanitized; raw
host/tool stderr stays private to the invocation, never printed as workflow commands.

Only native exit 0, host pass, empty problems and matching change/PR/H/T/P/canonical target plus
the exact-head approvals required for that tier can exit 0. Usage exits 2; all other refusals/failures exit 1.
Missing/partial host data never falls back to offline success. Final CI certifies the actual remote H.

It replaces the 0.x `check-signoff.sh`, but not one for one. The 0.x gate ran on every pull
request touching `gated-paths` and required a `readiness.md` with fingerprinted evidence; 1.0
drops that record, the fingerprint and `evidence-fingerprint.sh`; all-PR integration requires a
unique review carrier rather than skipping unnumbered branches. `init.sh --upgrade` warns while `signoff-requirements.md` still lists
`gated-paths:`; replace the CI step and fold the review policy into the constitution's `Review
and checks` at the cutover.

## Spec and context advisories — `doctor.sh --strict`

```
bash .prdkit/scripts/bash/doctor.sh --strict
```

Doctor always fails on malformed or duplicate IDs, malformed records, installation drift,
agent definition or tier-map findings, a malformed `specs/log/<id>.md`, and a change record
deleted in history without its log entry (`check-review.sh` fails the same at close).
It reports, as advisories: a 0.x layout or two canons, a `specs/archive/` folder on main, a
`specs/archive.md` whose base commit or last 0.x feature cannot be read, agent context naming
removed 0.x paths, spec files over their reading budgets,
cited IDs that are undefined or retired (in spec files and tests), a reviewed change record
still on the default branch and in the checkout with no child or outcome checkpoint keeping it
open (merged without closing, including T0 and records with no verdict), trace
drift (`Code:` paths not in the repository, stale `planned:` markers, unallocated R/Q items and
parts, change records restating or citing undefined IDs), past-due hold reminders and expired waivers,
open inbox items and their age, retained resolved items, inbox items in the old one-line form, local machine paths in
specs and agent context, links to missing files in the spec and `specs/archive.md`, spec files
that no chain of links from
`product.md` or `architecture.md` reaches (1.1 layout; retired files exempt) and `observed.md`
pieces it does not link, a lifecycle stage naming no environment that
`specs/architecture/environments.md` lists, raw evidence under `specs/`, a stale worktree
registration, and
agent context files (`CLAUDE.md`, `AGENTS.md`, ...) over `context-budget-bytes` (default
16384; 0 disables) in the `## Configuration` section of `.prdkit/memory/config.md`.
`--strict` promotes advisories to failing findings, which makes it an opt-in CI gate; `--json`
reports `{result, findings, advisories, trace, strict, ...}`, where `trace` counts each trace
check by a stable code, so CI can ratchet a count down without failing on every advisory.

Text and JSON also report total reading lines over budget (`budget_excess_reading_lines`):
the sum of each reading-budget file's excess, not its whole size or the advisory count.
The total uses the same reading-line count as the advisories: validated generated
navigation is excluded, and a reader failure makes the total incomplete and fails doctor.
Byte-based agent context budgets are separate. Compaction due is an advisory at ten closes
since the latest compaction line in either log order, including pending `specs/log/<id>.md`
files.

The "Merged without closing" advisory needs the default-branch ref and its tree and blob
objects locally; it does not need branch ancestry. Fetch full history (for example, use
`actions/checkout` with `fetch-depth: 0`) for the separate history-based "Closed without
a log entry" check.
