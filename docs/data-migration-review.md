# Reviewing data evolution

Apply this guidance when the actual change affects durable data, migration, consistency,
retention, or recovery. Select relevant checks; a documentation-only change does not need a
migration form. Data changes are review tier T2 or higher.

- State the changed invariant, schema or behavior and the affected data.
- Define forward steps, ordering, idempotency, concurrency, and partial-failure behavior.
- Explain recovery and rollback limits and relevant backup or restore evidence.
- Verify using the project's appropriate commands and environment.
- Record operational ownership and action authority before live changes.

Evidence belongs in the change's Acceptance, linked to its original output; a migration's
lasting rule (for example an invariant on retained data) belongs in the owning part's L2 file.
The constitution's `Review and checks` names any extra review the project requires for data.
