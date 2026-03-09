# MCU Hook System

This directory contains an experimental ACP-compatible hook profile for Merchant
Custody Underwriting (MCU).

The design keeps `AgenticCommerceHooked` as the standard job kernel and moves
MCU-specific policy, bond, principal, and underwriting flows into a separate
module. The goal is to preserve ACP's small, predictable escrow lifecycle while
still supporting bond-backed merchant execution and underwriter-signed
finalization.

## Design Summary

The MCU module follows a "light hook + explicit coordinator" model:

- ACP core escrows only the provider service fee.
- `MCUHookLite` stores MCU configuration and gates ACP transitions.
- `MCUCoordinator` performs the heavy sidecar steps after ACP transitions.
- `MCUJobAdapter` bridges caller-shape assumptions when interacting with
  `BondManager`.
- `UnderwriterEvaluator` verifies underwriter signatures and acts as the ACP
  evaluator contract, including post-timeout success dispute decisions.

This split intentionally avoids packing every bond and principal side effect
into ACP hook callbacks. That keeps the hook smaller, fits better with
`AgenticCommerceHooked`'s gas-limited callback model, and leaves `claimRefund()`
outside the hook surface as intended by ACP.

## Module Layout

| File | Responsibility |
|------|----------------|
| `IAgenticCommerceKernel.sol` | Local interface for the hookable ACP kernel used by this module. |
| `IBondManager.sol` | Sidecar settlement interface for bond, principal, timeout, and slash flows. |
| `MCUTypes.sol` | Shared enums and payload structs used across the MCU contracts, including success-dispute decisions. |
| `MCUHookLite.sol` | Policy hook that commits profile metadata, gates ACP actions, and tracks MCU sidecar state and delivery-confirmation deadlines. |
| `MCUCoordinator.sol` | Explicit orchestrator for funding, delivery confirmation, post-timeout success disputes, bond release, timeout handling, and reject cleanup. |
| `MCUJobAdapter.sol` | Per-job adapter that pulls funds and presents the sender shape expected by `BondManager`. |
| `UnderwriterEvaluator.sol` | Contract evaluator that verifies underwriter EIP-712 decisions for ACP `complete()` / `reject()` and success-dispute resolution. |

## How It Fits ACP

ACP remains the job rail:

- `createJob()` creates the job and stores the optional hook.
- `setBudget()` commits the MCU profile.
- `fund()` escrows the provider fee in ACP.
- `submit()` records the evidence bundle for evaluator review.
- `complete()` / `reject()` are still evaluator-driven terminal decisions.
- `claimRefund()` remains non-hookable and refunds only the ACP escrow.

The MCU module handles the non-core settlement legs:

- underwriting premium
- merchant bond
- funded principal release
- delivery mirroring into `BondManager`
- delivery-confirmation timeout escalation
- bond release, slash, timeout settlement, and reject cleanup

This boundary is important: the ACP budget should represent the provider service
fee, not a merged bucket for premium, principal, bond, and compensation.

## Expected Job Flow

A typical MCU-backed job is expected to follow this sequence:

1. `createJob(provider, evaluator = UnderwriterEvaluator, expiredAt, description, hook = MCUHookLite)`
2. `setBudget(jobId, serviceFee, abi.encode(MCUTypes.MCUCommit))`
3. `fund(jobId, serviceFee, optParams)`
4. `MCUCoordinator.orchestrateFunding(jobId, permit, permitSig)`
5. `submit(jobId, bundleHash, abi.encode(MCUTypes.SubmitEvidence))`
6. `UnderwriterEvaluator.completeBySig(...)` or `UnderwriterEvaluator.rejectBySig(...)`
7. Success path:
   - client confirms delivery via `MCUCoordinator.confirmDelivery(...)`
   - or, after the delivery-confirmation timeout expires, the merchant opens a
     dispute via `MCUCoordinator.openSuccessDispute(...)`
   - the underwriter resolves that dispute via
     `UnderwriterEvaluator.resolveSuccessDisputeBySig(...)`
   - release outcome: `MCUCoordinator.releaseBond(...)`
   - slash outcome: coordinator applies a bond slash and the job settles in
     `SuccessSlashed`
8. Failure / expiry path:
   - reject cleanup via `MCUCoordinator.finalizeRejectedJob(...)`
   - or timeout cleanup via `MCUCoordinator.settleExpiry(...)`

## Sequence Diagram

