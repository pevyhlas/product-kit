# Same-PR finalization retains non-gating runtime unknowns without cleanup work

A docs-only change has a locally verifiable PR obligation. Production observation was explicitly
non-gating before execution. The fixture's .eval-state/pr.md is an offline PR transport, not real
published evidence. The agent finalizes on the same branch, keeps the canon unchanged, records
unknown runtime status and deletes the change with its log entry. The handoff must name the
closing SHA and leave its approval pending. Only then does the assertion supply a synthetic
independent approval and check that the closed T1 head can pass.
