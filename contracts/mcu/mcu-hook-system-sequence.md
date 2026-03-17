# MCU Hook System Sequence Diagram

This document mirrors the abstract ERC-ACP sequence, but replaces the generic
hook with the concrete MCU hook system used in this repository:
`AgenticCommerceHooked`, `MCUHookLite`, `MCUCoordinator`,
`MCUSettlementEscrow`, `CollateralManager`, and `UnderwriterEvaluator`.
In this MCU flow, the end user and the ACP client are the same identity, so the
diagram uses a single `Client` actor.

Terminology: both the code and the diagrams now use **collateral** consistently
(`CollateralManager`, `lockCollateral`, `releaseCollateral`,
`requiredCollateralUsdc`).

## Business-Level Sequence Diagrams

These three diagrams follow the hand-drawn reference more closely: they keep
`ACP` and the `MCU` sidecar as separate lanes, emphasize phase boundaries, and
focus on workflow outcomes rather than every internal call. The
implementation-level diagrams remain below.

### Single-Stage Job

`settlementJobId = jobId`. The same ACP job carries request, funding, evidence,
underwriting, and settlement.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    participant ACP as ACP / AgenticCommerceHooked
    participant MCU as MCU Hook System
    actor Underwriter

    Note over Client,Underwriter: Resource model: one ACP job, one settlement identity, no AwaitingClose phase

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 1 - Request
        Client->>ACP: createJob(provider, evaluator=UnderwriterEvaluator, hook=MCUHookLite)
        Client->>ACP: setBudget(jobId, serviceFee, abi.encode(singleStageCommit))
        ACP->>MCU: beforeAction(jobId, setBudget, data)
        Note over ACP,MCU: ACP keeps the fee rail; MCU commits underwriting configuration
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 2 - Funding and Protection
        Client->>ACP: fund(jobId, serviceFee, optParams)
        ACP->>MCU: afterAction(jobId, fund, data)
        Client->>MCU: orchestrateFunding(jobId, permit, permitSig)
        Client->>MCU: pay underwriter premium (handled via CollateralManager)
        MCU->>Provider: pull and lock provider collateral
        opt releasePrincipal == true
            MCU->>Provider: deploy client principal to the execution wallet
        end
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 3 - Delivery and Underwriting
        Provider->>ACP: submit(jobId, bundleHash, submitEvidence)
        ACP->>MCU: afterAction(jobId, submit, data)
        alt underwriter approves the deliverable
            Underwriter-->>Client: sign CompleteDecision (off-chain)
            Client->>MCU: submit completeBySig(decision, sig) (on-chain tx)
            MCU->>ACP: complete(jobId, ...)
        else underwriter rejects the deliverable
            Underwriter-->>Client: sign RejectDecision (off-chain)
            Client->>MCU: submit rejectBySig(decision, sig) (on-chain tx)
            MCU->>ACP: reject(jobId, ...)
            Client->>MCU: finalizeRejectedJob(jobId)
            MCU-->>Client: run reject-side cleanup
        end
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 4 - Settlement after approval
        alt Scenario A - provider release request and no client dispute
            Provider->>MCU: requestCollateralRelease(jobId)
            Note over Client,MCU: dispute window passes without challenge
            Provider->>MCU: releaseCollateral(jobId)
            MCU-->>Provider: release locked collateral
        else Scenario B - provider release request, dispute opened, underwriter sides with provider
            Provider->>MCU: requestCollateralRelease(jobId)
            Client->>MCU: openSuccessDispute(jobId, disputeHash)
            Underwriter-->>Provider: sign SuccessDisputeDecision(ReleaseCollateral) (off-chain)
            Provider->>MCU: submit resolveSuccessDisputeBySig(...) (on-chain tx)
            Provider->>MCU: releaseCollateral(jobId)
            MCU-->>Provider: release locked collateral
        else Scenario C - provider release request, dispute opened, underwriter sides with client
            Provider->>MCU: requestCollateralRelease(jobId)
            Client->>MCU: openSuccessDispute(jobId, disputeHash)
            Underwriter-->>Client: sign SuccessDisputeDecision(SlashCollateral) (off-chain)
            Client->>MCU: submit resolveSuccessDisputeBySig(...) (on-chain tx)
            MCU-->>Client: slash collateral / coverage to client
        end
    end