The following sequence shows the full ACP core + MCU sidecar flow, including the
hook callbacks, coordinator orchestration, adapter plumbing, and the
underwriter-signed terminal decision:

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    actor Underwriter
    participant ACP as AgenticCommerceHooked
    participant Hook as MCUHookLite
    participant Coord as MCUCoordinator
    participant Adapter as MCUJobAdapter
    participant Bond as BondManager
    participant Eval as UnderwriterEvaluator

    Client->>ACP: createJob(provider, evaluator=Eval, hook=Hook)
    Client->>ACP: setBudget(jobId, serviceFee, abi.encode(MCUCommit))
    ACP->>Hook: beforeAction(jobId, setBudget, data)
    Hook-->>ACP: validate wiring, provider, evaluator, and commit
    Note over Hook: store MCU profile and memoId
    Note over Hook: sidecarState = Committed

    Client->>ACP: fund(jobId, serviceFee, optParams)
    ACP->>Hook: beforeAction(jobId, fund, data)
    Hook-->>ACP: require sidecarState = Committed
    ACP->>ACP: escrow provider fee and mark job Funded
    ACP->>Hook: afterAction(jobId, fund, data)
    Note over Hook: sidecarState = FeeEscrowed

    alt job expires before coordinator funding
        Note over ACP: claimRefund() stays outside the hook surface
        Client->>ACP: claimRefund(jobId)
        ACP->>ACP: refund ACP fee escrow only and mark job Expired
        Client->>Coord: settleExpiry(jobId)
        Coord->>Hook: markExpirySettled(jobId)
        Note over Hook: sidecarState = ExpirySettled

    else client activates the MCU sidecar
        Client->>Coord: orchestrateFunding(jobId, permit, permitSig)
        Coord->>ACP: getJob(jobId)
        Coord->>Hook: getCommit(jobId) + jobSidecarState(jobId)
        alt no adapter exists yet
            Coord->>Adapter: new MCUJobAdapter(paymentToken, Bond, controller)
            Coord->>Adapter: configure(jobId, client, provider, memoId, merchantWallet)
        else adapter already exists
            Coord->>Hook: jobAdapter(jobId)
        end
        Coord->>Adapter: pullBondFromProvider(requiredBondUsdc)
        Note over Adapter,Provider: adapter uses ERC20 transferFrom against prior allowance
        opt releasePrincipal == true
            Coord->>Adapter: pullPrincipalFromClient(fundedPrincipalUsdc)
            Note over Adapter,Client: adapter pulls principal before BondManager release
        end
        Coord->>Adapter: lockBond(permit, permitSig)
        Adapter->>Bond: lockBond(permit, permit.user, unlockAt, permitSig)
        opt releasePrincipal == true
            Coord->>Adapter: releasePrincipal(permit, permitSig)
            Adapter->>Bond: releasePrincipalToMerchant(permit, permitSig)
        end
        Coord->>Hook: markProtected(jobId, adapter)
        Note over Hook: sidecarState = Protected

        alt job expires after protection but before evaluator decision
            Note over ACP: claimRefund() stays outside the hook surface
            Client->>ACP: claimRefund(jobId)
            ACP->>ACP: refund ACP fee escrow only and mark job Expired

            Client->>Coord: settleExpiry(jobId)
            Coord->>Hook: markExpiryPendingTimeout(jobId)
            Coord->>Adapter: claimTimeout()
            Adapter->>Bond: claimTimeout(memoId)
            Coord->>Hook: markExpirySettled(jobId)
            Note over Hook: sidecarState = ExpirySettled

        else client submits evidence and evaluator decides
            Client->>ACP: submit(jobId, bundleHash, abi.encode(SubmitEvidence))
            ACP->>Hook: beforeAction(jobId, submit, data)
            Hook-->>ACP: require sidecarState = Protected
            ACP->>ACP: store deliverable and mark job Submitted
            ACP->>Hook: afterAction(jobId, submit, data)
            Note over Hook: verify evidence matches commit
            Note over Hook: sidecarState = EvidenceSubmitted

            alt underwriter approves completion
                Underwriter-->>Client: sign CompleteDecision
                Client->>Eval: completeBySig(decision, sig)
                Eval->>Hook: jobUnderwriter(jobId) + jobMemoId(jobId)
                Eval->>Eval: verify signer, memoId, deadline, and nonce
                Eval->>ACP: complete(jobId, reason, abi.encode(CompleteContext))
                ACP->>Hook: beforeAction(jobId, complete, data)
                Note over ACP,Hook: complete() beforeAction is pass-through
                ACP->>ACP: mark job Completed
                ACP->>Hook: afterAction(jobId, complete, data)
                Note over Hook: sidecarState = SuccessPendingConfirmation

                alt client confirms before delivery-confirmation timeout
                    Client->>Coord: confirmDelivery(jobId, deliveryNonce, deliverySig)
                    Coord->>Adapter: confirmDeliveryBySig(deliveryNonce, deliverySig)
                    Adapter->>Bond: confirmDeliveryBySig(memoId, deliveryNonce, deliverySig)
                    Coord->>Hook: markSuccessPendingBondRelease(jobId)
                    Note over Hook: sidecarState = SuccessPendingBondRelease

                    Note over Client,Coord: after unlockAt
                    Client->>Coord: releaseBond(jobId)
                    Coord->>Adapter: releaseBondAndForward()
                    Adapter->>Bond: releaseBond(memoId)
                    Adapter-->>Provider: forward released bond balance
                    Coord->>Hook: markSuccessSettled(jobId)
                    Note over Hook: sidecarState = SuccessSettled

                else merchant opens dispute after timeout
                    Provider->>Coord: openSuccessDispute(jobId, disputeHash)
                    Coord->>Hook: jobDeliveryConfirmationDeadline(jobId)
                    Coord->>Hook: markSuccessDisputeOpen(jobId, disputeHash)
                    Note over Hook: sidecarState = SuccessDisputeOpen

                    Underwriter-->>Provider: sign SuccessDisputeDecision
                    Provider->>Eval: resolveSuccessDisputeBySig(decision, attestation, slashSig, sig)
                    Eval->>Hook: jobUnderwriter(jobId) + jobMemoId(jobId) + jobSidecarState(jobId)
                    Eval->>Eval: verify signer, memoId, dispute hash, deadline, and nonce
                    Eval->>Coord: applySuccessDisputeDecision(decision, attestation, slashSig)

                    alt dispute outcome releases bond
                        Coord->>Hook: markSuccessPendingBondRelease(jobId)
                        Note over Hook: sidecarState = SuccessPendingBondRelease

                        Note over Provider,Coord: after unlockAt
                        Provider->>Coord: releaseBond(jobId)
                        Coord->>Adapter: releaseBondAndForward()
                        Adapter->>Bond: releaseBond(memoId)
                        Adapter-->>Provider: forward released bond balance
                        Coord->>Hook: markSuccessSettled(jobId)
                        Note over Hook: sidecarState = SuccessSettled

                    else dispute outcome slashes bond
                        Coord->>Adapter: slashBond(attestation, slashSig)
                        Adapter->>Bond: slash(attestation, slashSig)
                        Coord->>Hook: markSuccessSlashed(jobId, disputeHash, slashAttestationHash)
                        Note over Hook: sidecarState = SuccessSlashed
                    end
                end

            else underwriter rejects
                Underwriter-->>Client: sign RejectDecision
                Client->>Eval: rejectBySig(decision, sig)
                Eval->>Hook: jobUnderwriter(jobId) + jobMemoId(jobId)
                Eval->>Eval: verify signer, memoId, deadline, and nonce
                Eval->>ACP: reject(jobId, reason, abi.encode(RejectContext))
                ACP->>Hook: beforeAction(jobId, reject, data)
                Note over ACP,Hook: reject() beforeAction is pass-through
                ACP->>ACP: mark job Rejected
                ACP->>Hook: afterAction(jobId, reject, data)
                Note over Hook: sidecarState = RejectPendingSlash

                Client->>Coord: finalizeRejectedJob(jobId)
                Coord->>Adapter: sweepResidualToProvider()
                Adapter-->>Provider: return residual adapter balance
                Coord->>Hook: markRejectSettled(jobId)
                Note over Hook: sidecarState = RejectSettled
                Note over Hook: a pre-protection reject in other flows settles directly
            end
        end
    end
