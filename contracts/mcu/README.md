# MCU Hook System

This directory contains an experimental ACP-compatible hook profile for Merchant
Custody Underwriting (MCU).

The design keeps `AgenticCommerceHooked` as the standard job kernel and moves
MCU-specific policy, collateral, principal, and underwriting flows into a
separate module. The goal is to preserve ACP's small, predictable escrow
lifecycle while still supporting collateral-backed provider execution and
underwriter-signed finalization.

## Design Summary

The MCU module follows a "light hook + explicit coordinator" model:

- ACP core escrows only the provider service fee.
- `MCUHookLite` stores MCU configuration, manages the underwriter registry,
  classifies each MCU job as single-stage or two-stage, and gates ACP
  transitions.
- `MCUCoordinator` performs the heavy sidecar steps after ACP transitions.
- `MCUSettlementEscrow` acts as the per-job settlement escrow and presents the
  sender shape expected by `CollateralManager`.
- `UnderwriterEvaluator` verifies underwriter signatures and acts as the ACP
  evaluator contract, including post-completion success dispute decisions.

This split intentionally avoids packing every collateral and principal side effect
into ACP hook callbacks. That keeps the hook smaller, fits better with
`AgenticCommerceHooked`'s gas-limited callback model, and leaves `claimRefund()`
outside the hook surface as intended by ACP.

## Module Layout

| File | Responsibility |
|------|----------------|
| `IAgenticCommerceKernel.sol` | Local interface for the hookable ACP kernel used by this module. |
| `ICollateralManager.sol` | Sidecar settlement interface for collateral, principal, timeout, and slash flows. |
| `MCUTypes.sol` | Shared enums and payload structs used across the MCU contracts, including success-dispute decisions. |
| `MCUHookLite.sol` | Policy hook that commits profile metadata, gates ACP actions, and tracks MCU sidecar state plus settlement-window timing. |
| `MCUCoordinator.sol` | Explicit orchestrator for funding, provider release requests, client dispute windows, success-dispute resolution, collateral release, timeout handling, and reject cleanup. |
| `MCUSettlementEscrow.sol` | Per-job settlement escrow that pulls funds and presents the sender shape expected by `CollateralManager`. |
| `UnderwriterEvaluator.sol` | Contract evaluator that verifies underwriter EIP-712 decisions for ACP `complete()` / `reject()` and success-dispute resolution. |

## How It Fits ACP

ACP remains the job rail:

- `createOpenJob()` creates a two-stage open leg that may later park in
  `AwaitingClose`.
- `createJob()` creates either a single-stage MCU job or a later two-stage close
  leg.
- `setBudget()` commits the MCU profile.
- `fund()` escrows the provider fee in ACP.
- `submit()` records the evidence bundle for evaluator review on single-stage and
  two-stage close jobs.
- `complete()` / `reject()` are still evaluator-driven terminal decisions.
- `claimRefund()` remains non-hookable and refunds only the ACP escrow.

Within that rail, `MCUHookLite` owns the MCU-specific classification and linkage:

- it derives `SingleStage`, `TwoStageOpen`, or `TwoStageClose` from the ACP job
  kind plus `MCUCommit.parentJobId`
- it manages the active parent/close linkage for two-stage jobs
- it enforces that every two-stage close leg reuses the same underwriter chosen
  by the parent open leg
- it requires newly committed single-stage and two-stage open jobs to pick a
  registered underwriter signer

The MCU module handles the non-core settlement legs:

- underwriting premium
- provider collateral
- funded principal deployment
- delivery mirroring into `CollateralManager`
- delivery-confirmation timeout escalation
- collateral release, slash, timeout settlement, and reject cleanup

This boundary is important: the ACP budget should represent the provider service
fee, not a merged bucket for premium, principal, collateral, and compensation.

## Expected Job Flow

The current MCU hook supports three flows:

1. Single-stage:
   - the hook admin or `MCUHookSystemExample` owner calls `registerUnderwriter(underwriter)`
   - `createJob(provider, evaluator = UnderwriterEvaluator, expiredAt, description, hook = MCUHookLite)`
   - `setBudget(jobId, serviceFee, abi.encode(singleStageCommit{ parentJobId = 0 }))`
   - `fund(jobId, serviceFee, optParams)`
   - `MCUCoordinator.orchestrateFunding(jobId, permit, permitSig)`
   - `submit(jobId, bundleHash, abi.encode(MCUTypes.SubmitEvidence))`
   - `UnderwriterEvaluator.completeBySig(...)` or `rejectBySig(...)`
   - after successful completion, the `provider` requests collateral release,
     the `client` gets a dispute window, and settlement then resolves into
     collateral release or slash

