# Optional capability and agent lifecycle

A capable current session can coordinate and implement ordinary work. Independent review
needs a distinct context/reviewer where applicable. Add reusable specialist definitions when
recurring needs justify them, rather than automatically creating an agent for each domain.

The project owns `.prdkit/memory/agents.md` and optional `.prdkit/agents/<name>.md`
definitions using the [neutral template](../templates/agent-definition-template.md).
Definitions name a tier, never a model. Validate the actual harness format/loader after a
render; unavailable validation stays unknown.

## Rendering projections

`.prdkit/scripts/bash/render-agents.sh` is the deterministic renderer (Bash + awk, offline):

| Command | Effect |
|---------|--------|
| `render-agents.sh` | Write `.claude/agents/<name>.md` / `.opencode/agents/<name>.md`; nothing is written while the tier map or a definition's `harnesses:` line has findings |
| `render-agents.sh --check [--json]` | Exit 1 on tier-map findings, malformed `harnesses:` lists, unresolvable tiers, missing or (with a baseline) unowned projections, or model/variant/description/body drift |
| `render-agents.sh --resolve [--json]` | Show each agent/harness model, variant and its source (baseline, literal, override) |
| `render-agents.sh --refresh-baseline <library> [--library-ref <ref>]` | Vendor the library `tiers.json` at a committed revision and update the `Tier baseline:` line |

Resolution: shared baseline (explicit `Local tier -> Library tier` row, else the library tier
of the same name, else the aliases `frontier`->`verydeep`, `high`->`deep`, `fast`->`light`)
or, without a baseline, the legacy literal table; then `tier:` overrides, then `agent:`
overrides (a specific harness beats `*`). The renderer owns `model`, OpenCode `variant`,
`description` (copied from a single-line neutral description; a block scalar stays
project-owned) and the prompt body (the whole neutral body, local overlay included). Every
other projection frontmatter key and leading generated-marker comments are preserved; files
are rewritten only when content changes. A new projection gets name, description and model
(plus `mode: subagent` and variant for OpenCode); add native extras once and they persist.

A definition limits its harnesses only with a bracketed list of projection harnesses,
`harnesses: [opencode]` or `harnesses: [claude, opencode]`. A bare value, an empty list or an
unknown name is a finding, and the render refuses until it is fixed; it is never read as
"every harness". Once a `Tier baseline:` is declared, every file in `.claude/agents/` and
`.opencode/agents/` must be owned. That means rendered from a definition that targets that
harness, or listed on a `Hand-owned agents: <name>, <name>` line in agents.md for projections
the project maintains by hand. An unowned projection is a finding, because nothing would check
its model or body. The banned-model check still covers hand-owned projections.

Agent libraries own canonical bodies and the shared tier map; the project owns its overlay,
the tier mapping and reasoned overrides. Refreshing a library body (for example with the
library's sync tooling) is followed by `render-agents.sh` and a reviewed diff.

`/prdkit-configure` handles authorized definition/mapping changes. `/prdkit-doctor` diagnoses
roster coverage, missing projections and tier-map findings (banned exact ids, missing
reasons, snapshot hand edits or baseline mismatch, literal ids beside a baseline, malformed
`harnesses:` lists); with a shared baseline it also reports projection drift and unowned
projections, as does the adoption gate (`check-adoption.sh`). Change a mapping on recorded
evidence and an explicit proposal; finding counts or model novelty alone do not demonstrate
better performance.

This lifecycle supports delivery. Product learning about user value is a separate concern
handled by `/prdkit-learn`.
