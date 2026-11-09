# <Product> — archive

<!-- Past tense, condensed: directions tried, why they stopped, lessons and notable outcomes.
What still binds lives in the spec, never here. Agents read this file on demand (a history
question, before re-trying a direction), never by default. Each entry is a few lines; its
details stay in git at the base. Past the budget, condense older entries harder.
new-change.sh reads the Base, Last and Log lines to never reuse an old number. -->

**Base**: `<full commit sha>`, main before the cutover (<YYYY-MM-DD>). Details:
`git show <sha>:<path>`; history: `git log -- <path>`.

**Last 0.x feature**: <NNN, or none>; new changes number above it.

**Log condensed through**: <NNN, or none>; those entries: `git show <sha>:specs/log.md`.

## <Direction tried>

- **Tried**: <what, when, for which journey or part>.
- **Stopped because**: <the evidence or the owner's decision; owner words verbatim>.
- **Lesson**: <what to do or avoid next time>.
- **Details**: `specs/features/<id>/` at the base.
