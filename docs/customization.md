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

When `Banned models:` is set, the kit checks `model:` in `.opencode/agents/*.md`, including
hand-owned files. Use an unindented top-level key with an inline plain or quoted model
token (optional trailing comment), or a folded (`>`/`>-`) or literal (`|`) block with one
model token on one content line. A `#variant` does not exempt the base ID from a ban.
The kit does not evaluate general YAML: indented root mappings, flow mappings at the
root, aliases or merges that supply the model, and other unsupported model forms get a
file-and-line finding in both render and `--check`. Rewrite the model as a plain
`model: provider/model#variant` scalar to make it verifiable. This is a check of kit
projection files, not of OpenCode's full configuration or inherited models.

For projection frontmatter, use exactly `---` on the opening and closing lines.
Render and `--check` report noncanonical delimiters with the file and line, even
without model bans or optional settings. If the file contains CRLF, convert the
whole file to LF line endings, not just the reported line. Render refuses before
updating any projection. Doctor and adoption check managed projections when a tier
baseline is in use, and also check files covered by configured model bans.

The `.ref` file (library commit + sha256) lets doctor detect hand edits to the snapshot and a
mismatch with the `Tier baseline:` commit; it does not prove the snapshot came from that upstream commit, so
review the vendoring diff. `Baseline snapshot:` must be a relative path inside the
repository. With a baseline, a `Hand-owned agents:` line names projections kept without a
neutral definition; any other unowned projection is a finding.

### Optional projection settings

Add this table outside a code fence in `.prdkit/memory/agents.md`, separated from other
tables by a blank line. The fifth column is optional; existing four-column tables still
work. Use the **local** tier from the neutral definition, not its mapped library tier.

```text
| Projection tier | Claude effort | OpenCode permissions | OpenCode preamble | Claude tools |
|-----------------|---------------|----------------------|-------------------|--------------|
| *               |               |                      | Use the project rubric. | |
| reviewer        | high          | read, glob, grep     | Start with the review rubric. | Read, Grep, Glob |
| maker           |               | read, glob, grep, edit, shell |          | Read, Grep, Glob, Bash, Edit, Write |
```

- Omit the table for unchanged output. Leave a cell empty to leave the setting undeclared.
  Placeholders such as `-`, `none`, and `n/a` are not valid effort or permissions values.
  Use LF line endings. Each tier has at most one row, and each row must set something.
- **Claude effort** owns `effort:` only for that tier. Choose `low`, `medium`, `high`, `xhigh`,
  or `max`; check that the Claude Code version and chosen model support the level.
