# Compaction

**Inputs**: current canon, code, constitution, agent memory and worklogs, owner direction.
**Writes**: the spec files ([spec.md](spec.md), Layout), inbox, `specs/archive.md`.
**Result**: one current canon the owner reads quickly, plus owner questions.

## Compaction (on overflow, and every ten closed changes)

Preserve operative hold and waiver rows and their referenced authority entries. Move long quotes
out of the rows by checked reference ([protocol.md](protocol.md)), never by shortening the scope.

Rewrite within the budgets, by tightening and splitting, never by dropping items. Keep current truth, decisions with their alternatives
and revisit conditions, why-it-works assumptions, and retired IDs (one line each). Drop to git: history,
amendment notes, superseded wording and resolved questions. Keep a rejected alternative that is
still a plausible proposal; it prevents re-proposals. `specs/archive.md` grows into git
instead: condense its older entries harder; their details stay at the referenced commits. First fold each
`specs/log/<id>.md` into `specs/log.md` at its newest end (on top, unless the log lists the
oldest change first), ordered like the log by date, then change number, and delete the entry
files. `specs/log.md` past its budget keeps its newest entries; the older ones, up to a number below every open or planned
change, become archive entries for notable outcomes and lessons, and the archive's **Log condensed
through** line names that number and the log at the commit before. A first `specs/archive.md`
starts from `archive-template.md`. End each pass
with `- <date> compaction: <what changed>` as the newest entry in `specs/log.md` (on top, unless
the log lists the oldest change first).
