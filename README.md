# ERC-ACP

**Agentic Commerce** — job escrow with evaluator attestation for trustless agent-to-agent commerce.

## Contents

- **[ERC-agentic-commerce.md](./ERC-agentic-commerce.md)** — Specification: Open → Funded → Submitted → Completed | Rejected | Expired; only the evaluator can complete a job.
- **contracts/** — Reference implementations for the ACP migration, canonical underwriting hook integration, and settlement-side economic modules. See [contracts/README.md](./contracts/README.md).
- **[backend/underwriting_query_api/README.md](./backend/underwriting_query_api/README.md)** — Operator guide for the underwriting query backend, Postgres materialization flow, sync worker, and dispute gateway APIs.

## Quick start

1. Read the spec: [ERC-agentic-commerce.md](./ERC-agentic-commerce.md).
2. Bootstrap dependencies from a fresh checkout: `./script/bootstrap-foundry-deps.sh`.
3. For new ACP core work, use the canonical submodule-backed source in `contracts/acp/contracts/` via `@acp/...` imports.
4. For underwriting workflows, treat `contracts/hooks/underwriting/` as the workflow authority and `contracts/settlement/` as the premium/collateral/principal/dispute layer.
5. Protected underwriting in the canonical shared-environment path is currently USDC-only via `UnderwritingHook.setAllowedSettlementToken(...)`.

## Shared-Environment Deployment

Foundry scripts in `script/` deploy and operate the underwriting stack on a shared Tenderly Base virtual testnet.

### Prepare a Tenderly operator shell

Copy the example env file, fill in the real operator inputs, then load it into
the current shell:

```bash
cp script/tenderly-shared-env.env.example .env.tenderly.shared
$EDITOR .env.tenderly.shared
source script/load-tenderly-shared-env.sh .env.tenderly.shared
```

The loader:

- validates the full Task 1 input set, including Tenderly RPC/WSS and all four actor keys
- derives and exports `DEPLOYER_ADDRESS`, `UNDERWRITER_ADDRESS`, `CLIENT_ADDRESS`, and `PROVIDER_ADDRESS`
- prints the deployment success criteria before you broadcast anything
- provides `use_actor_key <deployer|underwriter|client|provider>` so the script-facing `PRIVATE_KEY` is always switched explicitly before each `forge script` invocation

### Deploy the full stack

```bash
use_actor_key deployer

forge script script/DeployUnderwritingSharedEnv.s.sol:DeployUnderwritingSharedEnv \
  --rpc-url $TENDERLY_VIRTUAL_TESTNET_RPC --broadcast
```

### Register an underwriter

```bash
export UNDERWRITING_HOOK=<hook-address>
use_actor_key deployer

forge script script/RegisterUnderwriter.s.sol:RegisterUnderwriter \
  --rpc-url $TENDERLY_VIRTUAL_TESTNET_RPC --broadcast
```

### Configure underwriter recipients

Called by the underwriter themselves to set premium and recovery addresses:

```bash
export COLLATERAL_MANAGER=<manager-address>
use_actor_key underwriter

forge script script/ConfigureUnderwriterRecipients.s.sol:ConfigureUnderwriterRecipients \
  --rpc-url $TENDERLY_VIRTUAL_TESTNET_RPC --broadcast
```

### Redeploying safely

The deploy script creates fresh instances every run. To redeploy, re-run the deploy script and update all downstream references (hook address in job creation, underwriter registration, recipient configuration) to point at the new addresses logged by the script.

## License

MIT. Copyright (c) 2026 Virtuals Protocol.
