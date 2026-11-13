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
comma-separated (for example `origin/develop, origin/release`). The review check accepts only
`origin/HEAD` and this list, read from its committed config, never a change-local edit, as the
base it reads its policy from; without `origin/HEAD` it fails.

`review-t0-paths` lists the paths a T0 (docs-only) change may touch, comma-separated literal
paths, a trailing `/` naming a directory (for example `docs/, README.md`); no patterns. It is
read from the trusted integration branch. A T0 change passes only when every path it changes,
outside its record and the log, is a regular non-executable file under one of them, and never
`.prdkit/`, another change record or the L0/L1 spec. Unset, T0 covers only the record and the log.
