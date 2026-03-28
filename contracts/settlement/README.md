# Underwriting Settlement Layer

The underwriting migration splits responsibilities across two layers:

- `hooks/underwriting/` is the workflow authority. It admits commits, gates fund/submit transitions, checks evidence, and preserves parent/close job linkage.
- `settlement/UnderwritingSettlementCoordinator.sol` owns collateral release, expiry, reject, and post-success dispute orchestration.
- `settlement/UnderwritingEvaluator.sol` keeps canonical complete/reject timing with client confirmation windows.
- `settlement/UnderwritingCollateralManager.sol` owns underwriter payout/recovery routing, permit verification, premium collection, principal release, collateral lock/release, and slashing.
- `settlement/UnderwritingSettlementEscrow.sol` is the per-settlement token-moving adapter created on demand when funding is orchestrated.

The canonical runtime for the migration is:

1. `@acp/AgenticCommerce.sol`
2. `hooks/underwriting/UnderwritingHook.sol`
3. `settlement/UnderwritingEvaluator.sol`
4. `settlement/UnderwritingSettlementCoordinator.sol`
5. `settlement/UnderwritingCollateralManager.sol`
6. `settlement/UnderwritingSettlementEscrow.sol`

`examples/UnderwritingHookSystemExample.sol` remains a legacy migration helper for tests and local integrations only; it is not part of the canonical shared-environment deployment.

## Target Canonical Flow

This section describes the checked-in canonical runtime path. `script/DeployUnderwritingSharedEnv.s.sol` now deploys proxied `@acp/AgenticCommerce.sol`, whitelists `UnderwritingHook` inside ACP, pins the settlement token on the hook, and then wires the settlement-side components.

1. Deploy the long-lived canonical components: proxied `@acp/AgenticCommerce.sol`, `settlement/UnderwritingCollateralManager.sol`, `hooks/underwriting/UnderwritingHook.sol`, `settlement/UnderwritingSettlementCoordinator.sol`, and the settlement-side `settlement/UnderwritingEvaluator.sol`.
2. Whitelist `UnderwritingHook` in ACP and call `setAllowedSettlementToken(...)` before any protected underwriting jobs are created.
3. Wire the hook to the settlement-side evaluator and coordinator once via `setWiring(...)`.
4. Register underwriters via `registerUnderwriter(...)` and set their recipients via `setUnderwriterRecipients(...)`.
5. Create an ACP job with `hook = UnderwritingHook` and `evaluator = settlement/UnderwritingEvaluator.sol`.
6. Commit underwriting terms during `setBudget(...)`.
7. Fund the ACP job, then call `orchestrateFunding(...)` with the matching `UnderwritePermit`. Premium is paid immediately to the underwriter's `premiumRecipient`; collateral is locked in the collateral manager; funded principal is released to the merchant execution wallet.
8. Provider submits evidence through ACP before `expiredAt`.
9. Client confirms inside `clientConfirmationWindowSeconds`, or the underwriter adjudicates after the window with `completeBySig(...)` or `rejectBySig(...)`.

## Collateral Routing

| Outcome | Collateral destination | Coordinator method(s) |
|---------|------------------------|-----------------------|
| **Success** (no dispute) | Returned to provider via escrow | `requestCollateralRelease()` → `releaseCollateral()` |
| **Success** (dispute slash) | Sent to underwriter's recovery recipient | `requestCollateralRelease()` → `openSuccessDispute()` → `applySuccessDisputeSlash()` |
| **Timeout** (job expires) | Sent to underwriter's recovery recipient | `settleExpiry()` |
| **Reject** (underwriter rejects) | Sent to underwriter's recovery recipient | `finalizeRejectedJob()` |

### Success release path

After a job completes, collateral does not release automatically. The provider calls `requestCollateralRelease()` to signal intent (→ `SuccessPendingRelease`). If `unlockAt` is 0, `releaseCollateral()` can proceed immediately. If `unlockAt` is in the future, the client has until that timestamp to open a dispute.

### Post-success dispute path

The client calls `openSuccessDispute(jobId, reasonCode)` before `unlockAt` (→ `DisputeOpen`), blocking release. The underwriter then resolves the dispute by signing a `SlashAttestation` and calling `applySuccessDisputeSlash()` (→ `RecoverySettled`). The collateral manager sends the slashed portion to the underwriter's `recoveryRecipient` and any remainder back to the provider via the escrow.

### Timeout and reject paths

Reject settlements route through `claimTimeout()` on the collateral manager, which sends the full locked collateral to the underwriter's configured `recoveryRecipient`. Expiry settlements do the same for protected jobs with locked collateral, while close-job expiries and `FeeEscrowed` expiries may settle directly to `ExpirySettled` without a collateral-manager timeout claim.

## Settlement State Machine

```
orchestrateFunding  →  CollateralLocked / PrincipalReleased
                                 │
                    requestCollateralRelease
                                 │
                                 ▼
                        SuccessPendingRelease
                           │            │
            (past unlockAt) │            │ openSuccessDispute (before unlockAt)
                            │            │
                            ▼            ▼
                     SuccessSettled   DisputeOpen
                                         │
                          applySuccessDisputeSlash
                                         │
                                         ▼
                                   RecoverySettled
```

Close jobs start at `None` and share the parent's settlement identity and escrow.

## Deployment

Current checked-in deployment status:

- `script/DeployUnderwritingSharedEnv.s.sol` deploys the canonical proxied `@acp/AgenticCommerce.sol` runtime.
- The script whitelists `UnderwritingHook` in ACP and pins `allowedSettlementToken` before wiring the settlement-side evaluator and coordinator.

Use `script/DeployUnderwritingSharedEnv.s.sol` to deploy the canonical long-lived runtime and wire it in a single broadcast run. After deployment:

1. **Register underwriters** via `script/RegisterUnderwriter.s.sol` (hook admin only).
2. **Configure recipients** via `script/ConfigureUnderwriterRecipients.s.sol` (called by the underwriter).

Required environment variables for deployment:

| Variable | Description |
|----------|-------------|
| `PRIVATE_KEY` | Deployer private key (becomes hook admin) |
| `BASE_USDC` | USDC token address |
| `ACP_TREASURY` | Platform fee treasury |
| `CLIENT_CONFIRMATION_WINDOW` | Seconds the client may confirm before underwriter takes over |

The post-success dispute window is controlled per-job by the `unlockAt` field in the underwriting permit, not by a deploy-time parameter. When `unlockAt` is 0, collateral can be released immediately after `requestCollateralRelease()` with no dispute window.

## Boundary Rules

- Keep workflow legitimacy in the hook.
- Keep economic state and dispute execution in settlement contracts.
- Keep `claimRefund()` outside the hook surface.
- Linked close jobs reuse the parent settlement identity and escrow. Because `orchestrateFunding(...)` does not create a fresh settlement position for that close leg, the close job's `jobSettlementState` intentionally remains `SettlementState.None` until a settlement-side action is taken against the shared position.
