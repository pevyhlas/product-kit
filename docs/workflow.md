# Product-Kit workflow

Product-Kit has two views of one protocol:

- [Human workflow](human-workflow.md): direction, decisions, outcomes and learning.
- [Agent workflow](agent-workflow.md): context, changes, evidence and resumption.

```text
owner direction ──► specs/inbox.md ──► spec edit (L0 / L1 / L2) ─┐
                                                                  ▼
bounded request ──► change opened ──► build + check ──► review ──► acceptance ──► close
                     specs/changes/<id>.md                         (live where   log line,
                                                                    it matters)  record deleted
                                                                  │
outcomes ──► /prdkit-learn ──► inbox proposals ◄──────────────────┘
```

Use `/prdkit` to enter the loop, `/prdkit-inbox` to answer pending questions and incorporate
recorded direction, and `/prdkit-status` for the generated view. `/prdkit-product`
edits product intent, `/prdkit-target` plans a programme of changes and `/prdkit-learn` reviews
outcomes. `/prdkit-init`, `/prdkit-configure` and `/prdkit-doctor` handle setup, policy and
diagnostics.

The playbooks are internal agent operations, not human checkpoints. Consequential questions
come before a change opens; ordinary building continues within authorized scope. Every
acceptance item still needs actual evidence. See [spec.md](../workflows/spec.md) and
[change.md](../workflows/change.md).
