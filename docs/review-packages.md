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

A clean full package can be reused only for the same head, range, trusted base and policy
after checking its artifact inventory. Extra context, evidence or a focused delta needs a fresh package. A different
head can be packaged even if only the record changed. Interrupted rounds retain their number
and evidence. A completion binding is written last by same-directory rename.

All existing guard leaves (regular, directory, FIFO or symlink, including dangling/nonregular
targets) refuse without opening or reclaiming them. Directory creation and a same-filesystem
hard-linked private claim establish ownership; a leaf type precheck alone does not. Cleanup
is unarmed until claim confirmation and verifies the owned inode before release. Interrupted
or unsupported claims can remain stale for explicit reconciliation; no automatic lock repair,
new runtime dependency or implicit host operation is attempted.
