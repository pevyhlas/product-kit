# Public command reference

Everyday use: describe an outcome with `/prdkit`, inspect progress with `/prdkit-status`.
Command definitions are thin public entry points; the [agent playbooks](../workflows/README.md)
own the operational behavior, starting with [protocol.md](../workflows/protocol.md).

- [`/prdkit`](../commands/prdkit.md) — route a request: owner direction to the inbox and the
  spec, bounded work into a new or open change, questions answered from the spec and code,
  overflow or a 0.x layout to compaction. `--explore` edits nothing, `--plan` writes a change
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
- [`/prdkit-init`](../commands/prdkit-init.md) — guided adoption, or the one-time cutover of a
  0.x project.
- [`/prdkit-configure`](../commands/prdkit-configure.md) — constitution, action policy,
  capabilities and optional settings.
- [`/prdkit-doctor`](../commands/prdkit-doctor.md) — read-only diagnostics; `--json`, and
  `--strict` to fail on advisories.

On a harness without native slash commands, ask it to read `.prdkit/workflows/protocol.md` and
follow the matching installed operation. A command name does not grant extra action authority.

## Installed version, spec layout and migration

Ordinary `status.sh` and `doctor.sh` output includes these three observations separately.
Their `--json` output adds an `adoption` object, for example a current kit with legacy specs:

```json
{"installed_version":"1.3.3","spec_layout":"0.x","mixed_spec_forms":false,"migration_state":"required"}
```

`installed_version` comes only from `.prdkit/.manifest`; missing, empty or duplicate version
metadata yields `null` (text: `unknown`), even if a source checkout is present. This is the
recorded installation version, not an integrity verdict; doctor findings report drift separately.

| Observed layout | `spec_layout` | `migration_state` |
|---|---|---|
| Legacy 0.x canon only | `0.x` | `required` |
| Legacy and current canons | `both` | `incomplete` |
| Current spec with single-file and split forms together | `1.0` | `incomplete` |
| Current spec, one form | `1.0` | `not-indicated` |
| No recognized spec | `none` | `unknown` |

`1.0` is the existing layout-family marker for current 1.x specs, not the installed kit version.
`mixed_spec_forms` identifies competing `specs/SPEC.md` and split files. Layout detection keeps
the existing rules for ignored legacy leftovers and empty `.gitkeep` directories.
Migration state is derived from layout only: `not-indicated` never certifies migration completion
or owner acceptance. Updating the installed kit does not rewrite `specs/`.
Existing status `layout`/`mixed_spec_forms` and opt-in doctor `configuration.version` stay available;
the summary adds no findings and does not change exit codes or require `--inventory`.
