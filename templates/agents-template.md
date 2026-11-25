# Capabilities

Map recurring needs to available agents or humans. One capable session may cover several roles
where independence is not required; a reviewer never reviews its own implementation.

| Role | Available agent or human | Notes |
|------|--------------------------|-------|
| Intent owner | <human> | product direction, consequential choices |
| Implementation | <session or worker> | bounded changes |
| Independent review | <reviewer context> | review by tier |

## Review registry

<!-- Register stable lowercase identities before their reviews are used. Integrate this policy
first: check-review reads the trusted integration branch's current registry, never the change's.
Role is exactly reviewer or maker. A maker is never eligible, even if listed as a reviewer too.
Capability rows above describe responsibilities; only this registry grants reviewer eligibility.
| Identity | Role |
|----------|------|
| code-review | reviewer |
| implementation-worker | maker |
-->

## Optional tier map

Neutral definitions in `.prdkit/agents/<name>.md` name a tier, never a model;
`.prdkit/scripts/bash/render-agents.sh` (installed with `init.sh --with agent-tiers`) resolves it
here. Opt in to the shared baseline with
`render-agents.sh --refresh-baseline <agent-library checkout>`, then write these lines outside
the code block:

```text
Tier baseline: agent-library tiers.json@<commit written by --refresh-baseline>
Banned models: <exact ids never to project, comma-separated; optional>
Hand-owned agents: <projection names kept without a definition, comma-separated; optional>

| Local tier | Library tier |
|------------|--------------|
| <tier used by a definition> | <verydeep, deep, standard or light> |

| Scope | Harness | Model | Variant | Reason |
|-------|---------|-------|---------|--------|
| <tier:NAME or agent:NAME> | <claude, opencode or *> | <exact id or blank> | <variant or blank> | <why it deviates> |
```

Every override needs a Reason. Neutral definitions require a pinned shared baseline.

To opt into extra projection settings, add a table like this outside the code fence:

```text
| Projection tier | Claude effort | OpenCode permissions | OpenCode preamble |
|-----------------|---------------|----------------------|-------------------|
| *               |               |                      | Use the project rubric. |
| deep            | high          | read, glob, grep     | Start with the review rubric. |
```

Use one row per local tier. Only an empty cell leaves a setting undeclared. Claude effort accepts
`low`, `medium`, `high`, `xhigh`, or `max`. OpenCode permissions opts the tier into V2: `deny`
blocks all actions; a comma-separated list allows only those actions, for all resources.
This replaces any existing permission block and writes the resolved variant as `model:
provider/model#variant` instead of a separate `variant:`. Migrate any other V1 agent fields
before opting in. Remove YAML anchors and aliases before opting into effort or permissions.
A preamble is one Markdown line without pipes or HTML comments; the `*` row provides a
preamble fallback only. Use LF line endings. Omit the table to keep the default render behavior.
