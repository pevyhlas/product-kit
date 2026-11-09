# Request service — why it works

## Requesters see status without asking (R-01, Q-01)

- **Mechanism**: P1 alone owns request state; P2 reads it on view and on change.
- **Assumptions**: the identity provider returns a stable user id.
- **Decided in**: D-01.
