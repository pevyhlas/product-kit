# Harness invocation and capability support

Product-Kit ships Markdown operations and Bash helpers. Installation targets are tested as
filesystem contracts; actual agent behavior is evaluated separately with local harness runs.

| Target | Entry | Neutral fallback |
|--------|-------|------------------|
| Claude Code | `.claude/commands/` public commands | Read `.prdkit/workflows/protocol.md` |
| OpenCode | `.opencode/commands/` public commands | Read `.prdkit/workflows/protocol.md` |
| Codex / AGENTS.md readers | Managed AGENTS.md section | Same installed playbooks |

Start with protocol.md in every case. The installer defaults to Claude plus AGENTS.md,
detects existing OpenCode/Codex markers on fresh install, and preserves the selected set
on upgrade. `--harness` takes names separated by commas and/or spaces; an unknown name
(including a list glued together without separators) exits 2 instead of installing less.
AGENTS.md-reading tools without a first-class target use `agents`.

`/prdkit-inbox` uses the current client's native question interface when available, otherwise
ordinary conversation, one question at a time. An AGENTS.md reader can follow
`.prdkit/workflows/inbox.md` directly. Installation does not prove native question UI behavior;
record that separately from conversational fallback and file-incorporation evaluations. The
shared Markdown queue and resolution contract apply on every harness.

### Removing a harness

On an existing install, an explicit `--harness` list must keep every harness the manifest
records; dropping one exits 2. Otherwise the manifest would stop recording that harness while
its command files stayed on disk, unchecked. Omit `--harness` to keep the recorded set, or
widen it with a longer list. There is no in-place removal. Removing a harness is a
deliberate reinstall:

1. Run a normal `--upgrade` first, so unmodified files are current.
2. Delete that harness's `prdkit*.md` command files (for `agents`, the AGENTS.md managed
   section) and `.prdkit/.manifest`.
3. Re-run the installer with the narrower `--harness` list.

Existing templates and memory are kept on that run, because no pristine hash is recorded.
Re-record the adoption contract afterwards. Doctor and the adoption gate report any
`prdkit*.md` command file the manifest does not record.

Native command/agent formats evolve. Validate loading with the actual selected harness
before claiming compatibility. A file being installed proves installation, not that every
current harness feature was tested. Behavioral eval reports should record driver/version.

Independent review requires a distinct reviewer/context. If the harness cannot dispatch one,
arrange an available reviewer or report the requirement pending. Optional neutral agent
definitions are projected by `render-agents.sh` (see [agent lifecycle](agent-lifecycle.md)):
Claude Code receives `model`, OpenCode `model` + `variant` (the official effort field;
`reasoningEffort` would become a model option). OpenCode also passes unknown frontmatter keys
to the model, so neutral/provenance keys (`tier`, `source`, `library-ref`, …) are removed from
its projections and provenance lives in YAML comments. Claude effort is not projected. Native
extras (tools, permissions, mode, colour, memory) stay project-owned and are preserved.
The kit does not assume all harnesses have identical subagent, permission, or effort controls.

## Recorded evaluation coverage

Record capabilities separately. A result for one capability never fills another column:

| Capability | Required evidence |
|---|---|
| Installation/integrity | Source revision, dirty state, target, install mode and manifest digest; actual helper exit codes |
| Native loading | Exact CLI version and native command/agent discovery or invocation output |
| Agent execution | Scenario, transcript, observable acceptance and driver exit; timeout/quota/crash is ERROR |
| Structured capture | Parsed real harness output; complete/partial coverage and attribution limits |
| Runtime events | Exact event and observed invocation; not inferred from command-hook prose |
| Independent review access | Fresh reviewer identity/context, readable revision-bound package and original report |

Use `PASS`, `FAIL`, `ERROR`, `UNKNOWN` or explicitly justified `NOT_APPLICABLE`, with the kit
revision, harness/model version, date, environment and original evidence link. Version output
alone proves availability only. Do not convert mock results into agent observations. Current
session identity is external evidence: doctor cannot infer it from installed command files.