2. Two-stage open:
   - the hook admin or `MCUHookSystemExample` owner calls `registerUnderwriter(underwriter)`
   - `createOpenJob(provider, evaluator = UnderwriterEvaluator, expiredAt, description, hook = MCUHookLite)`
   - `setBudget(openJobId, serviceFee, abi.encode(openCommit{ parentJobId = 0 }))`
   - the `client` selects the concrete `underwriter` inside `openCommit` during
     this `setBudget(...)` step; `createOpenJob(...)` itself does not choose the
     underwriter signer
   - `fund(openJobId, serviceFee, optParams)`
   - `MCUCoordinator.orchestrateFunding(openJobId, permit, permitSig)`
   - `UnderwriterEvaluator.completeBySig(...)` or `rejectBySig(...)` while the
     open job is still ACP `Funded`
   - on success, `MCUHookLite` marks the parent sidecar `AwaitingClose`

3. Two-stage close:
   - when the client wants to unwind or settle, it calls
     `createJob(provider, evaluator = UnderwriterEvaluator, expiredAt, description, hook = MCUHookLite)`
   - `setBudget(closeJobId, closeServiceFee, abi.encode(closeCommit{ parentJobId = openJobId }))`
   - during that commit, `MCUHookLite` validates the parent open leg, binds the
     active linkage, derives `settlementJobId = parentJobId`, and enforces that the close leg
     reuses the same underwriter that was originally selected in the parent
     open-stage `setBudget/openCommit`
   - `fund(closeJobId, closeServiceFee, optParams)`
  - `MCUCoordinator.orchestrateFunding(closeJobId, ...)` reuses the parent
    settlement escrow and `settlementJobId` but does **not** pull new collateral or principal
   - `submit(closeJobId, bundleHash, abi.encode(MCUTypes.SubmitEvidence))`
   - `UnderwriterEvaluator.completeBySig(...)` or `rejectBySig(...)`
   - after successful completion, the `provider` requests collateral release,
     the `client` may dispute within the settlement window, and the close-leg
     settlement then determines whether the **parent open-leg collateral** is
     released or slashed
   - if a close attempt reaches ACP `Rejected` or `Expired` and the MCU cleanup
     step finishes, the parent open leg stays `AwaitingClose` and the client can
     commit a replacement close job

4. Failure / expiry paths:
   - reject cleanup via `MCUCoordinator.finalizeRejectedJob(...)`
   - timeout cleanup via `MCUCoordinator.settleExpiry(...)`

Important semantic note:

- `principal` is client capital handed to the provider for strategy execution.
- The current `CollateralManager` method name `releasePrincipalToMerchant(...)` is used
  during the **open leg**, but semantically this is principal **deployment** to
  `merchantExecutionWallet`, not final settlement.
- In a single-stage flow, the user-facing `deliverable` is submitted on that
  same job.
- In a two-stage flow, the user-facing `deliverable` is only submitted on the
  **close leg**.

## Review Draft Settlement Semantics

This section is a review draft for the next settlement model. It defines the
intended protocol semantics using business terms and is **not** a claim that the
current contracts already implement the quorum flow exactly as written below.

Terms used in this draft:

- `client`: the end user initiating the workflow
- `provider`: the counterparty executing the workflow
- `collateral`: the provider-posted locked value that can later be released or
  slashed
- settlement identity is job-native: `settlementJobId = jobId` for standalone
  and open flows, and `settlementJobId = parentJobId` for two-stage close flows
- settlement decisions should bind to the relevant job lineage, outcome,
  deadline, nonce, and policy

Open-stage admission rules:

- The two-stage `open job` decides whether underwriting is established for the
  workflow.
- If the underwriter approves the open leg, the workflow becomes an active
  underwritten cycle and may later enter close-stage settlement.
- If the underwriter rejects the open leg, that rejection is terminal for the
  workflow.
- After an open-stage underwriter rejection, the current workflow **MUST NOT**
  continue into the same close-stage flow or settlement path.
- If the client still wants to proceed after open-stage rejection, the client
  **MUST** submit a new ACP job and start a new negotiation / underwriting
  context.

Close-stage settlement scope:

- The `2-of-3` settlement model only applies after underwriting has already been
  accepted.
- The settlement signer set is:
  - `Client`
  - `Provider`
  - `Underwriter`
- In this draft, the intended settlement outcomes are:
  - `Provider + Underwriter => ReleaseCollateralToProvider`
  - `Client + Underwriter => SlashCollateralToClient`
