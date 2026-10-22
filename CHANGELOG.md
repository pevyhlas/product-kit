# Changelog

All notable changes to Product-Kit are documented here. The format is loosely based on
[Keep a Changelog](https://keepachangelog.com/), and Product-Kit uses semantic versioning.

Pre-0.1.0 history is condensed into the design decisions it produced rather than replayed
change by change.

## [Unreleased]

- The installer ignores `.prdkit/retrospective/` in Git (added on the next upgrade), so optional
  usage-enrichment inputs with agent names, costs and notes are not committed by a routine
  `git add -A`. Change cleanup copies them out of the worktree like evidence.
- `new-change.sh` serializes automatic numbering on a lock in the Git common directory, so
  concurrent runs, linked worktrees included, no longer open changes with the same number.
- `ledger-emit.sh` refuses an adapter `command:` that is a symlink, so the inside-repository rule
  cannot be bypassed by linking to an executable elsewhere.
- `init.sh` installs commands as copies by default, so a change worktree keeps its slash commands
  without an initialized submodule. `--symlink` stays available, and an existing symlink install
  keeps its links until you pass `--copy` once; `new-change.sh` now warns when a new worktree's
  command links do not resolve and names the fix.
- The behavioral eval runner stops before setting up a scenario when it cannot allocate a
  fixture directory, and fixture setup refuses an empty or reused root, so a scenario never
  initializes Git or commits in the caller's checkout.
- The installer keeps every write and deletion inside the project. A manifest entry outside the
  installed layout is ignored, a symlinked or escaping managed directory is refused before
  anything is written, kit-owned files replace a symlink instead of writing through it, and a
  symlinked template or memory file is kept, even with `--force`.
- Releases and their tag messages are titled `Product Kit - vX.Y.Z`. The CHANGELOG heading keeps
  its subtitle, and the release notes still open with it.
- The README leads with the pitch, how Product-Kit differs from per-feature spec tools and
  its principles, in less text.

## [1.1.0] — 2026-10-19 — journeys first, an executive page and a readable inbox

1.1.0 is the first public release. The public repository starts at this version; the entries
below it record the earlier development. Product-Kit is experimental and may not suit every
project.

The owner's review of the three 1.0 pilots: the spec dropped items to fit its ceilings, read as
dense text, and could not describe a large product. 1.1 reshapes the spec around what users do,
for people first.

### Changed

- **L0 is an executive page plus detail files.** `specs/product.md` is read at a glance (80
  lines): one sentence, the problem as a table of pains with their evidence and the journeys
  that solve them, a diagram, who it is for (personas only), the core loop and the supporting
  journeys, the most important items, the bet and what waits on the owner. Journeys,
  requirements, qualities, constraints and non-goals move to `specs/product/`.
- **The lifecycle decides what is needed now.** `specs/product/lifecycle.md` names the stage
  (Idea, Demo, MVP, Private preview, Public preview, GA, Sunset, Retired) now and next, with
  each stage's goal, audience, environment, promise and exit criteria; only the owner moves it.
  An item needed only later carries `from: <stage>`; product.md shows journeys by area and
  stage. Agents build for the current stage: bounds.sh lists later items apart, status shows the
  stage, and doctor checks stage names, reached markers and that product.md's stage columns
  match the journeys' markers. Testers and demo audiences are a stage's audience, not personas.
  A constitution rule deferred for now names the stage it is due before, and an older
  constitution Stage field points to lifecycle.md.
- **Environments are where stages run.** A new architecture topic,
  `specs/architecture/environments.md`, lists each environment: what it is for, where it is
  provisioned (its own account, subscription or project; a small product's production may start
  in the early-access one), its data, who reaches it and how a release gets there, with the promotion
  path as a diagram. An environment is not a stage: early access keeps taking new features first
  once production opens. Each stage's **Environment** line names one, and doctor advises when it
  names none the topic lists.
- **Journeys come first.** One file per journey (`specs/product/journeys/j-NN-<slug>.md`): which
  persona, intent, situation, scenario, variations (such as an intermittent connection) and
  success. The chain runs pain → journey → part. Testers, deployers and self-hosters are not
  personas, and people who do the same thing at different points of the loop (one starts it,
  another continues it) are one persona, with one experience. Requirements and qualities cite
  the journeys they serve; architecture gives each journey a path through the parts.
- **Each level opens with a one-page summary.** `specs/architecture.md` becomes the overview (100
  lines): the system diagram, parts and why each exists, the core loop as a sequence diagram,
  key decisions, key areas (security and privacy, observability and live site, data, interfaces,
  environments, operations) in a line each, and risks. Detail goes to
  `specs/architecture/<topic>.md` (`architecture-topics-template.md`) and to the part files;
  technology choices are decisions.
- **Parts are the boxes of the system diagram** (an app, a service, a worker, a store), each
  saying which journeys need it, with components as sections. A component gets its own file
  (`specs/parts/p<n>-<slug>/<component>.md`) only when the part outgrows its budget. Tooling goes
  to the operations topic and external systems to the interfaces topic.
- **Diagrams first.** Mermaid flowcharts, sequence and state diagrams replace the prose they
  make redundant; IDs and promises stay in text.
- **Ceilings become reading budgets, and every budget has a split.** Past one, a file is
  tightened or split, never trimmed of items. spec.md's Layout names where each file grows
  (journeys into two journeys; pains and personas into `users.md`; non-goals, lifecycle,
  topics, observed facts and the Retired list into area or stage files; a component or any
  piece into two), and each piece keeps its parent's budget. The parent links every piece:
  doctor advises on a spec link to a missing file, on a spec file that no chain of links from
  product.md or architecture.md reaches (1.1 layout; a folder link reaches the files directly in
  it; retired files exempt), and on an `observed/` piece `observed.md` does not link. Spec text
  is crisp, names roles rather than people, and uses repository-relative paths.
- **The inbox is readable.** Each item is a heading, a `*<date> · <owner|agent> · <disposition>*`
  line, and either the owner's words as a quote or a question with numbered options, the
  recommended one first, and the default if no answer comes. Scripts still read the one-line
  form; doctor asks to rewrite it.
- **No raw archive on main.** Old files on main surface in searches and conflict with the
  current spec, so the cutover no longer moves them under `specs/archive/`. It condenses the old
  canon, targets and every feature folder: what still binds goes into the spec (decisions,
  observed facts, rules; owner words verbatim), directions tried, why they stopped and lessons
  go into one past-tense `specs/archive.md` with each entry's details as a git path at the
  cutover's base commit, and the files leave main with `git rm`; git keeps them. Agents read
  `specs/archive.md` on demand, never by default. A feature or target the owner keeps open
  becomes a change record instead of finishing in place, and `planned:` markers name that change,
  never the removed target (found drafting a consumer project's 1.1 spec): a feature folder
  beside the 1.0 spec is two canons, and status lists it in flight as a cutover to finish
  (`leftover_features` in `--json` replaces `legacy_changes`). Doctor and status judge 0.x
  folders by what git would keep, so an ignored leftover of a removed folder no longer counts.
  Agent context and harness memory stop naming the removed folders.

### Added

- `bounds.sh <change>` lists the constraints, non-goals and qualities a change must respect,
  from the parts and journeys in its record's header, widened through the parts table, and
  lists later-stage items apart. The change record's new Bounds section
  marks each it could break as holding or in conflict (a conflict goes to the owner), and the
  reviewer runs the same list: a violated constraint or non-goal is a high finding.
- `J-` (journey) and `N-` (non-goal) IDs. A journey file's heading defines it:
  `# J-01 Title (hypothesis)`. Status counts journeys and non-goals.
- Templates: `journey`, `requirements`, `qualities`, `constraints`, `non-goals`, `lifecycle`,
  `architecture-topics`, `archive`.
- Doctor: a finding for a change record deleted without its `specs/log.md` line, and advisories
  for a machine's own paths (`/home/<user>`, `/Users/<user>`, `C:\Users\<user>`) in tracked
  Markdown outside 0.x folders and `specs/archive/`, and for one-line inbox items.
- `specs/architecture/decisions.md` holds D- decisions as `## D-NN` sections with bold-label
  lines (decision, alternatives, revisit when), split into `decisions/<area>.md` past its budget;
  a decision heading carries its own `(retired: <reason>)`. A `## Retired` list in
  `specs/architecture/retired.md` records parts that went and IDs that moved; status counts them.
- `check-review.sh` fails a close whose head deletes the change record without adding its
  `specs/log.md` line, and counts `specs/product/` and `specs/architecture/` as L0/L1 edits.
- The parts table's Maturity column is found by its header, not its position.
- Doctor advises on a tracked `specs/archive/`, on a `specs/archive.md` whose base commit is not
  in the repository or whose last 0.x feature cannot be read, and on agent context naming removed
  0.x paths: a plain repo-relative path, never a placeholder, glob, bare folder, `git show`
  pointer, URL or `owner/repo:path` (found in a pilot). It checks the links in `specs/archive.md`
  and gives it a 150-line budget that grows into git: older entries condense harder.
- `new-change.sh` never reuses a 0.x feature number once the folders are gone: it reads them from
  git (the folders at the archive's base commit, and those removed in recent history) and from
  the archive's `**Last 0.x feature**` line, read loosely, and takes the highest. When none of
  them can be read but `specs/archive.md` exists, it stops and asks for a fix or `--number`; a
  shallow clone without the archive warns.

### Fixed

- `status.sh` and `doctor.sh` missed a capitalized `Retired:` or `Unenforced` marker, so a
  retired item counted as live and an unenforced quality or invariant went unlisted. The
  markers now match in any case (found dry-running a consumer project's cutover).
- A parts-table row with `planned:` in any cell marked the whole part planned, and a Maturity
  cell holding a planned marker lost its maturity. Both now come from the Maturity cell
  (`hypothesis, planned: 012-export`); found drafting a consumer project's 1.1 spec.
- `new-change.sh` handed out a number that a `planned: <change>` marker already names, so the new
  change collided with the planned one. It now reserves every change the spec's `planned:`
  markers name, outside comments and code blocks, reading each item whole, so a marker that
  wraps across a line counts; it takes the highest with its other sources. Found in pilots. An
  explicit `--number` still overrides, with a notice naming what else holds that number (its own
  `planned:` marker does not count).
- On macOS, in a UTF-8 locale, macOS awk stops with "towc: multibyte conversion failure" when a
  regex meets one byte of a multibyte character. On a one-line inbox item with the `→` arrow
  (since 1.0.1), `status.sh` exited 2, and `doctor.sh` printed the error, still exited 0 and
  silently dropped the inbox advisories from that item on. On a spec or test file citing an ID
  beside any non-ASCII character, such as a dash, a curly quote or an accent (`R-01—`,
  `“R-01”`; since 1.0.0), `doctor.sh` did the same with its citation advisories. One character
  is now compared, never matched; found standing in for the macOS CI job.

### Adoption

- 1.0 projects keep working: a single `specs/product.md` still parses and keeps its 150-line
  budget, and its one-digit `- **J-1 …**` journey bullets are an advisory pointing to the
  Restructure, not a failing finding. To adopt 1.1, run the Restructure in `.prdkit/workflows/compact.md` once, between
  changes: journey files, the detail files, parts as boxes, the inbox as headed items.
- 0.x projects cut over straight to the 1.1 layout (`compact.md`, Cutover).
- A 1.0 project with `specs/archive/` on main runs the same condensing pass in its Restructure,
  from the commit the Restructure starts from; an open 0.x feature becomes a change record.
  Doctor advises until then.
- **First public release.** This repository starts from fresh history at 1.1.0, so earlier
  tags and commits are not available here. A project pinned to an earlier commit re-pins to
  v1.1.0 with the usual submodule steps:
  `git -C .product-kit fetch --tags && git -C .product-kit checkout v1.1.0`, then
  `bash .product-kit/scripts/init.sh --upgrade`, and commit the new submodule pin.

## [1.0.1] — 2026-10-19 — cutover fixes

Fixes found cutting pilot consumer projects over to 1.0, and dry-running another's cutover.

### Fixed

- `init.sh --check` listed no retired-helper call after the first CI workflow that references
  no kit file (the scan ran under `pipefail` and stopped there). It now finishes, and it lists
  references in every tracked project file too, not only CI workflows: installed or kit paths
  to retired helpers, templates and workflows (a template the project added is its own), and a
  retired helper's name as a quoted string, which a script uses to build the path.
  A CI job running a project script that sourced `artifact-lib.sh`, or a test pinning a retired
  template, failed after the upgrade with no warning. Prose (`*.md`), recorded diffs, `specs/`,
  the installed kit and `#` comment lines are not scanned; names with any characters are read.
- Owner inbox: the disposition arrow is the one after a closing quote that names a disposition,
  so quoted words that contain `→` or `->` no longer read as a line without a disposition.
- Records: a value runs to the next `key=`, so `until=v2 and the security review` and
  `what=internal beta build` keep every word instead of being cut to the first; a word
  before the first key is a malformed record. A date stays a date, so a dated hold with a note
  but no `—` still expires. The reason starts at a `—` after any whitespace.
- Status: a squash-merged branch stays "possibly squash-merged" after the default branch changes
  its files again or GitHub's update-branch merged the default branch into it.

### Docs

- Cutover and the migration guide: renumber one-digit IDs to two digits with their citations,
  have a project link check skip `specs/archive/`, and convert an older inbox preamble to the
  1.0 line format. The guide lists `record-analysis.sh` (removed in 0.17) among retired helpers.

## [1.0.0] — 2026-10-19 — hierarchical spec

1.0 replaces the 0.x product definition, targets and per-phase feature workspaces with one
short, current spec in three levels and short-lived change records. In the round-2 replays
most of the gain came from taking machinery out (v4 scored 97/126 against 90/126, mostly on
owner burden, economy and resumability); the L0/L1/L2 hierarchy itself was not isolated. The
kit's installed text shrinks from about 134 KB to about 37 KB.

### Changed

- **Spec**: `specs/product.md` (L0: problem, users, requirements `R-`, qualities `Q-`,
  constraints `C-`, thesis), `specs/architecture.md` (L1: parts `P<n>`, interfaces, choices,
  why it works, decisions `D-` in `specs/decisions/`) and `specs/parts/<part>.md` (L2:
  behaviors `P<n>.B-`, invariants `P<n>.I-`), or one `specs/SPEC.md` for a small product. A line
  stays only if it rules out meaningful wrong implementations and rejects no valid real input.
  Markers `(hypothesis|validated)`, `planned: <change>` (written with the maturity:
  `(validated, planned: <change>)`), `retired: <reason>`, `unenforced`; a bullet's markers may
  wrap onto its continuation lines. Size ceilings are advisory and never targets.
- **Changes**: `specs/changes/<id>.md` (intent with inbox dispositions, spec edits, approach,
  tasks, checks, Acceptance `Item | Proves | Check | Attempts | Result`, State) is deleted when
  the change closes, leaving one line in `specs/log.md`. Spec edits land in the PR whose code
  and tests realize them. A programme is a parent change (`/prdkit-target`).
- **Owner channel and records**: owner direction verbatim in `specs/inbox.md`, facts about
  external systems in `specs/observed.md`, `HOLD`/`WAIVER`/`ATTEST`/`DEPLOY` lines in
  `specs/records.md`.
- **Protocol** carries the 0.15 authority wording, the stall budget (three attempts, or two
  without new information, then an alternatives note and NEEDS_DECISION) and the 0.16 rule that
  raw evidence never lives in `specs/`. Review is proportional to tiers T0–T3 and run by the
  worker, not CI: each report is posted on the PR and recorded as one `**Review**:` line in the
  change's State.
- **Workflows**: `protocol`, `spec`, `change`, `status`, `compact` (cutover and compaction),
  `init`, `configure`, `learn`, `doctor`. The eight command names are unchanged; their
  descriptions now route to these playbooks.
- **Helpers**: new `spec-lib.sh` and `new-change.sh` (numbering across checkouts and branches,
  worktree by default, never overwrites, refuses the in-place fallback on a dirty tree, names
  uncommitted `specs/` context the new worktree lacks as `UNCARRIED_SPECS`). New
  `check-review.sh` replaces the sign-off gate: before merge it checks the change record's State
  `**Review**:` lines against the exact head being merged. Every reviewer's latest verdict must
  be PASS with nothing blocking for the rigor (medium blocks when no Rigor is named), and an
  earlier blocking line stands until a later clean PASS from the same reviewer reaches it. Recorded
  ranges, commit hashes, superseded rounds included, must chain from the change's start and
  from each reviewer's head to the merged head, so scoped re-reviews of fixes pass and a gap
  fails. T1–T3 need one independent verdict, T3 the owner's too. A pull request carrying only
  the record and the log (a change closed after its code merged) skips coverage. It needs no
  network or model credentials, so the merging agent and CI can both run it.
  `build-review-package.sh` prints the resolved `BASE_SHA` and `HEAD_SHA` the line records.
  `status.sh [--json]` is rewritten as one generated view (true now, in flight, live, holds and
  waivers, owner queue, longest pole). It finds open change records in every registered
  worktree and says where each lives,
  lists a 0.x feature kept open beside the 1.0 spec as a legacy change with its task progress,
  labels possibly squash-merged branches, counts a deploy's distance from the default branch
  both ways, reads `DEPLOY <app> env=<env> rev=none …` as nothing deployed, never counts a
  passed item as stalled, and never fetches in a partial clone (Git without
  `GIT_NO_LAZY_FETCH` skips those reads and says so). A record the root's log closed is not
  listed from an older worktree. `doctor.sh [--json] [--strict]`
  is rewritten for the 1.0 layout; it reports inbox lines it cannot parse, accepts
  `YYYY-MM-DDThh:mmZ` dates and flags `specs/SPEC.md` beside split spec files.
  `cleanup-feature.sh` is now `cleanup-change.sh`; it refuses a dirty worktree before copying
  anything, copies every evidence file and retrospective from the worktree's cache into the main
  checkout's and verifies them, appends the worktree's ledger events, then removes the worktree.
  It refuses to run as the copy inside the worktree it removes.
  Review packages go to `.prdkit/cache/evidence/<change-id>/reviews/`, retrospectives to
  `.prdkit/cache/retrospectives/`. `check-delivery.sh` takes an optional checkout path.
- **Ledger**: `prdkit.ledger.v1` is unchanged; the feature id is the change id. 1.0 emits
  `feature.created`, `review.recorded`, `evidence.recorded`, `blocker.opened`/`resolved` and
  `feature.merged`; the other 0.x events stay schema-valid in existing spools.
- **Installer**: never creates or edits `specs/`; reports when a 0.x project needs its cutover,
  when `signoff-requirements.md` still configures the 0.x CI gate, and when a CI workflow
  calls a removed helper (`--check` lists each call under RETIRED; the upgrade warns).
- **Constitution template** drops `Stage`; review and check requirements live in its
  `Review and checks` section.

### Removed

- Workflows: intake, specify, clarify, plan, tasks, analyze, implement, verify, review,
  signoff, integrate, delivery, amend, target, product, parts, reconcile-canon, baseline,
  explore-design, integrations, artifacts.
- Templates: target, tasks, plan, acceptance, readiness, outcome, opportunity, domain-spec,
  canon-archive, design-review-prompt, signoff-requirements, agent-file.
- Helpers: `create-new-feature.sh`, `check-artifacts.sh`, `check-canon.sh`,
  `check-implement-gates.sh`, `check-prerequisites.sh`, `check-signoff.sh`,
  `evidence-fingerprint.sh`, `review-scope.sh`, `setup-plan.sh`, `resolve-context.sh`,
  `update-agent-context.sh` and the libraries only they used (`artifact-lib`, `evidence-lib`,
  `parts-lib`, `status-lib`, `review-scope-lib`).
- **The 0.x sign-off gate** (`check-signoff.sh`, readiness records and evidence fingerprints);
  `check-review.sh` replaces it.
- Status filters (`--target`, `--feature`, `--part`, `--overview`, `--all`) and linked
  repositories; issue export and agent optimization; the agent context updater and its
  section caps (`context-budget-bytes` remains).
- Eval scenarios 02 (implement gate), 03 (sign-off pressure) and 07 (phase preflight); the
  layered-parts example and the baseline, backlog, layered-parts and private-adoption docs.

### Fixed

- `init.sh --check` reported an unedited AGENTS.md managed section from an older kit as a
  kit-owned edit with a diff against a kit script; it is now OUTDATED, and an edited section
  points at the text between the markers.

### Migration

- From any 0.x version. Before upgrading, check `.prdkit/memory/signoff-requirements.md`: with
  `gated-paths:` CI runs `check-signoff.sh`; replace that step with `check-review.sh`. Replace
  other CI steps that call a removed helper (`init.sh --check` lists them).
- `init.sh --upgrade` installs 1.0, removes retired kit files (an edited retired template is
  kept with a warning) and leaves `specs/` untouched. Then, between changes, run `/prdkit-init`
  for the one-time cutover (`compact.md`): write L0 and L1 from the current canon and code,
  turn contradictions into inbox questions, `git mv` old canon, targets and closed features
  under `specs/archive/`, untrack raw evidence and fold the verification policy into the
  constitution. A feature the owner keeps open finishes in place under the 1.0 protocol. See [docs/migrating-to-1.0.md](docs/migrating-to-1.0.md).

## [0.17.0] — 2026-10-17 — lean feature workspace

In the round-2 replays, the arm without per-feature analysis, handover and acceptance files,
fingerprints and revision bumps reached comparable outcomes with less churn: 5 new files
instead of 12 in one episode, no revision bumps instead of 3 in another. This release removes
that machinery from the everyday path. The opt-in CI sign-off gate keeps working.

### Changed

- A feature is `spec.md` plus `tasks.md`. The tasks template gains `## Acceptance`
  (`Item | Proves | Check | Attempts | Result`, evidence by https URL or cache path), `## State`
  (current step, attempts per blocker and acceptance item, blockers, holds with their source,
  branch/checkpoint/PR, authority per action, next action) and an optional `## Checks`.
- Analysis writes no file and records no fingerprint. A blocking finding sets the spec's
  `Clarification: needs-decision` with the open question. `check-implement-gates.sh` checks
  clarification, an active linked target and defined tasks; its JSON keys are unchanged.
- No revision numbers: `Revision` is optional on every artifact and `Target revision` binds
  nothing, so an in-place target edit no longer forces feature rebinding. Legacy fields are
  tolerated (a malformed `Revision` still fails). Status no longer prints target revisions.
- Verify, signoff, delivery, implement and specify record acceptance, readiness and handover in
  tasks.md. Feature `acceptance.md` and `readiness.md` remain only as CI sign-off gate inputs;
  target `acceptance.md` is unchanged. The gate's evidence Subject is the feature ID, plus the
  legacy `, revision <n>` while a spec still carries one; it no longer requires `analysis.md`.
- `init.sh --upgrade` removes kit scripts, workflows and unmodified templates that an older kit
  recorded but this kit no longer ships; `--check` lists them as RETIRED. An edited template is
  kept with a warning.

### Removed

- `record-analysis.sh` and `templates/handover-template.md`.

### Upgrade notes

- Existing `analysis.md`, `handover.md` and non-gated feature `acceptance.md` files may stay;
  fold them into tasks.md at the next touch. Legacy `Revision` lines can be dropped then too.
- Gated projects: stamped readiness records keep validating (the readiness fingerprint's inputs
  are unchanged and still include a legacy `analysis.md` while it exists). Removing a spec's
  `Revision` changes its Subject, so re-capture evidence metadata and restamp when you do.

## [0.16.0] — 2026-10-17 — evidence out of specs

Consumer `specs/` folders were 98% committed tool output (one project: 281 MB of review
diffs, test result files and captures against 1.9 MB of spec, plan and tasks), partly because
the kit wrote and required it there.

### Changed

- `build-review-package.sh` writes `diff.patch`, `commits.txt` and `diffstat.txt` to the
  gitignored `.prdkit/cache/evidence/<feature>/reviews/<task>/round-N/` and creates the feature's
  `reviews/<task>/round-N/` only for the reviewer's short report. Rounds continue across both
  locations, including packages older kits wrote into the feature. JSON output adds
  `RECORD_DIR`; it warns when `.prdkit/cache/` is not gitignored.
- `init.sh` seeds `.prdkit/cache/` in `.gitignore`.
- The CI sign-off gate accepts an https URL (a CI run) as acceptance output and as `Check:`
  evidence, so raw output need not be committed. Independent reviews still need their local
  original record with a Verdict; plain http is rejected.
- Verify, review, integrate and the artifact contract keep raw output in CI or the cache and
  record a one-line summary with a link; archives never carry raw evidence.

### Added

- Doctor advisory for raw evidence still tracked under `specs/` (files under `reviews/`,
  `results/` or `evidence/` other than Markdown, and `.patch`, `.trx`, `.log`), with a count,
  size and the `git rm --cached` repair.

## [0.15.0] — 2026-10-17 — owner authority and stall budget

Rules that changed outcomes in controlled replays of real consumer episodes (both arms from a
cleaned baseline, blind judges). Each removes a cause of agent loops or owner re-work.

### Added

- Stall budget per blocker (`protocol.md`). Attempts are counted per failing outcome across
  tasks, PRs and sessions; a merged PR whose own checks pass while the outcome still fails is an
  attempt. After three attempts, or two with no new information, the agent writes an
  alternatives note (including a managed option and relaxing the forcing check) and reports
  NEEDS_DECISION to the owner while other eligible work continues.
- Owner inbox `specs/inbox.md` (`templates/inbox-template.md`): owner direction verbatim, dated,
  with a disposition (open, folded, declined, deferred). Folded lines are deleted once landed.
  The managed AGENTS.md section points to it, so every harness finds it.
- Observed facts `specs/observed.md`, and sample-first for external data shapes: before code
  depends on an external system's shape, capture a secret-safe sample or cite the contract.
  Readers of external data accept unknown fields; redacting checks keep a secret-safe debug path.
- Every owner question carries a recommendation and, for reversible choices, the default the
  agent applies if no answer arrives.
- Review scaled to the change by default (docs-only none; one domain one reviewer; several
  domains, interfaces, security or data each applicable domain; direction or architecture a
  design review plus the owner). No review round without changed source.
- Status answers the owner's question first and keeps merged, live and validated distinct,
  naming the longest remaining item and open owner items.

### Changed

- Only a human (the intent owner, or a human they name) extends limits or grants authority. An
  agent session, including an operational lead or coordinator, no longer allocates follow-up
  rounds after exhaustion. Owner words relayed verbatim stay owner direction and are not re-asked.
- Targets are edited in place; the template's append-only Amendments section is removed.
  Amendments record each active feature's impact once (`Spec impact: none — <reason>`) instead
  of touching unaffected features.
- Part-scoped review treats `specs/inbox.md` and `specs/observed.md` as neutral, so recording
  owner direction does not widen review to the whole product.

## [0.14.0] — 2026-10-16 — progress per part

### Added

- `status.sh --overview` (Markdown table; `--json` structured): one row per non-retired part
  (or one `(product)` row without parts, plus `(unscoped)` when needed) counting slice states
  across active targets, with each target's lowest-numbered ready slice as next eligible. Slices
  whose parts are unknown, retired or malformed are counted in an `(invalid parts)` row under
  every view instead of disappearing. It states that counts are mechanical and acceptance still
  needs evidence review. `--part` and `--checkout-only` narrow it.
- Optional `Parts` column in target slice tables. Tables are now read by header name, so
  existing four-column tables parse unchanged; an empty cell inherits the target's Parts.
  `--part <id>` lists only the slices carrying that part. Validation rejects slice parts outside
  the target's Parts or the manifest, `none`, malformed lists and slice parts without a manifest.
- Typed cross-target dependencies `<target-id>:<slice-id>` in Depends on, satisfied only when
  that slice reports `integrated`. Unknown targets or slices, malformed references and cycles
  through other targets are validation errors; nothing unresolved is ever satisfied.
- Owner-gate reasons: `owner-gated (<reason>)` / `pending owner decision (<reason>)` in the
  Contribution cell surfaces as `gate_reason`. A target `**Hold**: <reason or link>` reports its
  unstarted slices `held` (new state) with `hold_reason`; held outranks owner-gated, keeps the
  gate reason, and leaves integrated/in-flight slices unchanged. Empty, `none`, duplicated or
  misspelt holds (behind a list or quote marker, `**Hold:**`, other case) are invalid.
- Optional `## Linked repositories` table (`Repository | Path | Parts | Note`) in the product
  summary. The overview reads each local sibling checkout's regular files with this kit's
  parsers and never sources or runs anything from it. Git runs there only for read-only
  queries, with every transport refused, bundle URIs and credential helpers cleared, and
  partial-clone lazy fetching off (`GIT_NO_LAZY_FETCH`, Git 2.45+; older Git may still spawn
  the lazy-fetch subprocess, which then has no bundle URI, credential helper or allowed
  transport), so its configuration cannot make status fetch, write objects or run an
  upload-pack, ssh, remote-helper or credential-helper command; hooks, fsmonitor and pagers are
  also disabled (Git 2.31+). Git still reads that repository's configuration and metadata,
  which can make those queries fail (slices stay unverified), or block until interrupted when
  one of those files is a FIFO. A missing path, this project, another worktree of it or a
  directory inside it without its own repository, or a non-consumer root is `unavailable` with
  a reason; a non-regular or malformed manifest reads as kit version `unknown`. Doctor reports
  unavailable entries and an unknown kit version as environment advisories that `--strict`
  never promotes, because sibling checkouts depend on the machine (CI has none); a malformed
  declaration is a validation finding. This keeps the kit's rule that it never fetches across
  repositories.
- Slice JSON gains `gate_reason`, `hold_reason`, `parts` and `waiting_on`; target JSON gains
  `hold`. Existing fields and their order are unchanged; text names unsatisfied dependencies on
  other targets only.

### Changed

- Existing spellings that now carry meaning: parenthesised text right after an owner-gate
  marker is surfaced as `gate_reason` and appended to that slice's text line (`— gate: …`); a
  slice-table column headed `Part` or `Parts` assigns slice parts and is validated; a Hold-like
  line now holds the target or fails validation. Otherwise text output and validation are
  unchanged for projects that use none of the new syntax.

### Fixed

- Status never fetches: ancestry checks for integration records now refuse every transport,
  clear bundle URIs and credential helpers, and disable lazy fetching (Git 2.45+), so a partial
  clone missing a recorded revision reports it unverified instead of contacting its promisor
  remote. Older Git may still start the lazy-fetch subprocess, which can then neither download
  a bundle nor use any transport.

## [0.13.3] — 2026-10-16 — partial integration is not delivery

### Fixed

- Status no longer reports an incrementally landed feature as delivered. An integration
  record with `**Status**: partial` now yields feature integration `partial` and slice state
  `partially-integrated`, keeps the live preflight gates, and does not satisfy dependent
  slices. Previously only the recorded revision's ancestry was checked, so a feature with
  most tasks open showed `integrated` and released its dependents.
- Any other declared integration status except `complete`/`completed`/`integrated` fails
  closed to `unverified`, as does a duplicated, empty or misspelt Status line. Records
  without a Status field behave as before.
- Partial integration keeps task-driven next actions and live gates even if the feature
  spec already declares `integrated`; a partially integrated slice stays visible on a
  non-active target instead of reading `not-dispatchable`.
- The integrate workflow documents the partial record (one record, updated in place) for
  features landing over several changes.

## [0.13.2] — 2026-10-15 — proportionate recovery and review

### Fixed

- Distinguish routine tool/setup failures and interrupted checks from substantive repair
  rounds. Workers recover within existing authority; three substantive fix rounds retain
  the bounded lead-level escalation route, history and explicit owner/assignment limits.
- Scope delegation and reservations to actual outcomes, risks and resource contention;
  reassess evidence-only churn before expanding verification infrastructure.
- Require review blockers to identify current obligations and concrete consequences; reuse
  unaffected approvals and original evidence rather than recursively reviewing bookkeeping.
- Add behavioral recovery, explicit-limit and review-proportionality scenarios with compliant
  and violating controls. Existing project-owned templates/policies remain upgrade-preserved;
  old explicit holds require their authorized issuer to amend them.

## [0.13.1] — 2026-10-13 — reliable part membership validation

### Fixed

- Part and interface membership checks drain their input instead of exiting on the first
  match. Under `pipefail`, an early grep exit could interrupt a multi-write producer with
  SIGPIPE and incorrectly reject a known owner or consumer. Literal whole-line matching,
  absent-member rejection and genuine producer failures remain unchanged. Installed-helper
  regression coverage exercises a list larger than a pipe buffer on Linux and macOS.

## [0.13.0] — 2026-10-12 — layered parts and current-canon pilot readiness

### Added

- Opt-in layered product parts: part artifacts, interfaces and shared-canon manifests, exact
  section load sets, `resolve-context.sh`, v2 analysis fingerprints, `status --part` and
  checkout-local reporting. Legacy unscoped projects retain v1 behavior.
- Optional part-scoped review: base-revision, whole-change scope with interface-consumer
  escalation from `## Part review domains` (`product-level:`/`always-required:`). `review-scope.sh`
  supports project adapters; the feature-complete sign-off gate requires an approval per required
  part domain (product-level domains other than always-required ones may be NOT_APPLICABLE with
  rationale) and fails on an unresolvable base when parts are scoped or the changed-file list
  edits the policy. A legacy project's PR that edits (or, with no policy file, touches
  `.prdkit/memory/`) its sign-off policy in a shallow CI checkout now needs the base fetched, and
  the gate's own diff counts a renamed file's old path (`--no-renames`), so moving a file out of
  a gated path is gated. Parts guidance lives in the opt-in `parts.md` playbook.
- `adopt parts` and canon-reconciliation operations, archive templates and `check-canon.sh`:
  superseded decisions/docs/backlog mechanisms retain identity, authority, reason and replacement
  while current behavior and accepted future direction stay distinct. Generic pivot fixtures
  verify installed contracts; real consumer context savings remain a pilot measurement.

### Fixed

- `init.sh --harness` accepts names separated by commas and/or spaces. Previously an unknown
  name, including a space-separated list glued together without separators, warned and fell
  back to installing only `agents`, then rewrote the manifest to drop the other harnesses
  while their command files stayed on disk. An unknown or empty name now exits 2. On an
  existing install, an explicit list that would drop a recorded harness also exits 2 and
  names it. `--help` prints the full option list.
- Doctor and the adoption gate report any `prdkit*.md` command file in `.claude/commands/` or
  `.opencode/commands/` that the manifest does not record. That covers a harness dropped from
  the manifest even after the adoption-contract hash was re-recorded over it.
- A neutral definition's `harnesses:` must be a bracketed list of `claude`/`opencode`. A bare
  `harnesses: opencode` used to be silently ignored, projecting into every harness. That, an
  empty list or an unknown name is now a finding, and `render-agents.sh` refuses to write.
- With a `Tier baseline:`, every projection must be owned. An agent file with no neutral
  definition, or one excluded by its definition's `harnesses:` list, used to keep its model
  and body unchecked; it is now a finding unless agents.md names it on the new
  `Hand-owned agents:` line.
- The renderer owns a projection's `description`, copied from a single-line neutral
  description. Drift is reported by `--check`, doctor and the adoption gate.

## [0.12.1] — 2026-10-10 — consumer-root guard + stale readiness-template advisory

### Fixed

- Consumer-facing helpers (`render-agents.sh`, `check-adoption.sh`, `status.sh`) refuse to
  run when their resolved root has no `.prdkit/` — for example `.product-kit/scripts/render-agents.sh`
  run from a submodule, which resolved the kit checkout as the project, so `--check` passed
  vacuously and `--refresh-baseline` wrote the snapshot into the submodule. Run the installed
  copy under `.prdkit/scripts/bash/`.
- When the sign-off gate is configured (`gated-paths` under `## Sign-off gate`), doctor
  reports a customized `.prdkit/templates/readiness-template.md` that lacks the
  `Implementation fingerprint` / `Input fingerprint` fields the 0.12.0 gate requires
  (advisory; `--strict` fails). `--upgrade` preserves a modified template, so consumers that
  customized it before 0.12.0 kept a template whose new records the gate rejects; merge the
  kit template's change into the customized copy.

## [0.12.0] — 2026-10-09 — agent context budget, shared agent tier map + audit contract hardening

A long-lived consumer's root agent context file grew past 130 KB, loaded on every turn and
by every subagent: the context updater bounded list length but not entry length or file
size, and playbooks said "fold delivered truth" without naming where. This release names
the destinations and bounds the file, alongside the audit and delivery hardening below.

### Added

- Context budget configuration in `.prdkit/memory/config.md`: `context-budget-bytes`
  (16384; 0 disables), `context-recent-changes` (3) and `context-active-technologies` (20),
  read by a new installed `context-budget-lib.sh`. Existing installs use the defaults.
- Doctor context-budget advisories: agent context files over budget, sections over their
  caps, entries over 200 characters, and canonical `specs/product-spec/` docs over 64 KB
  (suggesting a split). Advisories never fail doctor and appear as a separate `advisories`
  JSON array; opt-in `doctor.sh --strict` promotes them to failing findings for CI.
- `agent-context-sections: off` (config) and a per-file `<!-- prdkit:orientation-only -->`
  marker line make the context updater leave agent context files untouched, so sections a
  project deliberately removed are never re-created.
- `init.sh --check` reports kit-named commands the kit no longer ships as RETIRED, and
  `--upgrade` removes them when the previous manifest recorded them or they are symlinks into the kit's `commands/`, so
  retired/disabled/unsupported entry points stop loading into every session. Unrecorded
  hand-made `prdkit*.md` files and user-made symlinks are kept and named in a warning.
- The agent file template carries a budget note and a "Where to look" pointer block.

- A delivery operation, handover template and read-only `check-delivery.sh` helper verify
  clean exact remote checkpoints using fresh remote refs rather than cached tracking state.

- Read-only `evidence-fingerprint.sh` captures evaluation metadata and final readiness
  input fingerprints; it observes inputs and never grants a verdict or approval.
- `cleanup-feature.sh` tears down a finished feature's isolated worktree the safe way — a
  non-forced `git worktree remove` that also prunes stale registrations. It refuses to remove
  the worktree it is run from, or one with uncommitted/unintegrated work unless `--force`, and
  `--prune` clears the stale "prunable" registrations a manual `rm -rf` leaves behind. Those
  stranded registrations are what make a resumed harness session fail to re-enter its worktree;
  `integrate.md` now points at this helper instead of describing manual removal.
- Read-only `doctor.sh` flags stale (`prunable`) worktree registrations and names the one-line
  `cleanup-feature.sh --prune` repair, so a deleted-but-still-registered worktree surfaces in
  diagnostics instead of silently breaking the next session that tries to resume inside it.
- Worktree ownership is documented as one owner per session across harnesses: `specify.md` says
  to work in the kit's worktree and not open a second harness-managed one; `harnesses.md` carries
  the per-harness matrix and the kit-owned vs. `--no-worktree` harness-owned modes. A
  configurable worktree location is deferred until a cross-harness pilot shows nesting friction.

### Changed

- `integrate.md`, `protocol.md` and the constitution template name where delivered truth
  goes — canonical domain docs, the feature integration record/archive, and one
  archive-index line — and state that agent context files hold only stable orientation and
  pointers, never per-feature narrative.
- Protocol context order is index-first progressive disclosure: open only documents the
  target/spec names, read documents over 32 KB by section, skip archives/ledgers/deferred-item files
  unless named, and do not search `.product-kit/` except for upgrades.
- Reviewer context (`review.md`, review prompt and agent definition templates) is the change
  package, the feature spec and named domain sections, never a glob such as
  `specs/product-spec/**`.
### Fixed

- `update-agent-context.sh` emits every entry as one line of at most 160 characters while
  staying idempotent, takes its section caps from configuration (Recent Changes now keeps
  the configured total instead of dropping an entry on a no-change re-run), and leaves an
  already over-budget file unchanged with a warning instead of growing it.

- Standing project action authority survives routine Git steps and compaction. Execution
  checkpoints verified increments and publishes authorized branch handovers independently
  of acceptance/merge readiness; explicit local-only holds remain honored. Bounded tactical
  verification repairs route through the authorized operational lead.

- Sign-off validates feature/revision identity, real Git evaluation revisions, current
  implementation fingerprints, resolved acceptance coverage/findings, original review
  verdicts, and final input/evidence freshness. Changed uncommitted/untracked implementation
  invalidates old evidence, including dirty nested submodules and staged gitlinks. Every
  declared feature criterion requires unique, resolved coverage. Evidence-only commits
  and staging/committing a reviewed deletion preserve unchanged implementation snapshots.
- Readiness, acceptance, review templates, and playbooks share the gate's `Check:`/`Review:`
  contract. Markdown original-evidence links parse portably; external URLs alone no longer
  count as existing evidence. Existing configured gates must adopt the documented metadata.
- Installer check, doctor, and adoption diagnostics detect missing/malformed managed AGENTS
  entry sections. The manifest records their section hash independently of consumer content.
  Doctor/adoption validate all manifest-listed files and kit-owned content without kit source;
  customized project-owned files remain allowed. Missing projection directories are diagnosed.
- Ledger JSON is validated and top-level event/operator/project metadata is injected without
  confusing nested keys. Whitespace-only empty objects remain valid; malformed/ambiguous
  input never enters a spool, including Unicode-equivalent duplicate keys and malformed UTF-8.
  Dot-only project names cannot escape central-spool directories.
- Automatic acronym slug generation uses Bash 3.2-compatible case conversion and portable
  word boundaries. macOS CI now covers ledger emission as well as the existing helper lanes.
- `status --all` includes archived features, with deduplication and matching history in
  explicit feature/target views.

### Upgrade notes

Pin the reviewed 0.12.0 tag commit, then refresh from the consumer root (never `--force`,
which resets project-owned templates and memory):

```bash
bash .product-kit/scripts/init.sh --check                      # preview
bash .product-kit/scripts/init.sh --upgrade --copy --harness <harnesses>
bash .product-kit/scripts/init.sh --check                      # confirm
```

Before the upgrade `--check` lists refreshed workflows/scripts and unmodified templates as
OUTDATED and the new helpers (`context-budget-lib.sh`, `check-delivery.sh`,
`cleanup-feature.sh`, `evidence-fingerprint.sh`, ...) as NEW, and any kit command no
longer shipped (for example an old disabled or unsupported entry point) as RETIRED; the
upgrade removes kit-installed RETIRED commands. After it, only deliberate
customization remains: MODIFIED templates (for example a customized review prompt or agent
file template, which keep their old text — diff them against the kit to adopt the new
reviewer-context and pointer guidance) and CUSTOMIZED memory files; `--check` still exits
non-zero while MODIFIED entries or kept RETIRED commands are listed, which is expected. A customized `config.md` is preserved
without the new `context-*`/`agent-context-sections` keys and the defaults apply; add the
keys to override them (set `agent-context-sections: off` if you removed the generated
sections, so the updater does not re-create them).
Update `adoption-pin`/`adoption-manifest-sha256` together, since the manifest changes.
Then run `doctor.sh`: an oversized `CLAUDE.md`/`AGENTS.md` now shows advisories only; move
per-feature narrative to canonical docs and the archive index before enabling `--strict`.

### Shared agent tier map

Consumers restated concrete model ids in every `.prdkit/memory/agents.md` because the kit had
no way to reference a shared tier map and no renderer: projections were written by an agent
following `/prdkit-configure` prose, and doctor never compared their content. Two consumers
drifted apart from each other and from the shared map (different OpenCode model generations,
no recorded reason). Models now resolve from one shared, commit-pinned map, deviations carry a
reason, and drift fails a check.

#### Added

- `render-agents.sh` (installed, Bash + awk, offline): deterministic native projections from
  `.prdkit/agents/<name>.md` and the tier map. `--check [--json]` fails on tier-map findings,
  unresolvable tiers, missing projections and model/variant/body drift; `--resolve` shows each
  agent/harness model and its source; `--refresh-baseline <library> [--library-ref <ref>]`
  vendors the library `tiers.json` at a committed revision into
  `.prdkit/agent-library/tiers.json` with a `.ref` provenance file (library commit + sha256)
  and updates the `Tier baseline:` line. Only `model`, OpenCode `variant` and the prompt body
  are renderer-owned; other projection frontmatter (tools, permissions, mode, colour, memory)
  and generated-marker comments are preserved, and unchanged files are not rewritten.
- Tier map syntax (opt-in, backward compatible): `Tier baseline: agent-library
  tiers.json@<commit>`, optional `Baseline snapshot:` path, `| Local tier | Library tier |`
  mapping rows, `| Scope | Harness | Model | Variant | Reason |` overrides (`tier:`/`agent:`
  scope; agent beats tier, a specific harness beats `*`), and an optional `Banned models:`
  line of exact ids. Legacy literal `| Tier | <Harness> model | ... |` tables still resolve.
- Shared library tier names (`verydeep`, `deep`, `standard`, `light`) resolve without a
  mapping row; the former kit names alias (`frontier`->`verydeep`, `high`->`deep`,
  `fast`->`light`) and an explicit mapping row always wins.
- `agent-tiers-lib.sh` findings in `doctor.sh` and `check-adoption.sh`: banned ids (tier map,
  overrides, baseline snapshot, projections), overrides without a Reason or with an invalid
  scope/harness, a malformed baseline line, a missing/invalid/hand-edited/mismatched snapshot,
  literal ids restated beside a baseline, mapping rows without a baseline or naming an unknown
  library tier. With a shared baseline, projection model/variant/body drift (and, in the
  adoption gate, missing projections) are findings too; OpenCode projections carrying
  neutral/provenance keys (`tier`, `source`, `library-ref`, …) as fields are flagged and the
  renderer removes them, since OpenCode passes unknown keys to the model as options.

#### Changed

- Templates, `/prdkit-configure` and docs (agent lifecycle, harnesses, customization) describe
  rendering with the script instead of hand-written projections, and the agent definition
  template lists the shared tier names. The kit itself still names no model.

#### Fixed

- `render-agents.sh` exits non-zero when a projection, snapshot, provenance file or tier map
  cannot be written (read-only file or directory), names the file, and never prints a
  created/updated or success line for it; previously the write ran inside a command
  substitution, so a failure still reported success and exited 0. Staged files live in one
  private temp directory removed on exit, error or interrupt.
- A projection that already uses a banned id no longer blocks the render that repairs it:
  when the tier map, overrides and snapshot are clean, render rewrites such projections
  (`--check`, doctor and the adoption gate still fail until it has). A banned projection the
  renderer does not own is reported after the render with a non-zero exit, and the refusal
  message now names tier map, override, snapshot or tier findings instead of "fix the tier
  map first".
- `Baseline snapshot:` must be a relative path inside the repository: absolute paths, `..`
  segments, symlinked directories that resolve outside the checkout and a symlinked snapshot
  or `.ref` are findings, and `--refresh-baseline` refuses to write there.
- `--library-ref` rejects a value starting with `-` (usage error) and must resolve with
  `git rev-parse --verify` to a commit; only that verified object name reaches later git
  calls, so a ref can no longer be parsed as a git option.
- New projections, snapshots and `.ref` files get the umask's default mode (0644 under
  umask 022) instead of mktemp's 0600; rewriting an existing file keeps its mode.
- The macOS CI lane runs `tests/test_agent_tiers.sh`, which now also covers banned ids in
  overrides, the baseline and literal tables refusing render and `--check` with nothing
  written.

#### Upgrade notes

- `Banned models:` matches exact id strings. The Claude and OpenCode forms of one model are
  different ids (for example `claude-opus-5` and `anthropic/claude-opus-5`); list each form
  you want banned.
- The `.ref` sha256 and library commit detect hand edits to the vendored snapshot and a
  mismatch with the `Tier baseline:` line; they do not prove the snapshot came from that
  upstream commit. Review the snapshot diff when vendoring.
- Nothing changes until a project opts in. A legacy literal tier map keeps today's doctor and
  adoption behavior (projection drift is checked only by an explicit `render-agents.sh
  --check`), unless it adds a `Banned models:` line or an overrides table.
- To adopt the shared map: run `render-agents.sh --refresh-baseline <agent-library checkout>`
  (add the printed `Tier baseline:` line if the map has none), add mapping rows only for local
  tier names the aliases do not cover, move each deliberate deviation into an override row
  with a Reason, delete the literal model table, add `Banned models:` if the estate bans ids,
  then `render-agents.sh` and review the projection diff. `render-agents.sh --check` should
  pass before committing; doctor and the adoption gate enforce it from then on.
- Restart the harness from the checkout after a render that changed projections.

## [0.11.1] — 2026-09-29 — manifest-driven adoption gate

### Fixed

- `check-adoption.sh` derives the expected command surface from the install manifest
  instead of the kit source, so the CI gate needs no submodule checkout (private-repo CI
  tokens often cannot fetch the submodule). The kit source, when present, is now a
  cross-check rather than a requirement; the pin still comes from the tracked gitlink.

## [0.11.0] — 2026-09-29 — consumer CI gates + central-spool adapter

The 0.10.0 estate evaluation found every long-lived consumer hand-building the same
guard rails; 0.11.0 ships them once, installed and opt-in.

### Added

- **Adoption gate** — `check-adoption.sh`, a one-line consumer CI step verifying the
  reviewed adoption contract: kit submodule pin (`adoption-pin`), manifest presence,
  integrity (`adoption-manifest-sha256`) and version consistency with the kit source,
  the exact public command surface per configured harness in the recorded install mode,
  and no leaked kit bootstrap. Keys live in the `## Configuration` section of
  `.prdkit/memory/config.md`; unset keys skip their check.
- **Sign-off gate** — `check-signoff.sh`, the mechanical readiness gate generalized from
  its consumer origin: change sets touching configured gated paths must carry a fresh
  `READY` feature-complete readiness record over current artifacts, a passing implement
  preflight, complete tasks, and resolved applicable evidence (existing in-repo original
  references, at least one `APPROVED` independent review). Activated by a
  `gated-paths: [...]` bullet in the `## Sign-off gate` section of
  `.prdkit/memory/signoff-requirements.md`; inapplicable (passing) when unset.
- **Central-spool adapter** — `ledger-spool-adapter.sh`, the per-host ledger adapter the
  estate previously copy-pasted per repo: wired as
  `command: .prdkit/scripts/bash/ledger-spool-adapter.sh`, it mirrors every event into
  `${XDG_DATA_HOME:-~/.local/share}/prdkit/ledger/<project>/events.jsonl` (project from
  `PRDKIT_PROJECT`, else the Git origin repo name — worktree-safe — else the directory
  name, sanitized to one path segment), preserving any embedded `project` field. Local
  only; no credentials, no network.
- `docs/ci-gates.md` documents both gates and their CI wiring.

## [0.10.0] — 2026-09-29 — install-mode memory + slice-selection autonomy

### Added

- The installer records the command install mode in the manifest (`mode: copy|symlink`)
  and later runs honor it, so `--upgrade` never silently flips tracked copies back to
  symlinks; a pre-0.10 manifest's mode is inferred from the installed files. `--symlink`
  explicitly switches back. Symlinked commands now use **relative** targets, so a
  committed symlink works in any checkout.
- Neutral agent definitions may carry an optional `source:` frontmatter key naming where
  the definition is canonically maintained (e.g. an external agent library); the kit
  preserves it untouched and external sync tooling may act on it.

- `status.sh` counts task lines whose checkbox glyph falls outside the `[ xXIRB]`
  contract (`tasks_unrecognized`, a text warning, and `next: fix-task-markers`) instead
  of silently dropping them from progress.
- `target_slices` derives a gate from the Contribution cell (`owner-gated` / `pending
  owner`, `optional`), and `status.sh` reports those slices as `owner-gated` /
  `ready-optional` with a `gate` field in JSON — an owner-gated slice is never presented
  as `ready-to-specify`.

### Changed

- **Slice selection is execution authority.** Unless a target declares an explicit
  ordering, optional slices, or an owner gate, every listed slice is required — so agents
  take the next dependency-ready slice (lowest number first) and proceed instead of
  stopping to ask which slice comes next; after integration, starting the next required
  slice is continuation, not a new decision (workflows/intake.md, workflows/protocol.md,
  workflows/target.md step 5, target template).
- Integrated features are historical records to `status.sh`: once integration is
  confirmed on the base branch — or the spec honestly declares `Status: integrated` —
  the implement preflight gates report `not-applicable` instead of re-running against a
  moved-on repository (which produced permanent, non-actionable `ANALYZE_GATE: fail`
  churn), and unconfirmed integrated records get `next: historical-record` rather than
  manufactured work.
- `update-agent-context.sh` bounds the `## Active Technologies` section at 20 entries
  (oldest dropped first), matching the existing Recent Changes cap; agent context files
  no longer grow without limit as branches contribute distinct stack strings.

### Fixed

- `ledger-emit.sh` injects the CLI event type as an `"event"` field when the stdin
  payload omits it, so hand-shaped payloads can no longer land spool lines that
  downstream collectors silently drop.

### Docs

- `docs/private-adoption.md` documents how retained pre-redesign feature specs meet the
  live artifact scan: `specs/features/_archive/<id>/`, or the in-place minimal metadata
  block two consumer projects used — and that a feature directory holding only pre-redesign
  files (e.g. `expansion.md` without `spec.md`) is invisible to status and doctor until
  it gets a minimal `spec.md`.

## [0.9.1] — 2026-09-29 — BSD/macOS sed portability

### Fixed

- `create-new-feature.sh` and `update-agent-context.sh` used GNU-sed-only constructs
  (`\+` in a basic regex; `\t` inside a bracket expression) that BSD/macOS sed treats
  literally — hyphen runs were not collapsed in generated branch/feature names and
  whitespace trimming silently failed on macOS. Both are now POSIX (`--*`,
  `[[:space:]]`). Discovered as un-upstreamed local patches carried by a consumer
  repository; the macOS CI lane now also runs `test_create_new_feature.sh` and
  `test_agent_context.sh` so BSD helper regressions are caught upstream.

## [0.9.0] — 2026-09-29 — agent-led product development

### Changed

- Clean pre-public redesign: eight public entry points (`/prdkit`, init, product,
  target, status, learn, configure, doctor); detailed delivery operations move to
  installed, harness-neutral `workflows/` outside the slash-command menu.
- Product definitions now include lifecycle and expansion horizons. Versioned delivery
  and learning targets link intent to feature slices and integrated acceptance.
- Early intent clarification, explicit explore/plan/execute modes, proportional planning,
  one acceptance map, phase-aware readiness, and documented resumption/action authority.
- Feature specifications use `spec.md`; analysis is bound to relevant input fingerprints,
  excluding task checkbox progress. Status distinguishes declared state from evidence.
- Target dependency validation detects missing/cyclic slices; status shows eligible slices
  and checks recorded integration against the actual base. Archived feature IDs remain reserved.
- Installer ships agent playbooks and an intent-oriented AGENTS.md entry; historical
  private migration scripts and environment-variable aliases are removed.
- Public guides, examples, diagnostics, artifact validation, and behavioral evaluations
  support the new workflow. Existing private repositories use one-off adoption.
- `doctor` diagnoses optional agent definitions: a neutral definition without a roster
  entry or without a projection file in an installed harness agents directory is reported
  (honoring an explicit `harnesses:` list). Projection content staleness is not evaluated —
  the kit ships no renderer.

### Removed

- The public low-level command chain, duplicate verification templates, mandatory
  specialist-agent creation, universal test/persona quotas, and convergence percentages.
- The 0.6.0–0.8.0 agent-evolution machinery: `/prdkit-agents` verify/refresh,
  `/prdkit-agent-sleep` with its `agent-sleep` config toggle and `sleep-cycles/` log, and
  the roster's tier → model/effort map heading. What remains: neutral definitions with a
  `tier` field, the roster's optional model mapping, the retrospective's per-agent
  effectiveness rollup, and the generic `agent-optimization` flow toggle
  (`workflows/integrations.md`) as the evidence-based optimization path.
- Dependence on private monitoring-host tools in retrospective guidance; enrichment is
  an optional documented data contract.
- Mixed review severity vocabularies: the current contract uses critical/high/medium/low.
  Unsupported private historical exports fail explicitly rather than reporting false zero counts.

## [0.8.0] — 2026-09-13 — retrospective feeds the agent lifecycle

Close the loop between the per-feature review and the agent ecosystem: a retrospective now records
how the agents actually performed on the feature, and — when configured — hands that evidence to
`/prdkit-agent-sleep`.

### Added

- **Agent effectiveness section** in every generated `retrospective.md`: a per-agent rollup of the
  feature's `review.recorded` outcomes (rounds, PASS/FAIL/WAIVED, findings raised), derived from the
  ledger alone (no enrichment or invented numbers required). This is the per-feature evidence
  `/prdkit-agent-sleep` aggregates across features to judge whether each agent's tier and definition
  still fit — so an agent's real performance is recorded, not just its token footprint.

### Changed

- **`/prdkit-retrospective`** gains an opt-in closing step: when `.prdkit/memory/config.md` sets
  `agent-sleep: on`, it surfaces the Agent effectiveness evidence and points at (or, where the
  project wires it, invokes) `/prdkit-agent-sleep`. With `agent-sleep` `off` or unset (the default)
  the retrospective is unchanged and says nothing about agent-sleep. The step only reads config and
  recommends a next command; it never edits agent definitions itself.

## [0.7.0] — 2026-09-13 — /prdkit-agent-sleep (agents evolve from evidence)

Agents become an evolving artifact: as models ship and evidence accumulates, their definitions
are reviewed and updated — without forcing that on every project.

### Added

- **`/prdkit-agent-sleep`** — periodic, harness-agnostic consolidation of the agent ecosystem.
  It evaluates each agent against the ledger/retrospective evidence (which agents/models/efforts
  were used, review outcomes, fix-round churn) and model currency, then proposes updates to the
  neutral definitions in `.prdkit/agents/` and the roster's tier map — staleness fixes, tier
  changes, model/effort remaps, new-agent proposals for uncovered domains. Non-destructive by
  default (a report; `--apply` applies approved changes, then re-derives projections via
  `/prdkit-agents` and logs the cycle under `.prdkit/agents/sleep-cycles/`). No invented numbers;
  the kit names no models (it suggests tier-map changes the project owns).
- **`agent-sleep` flow toggle** in `.prdkit/memory/config.md`. Left `off` (default) the command is
  never invoked automatically; `on` links it into `/prdkit-retrospective` so the per-feature review
  feeds the ecosystem-level one.

## [0.6.0] — 2026-09-13 — /prdkit-agents (neutral definitions → per-harness projections)

Make agent definitions portable across harnesses and keep the roster and sign-off in step.

### Added

- **`/prdkit-agents`** — verify and refresh the per-harness agent files (`.claude/agents/`,
  `.opencode/agents/`, …) that are **projected** from the neutral definitions in `.prdkit/agents/`
  (foundation shipped in 0.5.x: `docs/agent-lifecycle.md`, `templates/agent-definition-template.md`,
  the roster's `## Tier → model / effort map`). **verify** reports each definition × harness as
  in-sync / stale / missing, delegates format-validity to the target harness (the kit encodes no
  harness schema), and checks **roster ↔ sign-off consistency** as a vocabulary-aware judgment
  (e.g. sign-off "Security & Privacy" ↔ roster "Security Review") rather than a string match.
  **refresh** regenerates projections from the neutral source using the harness's own current
  format — the kit ships no renderer, so a harness changing its file format needs no kit change.
  Models are never named by the kit: model + effort come only from the tier map.
- `init.sh` creates `.prdkit/agents/` so the neutral-definition location exists on install.

## [0.5.0] — 2026-09-13 — flow configuration + opt-in retrospective

A project can now turn the post-merge retrospective into a standing part of the flow — without
that being forced on every consumer of the kit.

### Added

- **`.prdkit/memory/config.md` — a flow-configuration file** (seeded from
  `templates/config-template.md`, project-owned and preserved across `--upgrade`). It holds
  opt-in `- key: value` flow toggles that each default to **off**, so a project that never
  edits it runs the standard flow. This is the home for future "product flow adjustments"
  a project wants to enable without changing kit-owned command files.
- **Opt-in retrospective at merge.** The first `config.md` setting is `retrospective`. With
  `retrospective: on`, `/prdkit-merge` generates the feature's `retrospective.md` automatically
  after the feature is merged and archived (the same output as `/prdkit-retrospective`), reading
  the `feature.merged` event it just emitted. Generation is best-effort and never blocks the
  merge; token/cost figures still require the optional enrichment file and are never invented.
  Left `off` (the default), the retrospective stays a manual command and the merge is unchanged.

### Changed

- `init.sh` seeds `config.md` alongside the other memory files; `docs/customization.md` documents
  it as Layer 6 (flow configuration), distinct from the constitution's Rigor level and the task
  ledger's emission config.

## [0.4.1] — 2026-09-12 — retrospective input boundaries

### Fixed

- Retrospectives require an existing, unambiguous live/archive feature. Reject path
  arguments and symlinked output directories; publish through exclusive temporary
  storage and a non-directory-following rename rather than predictable `.md.tmp`.
- Enrichment is parsed once with **jq 1.6+**, validates schema and feature identity,
  and accepts only bounded non-negative integer token/session counts. Malformed
  enrichment fails without replacing the report. File content no longer enters Bash
  arithmetic. Negative tests cover input types, overflow and execution sentinels.

### Changed

- Owner-approved dependency exception: jq is required **only for optional enrichment**
  (and the full test suite). Ledger-only reporting remains available without jq.
  Updated the toolkit constitution, command contract, contributor docs and CI.

## [0.4.0] — 2026-09-12 — feature retrospectives

The ledger is now consumable as well as emittable: a new command turns a feature's recorded
event history into a reviewable retrospective, optionally enriched with token and model usage.

### Added

- **`/prdkit-retrospective`.** A new auxiliary command that reads the local ledger spool
  (`.prdkit/ledger/events.jsonl`), filters to one feature and dedupes on `event_id` (last wins),
  and writes a `retrospective.md` into that feature's spec directory via
  `.prdkit/scripts/bash/retrospective.sh`. The retrospective summarizes created/merged timing,
  tasks completed, review rounds and verdicts, findings, exploration convergence, and blockers;
  renders a chronological review-detail table; and emits honest, data-gated recommendations for
  cost, speed, and model/effort selection on the next feature. When the out-of-band enrichment
  file `.prdkit/retrospective/<feature-id>.enrich.json` (produced by an external host-side token
  enricher) is present, it also summarizes sessions, total tokens, and the
  per-type/model/effort/agent breakdown; the token section degrades to a clear "run the enricher"
  note when the file is absent, and token or cost numbers are never fabricated. Pure bash +
  coreutils + awk/sed — no new runtime dependency.

## [0.3.0] — 2026-09-11 — ledger completion

The `prdkit.ledger.v1` event stream is now complete enough to drive external telemetry —
metrics, dashboards, and tracker integrations project the workflow without touching the
authoritative files.

### Added

- **Full event vocabulary emitted.** Beyond `readiness.changed`, the commands now emit
  `feature.created` (specify), `tasks.generated` (tasks; supersedes the reserved, never-emitted
  `task.upserted`), `task.state_changed` and `evidence.recorded` (implement),
  `review.recorded` (implement rounds/waivers + signoff feature-level domains),
  `exploration.converged` (iterate), `blocker.opened`/`blocker.resolved`
  (implement/iterate/signoff), `phase.changed` (signoff), and `feature.merged` (merge, with
  task count and product-spec churn; projects with a customized terminal merge step emit it
  from that procedure). All emissions are best-effort and never block the workflow.
- **Machine-readable contract.** `schemas/prdkit.ledger.v1/` publishes one JSON Schema per
  event plus the shared envelope; `tests/test_ledger_schema.sh` keeps schemas, the seeded
  policy doc, and the emitting playbooks in lockstep.
- **Deterministic `event_id`.** Every newly added event carries an idempotency key
  (`<feature-id>/<event>/<discriminator>`) so re-runs converge in any adapter.
- **Opt-in operator attribution.** A task-ledger policy of `operator: git` makes
  `ledger-emit.sh` append the repo's git identity to each event — the first building block
  of a human audit trail; off by default.
- **Central-spool reference adapter** in the seeded task-ledger template: mirrors events
  into one per-host JSONL spool with repo attribution, for metrics collectors.

### Fixed

- **Adapter execution hardened.** `ledger-emit.sh` previously ran the policy-configured
  `command:` unquoted straight from `task-ledger.md` — repo-controlled content, so a PR
  editing that file could make a reviewer's next workflow command execute arbitrary shell.
  The adapter is now constrained to a single argument-free path (conservative character
  set, no `..`, resolving to an executable file inside the repository). Adapters that need
  arguments wrap them in a script.
- **Spool is valid JSONL.** Events are normalized to one line before spooling, so
  pretty-printed emission no longer splits one event across spool lines.
- **Spool stays out of git.** `init.sh` adds `.prdkit/ledger/` to the consumer's
  `.gitignore` — the local event spool grows unbounded by design and never belongs in
  history.

## [0.2.1] — 2026-09-11

### Fixed

- **`VERSION` now tracks releases.** The file init.sh stamps into every consumer's install
  manifest (and reports from `--check`) still read `0.1.0` in the 0.2.0 release — it had
  last been touched when the manifest feature was built, and 0.1.0 matched only by
  coincidence. Bumped to 0.2.1, and a new `tests/test_version.sh` fails CI whenever
  `VERSION` lags the newest CHANGELOG release header, so a release can no longer ship with
  stale provenance.

## [0.2.0] — 2026-09-11 — effort-scaled rigor

`rigor: full` now scales process effort — review fan-out, sign-off breadth, and dispatch
capability — with diff size, risk, and feature maturity, driven by consumer telemetry from the
v0.1.0 uptakes. Also carries the `init.sh` kit-owned-overwrite honesty fix.

### Added

- **Capability tiers in the agent registry.** The agents template's Registry gains a **Tier**
  column with four generic tiers (`frontier | high | standard | fast`) and a Capability tiers
  section: per-task, high-volume dispatches default to `standard`; risk-bearing reviews
  (security, auth, durable state, architecture) sit at `high`; `frontier` is reserved for the
  main executor on design-heavy work. The registry declares the policy; the consumer's harness
  agent definitions enforce it (model/effort fields — mapping examples in
  `docs/customization.md`). Review Effort Scaling ties in: risk-area diffs are reviewed at
  `high` or above, waiver/batch-eligible diffs may run at `standard` — tier changes reviewer
  capability, never whether the review happens.

### Changed

- **Effort-scaled rigor + staged sign-off.** `rigor: full` now scales process effort with diff
  size, risk, and feature maturity instead of firing every mechanism on every task:
  - **Exploration Loop is opt-in per task.** [DESIGN]/[UI] tasks default to the same
    single-pass + independent review as [IMPL]; a supplementary `[EXPLORE]` marker (for a
    declared Quality Bar, a new visual identity, a first-of-a-kind surface, or high-ambiguity
    aesthetics) routes a task through the 3-pass loop via `/prdkit-iterate`, which now rejects
    unmarked tasks (in-flight loop states still finish).
  - **Review waivers and batching.** A trivial diff outside every risk area may record a
    `WAIVED — trivial` entry instead of a review dispatch; consecutive small same-area tasks
    may share one batched review returning per-task verdicts. Risk-area diffs — the Stage
    Gates always-on set, Security & Privacy trigger areas, durable state/migrations — are
    always fully reviewed. Bounds are project-tunable in `signoff-requirements.md` (new
    **Review Effort Scaling** section).
  - **Staged sign-off.** The Required Review Domains table gains a **Phase** column:
    Security & Privacy (plus build/tests/no-secrets) is evaluated per change, trigger-based;
    the remaining domains, personas, and acceptance verification run once at feature-complete
    (every non-deferred task done); Code and Tests & Verification are satisfied by the recorded
    per-task review chain. `/prdkit-signoff` reports ON TRACK/BLOCKED mid-feature and can
    output SIGNED only at feature-complete.
  - **Proportional evidence.** Evidence depth follows change size; bookkeeping (waiver
    records, Gates Skipped) is never skipped.
  Driven by consumer telemetry after v0.1.0: frontier executors' first-pass quality meant three
  concepts for routine design work and a full domain matrix on every change cost far more than
  they caught, while the round-1 independent review kept catching real defects — so the review
  stayed mandatory and the fan-out became opt-in. See `docs/adr-rigor-profiles.md` (History,
  2026-09-11).

### Fixed

- **`init.sh` now tells the truth about kit-owned files on upgrade.** Commands (`.claude/commands/`,
  `.opencode/commands/`) and workflow scripts (`.prdkit/scripts/bash/`) are kit-owned and have always
  been refreshed by `--upgrade`, but `--check` previously listed a consumer-edited one under
  "MODIFIED … `--upgrade` preserves these" — which is false for kit-owned files. `--check` now reports
  such edits in a distinct **KIT-OWNED EDITS** bucket that states they will be overwritten, and
  `--upgrade` prints a `⚠ Overwrote …` line naming every edited command/script it replaced, instead of
  overwriting them silently. Templates and memory are still preserved-when-edited as before. The guidance
  is unchanged — express project-specific behavior in the constitution, not by forking a command — but
  the tooling no longer implies a preservation guarantee it does not provide. See
  [docs/customization.md](docs/customization.md#ownership-on-upgrade).

## [0.1.0] — 2026-09-10 — initial release

Product-Kit originates from GitHub's [Spec Kit](https://github.com/github/spec-kit) (MIT) and
generalizes it into a product-spec-driven workflow where feature specs are ephemeral expansions
merged into a durable product spec.

### The toolkit

- **23 `/prdkit-*` commands** covering the full workflow: the core path (`init`, `constitution`,
  `specify`, `clarify`, `plan`, `tasks`, `analyze`, `implement`, `signoff`, `merge`, `status`),
  optional gates (`validate`, `verify`, `walkthrough`, `checklist`, `scopecheck`, `converge`,
  `iterate`), and auxiliary commands (`baseline`, `domain`, `expandspec`, `specfix`,
  `taskstoissues`). `commands/` is the source of truth; `docs/commands.md` indexes it.
- **Rigor profiles**: a constitution-level `Rigor` field (`light` default, `full`) controls
  execution depth across the chain. `full` gives `[IMPL]` tasks a mandatory independent review
  with a bounded fix loop and `[DESIGN]`/`[UI]` tasks the three-pass Exploration Loop with blind
  judging; MEDIUM findings block and persona minimums rise.
- **Product-fit gate**: `/prdkit-specify` records a short **Product Fit** verdict for every
  feature — judged against the constitution's Product Direction and, if present, `meta/`
  vision/roadmap — and `/prdkit-analyze` surfaces off-direction work as an advisory (never
  blocking) finding, so a well-specified feature that does not serve the product's direction is
  visible before it is built, not after. `/prdkit-converge` is wired into the routine flow: run
  it before sign-off when a feature changed durable or stateful behavior, catching code↔spec
  drift mechanically rather than in a later reconciliation pass.
- **Constitution with Product Direction**: identity, mode, rigor, target users and problem,
  enduring outcomes, strategic non-goals, authority and intent (including an explicit
  *continuation is autonomous* rule so approved multi-slice work runs without a confirmation
  prompt between slices), tech stack, build commands, principles.
- **Templates** for every artifact (expansion, plan, tasks, checklist, verify, walkthrough,
  sign-off, sign-off requirements, domain spec, backlog idea, task ledger, review prompts,
  constitution and agents scaffolds), all project-owned and upgrade-safe.
- **Dependency-free bash scripts**: `init.sh` bootstrap with `--copy`, `--check`, `--upgrade`,
  `--force`, and run-once migrations; worktree-first feature creation; plan setup; prerequisite
  checks; deterministic clarify/analyze gate checks; review-package building; agent-context
  updates; task-ledger emission with an always-on local spool.
- **Multi-harness install** (`--harness claude|opencode|codex|agents|all`) with an idempotent
  managed section in `AGENTS.md` for harnesses without slash commands, and a per-file hash
  manifest so `--check` reports OUTDATED / MODIFIED / NEW without touching customized files.
- **Dependency-free test suite** (`tests/run.sh`, 19 files) over the scripts, the wiring between
  commands, templates and scripts, catalog and link integrity, and the generic-vocabulary
  guard; plus behavioral evals (`tests/evals/`) that run the command prose against a real agent,
  never in CI.
- **Docs**: workflow guide with right-sizing guidance, adoption path for existing codebases,
  customization layers, the data-migration review checklist, the backlog-ideas workflow, and
  decision records for rigor profiles, the baseline command, and the task ledger.
- **Product-stage calibration**: a constitution `Stage` field (`prototype → pre-release → ga`)
  plus a **Stage Gates** section let a project defer release-only MUSTs (durability, scale,
  lifecycle) to a later stage. `/prdkit-analyze`, the `[IMPL]` independent review, and
  `/prdkit-scopecheck` read Stage from the constitution (never from a dispatch prompt, preserving
  reviewer independence) and record a deferred MUST as a tracked "Deferred — stage gate" note
  rather than a CRITICAL finding — so a pre-release build stops burning fix rounds on
  production-grade hardening it does not need yet. Auth, privacy/security, and determinism/replay
  are never deferrable. Product Direction is now a required, freshness-checked constitution
  section.

### Design decisions recorded during pre-release

- **Worktree-first isolation**: `/prdkit-specify` creates each feature branch in
  `.worktrees/<branch>/` so uncommitted work, parallel agents, and IDE state on the current
  branch stay untouched; `--no-worktree` branches in place.
- **Independent review instead of multi-pass rewriting for `[IMPL]`**: multi-pass execution on
  the same checkout let each pass see the previous pass's code, so it converged by rewriting,
  not by judgment. `[IMPL]` tasks are implemented once and reviewed by an agent that did not
  write them over the real `BASE..HEAD` diff; at most three fix rounds, then `[B]` and escalate.
- **Exploration Loop for `[DESIGN]`/`[UI]`**: three passes with context cleared between them,
  each writing to an isolated `iterations/TXXX/concept-{N}/`, then a blind judgment over
  anonymized, shuffled copies against an optional Quality Bar. The mechanism was once called the
  Ralph Loop; the descriptive name replaced it before release.
- **Rigor profiles** (see `docs/adr-rigor-profiles.md`): one field, two behaviours, new installs
  default to `light`; an install that predates the field keeps `full` so nothing changes silently.
- **EARS acceptance criteria and FR-to-task traceability**: expansion requirements use
  WHEN / WHILE / IF-THEN / WHERE / SHALL patterns; story-phase tasks carry `[FR-###]`; analyze
  checks coverage mechanically; one E2E `[TEST]` task is always generated.
- **File-backed gates**: `/prdkit-analyze` writes `analysis.md`; `check-implement-gates.sh`
  enforces the clarify and analyze gates deterministically on any harness; a clean spec still
  records that clarification ran.
- **Semantic merge review**: `/prdkit-merge` records `MERGE_BASE`, requires a clean
  `specs/product-spec/`, blocks when the base's product-spec advanced since the fork, and has a
  fresh agent review the spec diff before the user confirms; rollback is
  `git checkout MERGE_BASE -- specs/product-spec/`.
- **`/prdkit-converge`**: post-implement audit of the actual code against expansion FRs, plan
  decisions, and constitution principles; its only mutation is appending convergence tasks.
- **`/prdkit-baseline`** (see `docs/design-baseline-command.md`): synthesize a first product-spec
  from an existing codebase with `[BASELINE - VERIFY]` tags for human review.
- **Task ledger** (see `docs/task-ledger-integration.md`): neutral `prdkit.ledger.v1` events to a
  project-owned command; the spool is always on, no backend is the default, core never holds a
  token or URL.
- **Generality invariant**: no stack-specific vocabulary or hardcoded toolchain commands in
  commands, templates, or scripts; everything project-specific comes from the consumer's
  constitution. The test suite enforces it.
- **Spec Kit 1.0 uptake** (upstream #4397, #4367, #3745, #3646, #3790, #4028): setup-plan emits
  the feature directory as `FEATURE_DIR` (was misnamed `SPECS_DIR`); prerequisite checks fail
  early with `/prdkit-specify` guidance when `expansion.md` is missing (unconditional — every
  validating caller reads it, so upstream's opt-in `--require-spec` flag was not carried over);
  `/prdkit-clarify` questions must be real interrogatives, never topic labels or bare
  requirement ids; `/prdkit-constitution` is scope-guarded and no longer edits dependent
  templates (they read the constitution at runtime); checklist `[x]` means reviewer-approved
  requirements quality, not implementation progress, and `/prdkit-implement` reads markers
  without modifying them (its gate stays advisory, unlike upstream's stop-and-ask).

### Removed before release

- **Lifecycle-authority and merge-integrity layer** (added, then reverted): transaction
  snapshots, claims, tombstones, endpoint identity hashes, coverage epochs, recovery-session
  chains, requirement-traceability registers, and the Integration Authority tuple. It existed
  only as command prose, no script implemented it, and no consumer project ever used it.
  Transaction guarantees are out of scope for Product-Kit.
- **`docs/commands/` mirror**: a byte-for-byte copy of every command file that nothing
  consumed. Migration 002 stays so older installs still drop the stale sync script on `--upgrade`.
- **Dead and superseded material**: two uninstalled repo-local skills, the unreferenced
  escalation template, and the never-implemented requirement-traceability ADR; three design
  docs condensed to decision records.

### Layout note

Product-Kit installs into `.prdkit/` in consumer projects (earlier pre-release versions used
`.specify/`; `init.sh` migrates a legacy `.specify/` directory automatically on upgrade).
