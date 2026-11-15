# Optional settings

Optional unset values use the defaults. Review publisher policy must be configured explicitly
on the trusted default branch before the online gate can pass.

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

The review gate also requires these trusted `## Configuration` entries (merge the real numeric
identities first; these placeholders are not usable policy):

```text
- review-host: github
- review-publishers: bot:<numeric account id>
- review-owner: user:<numeric owner id>
- review-publisher-isolation: required
```

`review-publishers` may list comma-separated `bot:` and `user:` numeric ids; `review-owner`
lists personal `user:` ids. Use `gh api users/<login> --jq .id` or
`gh api 'users/<slug>[bot]' --jq .id`. Do not list the shared `github-actions[bot]` identity:
a branch can add workflows using it. `required` is the kit's isolation choice and rejects a
publisher that also authored the PR; it proves account separation, not machine separation.
Use a dedicated reviewer-only App credential, a human publisher, or explicitly choose `shared`.
Shared mode warns that authenticated content/order/counts do not prove reviewer independence.
