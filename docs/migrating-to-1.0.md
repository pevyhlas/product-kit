# Migrating to 1.0

Product-Kit 1.0 replaces the 0.x product definition, targets and feature workspaces with one
hierarchical spec (`specs/product.md`, `specs/architecture.md`, `specs/parts/`) and short-lived
change records. A project on any 0.x version moves in two steps: an installer upgrade, which
never edits `specs/`, and a one-time cutover between changes, which an agent does with the owner.

## Before you upgrade

- **CI calls to removed helpers.** 1.0 removes `artifact-lib.sh`, `check-artifacts.sh`,
  `check-canon.sh`, `check-implement-gates.sh`, `check-prerequisites.sh`, `check-signoff.sh`,
  `cleanup-feature.sh`, `create-new-feature.sh`, `evidence-fingerprint.sh`, `evidence-lib.sh`,
  `parts-lib.sh`, `resolve-context.sh`, `review-scope-lib.sh`, `review-scope.sh`,
  `setup-plan.sh`, `status-lib.sh` and `update-agent-context.sh`; 0.17 removed
  `record-analysis.sh`. A CI step, project script or test that calls one, or reads a retired
  template or workflow, fails after the upgrade; `init.sh --check` lists each reference in a CI
  workflow or tracked project file under RETIRED. Replace it from the table below.
- **CI sign-off gate.** If `.prdkit/memory/signoff-requirements.md` lists `gated-paths:`, CI runs
  `check-signoff.sh`, which 1.0 removes. Replace that step with `check-review.sh`, which checks
  the change record's recorded review verdicts against the head being merged. It runs on change
  branches only, so guard the step; see [CI gates](ci-gates.md).
- **Open features.** Finish short in-flight features on 0.x first; the upgrade removes the 0.x
  per-phase playbooks. No feature folder survives the cutover: a feature the owner keeps open
  becomes a change record (`specs/changes/<id>.md`, same ID) with its intent, remaining tasks
  and acceptance, naming its old folder at the cutover's base commit.
- **Commit first.** The upgrade and the cutover are each one reviewable commit.

## Step 1: upgrade the kit

```bash
git -C .product-kit fetch --tags && git -C .product-kit checkout v1.1.0
bash .product-kit/scripts/init.sh --check     # RETIRED lists what the upgrade removes
bash .product-kit/scripts/init.sh --upgrade
```