```

### Open Two-Stage Job

`settlementJobId = openJobId`. This leg establishes underwriting and protection,
but does **not** submit the final deliverable and does **not** release
collateral.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    participant ACP as ACP / AgenticCommerceHooked
    participant MCU as MCU Hook System
    actor Underwriter

    Note over Client,Underwriter: Resource model: the open leg starts the workflow; the close leg is created later as a separate ACP job

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 1 - Request
        Client->>ACP: createOpenJob(provider, evaluator=UnderwriterEvaluator, hook=MCUHookLite)
        Client->>ACP: setBudget(openJobId, serviceFee, abi.encode(openCommit))
        ACP->>MCU: beforeAction(openJobId, setBudget, data)
        Note over ACP,MCU: ACP creates the open-leg job; MCU classifies TwoStageOpen and binds the chosen underwriter
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 2 - Funding and Protection
        Client->>ACP: fund(openJobId, serviceFee, optParams)
        ACP->>MCU: afterAction(openJobId, fund, data)
        Client->>MCU: orchestrateFunding(openJobId, permit, permitSig)
        Client->>MCU: pay underwriter premium (handled via CollateralManager)
        MCU->>Provider: pull and lock provider collateral
        opt releasePrincipal == true
            MCU->>Provider: deploy client principal to the execution wallet
        end
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 3 - Open-Leg Underwriting
        alt Scenario A - underwriter accepts principal deployment
            Underwriter-->>Client: sign CompleteDecision(open leg) (off-chain)
            Client->>MCU: submit completeBySig(decision, sig) (on-chain tx)
            MCU->>ACP: complete(openJobId, ...)
            Note over MCU: sidecarState = AwaitingClose
        else Scenario B - underwriter rejects the workflow
            Underwriter-->>Client: sign RejectDecision (off-chain)
            Client->>MCU: submit rejectBySig(decision, sig) (on-chain tx)
            MCU->>ACP: reject(openJobId, ...)
            Client->>MCU: finalizeRejectedJob(openJobId)
            MCU-->>Client: workflow ends; a new ACP job is required to continue
        end
    end
```

### Close Two-Stage Job

`settlementJobId = parentJobId`. The close leg reuses the parent protection
context and is where the final deliverable and collateral settlement occur.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    participant ACP as ACP / AgenticCommerceHooked
    participant MCU as MCU Hook System
    actor Underwriter

    Note over Client,Underwriter: Resource model: the parent open leg is already AwaitingClose; the close leg reuses the parent escrow and parent collateral

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 1 - Close Request
        Client->>ACP: createJob(provider, evaluator=UnderwriterEvaluator, hook=MCUHookLite)
        Client->>ACP: setBudget(closeJobId, closeServiceFee, abi.encode(closeCommit{ parentJobId = openJobId }))
        ACP->>MCU: beforeAction(closeJobId, setBudget, data)
        Note over ACP,MCU: ACP creates the close-leg job; MCU classifies TwoStageClose and verifies the parent linkage
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 2 - Fee Funding
        Client->>ACP: fund(closeJobId, closeServiceFee, optParams)
        ACP->>MCU: afterAction(closeJobId, fund, data)
        Client->>MCU: orchestrateFunding(closeJobId, unusedPermit, unusedSig)
        Note over ACP,MCU: close leg reuses the parent escrow and collateral context
        Note over Client,MCU: close leg does not collect a new underwriter premium
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 3 - Delivery and Underwriting
        Provider->>ACP: submit(closeJobId, bundleHash, submitEvidence)
        ACP->>MCU: afterAction(closeJobId, submit, data)
        alt underwriter approves the close deliverable
            Underwriter-->>Client: sign CompleteDecision (off-chain)
            Client->>MCU: submit completeBySig(decision, sig) (on-chain tx)
            MCU->>ACP: complete(closeJobId, ...)
        else underwriter rejects the close deliverable
            Underwriter-->>Client: sign RejectDecision (off-chain)
            Client->>MCU: submit rejectBySig(decision, sig) (on-chain tx)
            MCU->>ACP: reject(closeJobId, ...)
            Client->>MCU: finalizeRejectedJob(closeJobId)
            Note over Client,MCU: parent open leg stays AwaitingClose; a replacement close job may be created
        end
    end

    rect rgb(255, 236, 240)
        Note over Client,Underwriter: Phase 4 - Close Settlement after approval
        alt Scenario A - provider release request and no dispute
            Provider->>MCU: requestCollateralRelease(closeJobId)
            Note over Client,MCU: dispute window passes
            Provider->>MCU: releaseCollateral(closeJobId)
            MCU-->>Provider: release parent open-leg collateral
        else Scenario B - provider release request, dispute opened, underwriter sides with provider
            Provider->>MCU: requestCollateralRelease(closeJobId)
            Client->>MCU: openSuccessDispute(closeJobId, disputeHash)
            Underwriter-->>Provider: sign SuccessDisputeDecision(ReleaseCollateral) (off-chain)
            Provider->>MCU: submit resolveSuccessDisputeBySig(...) (on-chain tx)
            Provider->>MCU: releaseCollateral(closeJobId)
            MCU-->>Provider: release parent open-leg collateral
        else Scenario C - provider release request, dispute opened, underwriter sides with client
            Provider->>MCU: requestCollateralRelease(closeJobId)
            Client->>MCU: openSuccessDispute(closeJobId, disputeHash)
            Underwriter-->>Client: sign SuccessDisputeDecision(SlashCollateral) (off-chain)
            Client->>MCU: submit resolveSuccessDisputeBySig(...) (on-chain tx)
            MCU-->>Client: slash parent open-leg collateral / coverage to client
        end
    end
