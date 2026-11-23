# CI gates for consumer repositories

Three installed helpers provide read-only CI checks: adoption validates the installed kit,
review validates authenticated PR receipts and blockers, and strict doctor checks the spec and
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
Both adoption lanes expect a non-empty LF-terminated manifest and, when present, adoption
configuration. A failed or incomplete inventory is not a clean result.

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

```
bash .prdkit/scripts/bash/check-review.sh --pr <url> [--save-receipts <file>] [--json] [--head <rev>] [--base <rev>] [<change-id>]
```

```
bash /trusted-install/.prdkit/scripts/bash/publish-review.sh <change-id> --repo <fetch-only-clone> --pr <url> --reviewer <id> --verdict PASS|FAIL --counts <c>,<h>,<m>,<l> --report <url> --head <rev> [--since <rev>] [--from-report <file>] [--base <ref>] [--dry-run]
```

The publisher runs the helper and its libraries from the trusted default branch or a pinned
kit install, never from a PR checkout. `--repo` points at a fetch-only clone; do not execute its
code. A publisher CI job must never run PR-controlled code with the publisher key, including a
`pull_request` job with secrets. The gate's candidate-script residual is not permission to
expose publishing credentials to candidate code.

Reviews are run by the worker, never by CI: the worker dispatches the tier's independent
reviewers (`protocol.md`) and preserves each report verbatim. A trusted publisher posts its
content-bound v3 verdict in a submitted COMMENT review; repository text authenticates nothing.
Before merging, the merging agent runs the online check on the exact head it
merges (`--head <sha>`, then `gh pr merge --match-head-commit <sha>`). It passes when:

- every latest receipt verdict, in any tier, is PASS with no critical or high finding (no medium
  either under `Rigor: full`, or when the trusted constitution names no single Rigor); a
  reviewer's later receipt supersedes its earlier one in host order;
- no blocking line stands: a blocking line (a FAIL, or counts that block for the Rigor or
  cannot be read) by a reviewer at some content stands until a later clean PASS from the same
  reviewer, over a non-empty range, starts at `start` (a full re-review) or at content reachable
  from the failed content through that reviewer's own later lines; only the latter makes its
  range link. A blocking end that names no content here stands unless a later clean full
  re-review follows. Returning to earlier content or rewriting history never clears it;
