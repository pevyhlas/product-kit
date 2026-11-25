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
optional file. An inaccessible path or a lookup that cannot confirm absence is refused, not
listed as `absent`. Section hashes also use Git's blob format. The digest contains no timestamps.

Exit `0` means a complete digest, including an explicit empty notice when no sections match.
Exit `2` means bad usage, missing constitution, or a refused input. Unsupported Markdown names
the file and gives a `--raw` hint: use `read-spec.sh --raw` for a spec or open other files
directly. A refusal emits no partial digest. This evidence does not decide approval or change
any gate. It needs Git and standard tools, not jq or network access.

## Exact-head facts pack

`facts.sh` collects evidence from a Git checkout at the intended commit. The live index and
working tree do not need to be clean. The [review workflow](../workflows/review.md#review)
specifies when the pack is collected, verified and attached.

Without `--head`, the current `HEAD` is used. Pass `--base` to use the same base as the package
builder; otherwise the helper uses the unique merge base with the locally available `origin/HEAD`.
It never fetches. The change record must exist at `HEAD`. Python 3.11+ (stdlib only) is needed;
`jq` isn't. Only `--pr` with `gh` available triggers a host read through `pr-state.sh`. A missing,
failed or mismatched PR snapshot is **not collected**, never green. Check names and links from
the snapshot are preserved exactly. The PR's base tip can differ from the local diff's merge base.

The local collectors run against a private, detached snapshot of committed `HEAD`, with its own
Git index, metadata and object store. They see only objects reachable from `HEAD` within the
repository's recorded shallow boundaries. That history must be available locally. Doctor's
sparse-archive proof lookup uses only those objects, so a proof commit elsewhere in the live
repository cannot affect the pack. Use standalone `doctor.sh` for live diagnostics, including
stale-worktree and default-branch advisories.

The snapshot uses raw committed bytes, not checkout filters, and does not register a worktree
or initialize submodules. Ignored files, generated link targets, live edits, local Git
configuration and other worktrees do not enter the facts. Diff whitespace uses Git defaults
and the committed attributes at `HEAD`. Symlinks must stay within the snapshot; a target not
in the snapshot stays absent.

Each collection and `--verify` builds the snapshot anew in Python's temporary directory
(`TMPDIR` on Unix when set to a usable directory). Allow space on that volume for a new,
compressed pack of the reachable history, the raw checkout of `HEAD`, and Git's index and
other temporary files. The new pack can differ in size from the consumer's existing packs.

The cache contains a `summary.md` of at most 60 lines and the full `index.json`; excess detail
is linked from the summary. The key is facts script version, base SHA, and head SHA. The index
records commands, exit statuses and results, base/head tree IDs (which bind the committed
files), and hashes of the path map, collector, local tools, shallow boundaries if present, and
CI observation. Doctor evaluates the snapshot on the effective UTC date (`PRDKIT_TODAY` can
override it); the date is hashed as an input. Unchanged inputs produce byte-identical output;
no collection timestamp is stored. The summary contains the SHA-256 of the raw index bytes to
detect a mixed pair. The package builder copies both files as ordinary `--evidence`; it does
not validate their binding or make a review decision.

The summary covers captured collector results. The bounds collector lists constraints, non-goals
and qualities; it does not assess compliance, spec or design fit, or correctness.
Collector failures are recorded in a successfully written pack. Exit 2 is a refusal (such as
bad inputs, head mismatch, unsafe snapshot links, changed inputs during collection or unsafe cache).

Use `facts.sh --verify "$id"` with the original options to recompute and compare without writing.
It exits 0 if both files match, 1 on drift (including a missing pack), or 2 on refusal. CI may
run it with a restored pack; it is advisory unless the consumer makes it a required check.
A different toolchain, evaluation date or CI state can legitimately cause drift. Packs made
before snapshot-based collection use an older version key and should be regenerated.

### Path-to-check map

Optionally commit `.prdkit/memory/review-checks.json` (a UTF-8 JSON object). The kit doesn't
install a default map or name any checks. Example with consumer-defined check names:

```json
{
  "docs/**": ["Documentation"],
  "src/**/*.py": ["Unit tests"],
  "src/public/*": ["Interface compatibility"]
}
```

Globs are case-sensitive, repository-relative and match the entire path. `*`, `?` and `[abc]`
match within one component; a whole `**` component matches zero or more components. Check
names are exact, nonempty strings. Matching rules are combined with duplicates removed.
Deleted paths count; a rename contributes both its old and new paths. Each changed path is
listed in the index even if no rule matches. A configured check absent from the PR's required
inventory is marked **not reported as required**, with no inferred result. With no map the
pack explicitly reports that it is absent.
