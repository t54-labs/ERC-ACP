# Underwriting Settlement Layer

The underwriting migration splits responsibilities across two layers:

- `hooks/underwriting/` is the workflow authority. It admits commits, gates fund/submit transitions, checks evidence, and preserves parent/close job linkage.
- `settlement/UnderwritingSettlementCoordinator.sol` owns premium, collateral, principal, expiry, and dispute orchestration.
- `settlement/UnderwritingEvaluator.sol` keeps canonical complete/reject timing with client confirmation windows.
- `settlement/UnderwritingSettlementEscrow.sol` is the token-moving adapter created on demand when funding is orchestrated.

## Typical Flow

1. Deploy `UnderwritingHook`, `UnderwritingSettlementCoordinator`, and `UnderwritingEvaluator`.
2. Wire the hook to the evaluator and coordinator once via `setWiring(...)`.
3. Create an ACP job with `hook = UnderwritingHook` and `evaluator = UnderwritingEvaluator`.
4. Commit underwriting terms during `setBudget(...)`.
5. Fund the ACP job, then call `orchestrateFunding(...)` with the matching `UnderwritePermit`.
6. Submit evidence through ACP.
7. Finalize with the evaluator's underwriter signature path.

## Collateral Routing

| Outcome | Collateral destination | Coordinator method |
|---------|------------------------|--------------------|
| **Success** (provider completes) | Returned to provider via escrow | `releaseCollateral()` |
| **Timeout** (job expires) | Sent to underwriter's recovery recipient | `settleExpiry()` |
| **Reject** (underwriter rejects) | Sent to underwriter's recovery recipient | `finalizeRejectedJob()` |
| **Slash** (post-success dispute) | Sent to underwriter's recovery recipient | `applySuccessDisputeSlash()` |

Both timeout and reject paths route through `claimTimeout()` on the collateral manager, which sends locked collateral to the underwriter's configured `recoveryRecipient`. The slash path routes through `slash()` on the collateral manager via the escrow's `slashCollateral()`, sending the slashed portion to the recovery recipient and any remainder back to the provider.

## Deployment

Use `script/DeployUnderwritingSharedEnv.s.sol` to deploy all five contracts and wire them in a single transaction. After deployment:

1. **Register underwriters** via `script/RegisterUnderwriter.s.sol` (hook admin only).
2. **Configure recipients** via `script/ConfigureUnderwriterRecipients.s.sol` (called by the underwriter).

Required environment variables for deployment:

| Variable | Description |
|----------|-------------|
| `PRIVATE_KEY` | Deployer private key (becomes hook admin) |
| `BASE_USDC` | USDC token address |
| `ACP_TREASURY` | Platform fee treasury |
| `CLIENT_CONFIRMATION_WINDOW` | Seconds the client may confirm before underwriter takes over |

The dispute window (`disputeWindowSeconds`) is set to 0 in the deploy script for shared-env iteration. To change it, modify the script before running.

## Boundary Rules

- Keep workflow legitimacy in the hook.
- Keep economic state and dispute execution in settlement contracts.
- Keep `claimRefund()` outside the hook surface.
- Linked close jobs reuse the parent settlement identity and escrow. Because `orchestrateFunding(...)` does not create a fresh settlement position for that close leg, the close job's `jobSettlementState` intentionally remains `SettlementState.None` until a settlement-side action is taken against the shared position.
