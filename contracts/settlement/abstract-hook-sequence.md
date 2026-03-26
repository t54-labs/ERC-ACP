# Abstract ERC-ACP Sequence Diagram

This document captures the generic ERC-ACP request, negotiation, transaction,
and completion flow with an abstract hook. It intentionally does not assume any
specific hook implementation.

> Note: This is a generic ACP reference. The finalized underwriting flow in
> `hooks/underwriting/` requires `Submitted + EvidenceSubmitted` before
> evaluator-driven completion or rejection.

## Open Leg

```mermaid
sequenceDiagram
    autonumber
    actor User
    actor Client
    actor Provider
    participant ACP as ACP Core
    participant Hook as Abstract Hook

    User->>Client: Approve opening request
    Client->>ACP: createOpenJob(...)
    Client->>ACP: setBudget(openJobId, ...)
    ACP->>Hook: beforeAction(openJobId, setBudget, data)
    ACP->>Hook: afterAction(openJobId, setBudget, data)

    Client->>ACP: fund(openJobId, ...)
    ACP->>Hook: beforeAction(openJobId, fund, data)
    ACP->>Hook: afterAction(openJobId, fund, data)

    Note over Hook,Provider: Hook may deploy client principal and lock provider collateral
    Note over ACP,Hook: Some hook implementations may complete directly from Funded
    ACP->>Hook: beforeAction(openJobId, complete, data)
    ACP->>Hook: afterAction(openJobId, complete, data)
    ACP-->>Client: Open leg completed and waiting for future close
```

## Optional Linked Close Job Extension

Implementations that adopt ACP linked two-phase jobs can start a later close or
evaluation leg after the parent open leg is completed. ACP owns the parent/close
relationship; the hook still decides any additional close-leg policy checks.

```mermaid
sequenceDiagram
    actor User
    actor Client
    participant ACP as ACP Core
    participant Hook as Abstract Hook

    Note over User,Hook: Optional Phase 6 - Linked Close Job
    User->>Client: Approve close or reevaluation step
    Client->>ACP: createCloseJob(parentJobId, expiredAt, closeDescription)
    Note over ACP: inherit parent actors and record linked-job relationship

    Client->>ACP: setBudget(closeJobId, closeBudget, closeOptParams)
    ACP->>Hook: beforeAction(closeJobId, setBudget, data)
    Hook-->>ACP: Validate linked-close policy
    ACP->>Hook: afterAction(closeJobId, setBudget, data)

    Client->>ACP: fund(closeJobId, closeBudget, closeOptParams)
    ACP->>Hook: beforeAction(closeJobId, fund, data)
    Hook-->>ACP: Validate close-leg activation
    ACP->>Hook: afterAction(closeJobId, fund, data)

    Provider->>ACP: submit(closeJobId, deliverable, data)
    ACP->>Hook: beforeAction(closeJobId, submit, data)
    Hook-->>ACP: Validate final deliverable policy
    ACP->>Hook: afterAction(closeJobId, submit, data)
```

## Memo Ownership Summary

- `JobRequestMemo` is created by the `Client` and signed by the `Provider`.
- `PayableRequestMemo` is created by the `Provider` and signed by the `Client`.
- `TransactionMemo` is created by the `Client`.
- The `Abstract Hook` validates ACP lifecycle actions but does not author or sign
  the business memos.