`bash tests/evals/consumer-smoke.sh` produces one JSON record for the current source, including
dirty state, installation for all four targets, two upgrades preserving policy, and source-less
diagnostics/adoption. It is deterministic, local and credential-free, and runs in CI. Save stdout
as evidence; stderr contains failures. Native loading/execution/capture/events/review remain
unknown. Real runs use `tests/evals/run-evals.sh` and retain original transcripts separately.

For a consumer's configuration, `doctor.sh --inventory --json` adds a versioned inventory.
It distinguishes expected, tracked and checked-out source pins (a copied source directory has no
checkout revision), recorded versus actual file hashes, kit versus project ownership, and resolved
versus projected models with the winning rule. `null` is unknown; an absent legacy install mode
is not silently asserted as observed. Project copies override template seeds. Model precedence
uses the existing resolver: baseline/literal tier, tier override, then agent override; a specific
harness overrides wildcard at each scope. Native metadata stays project-owned. Read findings
alongside inventory: projected values are not proof of what an actual running model used.

| Harness | Installed filesystem contract | Recorded real-agent behavior | Native command loading / full delivery |
|---------|-------------------------------|------------------------------|----------------------------------------|
| Claude Code | Deterministic installer/catalog tests | 2.1.257 attempt: quota ERROR | Unknown |
| OpenCode | Deterministic installer/catalog tests and current-source consumer smoke | 2.0.26: ready-execution scenario PASS on a dirty 1.2.1 diagnostics candidate; [provenance and limits](evidence/2026-10-28-capabilities.md) | Unknown |
| Codex / AGENTS.md readers | Managed-entry installation/preservation tests | No committed real-agent result | Unknown |

The Claude observation is historical (0.9-era); OpenCode also previously passed six bounded
0.9-era scenarios on 1.18.31. The dated candidate observation above does not certify the released
1.2.1 or every future change. Update the matrix from actual driver/version observations and
original outputs. A complete journey,
resume/amendment, and comparative owner-feedback evidence are the next evaluation to record.

## Worktrees across harnesses

Product-Kit owns one neutral worktree per change by default: `new-change.sh` runs
portable `git worktree add` under `.worktrees/<branch>` and the agent works in the returned
path. Harnesses differ in whether they *also* have a worktree layer of their own, so the rule
is **one owner per change session** — the kit or the harness, never both.

| Harness | Native worktree layer | Binds the session | With Product-Kit |
|---------|-----------------------|-------------------|------------------|
| Claude Code | `EnterWorktree`/`ExitWorktree` under `.claude/worktrees/`; `worktree.baseRef` | Yes — a removed worktree fails re-entry on resume | Default: work in the kit path, do not also `EnterWorktree` it. Or `--no-worktree` + native worktrees |
| Codex CLI | Stable: none (runs in cwd). 0.154+: experimental `--worktree`/`/worktree` that binds each thread to its checkout | Only in managed mode | Default fits stable/manual use. For managed mode use `--no-worktree` |
| OpenCode | None built-in; community plugins add session worktrees | Only if a plugin binds | Default fits plugin-free use. With a worktree plugin use `--no-worktree` |
| Aider, Gemini CLI, plain AGENTS.md readers | None | No | Default — the kit-owned worktree is exactly right |
| Cursor background agents | Managed worktrees | Yes | `--no-worktree`; let the harness own isolation |

Pick one mode per project policy:

- **Kit-owned (default).** The kit creates the worktree; the agent operates in the returned path
  with ordinary file paths and does not open a second, harness-managed worktree for the same
  change. Lowest-common-denominator — works on every harness, including those with no worktree
  layer at all.
- **Harness-owned (`--no-worktree`).** The kit creates the branch in place and the harness's own
  worktree system owns isolation. Use this when the harness's worktrees are the team's workflow
  (Claude Code worktrees, Codex managed mode, an OpenCode plugin, Cursor background agents).

Either way, tear worktrees down with `cleanup-change.sh`, never `rm -rf`: a worktree directory
removed out of band leaves a stale registration that blocks a session trying to re-enter it on
resume. `doctor.sh` flags stale registrations read-only.
