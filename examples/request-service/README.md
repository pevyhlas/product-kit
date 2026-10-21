# Example: a first useful request service

A small, human-readable spec in the 1.1 layout. It records proposed behavior, not a claim that an
implementation or user research exists.

```text
Human: I want a simpler way for people to get their requests handled.
Agent: I recommend a first journey: submit, resolve, retrieve the resolution.
       Is this for one organization? Should requesters need new accounts?
Human: One organization. Use the existing identity system.
Agent: Recorded as C-01; routing and analytics are non-goals for now.
```

Read the [product](specs/product.md) and its [journey](specs/product/journeys/j-01-get-a-request-handled.md) (L0), the [architecture](specs/architecture.md) (L1) and
the [inbox](specs/inbox.md). An execution request would open a change for J-01 with
acceptance items proving R-01 and R-02, and the change would add any part file the work
shows is needed. The thesis stays a hypothesis until real requesters use it; a passing
automated journey alone cannot validate it.