- After the provider requests collateral release, the client may use a dispute
  window in the close-stage settlement process to challenge that release request
  before collateral is finalized.
- `Client + Provider => MutualSettlement` is **not** part of this draft v1
  settlement model.
- If no valid outcome is reached before timeout, the default handling **MUST**
  be defined explicitly by settlement policy.

## Sequence Diagram

### Open Leg

The open leg deploys client principal into the provider execution wallet under
underwriter protection. It does **not** submit the final deliverable and does
**not** release the provider collateral.

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

    Client->>ACP: createOpenJob(provider, evaluator=Eval, hook=Hook)
    Client->>ACP: setBudget(openJobId, serviceFee, abi.encode(openCommit))
    ACP->>Hook: beforeAction(openJobId, setBudget, data)
    Hook-->>ACP: validate wiring, provider, evaluator, and commit
    Note over Hook: store MCU profile and underwriting configuration
    Note over Hook: sidecarState = Committed

    Client->>ACP: fund(openJobId, serviceFee, optParams)
    ACP->>Hook: beforeAction(openJobId, fund, data)
    Hook-->>ACP: require sidecarState = Committed
    ACP->>ACP: escrow provider fee and mark open job Funded
    ACP->>Hook: afterAction(openJobId, fund, data)
    Note over Hook: sidecarState = FeeEscrowed

    alt job expires before coordinator funding
        Note over ACP: claimRefund() stays outside the hook surface
        Client->>ACP: claimRefund(openJobId)
        ACP->>ACP: refund ACP fee escrow only and mark job Expired
        Client->>Coord: settleExpiry(openJobId)
        Coord->>Hook: markExpirySettled(openJobId)
        Note over Hook: sidecarState = ExpirySettled

    else client activates the MCU sidecar
        Client->>Coord: orchestrateFunding(openJobId, permit, permitSig)
        Coord->>ACP: getJob(openJobId)
        Coord->>Hook: getCommit(openJobId) + jobSidecarState(openJobId)
        alt no escrow exists yet
            Coord->>Escrow: new MCUSettlementEscrow(paymentToken, Collateral, controller)
            Coord->>Escrow: configure(openJobId, client, provider, settlementJobId, executionWallet)
        else escrow already exists
            Coord->>Hook: load existing escrow address
        end
        Coord->>Escrow: pullCollateralFromProvider(requiredCollateralUsdc)
        Note over Escrow,Provider: escrow uses ERC20 transferFrom against prior allowance
        opt releasePrincipal == true
            Coord->>Escrow: pullPrincipalFromClient(fundedPrincipalUsdc)
            Note over Escrow,Client: client principal is staged for deployment
        end
        Coord->>Escrow: lockCollateral(permit, permitSig)
        Escrow->>Collateral: lockCollateral(permit, permit.user, unlockAt, permitSig)
        Note over Collateral,Client: CollateralManager also pulls decisionFeeUsdc premium from client during lockCollateral(...)
        opt releasePrincipal == true
            Coord->>Escrow: releasePrincipal(permit, permitSig)
            Escrow->>Collateral: releasePrincipalToMerchant(permit, permitSig)
            Note over Collateral,Provider: principal is deployed to merchantExecutionWallet
        end
        Coord->>Hook: markProtected(openJobId, escrow)
        Note over Hook: sidecarState = Protected

        alt open job expires after protection but before evaluator decision
            Note over ACP: claimRefund() stays outside the hook surface
            Client->>ACP: claimRefund(openJobId)
            ACP->>ACP: refund ACP fee escrow only and mark job Expired

            Client->>Coord: settleExpiry(openJobId)
            Coord->>Hook: markExpiryPendingTimeout(openJobId)
            Coord->>Escrow: claimTimeout()
            Escrow->>Collateral: claimTimeout(settlementJobId)
            Coord->>Hook: markExpirySettled(openJobId)
            Note over Hook: sidecarState = ExpirySettled

        else underwriter decides whether principal deployment is acceptable
            alt underwriter approves open leg
                Underwriter-->>Client: sign CompleteDecision(open attestation)
                Client->>Eval: completeBySig(decision, sig)
                Eval->>Hook: jobUnderwriter(openJobId) + jobSettlementJobId(openJobId)
                Eval->>Eval: verify signer, settlementJobId, deadline, and nonce
                Eval->>ACP: complete(openJobId, reason, abi.encode(CompleteContext))
                ACP->>Hook: beforeAction(openJobId, complete, data)
                ACP->>ACP: mark open job Completed
                ACP->>Hook: afterAction(openJobId, complete, data)
                Note over Hook: sidecarState = AwaitingClose
                Note over Client,Provider: collateral stays locked, no final deliverable yet

            else underwriter rejects open leg
                Underwriter-->>Client: sign RejectDecision
                Client->>Eval: rejectBySig(decision, sig)
                Eval->>ACP: reject(openJobId, reason, abi.encode(RejectContext))
                ACP->>Hook: afterAction(openJobId, reject, data)
                Note over Hook: sidecarState = RejectPendingSlash or RejectSettled
                Client->>Coord: finalizeRejectedJob(openJobId)
                Note over Client,Provider: workflow ends here; continuing requires a new ACP job
            end
        end
    end
