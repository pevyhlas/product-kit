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

| Harness | Installed filesystem contract | Recorded real-agent behavior | Native command loading / full delivery |
|---------|-------------------------------|------------------------------|----------------------------------------|
| Claude Code | Deterministic installer/catalog tests | 2.1.257 attempt: quota ERROR | Unknown |
| OpenCode | Deterministic installer/catalog tests | 1.18.31: six bounded 0.9.0 workflow scenarios PASS | Unknown |
| Codex / AGENTS.md readers | Managed-entry installation/preservation tests | No committed real-agent result | Unknown |

These observations describe the recorded 0.9 redesign evaluation, not 1.0 behavior; no 1.0
real-agent run is recorded yet (the kit's own development records are kept privately). Update the
matrix from actual driver/version observations and original outputs. A complete journey,
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
