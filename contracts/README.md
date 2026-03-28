# ACP Contract Layout

| Doc | Contract | Description |
|-----|----------|-------------|
| [ERC-agentic-commerce](../ERC-agentic-commerce.md) | **acp/contracts/AgenticCommerce.sol** via `@acp/...` | Canonical ACP core for new work. The local `AgenticCommerce.sol` and `AgenticCommerceHooked.sol` files remain temporary migration references until the legacy cleanup phase lands. |
| [Underwriting Settlement Layer](./settlement/README.md) | **hooks/underwriting/UnderwritingHook.sol**, **settlement/** | Canonical underwriting runtime. The lightweight hook-side `hooks/underwriting/UnderwritingCoordinator.sol`, `hooks/underwriting/UnderwritingEvaluator.sol`, and `examples/UnderwritingHookSystemExample.sol` remain legacy migration helpers and are not part of the production deployment target. |

## Deployment Scripts

Foundry scripts in `../script/` automate shared-environment deployment and operator setup. See the [top-level README](../README.md#shared-environment-deployment) for usage.

| Script | Purpose |
|--------|---------|
| `DeployUnderwritingSharedEnv.s.sol` | Deploys and wires the full underwriting stack (ACP, hook, coordinator, evaluator, collateral manager). |
| `RegisterUnderwriter.s.sol` | Registers an underwriter on the deployed hook (admin only). |
| `ConfigureUnderwriterRecipients.s.sol` | Sets an underwriter's premium and recovery recipient addresses on the collateral manager. |

**Copyright (c) 2026 Virtuals Protocol.** Licensed under the MIT License.
