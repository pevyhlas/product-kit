# Project-owned customization

| Surface | Owns |
|---------|------|
| `specs/` | The spec, change records, inbox, records and log: entirely yours, never edited by the installer |
| `.prdkit/memory/constitution.md` | Intent owner, Rigor, action policy, actual commands, review and checks, principles |
| `.prdkit/memory/agents.md` | Available capabilities and optional tier-to-model mappings |
| `.prdkit/templates/` | Project-owned presentation of spec files and records |
| `.prdkit/memory/config.md` | Optional settings: context budget, adoption-gate keys |
| `.prdkit/memory/task-ledger.md` | Optional event delivery |

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
neutral definition; any other unowned projection is a finding. Legacy literal tables keep
working.

## Rigor and proportion

Light and full share truthful evidence and relevant verification. Review follows the tiers in
the protocol (T0 docs only, T1 one part, T2 several parts or an interface, security or data, T3
an L0 edit or L1 one-way door); the constitution may require more. Full also makes medium
findings block and requires independent review of every substantive change. Critical and high
findings block under both. No universal persona or end-to-end test count applies.

## Ownership on upgrade

Templates and memory are preserved when edited. Commands, internal workflows, and scripts
are kit-owned and refreshed; `--check` reports KIT-OWNED EDITS honestly. Files under `specs/`
are not managed installer files. Customize policy and templates instead of forking operational
instructions. `--force` deliberately resets template/memory copies to kit defaults.

The installer writes and deletes only inside the project. It refuses, before writing anything,
when a directory it writes into (`.prdkit/` and its subdirectories, or a selected harness's
`.claude/commands/` or `.opencode/commands/`) is a symlink or resolves outside the project, or when
a directory sits where it installs a file. A kit-owned file replaced by a symlink is replaced
again by a regular file, never written through. A symlinked template or memory file is
project-owned: it is kept and reported, even with `--force`, so a shared policy can be a link.
AGENTS.md and `.gitignore` are edited through a symlink only while its target stays inside the
project (`AGENTS.md` linking to `CLAUDE.md` works); otherwise they are left untouched with a
warning. A manifest entry outside the installed layout is ignored with a warning, never deleted.

The manifest records selected harnesses and pristine hashes. It supports drift detection and
safe ordinary upgrades, not automatic conversion of a 0.x spec ([migrating to 1.0](migrating-to-1.0.md)).
Commands the kit no longer ships (retired, disabled or unsupported entry points) are
reported by `--check` as RETIRED and removed by `--upgrade` when the previous manifest
recorded them or they are symlinks into the kit's `commands/`; retired workflows and helpers
are removed, and a retired template is removed unless you edited it; an unrecorded hand-made `prdkit*.md` file or a user's own symlink is kept and
named in a warning, since it would otherwise keep loading into every session.
An explicit `--harness` list may not drop a recorded harness (see
[removing a harness](harnesses.md#removing-a-harness)). Doctor and the adoption gate report
any `prdkit*.md` command file the manifest does not record.
The AGENTS.md managed section has its own manifest hash; surrounding consumer text is
preserved. Doctor and the adoption gate check manifest-listed file presence and kit-owned
content without a source checkout, while customized template/policy hashes remain allowed.

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
and pointers only; delivered truth goes to the spec, and history to `specs/log.md` and Git.
`context-budget-bytes` (default 16384, 0 disables) in `.prdkit/memory/config.md` bounds them:
doctor reports a file over it as an advisory, and `doctor.sh --strict` fails on it for an
opt-in CI gate (see [CI gates](ci-gates.md)). The kit never writes these files beyond the
managed `AGENTS.md` section.