```

### Simplified Happy Path

This trimmed sequence shows only the straight-through success case: the client
confirms delivery before the confirmation timeout expires, no success dispute is
opened, and the merchant bond is released after `unlockAt`.

```mermaid
sequenceDiagram
    autonumber
    actor Client
    actor Provider
    actor Underwriter
    participant ACP as AgenticCommerceHooked
    participant Hook as MCUHookLite
    participant Coord as MCUCoordinator
    participant Adapter as MCUJobAdapter
    participant Bond as BondManager
    participant Eval as UnderwriterEvaluator

    Client->>ACP: createJob(provider, evaluator=Eval, hook=Hook)
    Client->>ACP: setBudget(jobId, serviceFee, abi.encode(MCUCommit))
    ACP->>Hook: beforeAction(jobId, setBudget, data)
    Note over Hook: sidecarState = Committed

    Client->>ACP: fund(jobId, serviceFee, optParams)
    ACP->>Hook: afterAction(jobId, fund, data)
    Note over Hook: sidecarState = FeeEscrowed

    Client->>Coord: orchestrateFunding(jobId, permit, permitSig)
    Coord->>Adapter: configure adapter and pull MCU funds
    Adapter->>Bond: lockBond(permit, client, unlockAt, permitSig)
    opt releasePrincipal == true
        Adapter->>Bond: releasePrincipalToMerchant(permit, permitSig)
    end
    Coord->>Hook: markProtected(jobId, adapter)
    Note over Hook: sidecarState = Protected

    Client->>ACP: submit(jobId, bundleHash, abi.encode(SubmitEvidence))
    ACP->>Hook: afterAction(jobId, submit, data)
    Note over Hook: sidecarState = EvidenceSubmitted

    Underwriter-->>Client: sign CompleteDecision
    Client->>Eval: completeBySig(decision, sig)
    Eval->>ACP: complete(jobId, reason, abi.encode(CompleteContext))
    ACP->>Hook: afterAction(jobId, complete, data)
    Note over Hook: sidecarState = SuccessPendingConfirmation

    Client->>Coord: confirmDelivery(jobId, deliveryNonce, deliverySig)
    Adapter->>Bond: confirmDeliveryBySig(memoId, deliveryNonce, deliverySig)
    Coord->>Hook: markSuccessPendingBondRelease(jobId)
    Note over Hook: sidecarState = SuccessPendingBondRelease

    Note over Client,Coord: after unlockAt
    Client->>Coord: releaseBond(jobId)
    Coord->>Adapter: releaseBondAndForward()
    Adapter->>Bond: releaseBond(memoId)
    Adapter-->>Provider: forward released bond balance
    Coord->>Hook: markSuccessSettled(jobId)
    Note over Hook: sidecarState = SuccessSettled