```

### Two-Stage Close Settlement Path

The two-stage close leg is where the final deliverable is submitted and where
the parent open-leg collateral is ultimately released or slashed.

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
    Client->>ACP: setBudget(closeJobId, closeServiceFee, abi.encode(closeCommit))
    ACP->>Hook: beforeAction(closeJobId, setBudget, data)
    Note over Hook: derive TwoStageClose, verify parent readiness, and store linkage

    Client->>ACP: fund(closeJobId, closeServiceFee, optParams)
    ACP->>Hook: afterAction(closeJobId, fund, data)
    Note over Hook: sidecarState = FeeEscrowed

    Client->>Coord: orchestrateFunding(closeJobId, unusedPermit, unusedSig)
    Note over Coord,Escrow: reuse parent escrow; no new collateral or principal pulled
    Coord->>Hook: markProtected(closeJobId, escrow)
    Note over Hook: sidecarState = Protected

    Provider->>ACP: submit(closeJobId, bundleHash, abi.encode(SubmitEvidence))
    ACP->>Hook: afterAction(closeJobId, submit, data)
    Note over Hook: sidecarState = EvidenceSubmitted

    Underwriter-->>Client: sign CompleteDecision
    Client->>Eval: completeBySig(decision, sig)
    Eval->>ACP: complete(closeJobId, reason, abi.encode(CompleteContext))
    ACP->>Hook: afterAction(closeJobId, complete, data)
    Note over Hook: sidecarState = SuccessPendingConfirmation

    Provider->>Coord: requestCollateralRelease(closeJobId)
    Coord->>Hook: markSuccessPendingCollateralRelease(closeJobId)
    Note over Hook: sidecarState = SuccessPendingCollateralRelease
    Note over Client,Coord: client dispute window begins

    alt client disputes within window
        Client->>Coord: openSuccessDispute(closeJobId, disputeHash)
        Coord->>Hook: markSuccessDisputeOpen(closeJobId, disputeHash)
        Note over Hook: sidecarState = SuccessDisputeOpen

        alt underwriter resolves in favor of release
            Underwriter-->>Provider: sign SuccessDisputeDecision(ReleaseCollateral)
            Provider->>Eval: resolveSuccessDisputeBySig(decision, emptyAttestation, "", sig)
            Eval->>Coord: applySuccessDisputeDecision(decision, emptyAttestation, "")
            Coord->>Hook: markSuccessPendingCollateralRelease(closeJobId)
            Note over Hook: sidecarState = SuccessPendingCollateralRelease
        else underwriter resolves in favor of slash
            Underwriter-->>Client: sign SuccessDisputeDecision(SlashCollateral)
            Client->>Eval: resolveSuccessDisputeBySig(decision, attestation, slashSig, sig)
            Eval->>Coord: applySuccessDisputeDecision(decision, attestation, slashSig)
            Coord->>Escrow: slashCollateral(attestation, slashSig)
            Coord->>Hook: markSuccessSlashed(closeJobId)
            Note over Hook: sidecarState = SuccessSlashed
        end
    else no client dispute before deadline
        Note over Client,Coord: release stays eligible once dispute window has closed
    end

    Note over Provider,Coord: after unlockAt and after any required dispute-window close
    Provider->>Coord: releaseCollateral(closeJobId)
    Coord->>Escrow: releaseCollateralAndForward()
    Escrow->>Collateral: releaseCollateral(settlementJobId)
    Escrow-->>Provider: forward released collateral balance
    Coord->>Hook: markSuccessSettled(closeJobId)
    Note over Hook: sidecarState = SuccessSettled
```

## Sidecar State Model

`MCUTypes.SidecarState` tracks the MCU-specific phase for each job independently
from ACP's core job status:

