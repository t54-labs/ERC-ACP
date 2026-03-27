# ACP Reference Implementations

| Doc | Contract | Description |
|-----|----------|-------------|
| [ERC-agentic-commerce](../ERC-agentic-commerce.md) | **AgenticCommerce.sol**, **AgenticCommerceHooked.sol** | Agentic Commerce protocol: minimal core plus hookable variant for Open → Funded → Submitted → Completed \| Rejected \| Expired jobs. |
| [Underwriting Settlement Layer](./settlement/README.md) | **hooks/underwriting/**, **settlement/**, **examples/UnderwritingHookSystemExample.sol** | Canonical underwriting hook integration where the hook owns workflow admission/evidence rules and the settlement layer owns premium, collateral, principal, expiry, and disputes. |

## Deployment Scripts

Foundry scripts in `../script/` automate shared-environment deployment and operator setup. See the [top-level README](../README.md#shared-environment-deployment) for usage.

| Script | Purpose |
|--------|---------|
| `DeployUnderwritingSharedEnv.s.sol` | Deploys and wires the full underwriting stack (ACP, hook, coordinator, evaluator, collateral manager). |
| `RegisterUnderwriter.s.sol` | Registers an underwriter on the deployed hook (admin only). |
| `ConfigureUnderwriterRecipients.s.sol` | Sets an underwriter's premium and recovery recipient addresses on the collateral manager. |

**Copyright (c) 2026 Virtuals Protocol.** Licensed under the MIT License.
