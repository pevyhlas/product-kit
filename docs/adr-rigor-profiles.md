# Decision: proportional verification and review

**Status**: accepted; carried into 1.0 as review tiers

Use one project Rigor field, light or full. Both require truthful evidence and relevant
verification. Review is proportional to the change's tier: T0 docs only (no reviewer), T1
inside one part (one), T2 several parts, an interface, security or data (one per applicable
concern), T3 an L0 edit or L1 one-way door (design review plus the owner). Full also makes
medium findings block and requires independent review of every substantive change.
Critical/high findings block under both. Project-specific risk reviews can apply to either.

Spec depth follows risk, not size: a line earns its place only where a wrong implementation
would be expensive. Tests and scenario coverage follow the behavior changed.

The operational source is [protocol.md](../workflows/protocol.md) and the project-owned
[constitution template](../templates/constitution-template.md). Tests protect applicability,
evidence and bounded attempts rather than duplicated prose or fixed quotas.
