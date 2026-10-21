# Product-Kit

**Keep one short, current spec of what your product must be. Let your agent change it and the
code together.**

> **Experimental.** One maintainer builds Product-Kit and uses it on a handful of projects. It
> may not fit your project, stack or agent harness. Interfaces can still change between
> releases; each [CHANGELOG](CHANGELOG.md) entry says how to upgrade.

Product-Kit is a file-first protocol for coding agents and the people directing them. The
spec narrows the space of acceptable implementations where a wrong choice is expensive; code
and tests stay the exact implementation. Humans and agents read the same Git-versioned
Markdown, and status is generated from it.

```text
You:    Users need to see which requests need their attention.
Agent:  Is this for individual users or team coordinators? Should it recommend an order?
        I recommend individuals and no ordering; that is my default if you don't answer.
You:    Individuals. Show what is unresolved; defer recommendations.
Agent:  Opened change 012-attention: it adds R-04 with the code, and acceptance A1 proves
        it. Ordering is deferred in the inbox. [builds, verifies, reviews within your policy]
Agent:  A1 passes on staging (rev 3f2c1ab, run link). Live usefulness is still unmeasured.
```

Product-Kit runs inside your active agent session. It does not operate a background service.

## Start here

Requires Git and Bash. Install from your consuming project:

```bash
git submodule add https://github.com/pevyhlas/product-kit .product-kit
bash .product-kit/scripts/init.sh
```

Then run `/prdkit-init`, followed by a request such as:

```text
/prdkit Help define the first useful release of this product.
/prdkit --explore Would collaboration actually help our current users?
/prdkit Let users see their unresolved requests.
/prdkit-status
```

Pin the submodule to a reviewed release tag or commit. A project on 0.x upgrades and then
cuts over once: see [migrating to 1.0](docs/migrating-to-1.0.md). See also
[getting started](docs/getting-started.md), [the human workflow](docs/human-workflow.md)
and [adopting an existing product](docs/adoption.md).

## The spec

```text
L0 specs/product.md            one page: stage, pains, personas, core loop, journeys by stage, the bet
   specs/product/journeys/     one file per journey (J): who, intent, scenario, variations
   specs/product/*.md          requirements (R), qualities (Q), constraints (C), non-goals (N)
   specs/product/lifecycle.md  the stage now (Idea, Demo, MVP, previews, GA, Sunset, Retired)
L1 specs/architecture.md       one page: diagram, parts and why, core loop, key decisions and areas
   specs/architecture/         decisions (D) and topics: security, observability, data, ...
L2 specs/parts/<part>.md       one box: why it exists, components, behaviors (P<n>.B), invariants (P<n>.I)
   specs/parts/<part>/         one file per component, once the part outgrows its file
   code and tests              the exact implementation; tests cite the IDs they prove
```

Each level opens with a one-page summary that links its detail. Journeys come first:
requirements cite the journeys they serve, and each part says which journeys need it.

- **Changes** are transactions on the spec and the code: `specs/changes/<id>.md` holds intent,
  spec edits, acceptance and resume state, and is deleted when the change closes; one line
  lands in `specs/log.md`.
- **Owner direction** is kept verbatim in `specs/inbox.md`, where agent questions offer numbered
  options; holds, waivers, attestations and deployments are one-line records in
  `specs/records.md`.
- **Markers** keep the spec honest: `(hypothesis|validated)`, `planned: <change>`,
  `retired: <reason>`, `unenforced`. Reading budgets keep files short; past one a file is
  tightened or split, never trimmed of items.
- **Evidence** stays in CI, the PR or `.prdkit/cache/`; the spec links it and never stores it.

A small project can keep everything in one `specs/SPEC.md`.

## Public commands

| Command | Purpose |
|---------|---------|
| `/prdkit` | Turn a request into a change, continue an open change, or answer from the spec |
| `/prdkit-status` | Generated view: true now, in flight, live, held, owner queue, longest pole |
| `/prdkit-product` | Shape or edit product intent (L0) |
| `/prdkit-target` | Plan a programme: a parent change with child changes and owner gates |
| `/prdkit-learn` | Evaluate outcomes against the thesis, qualities and hypotheses |
| `/prdkit-init` | Adopt the kit, or cut a 0.x project over to the 1.1 layout |
| `/prdkit-configure` | Constitution, action policy, capabilities and settings |
| `/prdkit-doctor` | Read-only diagnosis of layout, budgets, IDs, records and agent context |

The agent follows the playbooks in [workflows/](workflows/README.md), installed separately
from the slash-command menu. See the [command reference](docs/commands.md) and
[agent workflow](docs/agent-workflow.md).

## Harnesses and installation

```bash
bash .product-kit/scripts/init.sh --harness claude,opencode
bash .product-kit/scripts/init.sh --harness agents --copy
```

| Target | Installed entry points |
|--------|------------------------|
| `claude` | `.claude/commands/` |
| `opencode` | `.opencode/commands/` |
| `codex` / `agents` | Managed `AGENTS.md` entry pointing to neutral playbooks |

Every target receives `.prdkit/workflows/`, templates, policy scaffolds and helpers. Use the
installed playbook directly when slash commands are unavailable. Independent review requires
an available independent reviewer or context. See [harness support](docs/harnesses.md).

## Ownership and upgrades

Project-owned templates and memory are preserved when edited. Commands, workflows and helpers
are kit-owned and refreshed on upgrade. Everything under `specs/` is yours; the installer
never edits it.

```bash
bash .product-kit/scripts/init.sh --check
bash .product-kit/scripts/init.sh --upgrade
```

Update the submodule to the version you intend to adopt before upgrading. `--check` is
read-only and distinguishes OUTDATED, NEW, MODIFIED project files, KIT-OWNED EDITS and RETIRED
files; `--upgrade` removes retired kit files. `--force` resets installed templates and memory.
See [customization](docs/customization.md).

## Evidence and data

Acceptance names the revision and environment of each pass and links its output. Missing
evidence stays unknown. The optional execution ledger spools locally; external delivery
occurs only when configured. Token and model enrichment is optional and requires jq 1.6+.
Neither delivery metrics nor simulated users establish real user value. See
[ledger integration](docs/task-ledger-integration.md).

## Contributing and evaluation

```bash
bash tests/run.sh
```

The full suite requires jq 1.6+ for optional-enrichment coverage. CI also runs ShellCheck.
[Behavioral evals](tests/evals/README.md) exercise actual agents locally; offline mock runs
validate the runner, not agent quality. See [CONTRIBUTING.md](CONTRIBUTING.md) and
[tests/README.md](tests/README.md).

Issues and draft pull requests are welcome; only the maintainer merges. Report vulnerabilities
privately as [SECURITY.md](SECURITY.md) describes. Participation follows the
[code of conduct](CODE_OF_CONDUCT.md).

## Origin and license

Product-Kit originates from GitHub's [Spec Kit](https://github.com/github/spec-kit). Released
under the [MIT License](LICENSE), with upstream attribution preserved.
