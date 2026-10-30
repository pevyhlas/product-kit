# Optional settings

Unset values use the defaults. Settings never grant authority or weaken checks.

## Configuration

- context-budget-bytes: 16384

## Meaning

`context-budget-bytes` bounds each agent context file (`CLAUDE.md`, `AGENTS.md`, ...); doctor
reports a larger file, and 0 disables the check. Optional adoption-gate keys for
`.prdkit/scripts/bash/check-adoption.sh`: `adoption-pin` (the expected kit commit),
`adoption-manifest-sha256` and `adoption-source` (when the kit is not at `.product-kit`); update
them together on every kit bump.

`review-integration-branches` optionally lists additional remote-tracking integration branches,
comma-separated (for example `origin/develop, origin/release`). Review exemptions trust only
`origin/HEAD` and this list read from its committed config, never a change-local edit. Without
`origin/HEAD`, ordinary review coverage is still checked but neither exemption applies.