- `Committed`: MCU profile stored at `setBudget()`
- `FeeEscrowed`: ACP service fee funded, sidecar not yet activated
- `Protected`: collateral locked and principal deployed if configured
- `AwaitingClose`: open leg completed; principal deployment accepted and the
  parent leg can now admit a hook-linked two-stage close job
- `EvidenceSubmitted`: evidence bundle accepted after protection
- `SuccessPendingConfirmation`: a single-stage or two-stage close job completed,
  and the provider has not yet requested collateral release
- `SuccessDisputeOpen`: the provider requested collateral release, the client
  opened a dispute during the settlement window, and the underwriter has not yet
  resolved it
- `SuccessPendingCollateralRelease`: the provider requested collateral release, or the
  dispute resolved in favor of release, and the job is waiting for `unlockAt`
  plus any required dispute-window close
- `SuccessSettled`: collateral released to the provider after `unlockAt` and
  the dispute window have both passed
- `SuccessSlashed`: the close-stage dispute resolved against the provider and
  the collateral slash was applied
- `RejectPendingSlash`: ACP rejected after protection, reject-side settlement
  still outstanding
- `RejectSettled`: reject-side cleanup completed via
  `MCUCoordinator.finalizeRejectedJob()`; for two-stage close legs, the active
  parent/close linkage is cleared so a replacement close job can be committed
- `ExpiryPendingTimeout`: ACP expired, timeout-side settlement still
  outstanding
- `ExpirySettled`: expiry-side cleanup completed via
  `MCUCoordinator.settleExpiry()`; for two-stage close legs, the active
  parent/close linkage is cleared so a replacement close job can be committed

This keeps ACP status and MCU status separate: ACP says whether the job is open,
funded, submitted, completed, rejected, or expired, while the MCU sidecar state
tracks whether underwriting settlement work is still outstanding. For two-stage
flows, the open leg parks in `AwaitingClose`, while the close leg is the only
leg that can advance into the final collateral release/slash states. In a
single-stage flow, the same job advances directly into the final confirmation,
release, or slash states without ever touching `AwaitingClose`.

## Why the Coordinator Exists

The coordinator is the key architectural choice in this module.

Instead of performing all side effects inside ACP hook callbacks, the hook is
kept focused on validation and state commitments, while the coordinator handles
the expensive or sidecar-specific steps explicitly. This has a few benefits:

- it avoids heavy external calls inside hook callbacks
- it makes the funding and settlement steps easier to test directly
- it keeps timeout handling compatible with ACP's non-hookable `claimRefund()`
- it isolates `CollateralManager`-specific assumptions behind the escrow

This is especially useful while the sidecar surface is still evolving.

## Current Status

This module is currently a prototype and should be treated as experimental.

- The escrow's token movement and `CollateralManager` plumbing are wired.
- The success path now includes a provider-initiated collateral release request,
  a client dispute window, and an underwriter-signed success dispute lane that
  can release or slash the provider collateral.
- `MCUCoordinator.orchestrateFunding()` has lean integration coverage with mock
  ACP and hook dependencies.
- The module builds cleanly with `forge build --contracts contracts/mcu`.
- The focused MCU tests pass with `forge test --match-path "test/mcu/*.t.sol" --contracts contracts/mcu`.

Some parts are still intentionally lightweight:

- broader end-to-end ACP integration is not fully covered yet
- reject, expiry, and slash settlement semantics still depend on the final
  `CollateralManager` rules
- the module currently favors clarity and separable responsibilities over full
  atomic settlement

In terms of `hook-profiles.md`, this implementation is closest to an
experimental Profile C hook system today, with a path toward a cleaner advanced
settlement profile as the sidecar surface hardens.

## Notes for Integrators

- Use `AgenticCommerceHooked`, not the plain `AgenticCommerce` contract, when
  integrating this module.
- In this README, use `client` consistently for the end-user identity.
- In this README, use `provider` consistently for the counterparty that posts
  collateral.
- `MCUHookLite` implements `IACPHook` directly rather than using
  `BaseACPHook`. This avoids coupling to helper logic while the MCU module is
  still stabilizing.
- Treat the ACP evaluator as the `UnderwriterEvaluator` contract, not the raw
  underwriter EOA.
- Set `MCUTypes.MCUCommit.deliveryConfirmationTimeoutWindow` to the maximum time
  the client has to dispute a provider release request before settlement may
  proceed without that dispute.
- `releaseCollateral()` remains permissionless finalization once the job has already
  satisfied the provider request, dispute-window, and `unlockAt` requirements.
- Keep ACP fee escrow and MCU settlement amounts separate in off-chain clients
  and UI flows.
