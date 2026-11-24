# Public command reference

Everyday use: describe an outcome with `/prdkit`, inspect progress with `/prdkit-status`.
Command definitions are thin public entry points; the [agent playbooks](../workflows/README.md)
own the operational behavior, starting with [protocol.md](../workflows/protocol.md).

- [`/prdkit`](../commands/prdkit.md) — route a request: owner direction to the inbox and the
  spec, bounded work into a new or open change, questions answered from the spec and code,
  overflow to compaction. `--explore` edits nothing, `--plan` writes a change
  record and proportional execution plan without code, `--execute` runs the bounded change;
  ready work consumes approved product/design intent. `continue` resumes from the
  change's State after checking actual repository state.
- [`/prdkit-status`](../commands/prdkit-status.md) — runs `status.sh` (`--json` for the derived
  form) and answers the question first, then outcome progress and the longest pole. Recorded
  milestone evidence and no-progress counts stay distinct from PR/test totals. Read-only.
- [`/prdkit-inbox`](../commands/prdkit-inbox.md) — reconcile recorded answers, then review owner
  questions one at a time through the agent. Select IDs or tags in ordinary words (for example,
  `tags ux, export`); `preview` requests a read-only review. Answers update the governing spec
  and provenance before the item is removed. Pending processing is distinct from waiting on you.
- [`/prdkit-product`](../commands/prdkit-product.md) — edit L0 (`specs/product.md` and
  `specs/product/`, or the L0 sections of `specs/SPEC.md`) inside a change, with the owner's words
  quoted.
- [`/prdkit-target`](../commands/prdkit-target.md) — discover work from product intent and design
  together, then plan a programme: coverage, bounded children, dependency outcomes and owner gates.
- [`/prdkit-learn`](../commands/prdkit-learn.md) — compare observations with the thesis,
  qualities and hypotheses; proposals go to the owner through the inbox.
- [`/prdkit-init`](../commands/prdkit-init.md) — guided adoption.
- [`/prdkit-configure`](../commands/prdkit-configure.md) — constitution, action policy,
  capabilities and optional settings.
- [`/prdkit-doctor`](../commands/prdkit-doctor.md) — read-only diagnostics; `--json`, and
  `--strict` to fail on advisories.

On a harness without native slash commands, ask it to read `.prdkit/workflows/protocol.md` and
follow the matching installed operation. A command name does not grant extra action authority.

When using `new-change.sh` directly, pass `--programme` to include the commented outcome
checkpoint scaffold for a programme parent or continuing follow-up queue. Ordinary records get
only a pointer to the format. See [Running a change](../workflows/change.md).

For projects with a UI, the optional L1 [design summary](../workflows/spec.md#layout) uses the
installed `design-template.md`; no separate command is needed.

## Installed version and spec layout

The `status.sh` and `doctor.sh` adoption summary distinguishes the recorded installation
version from the spec layout. In JSON, `adoption.installed_version` comes from
`.prdkit/.manifest` and is `null` if unknown. `adoption.spec_layout` is `1.0` for the current
layout family, `none` if no spec is recognized, or `unsupported` for an unsupported layout.
`adoption.mixed_spec_forms` flags competing single-file and split specs. The install version
does not certify the spec or the installed files.
