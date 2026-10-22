# Getting started

Product-Kit is experimental and may not fit every project: see the note in the [README](../README.md).

1. Install from the consuming repository with Git and Bash:

   ```bash
   git submodule add https://github.com/pevyhlas/product-kit .product-kit
   bash .product-kit/scripts/init.sh
   ```

   Select `--harness opencode`, `--harness agents`, or a comma-separated set when appropriate.
   Pin the submodule to a reviewed tag or commit. Commands install as copies, which work in
   every checkout, change worktrees and CI included ([install mode](customization.md#command-install-mode)).

2. Run `/prdkit-init`. The agent reads your repository before asking setup questions, fills
   `.prdkit/memory/constitution.md` (intent owner, action policy, actual commands, review and
   checks) and writes the first spec: `specs/SPEC.md` for a small product, otherwise the journeys,
   `specs/product.md` with `specs/product/`, and `specs/architecture.md`, describing what is true
   now. Inferred intent
   is marked `hypothesis` and open questions go to `specs/inbox.md`.
3. Read L0 and L1 and confirm or correct them; that is the owner review the spec depends on.
4. Describe an outcome with `/prdkit`. Ask to explore, plan or execute. Bounded work opens a
   change under `specs/changes/` in its own worktree (`.worktrees/<id>`, ignored by Git).
5. Use `/prdkit-status` for progress. `/prdkit-doctor` diagnoses installation and the spec
   without modifying files. `/prdkit-configure` changes policy under your authority.

A change's worktree starts from the current commit, so commit the constitution and the spec
before the first change, or open it with `--no-worktree`. The agent never silently drops
uncommitted context when creating a worktree, nor commits unrelated work to make it available.

Without slash commands, ask the agent to read `.prdkit/workflows/protocol.md` and treat your
message as input. See [harnesses](harnesses.md), the [human workflow](human-workflow.md) and
[adoption](adoption.md). A project on 0.x reads [migrating to 1.0](migrating-to-1.0.md) first.
