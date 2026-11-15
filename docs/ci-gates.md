# CI gates for consumer repositories

Three installed helpers provide read-only CI checks: adoption validates the installed kit,
review validates authenticated PR receipts and blockers, and strict doctor checks the spec and
agent context. Online review gating needs `gh`, `jq` and host access in every tier. Adoption,
doctor and offline review previews need no host credential; no helper needs a model credential.

## Adoption gate — `check-adoption.sh`

```
bash .prdkit/scripts/bash/check-adoption.sh
```

Verifies the reviewed adoption contract on every PR:

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

Record the expected values in the `## Configuration` section of
`.prdkit/memory/config.md` and move them together on every kit bump:

```
- adoption-pin: <full 40-hex kit commit>
- adoption-manifest-sha256: <sha256 of .prdkit/.manifest>
```

Unset keys skip their check (the gate then still validates the manifest and command
surface). The gate is manifest-driven: the pin is read from the tracked gitlink and the
expected surface from the manifest, so a `mode: copy` install passes CI with no submodule
checkout at all (a `mode: symlink` install still needs the source present for its links
to resolve). When the kit source is readable, its VERSION and shipped command set are
cross-checked as well. `--json` emits `{result, checks, findings}`.

## Review check — `check-review.sh`

```
bash .prdkit/scripts/bash/check-review.sh --pr <url> [--save-receipts <file>] [--json] [--head <rev>] [--base <rev>] [<change-id>]
```

```
bash .prdkit/scripts/bash/publish-review.sh <change-id> --pr <url> --reviewer <id> --verdict PASS|FAIL --counts <c>,<h>,<m>,<l> --report <url> --head <rev> [--since <rev>] [--from-report <file>] [--base <ref>] [--dry-run]
```

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
  change's delta from where it leaves `--base`, outside its own record and log). A blocking
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
  every path it changes since its start, outside its record and `specs/log.md`, is a regular
  non-executable file under one of them, and none is under `.prdkit/`, `.product-kit`, another
  change record or the L0/L1 spec. Unset, T0 covers only the record and the log.

The tier is the record's one `**Tier**:` field, whose whole value (up to the next `·`) is exactly
one of T0–T3 (`T1/T3`, `T1-T3`, `T1, T3` or a second field, even in a comment, fails). It may
rise, never fall. Its floor is the highest tier the record names on the default branch, on
`--base`, where the change left the base and at every commit of the branch since, and T3 when the
change edits L0 (`specs/product.md` or `specs/product/`, as `protocol.md` tiers it). A record on
the default branch, on `--base` or at the change's start whose tier field is not exactly one tier
fails the check. A record-only commit that lowers T3 to T1 after review fails and the owner's
verdict is still required. The record and `specs/log.md` stay exempt from coverage only as
regular, non-executable files (or absent) where the change starts and at the head (never a
directory, link or submodule), and a submodule's `ignore` setting never hides a gitlink change.
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
when its provenance commits are local; authenticated tokens survive an absent reviewed head.

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

Only `authority:"host"` can pass with exit **0**. For offline preview:

```bash
bash .prdkit/scripts/bash/check-review.sh --pr <url> --save-receipts receipts.txt <change-id>
bash .prdkit/scripts/bash/check-review.sh --receipts receipts.txt <change-id>  # preview pass: 3
```

Snapshots are writable, unauthenticated, US-separated normalized rows, readable with awk and
without gh/jq. They re-run local policy, fingerprints, coverage, owner slice and legacy history.
JSON reports `authority:"snapshot"`; no source reports `authority:"none"`. Human output prints
PREVIEW and fetch time. A would-be pass in either mode exits **3**, not merge authority. JSON
also reports `pr`, `pr_head`, `head_is_pr_head`, `publisher_isolation`, receipt/ignored/invalid/
carried counts, `legacy_blockers`, native `owner` metadata and `reviews[].receipt` URLs.

The legacy blocker-only scan reads active 1.x State review lines from raw Git blobs and complete
history, including deleted/edited/transferred inherited records. No 1.x PASS converts or covers.
FAIL, blocking counts and unreadable verdicts/counts stand until the same reviewer's clean full
native PASS on this PR includes them in its own reviewed history. Owner and unnamed blockers
need a valid native owner approval with the same historical proof. Lines never enter coverage.
These blockers apply to T0 and record-only changes too. Branch renaming can escape closed-PR
carry; rewriting pre-merge branch history can erase a newly introduced legacy line. Default-
branch inherited blockers are protected. The candidate's CI scripts remain part of the trust
boundary: trusted execution is not provided by this change. With shared credentials, review
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
current branch. If `--head` differs from the PR head, only fingerprint-identical metadata changes
are allowed, so an unpushed closing commit can be checked. Merge using the actual PR head.

It authenticates recorded verdicts; it does not review, and it never grants merge authority. Where the
plan offers no branch protection, the merging agent's run is the gate. CI can run it as a
visible status, with the branch history fetched. It applies to change branches only: a branch
not named after a change has no record to check. Pin each action to a full commit SHA with its
version as a comment, as the kit's own workflows do.

```yaml
- uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5 # v4.3.1
  with: { fetch-depth: 0, ref: "${{ github.event.pull_request.head.sha }}" }
- name: Authenticated review covers the head
  env:
    HEAD_REF: ${{ github.head_ref }}
    HEAD_SHA: ${{ github.event.pull_request.head.sha }}
    BASE_REF: ${{ github.base_ref }}
    PR_URL: ${{ github.event.pull_request.html_url }}
    GH_TOKEN: ${{ github.token }}
  run: |
    # actions/checkout may initialize origin without its remote-default symbolic ref.
    git remote set-head origin --auto
    case "$HEAD_REF" in
      [0-9][0-9][0-9]-*) bash .prdkit/scripts/bash/check-review.sh --pr "$PR_URL" --head "$HEAD_SHA" --base "origin/$BASE_REF" "$HEAD_REF" ;;
      *) echo "Not a change branch; no review record to check." ;;
    esac
```

It replaces the 0.x `check-signoff.sh`, but not one for one. The 0.x gate ran on every pull
request touching `gated-paths` and required a `readiness.md` with fingerprinted evidence; 1.0
drops that record, the fingerprint and `evidence-fingerprint.sh`, and checks change branches
against their own record. `init.sh --upgrade` warns while `signoff-requirements.md` still lists
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
parts, change records restating or citing undefined IDs), expired holds and waivers,
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