```

## Sidecar State Model

`MCUTypes.SidecarState` tracks the MCU-specific phase for each job independently
from ACP's core job status:

- `Committed`: MCU profile stored at `setBudget()`
- `FeeEscrowed`: ACP service fee funded, sidecar not yet activated
- `Protected`: bond locked and principal released if configured
- `EvidenceSubmitted`: evidence bundle accepted after protection
- `SuccessPendingConfirmation`: ACP completed, sidecar success still needs
  delivery confirmation or timeout-based merchant escalation
- `SuccessDisputeOpen`: the delivery-confirmation timeout has expired, the
  merchant opened a dispute, and the underwriter has not yet resolved it
- `SuccessPendingBondRelease`: delivery was confirmed or the dispute was
  resolved in favor of releasing the merchant bond, and the job is waiting for
  `unlockAt`
- `SuccessSlashed`: the post-timeout success dispute resolved against the
  merchant and the bond slash was applied
- `RejectPendingSlash`: ACP rejected after protection, reject-side settlement
  still outstanding
- `ExpiryPendingTimeout`: ACP expired, timeout-side settlement still
  outstanding

This keeps ACP status and MCU status separate: ACP says whether the job is open,
funded, submitted, completed, rejected, or expired, while the MCU sidecar state
tracks whether underwriting settlement work is still outstanding.

## Why the Coordinator Exists

The coordinator is the key architectural choice in this module.

Instead of performing all side effects inside ACP hook callbacks, the hook is
kept focused on validation and state commitments, while the coordinator handles
the expensive or sidecar-specific steps explicitly. This has a few benefits:

- it avoids heavy external calls inside hook callbacks
- it makes the funding and settlement steps easier to test directly
- it keeps timeout handling compatible with ACP's non-hookable `claimRefund()`
- it isolates `BondManager`-specific assumptions behind the adapter

This is especially useful while the sidecar surface is still evolving.

## Current Status

This module is currently a prototype and should be treated as experimental.

- The adapter's token movement and `BondManager` plumbing are wired.
- The success path now includes a delivery-confirmation timeout and an
  underwriter-signed success dispute lane that can release or slash the
  merchant bond.
- `MCUCoordinator.orchestrateFunding()` has lean integration coverage with mock
  ACP and hook dependencies.
- The module builds cleanly with `forge build --contracts contracts/mcu`.
- The focused MCU tests pass with `forge test --match-path "test/mcu/*.t.sol" --contracts contracts/mcu`.

Some parts are still intentionally lightweight:

- broader end-to-end ACP integration is not fully covered yet
- reject, expiry, and slash settlement semantics still depend on the final
  `BondManager` rules
- the module currently favors clarity and separable responsibilities over full
  atomic settlement

In terms of `hook-profiles.md`, this implementation is closest to an
experimental Profile C hook system today, with a path toward a cleaner advanced
settlement profile as the sidecar surface hardens.

## Notes for Integrators

- Use `AgenticCommerceHooked`, not the plain `AgenticCommerce` contract, when
  integrating this module.
- In this README, `client` and `user` refer to the same end-user identity.
- In MCU terminology, ACP `provider` is the merchant counterparty that posts
  the bond.
- `MCUHookLite` implements `IACPHook` directly rather than using
  `BaseACPHook`. This avoids coupling to helper logic while the MCU module is
  still stabilizing.
- Treat the ACP evaluator as the `UnderwriterEvaluator` contract, not the raw
  underwriter EOA.
- Set `MCUTypes.MCUCommit.deliveryConfirmationTimeoutWindow` to the maximum time
  the client has to confirm delivery before the merchant can open a success
  dispute.
- Keep ACP fee escrow and MCU settlement amounts separate in off-chain clients
  and UI flows.
