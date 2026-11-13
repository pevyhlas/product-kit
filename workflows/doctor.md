# Diagnostics

**Inputs**: installed kit, `specs/`, tests, agent context files.
**Writes**: none.
**Result**: concrete findings and the smallest repair for each.

Run `.prdkit/scripts/bash/doctor.sh` (`--json`, `--strict`): 0.x layout or two canons, a
`specs/archive/` folder on main, a `specs/archive.md` whose base commit or last 0.x feature
cannot be read, agent context naming removed 0.x paths, files over their reading budgets, cited
IDs that are undefined or retired, malformed records, a closed change without its log entry,
a malformed `specs/log/<id>.md`, a reviewed record merged without closing,
expired holds and waivers, open inbox items by age, pending answers, retained resolved and
one-line inbox items, missing inbox metadata/provenance, duplicate IDs/option keys and stale answer
revisions, local machine
paths, links to missing files in the spec and `specs/archive.md`, spec files no summary links
(1.1 layout), `observed/` pieces `observed.md` does not link, a lifecycle stage naming no
environment the environments topic lists, raw evidence under `specs/`, oversized agent context
files and agent projection drift. Trace advisories, counted by code under `trace` in `--json`:
missing `Code:` paths, `planned:` markers naming a closed or no open change, retired IDs cited in
spec text, R/Q items no part or architecture file cites, parts citing no J/R/Q, and change
records restating spec items or citing undefined IDs. Malformed spec IDs/records, an unlogged
close, duplicate inbox identities/fields/option keys and mismatched answer revisions are errors;
the rest are advisories that `--strict` fails. The kit's `scripts/init.sh --check` reports
installation drift. Never repair during diagnosis or read a clean report as readiness.

Ordinary text and JSON also separate installed kit version (manifest), observed spec layout and
layout-derived migration state. `required` means legacy 0.x; `incomplete` means competing canons
or spec forms; `not-indicated` means current layout only; `unknown` means no recognized spec.
Neither a current installed version nor `not-indicated` verifies migration completion. Missing
or ambiguous manifest version stays unknown; the source checkout is not a substitute.

For configuration/provenance questions add `--inventory --json`. It reports installed hashes,
project-owned customizations, source pins and resolved versus projected agent models with winning
rules. Unobserved active harness/model and runtime capabilities remain unknown. This is opt-in:
do not load the full inventory for ordinary status questions. See the findings as well as the
inventory; a recorded pin or projected model does not prove the running session used it.
