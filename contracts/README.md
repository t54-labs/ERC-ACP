# ACP Contract Layout

| Doc | Contract | Description |
|-----|----------|-------------|
| [ERC-agentic-commerce](../ERC-agentic-commerce.md) | **acp/contracts/AgenticCommerce.sol** via `@acp/...` | Canonical ACP core for new work and the only ACP source of truth kept in this repo. |
| [Underwriting Settlement Layer](./settlement/README.md) | **hooks/underwriting/UnderwritingHook.sol**, **settlement/** | Canonical underwriting runtime. `examples/UnderwritingHookSystemExample.sol` remains a legacy helper for tests and local integrations, but the production deployment target is the hook plus settlement stack described in `settlement/README.md`. |

## Deployment Scripts

Foundry scripts in `../script/` automate shared-environment deployment and operator setup. See the [top-level README](../README.md#shared-environment-deployment) for usage.

| Script | Purpose |
|--------|---------|
| `DeployUnderwritingSharedEnv.s.sol` | Deploys and wires the full underwriting stack (ACP, hook, coordinator, evaluator, collateral manager). |
| `RegisterUnderwriter.s.sol` | Registers an underwriter on the deployed hook (admin only). |
| `ConfigureUnderwriterRecipients.s.sol` | Sets an underwriter's premium and recovery recipient addresses on the collateral manager. |

**Copyright (c) 2026 Virtuals Protocol.** Licensed under the MIT License.