```

## Implementation-Level Open Leg

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    actor Underwriter
    participant ACP as AgenticCommerceHooked
    participant Hook as MCUHookLite
    participant Coord as MCUCoordinator
    participant Escrow as MCUSettlementEscrow
    participant Collateral as CollateralManager
    participant Eval as UnderwriterEvaluator

    Note over Client,Eval: Phase 0 - Discovery
    Client->>Provider: Request quote and execution terms
    Provider-->>Client: Return quote and settlement terms

    Note over Client,Eval: Phase 1 - Open Request
    Client->>ACP: createOpenJob(provider, evaluator=Eval, hook=Hook)
    Client->>ACP: setBudget(openJobId, serviceFee, abi.encode(openCommit))
    Note over Client,ACP: underwriter is selected in setBudget/openCommit
    ACP->>Hook: beforeAction(openJobId, setBudget, data)
    Note over Hook: sidecarState = Committed

    Note over Client,Eval: Phase 2 - Funding and Protection
    Client->>ACP: fund(openJobId, serviceFee, optParams)
    ACP->>Hook: afterAction(openJobId, fund, data)
    Note over Hook: sidecarState = FeeEscrowed

    Client->>Coord: orchestrateFunding(openJobId, permit, permitSig)
    Coord->>Escrow: pullCollateralFromProvider(requiredCollateralUsdc)
    Escrow->>Collateral: lockCollateral(permit, permit.user, unlockAt, permitSig)
    Note over Collateral,Client: CollateralManager also pulls decisionFeeUsdc premium from client during lockCollateral(...)
    opt releasePrincipal == true
        Coord->>Escrow: pullPrincipalFromClient(fundedPrincipalUsdc)
        Coord->>Escrow: releasePrincipal(permit, permitSig)
        Escrow->>Collateral: releasePrincipalToMerchant(permit, permitSig)
        Note over Provider,Collateral: principal is deployed to merchantExecutionWallet
    end
    Coord->>Hook: markProtected(openJobId, escrow)
    Note over Hook: sidecarState = Protected

    Note over Client,Eval: Phase 3 - Open Completion
    alt underwriter approves open leg
        Underwriter-->>Client: Sign CompleteDecision(open attestation) (off-chain)
        Client->>Eval: submit completeBySig(decision, sig) (on-chain tx)
        Eval->>ACP: complete(openJobId, reason, abi.encode(CompleteContext))
        ACP->>Hook: afterAction(openJobId, complete, data)
        Note over Hook: sidecarState = AwaitingClose
        Note over Client,Provider: collateral remains locked, no final deliverable yet
    else underwriter rejects open leg
        Underwriter-->>Client: Sign RejectDecision (off-chain)
        Client->>Eval: submit rejectBySig(decision, sig) (on-chain tx)
        Eval->>ACP: reject(openJobId, reason, abi.encode(RejectContext))
        Note over Client,Provider: workflow terminates; continuing requires a new ACP job
    end
```

## Implementation-Level Two-Stage Close Extension

