# Targeted review packages

`build-review-package.sh CHANGE BASE [HEAD]` retains the full BASE..HEAD commits, diffstat and
binary diff. `--since REV` adds a focused delta using the existing trusted merge-base and
automatic-merge/fallback rules; it never replaces the full diff. `--context PATH` snapshots a
whole tracked regular file at HEAD; `--evidence PATH` copies stable local evidence without
certifying its revision, completion or applicability. All paths are repository-relative.

## What is automatic

The four-column `manifest.tsv` inventories artifacts. `context-manifest.tsv` adds
`artifact, source_rev, source_path, source_blob, first_line, last_line, obligation, reason`
(tab-separated). It includes:

- the actual change record, in full, or its recovered historical source on a closing head;
- the parent's header, outcome checkpoint, actual child row and dependency/hold/limit sections,
  not a whole-parent default;
- uniquely resolved child spec IDs and heading-linked blocks, including nested item bodies;
- the **actual** installed `bounds.sh` output on materialized HEAD canon and the actual child's
  scope, with all input blobs inventoried (a recovered scope record keeps its historical binding);
- trusted policy/registry/config at `policy_at`, required product/architecture canon and
  conservative part/cross-interface context. Proposed changes remain in the full diff.

Ambiguous IDs/headings, missing/unsafe objects, unsupported links and unverified verification
are recorded in `context-gaps.txt`, not silently discarded. Whole-file explicit selections
remain available. Selections are structural context, never proof of semantic completeness.
The reviewer needs no shell or network when the package is inside its allowed read boundary.
The builder does not render the review prompt. The dispatcher sends it and makes the
[spec review rules](../workflows/review.md#review) readable when reviewing spec edits.

Explicit whole-file snapshots remain under `context/<repo-relative-path>`; generated spans
use the disjoint `context-sections/` namespace. Repeated exact spans share an artifact while
retaining each obligation's provenance. Final artifact bytes/hashes are checked before completion.
Spec enumeration uses literal NUL-delimited Git paths; rejected entries remain named gaps.

An unchanged `--since` range refuses with **no round needed**. The latest comparable completed
package is fingerprinted from its actual head and recorded base tip, not a saved digest or
today's base tip. Equal fingerprints allow automatic reuse only for clean, ordinary full packages
with the same base branch, range start, trusted policy revision and committed tree. A changed
closed head is rebuilt because its historical record can differ. Extra context, evidence, a
focused patch or live gate inputs also prevent automatic reuse. Interrupted rounds
retain evidence and numbering; their existence does not prove completion. A completion binding
is published last by same-directory rename. Empty, unterminated or malformed historical
bindings remain incomplete evidence, preserving numbering and ordinary unknown-comparison
previews. Allocation/comparison/assembly share an exclusive directory/verified private-inode
claim; a busy call
refuses rather than opening another round. An interrupted lock requires explicit reconciliation;
never erase failure evidence. Unknown fingerprints do not mean equal or changed: targeted
requests fail before allocation, while ordinary full structural previews remain available.

All existing guard leaves (regular, directory, FIFO or symlink, including dangling/nonregular
targets) refuse without opening or reclaiming them. Directory creation and a same-filesystem
hard-linked private claim establish ownership; a leaf type precheck alone does not. Cleanup
is unarmed until claim confirmation and verifies the owned inode before release. Interrupted
or unsupported claims can remain stale for explicit reconciliation; no automatic lock repair,
new runtime dependency or implicit host operation is attempted.

## Optional host facts and advisory map

`--pr https://github.com/owner/repository/pull/7` captures `gate.json`, `gate.status` and
`gate.stderr` from the existing `check-review.sh --json --diagnostics` evaluation.
Existing JSON fields and gate exits do not change; diagnostics are additive facts collected
at the native eligibility, coverage, scope and blocker predicates.

`dispatch.json` distinguishes **retained now**, **review_now**, and **prospective_carry**.
Only a complete fresh host evaluation bound to this PR, content, trusted integration tip and
policy establishes retention. The gate's metadata-only descendant case is allowed; unpublished
changed code is unbound. Missing tools, partial reads, unavailable owner activity, malformed
diagnostics or mismatched bindings produce `coverage=unknown`, `dispatch=pending`, and null
lists (not an empty required panel). Cached files/snapshots never restore host authority.
No fetch, publication, credential change or publisher key is required.

For a reduced **advisory** recommendation add `--review-plan PATH` with `--pr` and `--since`.
JSON is data, never sourced. This minimal contract uses **whole changed entries**, not a hunk
schema. Supply every prior reviewer and every additional applicable concern under existing
project policy; concern selection remains the lead's judgment, not mandatory generic ceremony.
Exactly one JSON object is accepted, and that same copied object is consumed. Prior current-PR
identities include valid receipts for other changes, without granting those receipts coverage.
Standing native, scope or uncleared legacy blockers exclude the identity from retained and
prospective classifications; cleared historical rows do not become new blockers.

```json
{
  "change": "001-example",
  "pr": "https://github.com/owner/repository/pull/7",
  "head": "<exact commit>",
  "since": "<earlier reviewed commit>",
  "base_ref": "refs/remotes/origin/main",
  "base_at": "<frozen trusted integration tip>",
  "policy_at": "<frozen trusted default tip>",
  "reviewers": [
    {"id":"code","action":"review","reason":"inspect whole fix and cross-boundary effects",
     "obligations":["P1.B-01"],"references":["<native receipt URL>"]},
    {"id":"security","action":"unaffected","reason":"explicit lead scope judgment, not approval",
     "obligations":["P1.B-01"],"references":["<native receipt URL>"]}
  ],
  "fixes": [
    {"path":"src/example.txt","reviewers":["code"],"obligations":["P1.B-01"],
     "receipt":"<native receipt URL>","finding":"high-1"}
  ],
  "context": [
    {"path":"specs/parts/p1.md","selector":"Behavior","reason":"affected section"}
  ]
}
```

Bindings are exact; scripts compute fingerprints. Identities must be eligible at trusted
policy. Reasons, obligations and report/finding references are nonempty, duplicates are refused.
Obligations resolve to unique spec IDs or `path#unique-heading` (trusted policy paths use
`policy_at`). `context` selects a unique exact heading or its ordinary Markdown slug, through
all subsections. Unsupported/ambiguous Markdown requires explicit context, not a guessed sibling.
`references` and `receipt` name native receipt URLs observed by the evaluator, or `new-change`
for an additional concern/new work. A locator identifies a finding in that report; the selected
reviewer, not a parser, decides whether it is fixed.

Every changed entry must be assigned, including metadata and merge resolutions. Canonical
stream changes are also accounted for. If automatic merge is unavailable, accounting
conservatively includes every full-diff entry so omitted resolutions cannot disappear.
Missing/invalid assignments, omitted prior identities, ineligible concerns or unresolved
obligations disable reduced selection and remain `scope_pending`. Standing blockers always
remain actions regardless of the map. Native, foreign, carried, legacy, invalid, owner and
structural blockers remain alongside the recommendation; replacement reviews do not repair
invalid receipts or change tier floors.

Example: security PASS(start→F1), code FAIL(start→F1), fix F2. A valid map assigning the entire
fix to code and explaining security unaffected gives `review_now=[code]`,
`prospective_carry=[security]`, `retained=[]`; **the gate still FAILs**. Prospective carry
requires actual accepted edges reaching F1 from security's clean endpoint and from start,
and every standing checked-change blocker of the named delta reviewer ending exactly at F1.
More complex anchors require a scope decision/full review. Only an actual clean native
F1→F2 receipt from that reviewer, followed by a fresh online gate check, establishes carry.
A full start→F2 replacement may clear its own FAIL without bridging security's old endpoint.
Another reviewer's PASS never clears that FAIL. No hypothetical verdict enters any gate array.

Dispatch remains pending while verification/context or other obligations need human/agent
reconciliation. A retained coverage fact is not whole-gate approval, and a scope map never
proves independence, unaffected semantics or finding closure.
