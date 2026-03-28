# ERC-ACP

**Agentic Commerce** — job escrow with evaluator attestation for trustless agent-to-agent commerce.

## Contents

- **[ERC-agentic-commerce.md](./ERC-agentic-commerce.md)** — Specification: Open → Funded → Submitted → Completed | Rejected | Expired; only the evaluator can complete a job.
- **contracts/** — Reference implementations for the ACP migration, canonical underwriting hook integration, and settlement-side economic modules. See [contracts/README.md](./contracts/README.md).

## Quick start

1. Read the spec: [ERC-agentic-commerce.md](./ERC-agentic-commerce.md).
2. Bootstrap dependencies from a fresh checkout: `./script/bootstrap-foundry-deps.sh`.
3. For new ACP core work, use the canonical submodule-backed source in `contracts/acp/contracts/` via `@acp/...` imports.
4. For underwriting workflows, treat `contracts/hooks/underwriting/` as the workflow authority and `contracts/settlement/` as the premium/collateral/principal/dispute layer.
5. Protected underwriting in the canonical shared-environment path is currently USDC-only via `UnderwritingHook.setAllowedSettlementToken(...)`.

## Shared-Environment Deployment

Foundry scripts in `script/` deploy and operate the underwriting stack on a shared Tenderly Base virtual testnet.

### Deploy the full stack

```bash
export PRIVATE_KEY=<deployer-pk>
export BASE_USDC=<usdc-address>
export ACP_TREASURY=<treasury-address>
export CLIENT_CONFIRMATION_WINDOW=3600  # seconds

forge script script/DeployUnderwritingSharedEnv.s.sol:DeployUnderwritingSharedEnv \
  --rpc-url $RPC_URL --broadcast
```

### Register an underwriter

```bash
export UNDERWRITING_HOOK=<hook-address>
export UNDERWRITER_ADDRESS=<underwriter-eoa>

forge script script/RegisterUnderwriter.s.sol:RegisterUnderwriter \
  --rpc-url $RPC_URL --broadcast
```

### Configure underwriter recipients

Called by the underwriter themselves to set premium and recovery addresses:

```bash
export COLLATERAL_MANAGER=<manager-address>
export PREMIUM_RECIPIENT=<premium-recipient>
export RECOVERY_RECIPIENT=<recovery-recipient>

forge script script/ConfigureUnderwriterRecipients.s.sol:ConfigureUnderwriterRecipients \
  --rpc-url $RPC_URL --broadcast
```

### Redeploying safely

The deploy script creates fresh instances every run. To redeploy, re-run the deploy script and update all downstream references (hook address in job creation, underwriter registration, recipient configuration) to point at the new addresses logged by the script.

## License

MIT. Copyright (c) 2026 Virtuals Protocol.
