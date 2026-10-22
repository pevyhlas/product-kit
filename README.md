# Product-Kit

**One short, current spec of what your product must be. Your coding agent changes it together
with the code.**

Coding agents change code faster than anyone can track what the product should be. Intent
scatters across chats, per-feature specs and pull requests, and each session re-decides it.
Product-Kit keeps that intent in one Markdown spec in your repository, from user journeys down
to the system's parts, and every change leaves it current. You set direction; the agent asks
only when your answer would change the outcome.

```text
You:    Users need to see which requests need their attention.
Agent:  Individual users or team coordinators? I recommend individuals and will assume that
        if you don't answer.
You:    Individuals.
Agent:  Change 012 adds requirement R-04 with the code. Acceptance A1 passes on staging
        (rev 3f2c1ab, run link); live usefulness is still unmeasured.
```

## How it differs

Feature-first tools such as GitHub's [Spec Kit](https://github.com/github/spec-kit), which
Product-Kit grew from, write a new spec for each feature. Product-Kit keeps one spec for the
whole product.

| | Per-feature specs | Product-Kit |
|---|---|---|
| What you keep | A spec, plan and task list per feature | One product spec, always current |
| After shipping | The feature's spec stays and drifts | The change record is deleted; one log line remains |
| Status | Read through the folders | Generated: true now, in flight, live, held, waiting on you |
| Your role | Review each phase's document | Answer only what changes the outcome |

## Principles

1. **Narrow, don't compile.** The spec rules out expensive wrong choices and never aims to be
   complete; code and tests are the exact implementation.
2. **Journeys first.** Every requirement and every part of the architecture names the user
   journeys it serves.
3. **People own intent.** The agent asks with a recommendation and a default, keeps your answers
   verbatim, and never grants itself more scope, attempts or permission.
4. **Evidence or unknown.** Done names a revision, an environment and a run; without them a claim
   stays unknown.
5. **Short by design.** Every file has a reading budget and a place to grow. The spec explains
   the system; git, pull requests and CI explain the work.

## Start here

> **Experimental.** One maintainer builds Product-Kit and uses it on a handful of projects.
> Interfaces can change between releases; each [CHANGELOG](CHANGELOG.md) entry says how to
> upgrade.

Requires Git and Bash. Product-Kit runs inside your agent session; there is no service. From
your project:

```bash
git submodule add https://github.com/pevyhlas/product-kit .product-kit
bash .product-kit/scripts/init.sh
```

Pin the submodule to a reviewed release tag, run `/prdkit-init`, then ask:

```text
/prdkit Help define the first useful release of this product.
/prdkit --explore Would collaboration actually help our current users?
/prdkit Let users see their unresolved requests.
/prdkit-status
```

See [getting started](docs/getting-started.md), [the human workflow](docs/human-workflow.md),
[adopting an existing product](docs/adoption.md) and, from 0.x,
[migrating to 1.0](docs/migrating-to-1.0.md).

## The spec

```text
L0 specs/product.md            one page: stage, pains, personas, core loop, journeys, the bet
   specs/product/journeys/     one file per journey (J): who, intent, scenario, variations
   specs/product/*.md          requirements (R), qualities (Q), constraints (C), non-goals (N)
   specs/product/lifecycle.md  the stage now (Idea, Demo, MVP, previews, GA, Sunset, Retired)
L1 specs/architecture.md       one page: diagram, parts and why, core loop, key decisions and areas
   specs/architecture/         decisions (D) and topics: security, observability, data, ...
L2 specs/parts/<part>.md       one box: why it exists, components, behaviors, invariants
   code and tests              the exact implementation; tests cite the IDs they prove
```

Each level opens with a one-page summary that links its detail; a small project can keep it all
in one `specs/SPEC.md`. Open changes live in `specs/changes/` and leave one line in
`specs/log.md` when they close. Owner direction and questions go in `specs/inbox.md`; holds,
waivers and deployments in `specs/records.md`. Evidence stays in CI or the pull request, and
the spec links it.

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

Behind each command the agent follows a [playbook](workflows/README.md). See the
[command reference](docs/commands.md) and the [agent workflow](docs/agent-workflow.md).

## Harnesses and upgrades

| `--harness` | Installs |
|-------------|----------|
| `claude` | `.claude/commands/` |
| `opencode` | `.opencode/commands/` |
| `codex` / `agents` | A managed `AGENTS.md` entry pointing to the playbooks |

Every target also gets the playbooks, templates and helpers under `.prdkit/`, so an agent
without slash commands follows the playbook directly. To upgrade, move the submodule to the new
release, then run `init.sh --check` (read-only) and `init.sh --upgrade`. Kit-owned files are
refreshed, templates and memory you edited are kept, and `specs/` is never touched. See
[harness support](docs/harnesses.md) and [customization](docs/customization.md).

The optional [execution ledger](docs/task-ledger-integration.md) spools locally and sends data
only where you configure it.

## Contributing

`bash tests/run.sh` runs the suite (jq 1.6+ for the optional-enrichment tests); CI adds
ShellCheck. [Behavioral evals](tests/evals/README.md) run real agents locally. Issues and draft
pull requests are welcome; only the maintainer merges. See [CONTRIBUTING.md](CONTRIBUTING.md),
[SECURITY.md](SECURITY.md) and the [code of conduct](CODE_OF_CONDUCT.md).

## License

[MIT](LICENSE). Product-Kit originates from GitHub's [Spec Kit](https://github.com/github/spec-kit);
its notice is in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
