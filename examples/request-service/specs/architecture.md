# Request service — architecture

**Inherits**: none

One service owns requests and their status; a web client is where everyone works.

## Shape

```mermaid
flowchart LR
  R([Requester]) --> P2[P2 Web client]
  O([Operator]) --> P2
  P2 -->|requests, status| P1[P1 Request service]
  P2 --> ID[(Organization identity)]
```

Requests and resolutions live only in P1. P1 trusts only the organization provider's tokens.

## Parts

| Part | What it is | Why it exists | Components | Maturity | Spec |
|------|------------|---------------|------------|----------|------|
| P1 Request service | an HTTP service | J-01: one owner of request state (R-01, R-02, Q-01) | API, storage | hypothesis | none yet |
| P2 Web client | pages in the browser | J-01: where requesters and operators work | submit, status, resolve | hypothesis | none yet |

## Core loop

```mermaid
sequenceDiagram
  actor R as Requester
  R->>P2: submit a request
  P2->>P1: create
  P1-->>P2: status
  R->>P2: open the request later
  P2->>P1: read status and resolution
```

## Key decisions

None yet; storage and hosting are left open.

## Key areas

| Area | In a line |
|------|-----------|
| Security and privacy | Sign-in is the organization's (C-01); only the requester and operators see a resolution (R-02). |
| Interfaces | Organization identity, for sign-in: when it fails nobody can sign in, and nothing is lost. |
| Data | Requests and resolutions, owned by P1; retention is left open. |
| Environments | TEST: early access, where a change is tried first; PROD: the whole organization. |

## Risks

- **Requesters see status without asking (R-01, Q-01)**: P1 alone owns request state and P2
  reads it on view and on change. Assumes the identity provider returns a stable user id.
  Rejected: an off-the-shelf help desk, because requests carry organization-specific fields.
  Revisit when more than one team handles requests.

## Left open

- Storage engine, hosting and retention; the first change picks them.