This guide follows release 1.1.0, whose cutover writes the 1.1 layout. A project already on 1.0
upgrades the same way, then [restructures](#already-on-10-restructure) instead of Step 2.

The upgrade installs the 1.0 commands, workflows, templates and helpers and removes retired
kit files: the per-phase workflows, the 0.x helpers and every retired template you never
edited. An edited retired template is kept with a warning; fold what you need into the
constitution or a 1.0 template, then delete it. Project memory is preserved: your constitution
keeps its wording (1.0 no longer reads `Stage`), and `signoff-requirements.md` stays until the
cutover folds it. The installer then reports that the project needs a cutover; until then
doctor reports the 0.x layout and 1.0 workflows do not apply.

## Step 2: cut over

Between changes, run `/prdkit-init`; the agent follows Cutover in `.prdkit/workflows/compact.md`:

1. Write the spec from the current canon, the code and the constitution, describing what is
   true now: journeys first (one file each under `specs/product/journeys/`), then requirements,
   qualities, constraints and non-goals, then the lifecycle, then the `product.md` summary, then
   `architecture.md`. Owner-decided, unbuilt items are `planned`. Contradictions become inbox
   questions with both sources, a recommendation and a default. IDs have two or more digits:
   `D-1` becomes `D-01`, with its citations in code and docs.
2. Give each constraint its why, scope (part and journey IDs, or `all`), source and revisit
   condition. A constraint whose only source is an earlier agent's text becomes an inbox
   question.
3. Draw the system diagram and list each box as a part in the `architecture.md` overview, with
   the journeys that need it; detail goes to `specs/architecture/<topic>.md`. Write a part file
   only for a box with real obligations, its components as sections; the rest may link a
   document that stays on main as `legacy`.
4. Condense, then remove: a sleep pass over the old canon, targets and every feature folder,
   from the main commit the cutover starts from (the base). What still binds goes into the
   spec, owner words verbatim: decisions as D-NN, observed facts, rules in requirements,
   constraints or the constitution, whose `Review and checks` takes in the old verification
   policy. Directions tried, why they stopped and lessons go into one condensed
   `specs/archive.md` (`.prdkit/templates/archive-template.md`): a few lines per entry, details
   as a git path at the base, plus the base and the last 0.x feature number, which
   `new-change.sh` never reuses. Then `git rm` them all; git keeps them, and no old file
   competes with the spec in a search. Agent context files, harness memory and agent
   instructions stop naming them, and links into them are repointed or dropped. Raw evidence
   elsewhere under `specs/` is untracked (`git rm --cached`) and kept under
   `.prdkit/cache/evidence/`.
5. Copy owner direction found in agent memory, plans and worklogs into `specs/inbox.md` as
   headed items (`.prdkit/templates/inbox-template.md`); an older prose preamble becomes the
   template's comment.
6. Read every file once more for the reader: crisp wording, roles not names, repo-relative
   paths. Run doctor and status. The owner reads L0 and L1 and confirms or corrects them.

## Already on 1.0: restructure

Between changes, the agent follows Restructure in `.prdkit/workflows/compact.md`: journey files,
the product and architecture detail files, the lifecycle, parts as the boxes of the system
diagram, and the inbox as headed items. A `specs/archive/` folder from the 1.0 cutover, and any
0.x feature folder still on main, get the same condensing pass (Step 2, item 4), from the main
commit the restructure starts from. A feature the owner keeps open becomes a change record, a
part that linked an archived document as `legacy` takes in what still binds, and agent context
that names `specs/archive/` points at `specs/archive.md`. Doctor reports `specs/archive/` on main
until then.

## Where 0.x things went

| 0.x | 1.0 |
|-----|-----|
| `specs/product-spec/` and its domain documents | `product.md` (L0), `architecture.md` (L1), `parts/` (L2) |
| `FR-`, `AC-`, domain IDs | `R-`, `Q-`, `C-`, `D-`, `P<n>`, `P<n>.B-`, `P<n>.I-`; acceptance items `A1`… per change |
| `specs/targets/<id>/target.md` | a parent change (`/prdkit-target`), or journeys and thesis in L0 |
| `specs/features/<id>/` (`spec.md`, `tasks.md`, `acceptance.md`, `readiness.md`) | `specs/changes/<id>.md`, deleted on close, plus one line in `specs/log.md` |
| Closed features, superseded canon and targets | what binds in the spec; directions tried and lessons in `specs/archive.md`; the files in git only |
| Holds, owner gates and approvals in task State or targets | `HOLD`, `WAIVER`, `ATTEST`, `DEPLOY` lines in `specs/records.md` |
| Opportunities and later horizons | inbox items `deferred:`, or `Left open` in L0 |
| Evidence and review packs under `specs/` | `.prdkit/cache/evidence/`, CI and PR links |
| `signoff-requirements.md`, Stage | the constitution's `Review and checks`; review tiers T0–T3 |
| `create-new-feature.sh`, `setup-plan.sh`, `check-prerequisites.sh`, `resolve-context.sh` | `new-change.sh`; the context order is in `protocol.md` |
| `cleanup-feature.sh` | `cleanup-change.sh` |
| `check-artifacts.sh`, `check-canon.sh`, `check-implement-gates.sh` | `doctor.sh` (IDs, records, layout, budgets) |
| `check-signoff.sh`, `evidence-fingerprint.sh`, `review-scope.sh` | `check-review.sh`: recorded verdicts must cover the merged head; no readiness record or fingerprint |
| `update-agent-context.sh` | removed; context files are hand-kept orientation, and doctor reports their size |
| `artifact-lib.sh`, `evidence-lib.sh`, `parts-lib.sh`, `review-scope-lib.sh`, `status-lib.sh` (sourced libraries) | `spec-lib.sh`, internal; a project script reads `doctor.sh --json` or `status.sh --json` instead |
| `record-analysis.sh` (removed in 0.17) | none; an analysis is part of the change record or its review report |
| `status.sh --target/--feature/--overview`, linked repositories | `status.sh [--json]`, one generated view |
| Retrospectives under the feature folder | `.prdkit/cache/retrospectives/<change-id>.md` |

The execution ledger keeps `prdkit.ledger.v1`; the feature id is now the change id. 0.x event
types stay schema-valid in existing spools, and 1.0 emits the subset listed in the
[task-ledger template](../templates/task-ledger-template.md).

To undo an upgrade before the cutover, revert its commit; `specs/` was not modified.
