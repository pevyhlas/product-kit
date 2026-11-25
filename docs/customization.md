# Project-owned customization

| Surface | Owns |
|---------|------|
| `specs/` | The spec, change records, inbox, records and log: entirely yours, never edited by the installer |
| `.prdkit/memory/constitution.md` | Intent owner, Rigor, action policy, actual commands, review and checks, principles |
| `.prdkit/memory/agents.md` | Available capabilities and optional tier-to-model mappings |
| `.prdkit/templates/` | Project-owned presentation of spec files and records |
| `.prdkit/memory/config.md` | Optional settings: context budget, adoption-gate keys |
| `.prdkit/memory/review-checks.json` | Optional [path-to-required-check map](review-packages.md#path-to-check-map) for `facts.sh` |

Use `/prdkit-configure` for policy and capability changes. Product direction is authoritative in
the spec, not duplicated in the constitution. Keep IDs, markers and record formats when
customizing templates; prose sections can adapt to the project.

## Parts and interfaces across repositories

Parts live within one canonical spec. When an interface crosses repositories, the owning
repository's spec and tests hold its promise and guard; each consuming repository has its own
spec and a pinned fixture or schema dependency. Do not add fake local parts for remote
repositories or copy a schema into Markdown. A platform document shared by several products is
linked from `architecture.md` (`Inherits`), naming the rules used, never copied.

## Agent tier map

`.prdkit/memory/agents.md` resolves each neutral definition's tier to a model per harness.
Definitions and `render-agents.sh` are the optional `agent-tiers` subsystem, installed with
`init.sh --with agent-tiers`; the tier-map checks in doctor and the adoption gate always run.
Several projects can share one optional tier map: a `tiers.json` committed at the root of a
git repository of your own, vendored from a local checkout with
`render-agents.sh --refresh-baseline <agent-library checkout>`. The file is one JSON object,
tier (`verydeep`, `deep`, `standard`, `light` in `agents-template.md`) to harness (`claude`,
`opencode`) to string fields (`model`, and `variant` for OpenCode):
`{"deep": {"claude": {"model": "<id>"}, "opencode": {"model": "<provider>/<id>", "variant": "high"}}}`.
The refresh writes a snapshot at `.prdkit/agent-library/tiers.json` (+ `.ref` provenance:
repository commit and sha256). It updates an existing `Tier baseline:` line to the new commit;
on a first opt-in it prints the line, `Tier baseline: agent-library tiers.json@<commit>`, for
you to add to the tier map. `agent-library tiers.json` is fixed wording the parser reads,
whatever the repository is called. With a baseline come optional
`| Local tier | Library tier |` rows and `| Scope | Harness | Model | Variant | Reason |`
overrides — the project's only model ids, each with its reason; resolution is in
[agent lifecycle](agent-lifecycle.md). An
optional `Banned models:` line lists ids that must never project. Matching is exact, per id
string: banning `claude-opus-5` does not ban its OpenCode form `anthropic/claude-opus-5`, so
list each harness's form separately. The snapshot is project-owned: refresh it with
`render-agents.sh --refresh-baseline` rather than editing it.
The `.ref` file (library commit + sha256) lets doctor detect hand edits to the snapshot and a
mismatch with the `Tier baseline:` commit; it does not prove the snapshot came from that upstream commit, so
review the vendoring diff. `Baseline snapshot:` must be a relative path inside the
repository. With a baseline, a `Hand-owned agents:` line names projections kept without a
neutral definition; any other unowned projection is a finding.

### Optional projection settings

Add this table outside a code fence in `.prdkit/memory/agents.md`, separated from other
tables by a blank line. Keep the four headings
and use the **local** tier from the neutral definition, not its mapped library tier.

```text
| Projection tier | Claude effort | OpenCode permissions | OpenCode preamble |
|-----------------|---------------|----------------------|-------------------|
| *               |               |                      | Use the project rubric. |
| deep            | high          | read, glob, grep     | Start with the review rubric. |
| standard        |               | deny                 |                   |
```

- Omit the table for unchanged output. Leave a cell empty to leave the setting undeclared.
  Placeholders such as `-`, `none`, and `n/a` are not valid effort or permissions values.
  Use LF line endings. Each tier has at most one row, and each row must set something.
- **Claude effort** owns `effort:` only for that tier. Choose `low`, `medium`, `high`, `xhigh`,
  or `max`; check that the Claude Code version and chosen model support the level.
- **OpenCode permissions** opts that tier into **OpenCode V2**. `deny` blocks all actions.
  A comma-separated list adds allows for those exact action names, for **all** their resources.
  Names use lowercase letters, digits and underscores and start with a letter. No wildcards.
  For resource-specific rules, leave this cell blank and manage them in the projection.
  A nonblank cell replaces the entire `permission:` or `permissions:` entry, not just its
  defaults. It also writes `model: provider/model#variant` when a variant resolves, removing
  any separate `variant:`. Keep the model ID and optional variant separate in the baseline and
  overrides; `--resolve` still reports them separately and `Banned models:` uses the base ID.
  Before opting in, follow the [OpenCode V2 migration guide](https://opencode.ai/docs/migrate-v1#agent-files).
  Rename `maxSteps:` to `steps:` and `disable:` to `disabled:`, remove `name:` (the filename
  supplies the ID), and migrate `prompt:` to the neutral agent body. Review `tools:` against
  the new permissions and move sampling/provider options to the model variant. If any such
  legacy keys remain, the renderer names the file and keys and writes no projections.
- **OpenCode preamble** inserts one literal Markdown line before the neutral body, after
  any generated-marker comments. The optional `*` row sets only a global preamble; a nonblank
  local preamble takes precedence. Do not put `|` in the preamble or HTML comments in the row.

When opting into effort or permissions, use a simple YAML block mapping and replace any
frontmatter anchors or aliases with explicit values before rendering. The renderer refuses
these constructs rather than breaking references in project-owned metadata.
`render-agents.sh --check` reports those blockers as well as drift. Removing an effort or permissions
setting hands that field back to the project; it does not delete it. Removing the permissions
setting also restores separate `model` and `variant` fields. If rolling back to the legacy
OpenCode format, restore the previous `permission:` block and remove `permissions:` by hand.

## Rigor and proportion

Light and full share truthful evidence and relevant verification. Review follows the tiers in
the protocol (T0 docs only, T1 one part, T2 several parts or an interface, security or data, T3
an L0 edit or L1 one-way door); the constitution may require more. T0 is checked against the
`review-t0-paths` setting, and Rigor is read from the trusted integration branch. Full also makes medium
findings block and requires independent review of every substantive change. Critical and high
findings block under both. No universal persona or end-to-end test count applies.

## Ownership on upgrade

Ordinary upgrades preserve edited templates and memory and refresh unmodified kit-owned
commands, internal workflows, and scripts. `--check` reports changes to those files as
KIT-OWNED EDITS. `--upgrade` requires a clean, committed checkout. It refuses to overwrite
or delete customized managed content,
even when committed or ignored. Files under `specs/` are not managed installer files.
Customize policy and templates instead of forking operational instructions.

The installer writes and deletes only inside the project. It refuses, before writing anything,
when a directory it writes into (`.prdkit/` and its subdirectories, or a selected harness's
`.claude/commands/` or `.opencode/commands/`) is a symlink or resolves outside the project, or when
a directory sits where it installs a file. Replacing a kit-owned file that is still shipped with
a custom symlink blocks an upgrade; the installer never writes through it. A plain upgrade keeps symlinked
templates and memory files. `--upgrade --force` still has to pass the overwrite checks.
`AGENTS.md` and `.gitignore` may link to a file inside the project (for example, `AGENTS.md`
can link to `CLAUDE.md`). An upgrade refuses links to root files outside the project.
When the kit no longer ships a manifest-listed file, `--check` reports it as retired drift. On
`--upgrade`, a retired regular file is unedited if its content matches the manifest hash; file
mode does not affect that decision. Installer-owned command symlinks are removed even if dangling.
Content edits, foreign symlinks, directories, and retired memory files are kept and listed for
manual follow-up. Retirement does not unlink an alias of a current install destination. If sparse
checkout excludes any retired tracked paths, the upgrade refuses before writing. Include the
listed paths with `git sparse-checkout add`, then retry. A successful upgrade drops all retired
entries from the manifest. Tracked references to removed files are warnings, not blockers. A plain
rerun with retired entries directs you to `--upgrade`.
The manifest records version, harnesses, install mode, selected options and pristine file
hashes. Upgrade from a clean, committed checkout. To deselect agent tiers, use
`--without agent-tiers`; the installer removes its managed files only when the project no
longer uses the subsystem, preserving a customized template.
An explicit `--harness` list may not drop a recorded harness (see
[removing a harness](harnesses.md#removing-a-harness)). Doctor and the adoption gate report
any `prdkit*.md` command file the manifest does not record.
The AGENTS.md managed section has its own manifest hash; surrounding consumer text is
preserved. Doctor and the adoption gate check manifest-listed file presence and kit-owned
content without a source checkout, while customized template/policy hashes remain allowed.

### Interrupted upgrades

Upgrades are not one global transaction: commands/helpers can already be new while the old
manifest still describes the prior install. File copies are staged beside their destinations
before replacement, so a failed copy cannot turn partial template bytes into a supposed user
customization. The manifest publishes last. An unfinished write phase leaves
`.prdkit/.install-state` naming its phase and path; `--check`, doctor and the adoption gate
report it as incomplete. Keep the original source revision available and retry it with
`init.sh --upgrade`, then check integrity. A marker can remain even after manifest publication;
it still requires a coherent retry, not deletion to make the gate green.
For a missing retired path, a retry verifies the committed file independently of the marker.
It checks a regular file's raw committed bytes, or those same bytes with every LF changed
to CRLF if the blob contains no CR. It does not apply checkout settings or run Git filters.
For committed command symlinks, it checks the link target. If required Git objects are missing
locally, the retry refuses rather than fetching them.

The write phase uses an exclusive `.prdkit/.install-lock` file with PID/host. Concurrent writers
are refused rather than waiting on stale ownership data. Normal failure/TERM releases the lock;
SIGKILL or machine loss cannot run cleanup. Before removing an abandoned lock, inspect its host,
owner process **and child writers** and ensure none can still publish. Preserve the marker and
original failure evidence, remove only the verified abandoned lock, and retry the same source.
Inspect leftover `*.prdkit-install.*` staging directories after an untrappable kill; they are never
treated as installed content or used as recovery inputs. Existing customization policy still
applies; `--force` is not a recovery requirement. The installer does not render agent projections,
so there is no projection rollback claim.

### Command install mode

Commands install as copies by default, so they work in any checkout: a change worktree or a CI
checkout needs no initialized submodule. `--symlink` installs relative links into the kit
instead; they resolve only where the kit is checked out, so each new change worktree then needs
`git -C <worktree> submodule update --init <kit path>`, and `new-change.sh` says so when they
dangle. The manifest records the mode and later runs keep it; pass `--copy` or `--symlink` to
switch. An install made before copies became the default keeps its symlinks until you pass
`--copy` once.

## Agent context budget

Agent context files (`CLAUDE.md`, `AGENTS.md` and harness equivalents) hold stable orientation
and pointers only; delivered truth goes to the spec, and history to `.prdkit/history/log.md` and Git.
`context-budget-bytes` (default 16384, 0 disables) in `.prdkit/memory/config.md` bounds them:
doctor reports a file over it as an advisory, and `doctor.sh --strict` fails on it for an
opt-in CI gate (see [CI gates](ci-gates.md)). The kit never writes these files beyond the
managed `AGENTS.md` section.
