# Targeted review packages

`build-review-package.sh CHANGE BASE [HEAD]` retains the full BASE..HEAD commits, diffstat and
binary diff. `--since REV` adds a focused delta using the existing trusted merge-base and
automatic-merge/fallback rules; it never replaces the full diff. `--context PATH` snapshots a
whole tracked regular file at HEAD; `--evidence PATH` copies stable local evidence without
certifying its revision, completion or applicability. `--facts` copies the exact change's
cached pair to `evidence/facts/{summary.md,index.json}` without certifying its binding.
All input paths are repository-relative. Ordinary `--evidence` cannot use the source paths
`facts` or `facts/*`, including ASCII case variants, even in a package without `--facts`.

## Read order

The package's `index.md` and the [review prompt](../templates/review-prompt-template.md) direct
reviewers to open `diff.patch` first, then `evidence/facts/summary.md` if the coordinator verified
the attached pair, then the **Review obligations** section of `index.md`. That section shows
binding BASE text and trusted default-branch policy with source pointers. Unchanged obligations
appear once. Comparisons ignore leading and trailing blank lines, but leave captured bytes
untouched and preserve every other whitespace difference. Changed text appears directly below
its BASE counterpart, marked proposed; new text is proposed only, and removals retain the
BASE text marked for review. Reviewers reconcile the proposals against BASE, as described
in the [review workflow](../workflows/review.md#review). Facts don't set obligations or grant
approval, and their bounds inventory does not show full bound bodies.

The inline excerpt budget is 16 KiB, including source labels and formatting. If the captured
material would exceed it, is not valid UTF-8 text, a BASE obligation cannot be resolved, or a
selected full or collapsed reference has no definition, the index shows no partial list and
explicitly requires reading `context-manifest.tsv`, the relevant packaged context, the bounds
inventories with their input bindings if present, and `context-gaps.txt`. Inline text permits
tab and LF but no other C0, DEL or C1 control characters. This includes rejecting CR even in
CRLF; the original artifact stays byte-for-byte. Otherwise, reviewers open
other files only to investigate a finding or resolve an obligation. The dispatcher still supplies
mandatory obligations and unresolved questions that automatic capture missed.

If neither BASE nor HEAD has spec files, the index states that no endpoint spec bounds apply.
Absence alone does not force extra reads. A closing change, including on a merged branch,
can still supply historical scope, not binding BASE acceptance. Unrecoverable history,
malformed headers, unsafe or unreadable inputs, and unresolved references are reported as gaps.
When a change introduces the first specs or removes the last ones, new specs are proposed and
removed BASE specs remain binding evidence for the review.

## What is automatic

The four-column `manifest.tsv` inventories artifacts. `context-manifest.tsv` adds
`artifact, source_rev, source_path, source_blob, first_line, last_line, obligation, reason`
(tab-separated). It includes:

- the full change record at BASE and HEAD when they differ, plus recovered historical scope on a
  closing head when not already represented;
- the union of the BASE and HEAD parents' headers, outcome checkpoints, actual child rows, and
  dependency/hold/limit sections, not whole parent records;
- spec IDs and heading links cited by the child and selected parent text, resolved at each
  source revision and including nested item bodies. Full, collapsed, and shortcut Markdown
  reference links use definitions in the same document, even outside the selected excerpt.
  Label matching folds case and collapses whitespace. Bare brackets without a matching
  definition are literal text; task-list markers are never references. Undefined full or
  collapsed references name their usage in `context-gaps.txt`. Dropping a citation or
  parent reference does not drop the BASE target; a closing record's historical context
  is labeled separately;
- the **actual** installed `bounds.sh` output on materialized HEAD canon and the actual child's
  scope when bounds inputs exist (a recovered scope record keeps its historical binding). When
  relevant inputs differ, `bounds-base.txt` and `bounds-base-inputs.tsv` capture the BASE scope
  independently. With no BASE child record, all BASE bounds are considered conservatively. An
  empty side has no spec bounds, but any scoped record header is still validated. The package
  compares bound bodies by ID across both revisions, including IDs that dropped out of
  candidate scope;
- trusted constitution and any registry/config at `policy_at`; BASE and HEAD product/architecture
  canon and `specs/design.md` where present, and conservative part/cross-interface context. The
  full diff remains authoritative for what changed. Absent conventional canon and optional
  registry/config files are not gaps, even if other specs exist.

Ambiguous IDs/headings, missing/unsafe objects, unsupported links and unverified verification
are recorded in `context-gaps.txt`, not silently discarded. Explicit snapshots keep their
HEAD bytes; when different, the BASE counterpart is also packaged. Selections are structural
context, not a recursive link crawl or proof of semantic completeness.
The reviewer needs no shell or network when the package is inside its allowed read boundary.
The builder does not render the review prompt. The dispatcher sends it and makes the
[spec review rules](../workflows/review.md#review) readable when reviewing spec edits.

Explicit whole-file snapshots remain under `context/<repo-relative-path>`; generated spans
use the disjoint `context-sections/` namespace. Repeated exact spans share an artifact while
retaining each obligation's provenance. Final artifact bytes/hashes are checked before completion.
Spec enumeration uses literal NUL-delimited Git paths; rejected entries remain named gaps.

A clean full package can be reused only for the same head, range, trusted base and policy
after checking its artifact inventory. This builder can create a fresh round for a head
packaged with the older format. Old rounds and evidence are preserved; no migration is
needed, and rebuilding is not an approval. Extra context, evidence or a focused delta needs
a fresh package. A different head can be packaged even if only the record changed.
Interrupted rounds retain their number and evidence. A completion binding is written last
by same-directory rename.

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
records commands as provenance, each marked `"audience": "maintainer-rerun-only"`. Shell-less
reviewers must not try to run them. The index also records exit statuses and results, base/head
tree IDs (which bind the committed files), and hashes of the path map, collector, local tools,
shallow boundaries if present, and CI observation. Doctor evaluates the snapshot on the effective
UTC date (`PRDKIT_TODAY` can override it); the date is hashed as an input. Unchanged inputs
produce byte-identical output; no collection timestamp is stored. The SHA-256 of the raw index
bytes in the summary detects a mixed pair. Collect and check the pair, attach it with `--facts`,
then check the copied pair at `evidence/facts/summary.md` and `evidence/facts/index.json` before
dispatch. The builder checks copy integrity, not the pair's binding or review readiness.
Regenerate older facts packs and review packages when preparing a package in the new layout;
no migration is needed.

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
