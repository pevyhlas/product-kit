<!--
SYNC IMPACT REPORT
- Version change: 1.1.3 → 1.1.4 (2026-10-30)
- Extend Principle III's optional-tool exception to explicit GitHub report consistency checks
  using gh and jq. Core offline review checking retains Bash/Git-only operation.
- Prior (1.1.2 → 1.1.3, 2026-10-20):
- Clarification only: the kit's own `specs/` records are kept privately and are not part of
  this repository; Product Direction says so and the Product-Spec Structure section is removed.
  No principle changed.
- Prior (1.1.1 → 1.1.2, 2026-09-30): recorded the status of the kit's own targets. No
  principle changed.
- Prior (1.1.0 → 1.1.1, 2026-09-29): aligned the post-0.9.0 specs/ layout. No principle changed.
- Prior (1.0.0 → 1.1.0, 2026-09-12): owner-approved exception to Principle III — jq 1.6+
  for optional retrospective enrichment; full tests require jq.
-->

# Product-Kit Constitution

**Version**: 1.1.4
**Ratified**: 2026-06-02
**Last Amended**: 2026-10-30

> This is Product-Kit's *own* constitution — the principles governing the toolkit itself.
> It is meta: Product-Kit ships a generic `templates/constitution-template.md` for projects
> that adopt it. This file governs how Product-Kit is built and maintained.

## Project Identity

- **Name**: Product-Kit
- **Description**: A reusable, project-agnostic spec-driven-development command toolkit (`/prdkit-*`) installable into any software project.
- **Type**: Developer tooling (commands + templates + bootstrap scripts)
- **Mode**: non-user-facing — there are no end-user personas; correctness is verified by the unit tests over the scripts and by the cleanliness/structure checks. These principles are the acceptance criteria.

## Product Direction

Product-Kit dogfoods its own protocol. Its product definition, decisions and development records
are kept privately and are not part of this repository; README.md and CHANGELOG.md describe the
public product.

## Tech Stack

<!-- Tech-stack summary. The internal plan operation preserves these managed markers. -->
<!-- PRDKIT-MANAGED:TECH-STACK:BEGIN -->
- **Languages**: Bash (scripts), Markdown (commands, templates, docs)
- **Frameworks/Runtimes**: none — POSIX/bash only, no npm/pip/build step
- **Optional tools**: jq 1.6+ for retrospective enrichment; gh and jq for opt-in GitHub review-report consistency
- **Storage**: files on disk
- **Platform/Deploy**: consumed as a git submodule (`.product-kit`) on macOS and Linux
<!-- PRDKIT-MANAGED:TECH-STACK:END -->

## Commands

```bash
# Build
# (none — Product-Kit is not compiled)

# Tests
bash tests/run.sh        # bash test runner; jq 1.6+ for enrichment coverage
```

## Test Personas

N/A — non-user-facing toolkit. Verification is automated (the test runner) and structural.

## Principles

### Principle I — Project-agnostic by default

Commands, templates, and docs MUST NOT assume any specific language, framework, or domain.
Anything project-specific is read from the consuming project's `.prdkit/memory/constitution.md`
and `.prdkit/memory/agents.md`. Generic defaults apply when those are absent.

### Principle II — No project-private leakage

Source material may be harvested from real projects, but only ABSTRACTED patterns ship.
No proprietary domain content, secrets, internal URLs, or project-specific names appear in
Product-Kit. Examples MUST use neutral, generic subjects.

### Principle III — Minimal dependencies and portability

Scripts MUST run with bash + coreutils + git, identically on macOS and Linux, with bounded
optional-tool exceptions: retrospective enrichment uses jq 1.6+ as its standard JSON parser
(2026-09-12), and explicitly requested GitHub review-report consistency uses gh and jq
(2026-10-30). Ledger-only reports and offline review checks require no jq or network.
Missing optional tools MUST fail clearly when their mode is requested; enrichment failures
MUST NOT replace a report, and unavailable report checks MUST NOT claim verified links.
No runtime package manager or compile step; the generator never installs dependencies.
The full test suite requires jq and MUST cover the no-jq ledger-only path.

### Principle IV — Project-owned customization

Installed projects own their copies of templates and memory files. Product-Kit upgrades
re-link commands but MUST NOT overwrite a project's templates, constitution, or agent registry.

### Principle V — Pluggable verification

Acceptance/walkthrough handling MUST support multiple backends (interactive, automated,
contract, golden-file) and MUST be skippable for non-user-facing projects, where the
constitution's principles serve as the acceptance criteria.

## Non-Negotiables

- **No leakage**: every shipped file passes a project-private content sweep.
- **Tests green before push**: the test runner and any validation scripts pass before pushing.
- **Generality**: a change that only makes sense for one project does not belong in Product-Kit.

## Governance

- **Amendment procedure**: edit this file directly (Product-Kit develops itself); version per below.
- **Versioning policy** (semantic): MAJOR = incompatible workflow/command changes; MINOR = new
  command/template/capability; PATCH = wording/clarification/fixes.
- **Compliance review**: changes are reviewed against these principles before merge.
