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

### Prepare a Tenderly operator shell

Export the required secrets and operator inputs, then source the setup helper:

```bash
export TENDERLY_ACCESS_KEY=<tenderly-access-key>
export DEPLOYER_PRIVATE_KEY=<deployer-private-key>
export UNDERWRITER_PRIVATE_KEY=<underwriter-private-key>
export CLIENT_PRIVATE_KEY=<client-private-key>
export PROVIDER_PRIVATE_KEY=<provider-private-key>
export BASE_USDC=<usdc-address>
export ACP_TREASURY=<treasury-address>
export PREMIUM_RECIPIENT=<premium-recipient-address>
export RECOVERY_RECIPIENT=<recovery-recipient-address>
export MERCHANT_EXECUTION_WALLET=<merchant-execution-wallet>

source script/tenderly_shared_env_setup.sh
```

The helper:

- defaults the Tenderly RPC, WSS, verifier URL, and `CLIENT_CONFIRMATION_WINDOW`
- derives and exports `DEPLOYER_ADDRESS`, `UNDERWRITER_ADDRESS`, `CLIENT_ADDRESS`, and `PROVIDER_ADDRESS`
- prints the deployment success criteria before you broadcast anything
- provides `tenderly_use_actor_key <deployer|underwriter|client|provider>` so the script-facing `PRIVATE_KEY` is always switched explicitly before each `forge script` invocation

### Deploy the full stack

```bash
tenderly_use_actor_key deployer

forge script script/DeployUnderwritingSharedEnv.s.sol:DeployUnderwritingSharedEnv \
  --rpc-url $TENDERLY_VIRTUAL_TESTNET_RPC --broadcast
```

### Register an underwriter

```bash
export UNDERWRITING_HOOK=<hook-address>
tenderly_use_actor_key deployer

forge script script/RegisterUnderwriter.s.sol:RegisterUnderwriter \
  --rpc-url $TENDERLY_VIRTUAL_TESTNET_RPC --broadcast
```

### Configure underwriter recipients

Called by the underwriter themselves to set premium and recovery addresses:

```bash
export COLLATERAL_MANAGER=<manager-address>
tenderly_use_actor_key underwriter

forge script script/ConfigureUnderwriterRecipients.s.sol:ConfigureUnderwriterRecipients \
  --rpc-url $TENDERLY_VIRTUAL_TESTNET_RPC --broadcast
```

### Redeploying safely

The deploy script creates fresh instances every run. To redeploy, re-run the deploy script and update all downstream references (hook address in job creation, underwriter registration, recipient configuration) to point at the new addresses logged by the script.

## License

MIT. Copyright (c) 2026 Virtuals Protocol.