Single-stage MCU jobs reuse the same protection and submission path as the
close-stage flow below, but they start from `createJob(...)` with
`parentJobId = 0` and never pass through `AwaitingClose`.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    actor Underwriter
    participant ACP as AgenticCommerceHooked
    participant Hook as MCUHookLite
    participant Coord as MCUCoordinator
    participant Escrow as MCUSettlementEscrow
    participant Collateral as CollateralManager
    participant Eval as UnderwriterEvaluator

    Note over Client,Hook: Parent open leg already reached Completed + AwaitingClose
    Client->>ACP: createJob(provider, evaluator=Eval, hook=Hook)
    Note over ACP: create a standalone ACP job; MCU will classify it during setBudget

    Client->>ACP: setBudget(closeJobId, closeServiceFee, abi.encode(closeCommit))
    Note over Client,ACP: close leg reuses the underwriter selected in the parent openCommit
    ACP->>Hook: beforeAction(closeJobId, setBudget, data)
    Hook-->>ACP: derive TwoStageClose, verify parent readiness, and record linkage

    Client->>ACP: fund(closeJobId, closeServiceFee, optParams)
    ACP->>Hook: afterAction(closeJobId, fund, data)
    Note over Hook: close sidecarState = FeeEscrowed

    Client->>Coord: orchestrateFunding(closeJobId, unusedPermit, unusedSig)
    Note over Coord,Escrow: reuse parent escrow; no new collateral or principal pulled
    Coord->>Hook: markProtected(closeJobId, escrow)
    Note over Hook: close sidecarState = Protected

    Provider->>ACP: submit(closeJobId, bundleHash, abi.encode(SubmitEvidence))
    ACP->>Hook: afterAction(closeJobId, submit, data)
    Note over Hook: close sidecarState = EvidenceSubmitted

    alt underwriter approves close deliverable
        Underwriter-->>Client: Sign CompleteDecision (off-chain)
        Client->>Eval: submit completeBySig(decision, sig) (on-chain tx)
        Eval->>ACP: complete(closeJobId, reason, abi.encode(CompleteContext))
        ACP->>Hook: afterAction(closeJobId, complete, data)
        Note over Hook: close sidecarState = SuccessPendingConfirmation

        Provider->>Coord: requestCollateralRelease(closeJobId)
        Coord->>Hook: markSuccessPendingCollateralRelease(closeJobId)
        Note over Hook: close sidecarState = SuccessPendingCollateralRelease
        Note over Client,Coord: client dispute window begins

        alt client disputes within window
            Client->>Coord: openSuccessDispute(closeJobId, disputeHash)
            Coord->>Hook: markSuccessDisputeOpen(closeJobId, disputeHash)
            Note over Hook: close sidecarState = SuccessDisputeOpen

            alt underwriter resolves in favor of release
                Underwriter-->>Provider: Sign SuccessDisputeDecision(ReleaseCollateral) (off-chain)
                Provider->>Eval: submit resolveSuccessDisputeBySig(decision, emptyAttestation, "", sig) (on-chain tx)
                Eval->>Coord: applySuccessDisputeDecision(decision, emptyAttestation, "")
                Coord->>Hook: markSuccessPendingCollateralRelease(closeJobId)
            else underwriter resolves in favor of slash
                Underwriter-->>Client: Sign SuccessDisputeDecision(SlashCollateral) (off-chain)
                Client->>Eval: submit resolveSuccessDisputeBySig(decision, attestation, slashSig, sig) (on-chain tx)
                Eval->>Coord: applySuccessDisputeDecision(decision, attestation, slashSig)
            end
        else no client dispute before deadline
            Note over Client,Coord: release stays eligible once the dispute window closes
        end

        Note over Provider,Coord: after unlockAt and after any required dispute-window close
        Provider->>Coord: releaseCollateral(closeJobId)
        Coord->>Escrow: releaseCollateralAndForward()
        Escrow->>Collateral: releaseCollateral(settlementJobId)
        Escrow-->>Provider: forward released collateral balance
        Coord->>Hook: markSuccessSettled(closeJobId)

    else underwriter rejects close deliverable
        Underwriter-->>Client: Sign RejectDecision (off-chain)
        Client->>Eval: submit rejectBySig(decision, sig) (on-chain tx)
        Eval->>ACP: reject(closeJobId, reason, abi.encode(RejectContext))
        Client->>Coord: finalizeRejectedJob(closeJobId)
    end
```

## Settlement Identity and Signature Summary

- `MCUCommit` is committed on-chain by the `Client` during `setBudget(...)`.
- `settlementJobId` is derived from ACP job lineage:
  `Standalone/Open => jobId`, `TwoStageClose => parentJobId`.
- `UnderwritePermit` and `permitSig` carry both the current `jobId` and the
  derived `settlementJobId` so `MCUCoordinator`, `MCUSettlementEscrow`, and
  `CollateralManager` can lock collateral and optionally deploy principal.
- `CompleteDecision`, `RejectDecision`, and `SuccessDisputeDecision` are signed
  by the `Underwriter` against the current ACP `jobId`; settlement identity is
  derived by the MCU contracts when collateral actions need it.

## Review Draft Settlement Semantics

This sequence file still shows the currently implemented close-stage path. For
review of the next settlement model, apply these business rules:

- open-stage underwriter rejection is terminal for that workflow
- continuing after open-stage rejection requires a new ACP job
- `2-of-3` settlement only applies after underwriting has been accepted
- the settlement signer set is `Client`, `Provider`, and `Underwriter`
- settlement identity is expressed in job-native terms rather than memo-like
  business identifiers
- the intended draft outcomes are:
  - `Provider + Underwriter => ReleaseCollateralToProvider`
  - `Client + Underwriter => SlashCollateralToClient`
- after the provider requests collateral release, the client may use a dispute
  window before collateral is finalized
- `Client + Provider => MutualSettlement` is not part of the current draft v1
- timeout handling must be defined explicitly by settlement policy

## Expiry Note

This sequence focuses on the main MCU request, execution, completion, reject,
and success-dispute paths. Expiry remains intentionally split across:

- `AgenticCommerceHooked.claimRefund(...)` for the ACP escrow refund.
- `MCUCoordinator.settleExpiry(...)` for MCU-specific timeout settlement after
  the ACP job is already marked expired.