- the reviews cover the change: each range end is `start` (no change) or `fp1:<sha256>` (the
  change's delta from where it leaves `--base`, outside its own record and closing metadata).
  Shared-log edits are included except for one validated new line closing the selected change. A blocking
  receipt may end at `none`, which gives no content coverage. Every non-blocking PASS range,
  superseded rounds included, links its two
  contents, and so does a blocking range resolved through the reviewer's own later lines. Each
  reviewer's reviewed content must link to this head's content (`fingerprint` in `--json`), and
  for T1–T3 so must `start`, so narrow re-reviews of fixes chain while a gap fails. A rebase, a
  squash, a reverted edit and a base merge that does not overlap keep the content; a fix or an
  overlapping base merge (`review.md`, Merge) changes it. Empty coverage ranges are refused;
  validated empty full PASS legacy-clearance receipts remain start-to-start verdicts and grant
  no edge. Adding content expires their clearance without invalidating them; a head already
  inside `--base` fails;
- the tier's minimum is present: one independent verdict for T1–T3, plus native owner approval
  for T3. The latest decisive owner review must be APPROVED, its GraphQL commit must equal the
  head strictly before submission in the activity log, and its L0/L1 fingerprint must equal this
  head's. CHANGES_REQUESTED and DISMISSED are barriers. A code fix or
  rebase can keep approval, while an L0/L1 edit voids it. Which concerns a T2 change
  needed is the worker's call; the check sees only what is recorded;
- the tier holds (see Policy from the trusted base below).

### Policy from the trusted base

The check never takes its policy from the change or the caller. Its policy snapshot is the
current tip of `origin/HEAD`'s target, the default branch (`policy_at` in `--json`), whatever
`--base` says; without `origin/HEAD` the check fails. `--base` only locates the change's start: it
must be `origin/HEAD`'s target or one of the `review-integration-branches` in its committed
`.prdkit/memory/config.md`, and any other `--base` (a local branch, a raw commit hash, an unlisted
remote branch) fails. At the policy snapshot it reads:

- **Rigor** from `.prdkit/memory/constitution.md`: exactly one Rigor line whose value is `light`
  or `full`, alone or followed by a space and a note. Anything else (none, two, `light/full`)
  fails the check and blocks medium findings. A branch that edits its own Rigor is still checked
  under the trusted one, with a note; the edit applies once it merges.
- **The reviewer registry** from `.prdkit/memory/agents.md` (below). A reviewer revoked there no
  longer counts, whatever the branch's merge base said.
- **Receipt policy** from `.prdkit/memory/config.md`: `review-host: github`, non-empty numeric
  `review-publishers` (`bot:<id>` and/or `user:<id>`), personal `review-owner` ids (`user:<id>`),
  and `review-publisher-isolation: required|shared`. Missing or malformed keys fail. Required
  isolation rejects the PR author as publisher; shared mode reports its independence limitation.
- **`review-t0-paths`** from `.prdkit/memory/config.md`: literal paths, a trailing `/` naming a
  directory (for example `- review-t0-paths: docs/, README.md`). A T0 change passes only when
  every path it changes since its start, outside its record and closing metadata, is a regular
  non-executable file under one of them, and none is under `.prdkit/`, `.product-kit`, another
  change record or the L0/L1 spec. Unset, T0 covers only the record and its validated closing
  metadata. Other shared-log edits follow the normal tier and allowlist rules.

The tier is the record's one `**Tier**:` field, whose whole value (up to the next `·`) is exactly
one of T0–T3 (`T1/T3`, `T1-T3`, `T1, T3` or a second field, even in a comment, fails). It may
rise, never fall. Its floor is the highest tier the record names on the default branch, on
`--base`, where the change left the base and at every commit of the branch since, and T3 when the
change edits L0 (`specs/product.md` or `specs/product/`, as `protocol.md` tiers it). A record on
the default branch, on `--base` or at the change's start whose tier field is not exactly one tier
fails the check. A record-only commit that lowers T3 to T1 after review fails and the owner's
verdict is still required. Exempt record or log content must be in regular, non-executable
files (or absent) where the change starts and at the head, never a directory, link or submodule.
A submodule's `ignore` setting never hides a gitlink change.
To land a policy change, merge it first in its own pull request, checked under the policy it
replaces.

### Reviewer eligibility and authenticated receipts

Every covering receipt must name an eligible identity in `.prdkit/memory/agents.md` at the
trusted base's current tip (`registry_at`, the same as `policy_at`). Without `origin/HEAD` no
identity is registered; an arbitrary `--base` or local main/master cannot supply its own policy.
A change cannot add its own maker to the registry and approve itself.
Use a `## Review registry` section with `| Identity | Role |` columns and exact roles `reviewer`
or `maker`. Lowercase identifiers may contain letters, digits, dots, underscores and hyphens.
A maker is denied even if also listed as a reviewer; duplicate or invalid roles are ambiguous.
Legacy `| Role | Available agent or human | Notes |` capability rows also work when they name an
exact identity and the role is `Independent review`/`Review` or `Implementation`/`Maker`.
Placeholders and free-form descriptions are not registrations. `owner` remains a reserved verdict.

**Adoption:** establish the advertised remote default (`git remote set-head origin --auto` after
fetching its history), and integrate the identities used by receipts before enabling
the updated gate. Existing concern labels such as `code` must become registered review identities, or be
reconciled with actual reviewer evidence. Preserve unresolved FAILs; deleting an ineligible
identity is not a clean verdict. Registry checking tests declared eligibility, not session independence.

GraphQL authenticates the publisher by author typename plus numeric database id, never login,
text or `viewer` typename. Each submitted publisher review must contain exactly one valid v3
block. Any edit marker, malformed block, wrong repo/PR, conflicting id or fingerprint mismatch
blocks. Identical retries are no-ops in their first host position. Non-publisher copies are ignored
and counted. Tokens are recomputed against the receipt's `base_at`, not today's advanced base,
using local provenance objects. An absent endpoint or a match only under the former shared-log
exclusion retains blocking history but grants no coverage or clearance. If this is a reviewer's
latest receipt, a different reviewer's PASS cannot replace it: obtain a corrected full PASS.

`--pr` reads every page, this PR's blockers for every change, and standing blockers from closed,
unmerged PRs of the same head branch. Earlier deliveries never grant coverage. Merged PRs supply
only restatements; repairs retain the origin PR's position and scope. See the
[review workflow](../workflows/review.md#repairing-an-edited-or-invalid-receipt) for publisher
logs and recovery. Logs live outside working trees under the absolute Git common directory,
`$(git -C <fetch-clone> rev-parse --git-common-dir)/prdkit/receipts/`, and must never be
maker-writable. Symlinked log components are refused; old `.prdkit/cache/receipts/` logs are
neither read nor migrated. A repair must have the original review author's typename and numeric id.
API errors, missing `gh`/`jq` and partial/non-advancing pages are
`authority:"unavailable"`, exit 1, never an empty list.

The owner's native approval is not a receipt. The activity guard requests ascending order,
includes merges/deletions, rejects same-second submission ties, and checks continuity only in
the deciding window. Retention is unknown. An undetermined approval needs a new push (even a
record-only commit) and re-approval. An absent approved commit names the required fetch. No
owner text or relay can replace this; the owner cannot self-approve a T3 PR.
CHANGES_REQUESTED blocks the entire current PR before every coverage exemption, even when
the carrier is missing. DISMISSED is a distinct revocation barrier. Barriers are per configured
numeric owner actor: only that issuer's later APPROVED review, after the same native provenance,
non-self-approval, activity, object and L0/L1 freshness checks, can clear it. COMMENTED/PENDING,
another owner's approval and record/tier edits cannot. An invalid later approval preserves the
negative and its diagnosis. No decisive event adds no positive requirement to otherwise exempt
PRs. Substantive T3 and owner/unnamed legacy-history clearance retain their separate requirements.
Unknown/missing identity or state, duplicate review ids and incomplete streams are unavailable,
not empty. This current-PR check grants no cross-PR coverage.

Only `authority:"host"` can pass with exit **0**. For offline preview:

```bash
bash .prdkit/scripts/bash/check-review.sh --pr <url> --save-receipts receipts.txt <change-id>
bash .prdkit/scripts/bash/check-review.sh --receipts receipts.txt <change-id>  # preview pass: 3
```

Snapshots are writable, unauthenticated, US-separated normalized rows, readable with awk and
without gh/jq. They re-run local policy, fingerprints, coverage, owner slice and legacy history.
The header is `prdkit-receipts 2`; owner rows append the authenticated `user:<database-id>`
actor after the existing review/time/state/commit/submission-head fields. Version 1 snapshots
are refused, not used to infer multi-owner clearance; capture a fresh snapshot with the current
checker. This does not change verdict receipt v3 or `fp1`.
JSON reports `authority:"snapshot"`; no source reports `authority:"none"`. Whenever authority is
not `host` (including `unavailable`), JSON `result` is `preview`, even when problems exist.
Consumers must inspect authority, problems and exit status: exit 1 is failure and 3 is a
would-pass preview; only a host-authority pass exits 0. Human output prints
PREVIEW and fetch time. A would-be pass in either mode exits **3**, not merge authority. JSON
also reports `pr`, `pr_head`, `head_is_pr_head`, `publisher_isolation`, receipt/ignored/invalid/
carried counts, `legacy_blockers`, native `owner` metadata and `reviews[].receipt` URLs.
The existing `owner` fields still describe the latest decisive event; `owner.actor` identifies
its actor, while `owner.barriers[]` reports each standing actor/review/state and distinct reason
(including an invalid later clearing attempt). `problems` includes these barriers at every tier.

The legacy blocker-only scan reads active 1.x State review lines from raw Git blobs and complete
history, including deleted/edited/transferred inherited records. No 1.x PASS converts or covers.
FAIL, blocking counts and unreadable verdicts/counts stand until the same reviewer's clean full
native PASS on this PR includes them in its own reviewed history. Owner and unnamed blockers
need a valid native owner approval with the same historical proof. Lines never enter coverage.
These blockers apply to T0 and record-only changes too. Branch renaming can escape closed-PR
carry; rewriting pre-merge branch history can erase a newly introduced legacy line. Default-
branch inherited blockers are protected. The ordinary gate does not authenticate its own execution
source; use the trusted all-PR boundary below for enforcement. With shared credentials, review
independence remains a deployment property, not something the host can prove.

A closing commit that deletes the record is checked against the record's last committed
version; `close-change.sh` makes that commit only after the check passes. A passing check whose
record is still at the head, with no child or outcome checkpoint, prints a note and reports
`"record_open":true` in `--json`; a project whose changes each close in one PR can fail its CI on
that. A programme parent's planning PR reports it too until its first child or outcome checkpoint
exists. Finalize new implementation
changes in their own PR, retaining context and evidence on that PR before deleting the record; no
cleanup-only PR is required. Auxiliary tracked plans are ordinary reviewed paths: removing them
after PASS invalidates coverage. Remove them before final review, or use ignored execution scratch
with useful context on the PR.

For a PR finalizing several changes, use the containing implementation record as review carrier
([review workflow](../workflows/review.md#review-carrier)). It inherits all required acceptance,
unresolved findings and the combined tier/reviewer concerns. Log/delete the other records before
the combined final review, then finalize only the carrier after PASS. Check the carrier ID; the
helper does not automatically transfer obligations or exempt sibling record deletions.

For compatibility, a pull request that carries only the record and the log since a trusted base,
including an old change's explicit disposition, skips coverage. Fingerprints, like that
exemption, are computed only against a trusted base; both trust only the remote default
identified by `origin/HEAD`, plus `review-integration-branches` in `.prdkit/memory/config.md` read
from that default's committed snapshot (for example `- review-integration-branches: origin/develop`).
A change cannot whitelist itself through its own config. Missing/duplicate settings grant no
additional trust. Establish `origin/HEAD` before relying on an exemption; blocker enumeration
still requires the online host in every tier.

Without `--base` the check uses `origin/HEAD`; it no longer falls back to `origin/main`,
`origin/master`, `main` or `master`, and an explicit base must be trusted as above. JSON exposes
`base_trusted` and `policy_at`. Name the actual PR target; a stacked branch whose target is not a
configured integration branch cannot pass until that target is configured. Only receipts on
this PR cover its checked change; earlier PASSes never carry. The change id defaults to the
current branch. Online, the PR head must be a local ancestor of `--head`, otherwise authority is
unavailable. A differing descendant must also be fingerprint-identical, so an unpushed closing
commit can be checked. Merge using the actual PR head.

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
  pull_request: opened, reopened, synchronize, edited, ready_for_review, converted_to_draft
  every applicable PR, forks and drafts included; no path/numbered-branch skips
  fresh GitHub-hosted ubuntu-24.04 job; finite job timeout (at least 11 minutes)
  permissions: {} by default; this job: contents: read, pull-requests: read
  trusted pre-shell constructor -> absolute trusted /bin/bash --noprofile --norc
    W's validated regular-blob launcher:
    check-pr-review.sh --repository <fixed-owner/name> --event <private-host-event-path>
```

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
this constructor. Install gh, jq, Git and core tools in trusted host tool locations, not the
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
`spec-lib.sh`, its required `spec-navigation-lib.sh`, and the `review-policy-lib.sh`,
`review-fingerprint-lib.sh`, `review-coverage-lib.sh`, `review-receipts-lib.sh`,
`review-owner-lib.sh` and `review-legacy-lib.sh` helpers. Every entry must be a contained regular
Git blob (mode 100644 or 100755); missing helpers, symlinks and gitlinks refuse before sourcing.
The navigation parser is required even for the launcher's early policy-ref parsing; it is not
loaded from adjacent candidate or workspace files. Native `spec_trusted_refs` at P must
approve the actual target's origin ref; a non-origin/unresolved mapping cannot alias another SHA
into trust. Unique merge base S stays distinct from T and P. An exact numbered branch selects its
ID, even when closed. Otherwise exactly one ID must be introduced by the union of net additions
and **complete** S..H history (side branches and merge-created additions included), minus IDs
present at S. Git 2.31+ combined-diff capability is required; incomplete history, no/multiple bases
or zero/multiple assignments refuse. The native gate owns record recovery, closure, tier,
fingerprints, owner events, receipts, coverage and sibling-deletion checks.

The launcher checks a 600-second overall budget, with up to 120 seconds per acquisition,
selection or extraction and 180 seconds for the native gate before cleanup. FIFO readers cap
stdout and stderr at 4 MiB each; native output at the ceiling refuses with `capture-limit`, never
truncated success. Selector history streams are separately capped. These limits do **not** cap
Git objects or native working files.

The launcher queues catchable cancellation, including during startup and cleanup. Only a group’s
own guard leader may signal it; the launcher sends private FIFO requests, never signals to a
remembered process-group ID. If required, the guard sends TERM, allows five seconds, and sends
KILL at most once, ending the guard itself. After release or KILL, the launcher only observes.
It polls the process table without calling `wait` on a leader, and treats ambiguous states
(including Linux `Zl`) as live. It allows readers a separate five-second drain window. If
shutdown or drain cannot be verified, it refuses with `cleanup-failed` and retains scratch.
If KILL prevents reporting the native exit, `native_exit` is null. This checks supervised
process groups; it does not contain processes that leave them. Uncatchable runner termination
can leave no complete result and is not PASS. stdout is one buffered JSON object,
newline-terminated:

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
ready/content-bound diagnostics can exit 0. Usage exits 2; all other refusals/failures exit 1.
Missing/partial host data never falls back to offline success. Final CI certifies actual remote H,
not the ordinary gate's permitted local metadata-only closing descendant.

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