- **Claude tools** sets `tools:` to a comma-separated allowlist. Use distinct tool names
  starting with an ASCII letter, followed by letters, digits, `_`, `.` or `-`. Do not use
  `[]`, wildcards or argument restrictions. If the projection has a `disallowedTools:` list,
  it must be readable and must not overlap the allowlist, including an added `Skill` tool.
  The renderer saves any previous native `tools:` in ownership comments. Keep those comments
  intact: on opt-out it restores the original field, or removes `tools:` if it was absent.
  It still applies any active skill declaration to the restored tools.
  For reviewers, keep the allowlist but omit `Bash`: the review package carries the diff
  and context. `Bash(...)` in `tools:` is not a supported command limit, and a scoped entry
  in `disallowedTools:` removes the whole tool. For command-level limits, use
  [`permissions.deny`](https://code.claude.com/docs/en/permissions.md#bash) in project settings
  (applies to the main session and all subagents), or add a project-owned
  [`PreToolUse` hook](https://code.claude.com/docs/en/sub-agents.md#hooks-in-subagent-frontmatter)
  to the agent's `hooks:` with matcher `Bash`. Use an executable script that exits `2` to
  block a command, and verify the hook runs in the trusted workspace. The kit does not generate hooks.
- **OpenCode permissions** opts that tier into **OpenCode V2**. `deny` blocks all actions.
  A comma-separated list adds allows for those exact action names, for **all** their resources.
  Names use lowercase letters, digits and underscores and start with a letter. No wildcards.
  For resource-specific rules, use a single-line list of `{action, resource, effect}` entries.
  Each needs an action name, a nonempty plain or quoted glob string, and `allow` or `deny`.
  Quote patterns starting with `*` or `?`, such as `"*.env"`. In double quotes, use
  `\"` or `\\` when needed. In single quotes, double any apostrophes. Control
  characters, a literal `|` (the table delimiter), YAML anchors and aliases are not supported.
  Rules follow the generated deny-all in the order given; the last matching rule wins.
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

For example, this **OpenCode permissions** cell grants `read` except for `.env` and
`.env.*` files. It does not grant shell, which is a separate way to read files:

```text
[{action: read, resource: "*", effect: allow}, {action: read, resource: "*.env", effect: deny}, {action: read, resource: "*.env.*", effect: deny}]
```

Project-owned agent definitions on a shared tier inherit its permissions and tools. Put an
agent that needs to edit or run shell commands on a maker tier that grants those operations.
To bound a maker tier's shell in OpenCode V2, put a shell deny-all before any shell allows
in its **OpenCode permissions** cell. Replace the placeholder commands with patterns your
project chooses and include any other permissions the maker needs in the same list:

```text
[{action: shell, resource: "*", effect: deny}, {action: shell, resource: "your-check-command", effect: allow}, {action: shell, resource: "your-build-command *", effect: allow}]
```

[OpenCode matches](https://opencode.ai/docs/permissions#matching) each command extracted by
its shell scanner. The exact pattern allows only that command with no arguments; the
trailing ` *` pattern also matches the command with no arguments. The kit does not install a
maker allowlist, and Claude's tier tool list cannot scope commands per agent (see above).
Tools and permission patterns are not a sandbox; in particular, Claude's `Bash` can modify files.

When opting into effort, tools or permissions, use a simple YAML block mapping and replace any
frontmatter anchors, aliases and alias-based merges with explicit values before rendering.
The guard looks for YAML references at the start of a node, not `*` or `&` in ordinary
text such as quoted permission patterns or block-scalar descriptions.
`render-agents.sh --check` reports those blockers as well as drift. Removing an effort or permissions
setting hands that field back to the project; it does not delete it. Removing the permissions
setting also restores separate `model` and `variant` fields. If rolling back to the legacy
OpenCode format, restore the previous `permission:` block and remove `permissions:` by hand.

### Optional skill projection

Declare `skills: [example-skill, another-skill]` in a neutral agent's frontmatter. Use a
nonempty, single-line bracketed list (not a block list) of at most 32 distinct lowercase IDs,
each at most 64 characters, with digits and single hyphens between segments. Write the
top-level `skills:` key without quotes or escapes. An agent that never opts in keeps
its native skill configuration.

In `.prdkit/memory/agents.md`, add the applicable settings outside code fences and HTML
comments. `Skill roots:` is optional and replaces both default search locations:
`.claude/skills/<plugin>/skills/<id>/` (any plugin) and `.agents/skills/<id>/`. Give it
comma-separated repository-relative directories that directly contain the ID directories.
Use plain paths without spaces, wildcards or `.`/`..` segments. Set `Claude skill prefix:`
to the actual plugin name if any declaring agent targets Claude Code.

```text
## Skills

Claude skill prefix: example-plugin
Skill roots: .claude/skills/example-plugin/skills, .agents/skills
```

Each ID needs a regular `SKILL.md` inside the repository. If more than one copy is found,
all copies must declare the same needs. Under `metadata` in the skill's frontmatter, the
optional `prdkit/needs` key takes a single-line, whitespace-separated string. For example:

```yaml
---
name: example-skill
description: Collect example evidence.
metadata:
  prdkit/needs: "bash python3"
---
```

A single-line flow map (`metadata: { prdkit/needs: "bash python3" }`) also works. Use simple
keys and single-line scalar values, not aliases, nested collections, escapes or folded
values. Absent or empty `prdkit/needs` means no shell is needed; any of `bash`, `python3`,
`git`, `gh`, `dotnet` and `network` requires shell access. These tokens do not check that
individual commands or network access are available. Unknown tokens, missing files and
unreadable declarations are line-numbered findings in render and `--check`; render writes
no projections until they are fixed.

For a declaring agent:

- **OpenCode:** Set its local tier's **OpenCode permissions** cell to take ownership of
  V2 permissions, or exclude OpenCode from that agent's `harnesses:` list. The renderer
  refuses to infer shell access from hand-owned or legacy permissions. A shell-dependent
  skill needs a `shell` allow on `*` with no later shell deny; the declaration does not say
  which commands the skill needs. After the tier's rules, the renderer
  denies all skills and then allows only the declared runnable IDs. For each blocked skill,
  the prompt points to `<id>.json` or `<id>.md` supplied by the maker. Pass those completed
  files with `build-review-package.sh --evidence <repo-relative-path>`; the package keeps
  them under `evidence/<repo-relative-path>` and lists them in its inventory. Without
  evidence the reviewer should report the facts as unverified.
- **Claude Code:** The renderer owns `skills:` and writes all declared IDs as
  `<plugin>:<id>`. Claude skips missing, disabled or non-model-invocable skills. The
  renderer adds `Skill` to a tier's tool allowlist if missing. Without a tier allowlist it
  preserves native tool restrictions, adding `Skill` if needed to a comma-separated
  value, single-line bracketed list or block list of tool names. Claude applies
  `disallowedTools` before `tools`; shell availability does not affect the Claude projection.
  Skill projection does not grant `Bash`.

Removing the neutral `skills:` key makes the next render undo its generated Claude entries:
it restores a prior single-line `skills:` list (or removes the added field) and removes only
the renderer-added `Skill` tool. Before opting in, put any existing native Claude `skills:`
block list on one line as a flow list (`[a, b]`). Keep the generated
`# prdkit-skill-projection:` comments, including the prefix and record values.
`--check` reports stale entries; both render and `--check` refuse damaged records
(including blank values) or fields that no longer match their recorded values for cleanup.
To change a managed inline tools list, first remove the declaration and render, then edit
the native list and opt back in. Files rendered before ownership comments existed, or with no remaining exact marker
prefixes, cannot be distinguished from hand-owned files. Reconcile them against a known-good
pre-opt-in version before re-rendering.
Skill-managed frontmatter that cannot be rewritten safely is rejected (for example, a
multiline quoted description). OpenCode regenerates the tier's permissions if that tier
remains opted in. The renderer does not install, copy or run skill files; make them
discoverable in each target harness and validate with its native loader.

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
