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
- trusted policy/registry/config at `policy_at`, required product/architecture canon, optional
  `specs/design.md` when present, and conservative part/cross-interface context. Proposed changes
  remain in the full diff.

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

## Role digests

```bash
bash .prdkit/scripts/bash/role-digest.sh [--extra FILE]... [--config FILE] <role>
```

The digest reads the consumer's working tree, not HEAD or the trusted integration branch. It
reads `.prdkit/memory/constitution.md` first and optional `.prdkit/memory/agents.md` second
(not the root `AGENTS.md`). Then it reads the files listed in optional
`.prdkit/memory/role-digest.conf`, or in `--config FILE` if supplied, followed by `--extra` files
in flag order. The config is plain text: one literal path per line, with empty lines and lines
starting with `#` ignored. No quoting, globbing or shell expansion is applied. All paths are
relative to the consumer root; spaces are allowed, but dot components, control characters and
symlinks are not. No config is created by the installer.

Sections use the same [focused Markdown grammar](../workflows/spec.md#generated-tracking-navigation)
as `read-spec.sh`. The digest checks each entire file and assigns each line to its nearest
recognized heading: each span starts at its heading and ends before the next heading of any
level, or at EOF. Text before the first heading is not a section. The heading and body are
searched literally, line by line (including comments and code within a section). Case folding
and word boundaries are ASCII: letters, digits and `_` are word characters. Quote a multiword
role. Headings inside literal blocks do not start sections.

Each match has a `Section: path:first-last | heading | content_blob=HASH` header followed by the
exact bytes in that inclusive line range and a separating newline. The footer lists the
unfiltered Git blob ID and path of every input, including the config, or `absent` for a missing
optional file. Section hashes also use Git's blob format. The digest contains no timestamps.

Exit `0` means a complete digest, including an explicit empty notice when no sections match.
Exit `2` means bad usage, missing constitution, or a refused input. Unsupported Markdown names
the file and gives a `--raw` hint: use `read-spec.sh --raw` for a spec or open other files
directly. A refusal emits no partial digest. This evidence does not decide approval or change
any gate. It needs Git and standard tools, not jq or network access.
