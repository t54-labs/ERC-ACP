# ACP Reference Implementations

| Doc | Contract | Description |
|-----|----------|-------------|
| [ERC-agentic-commerce](../ERC-agentic-commerce.md) | **AgenticCommerce.sol**, **AgenticCommerceHooked.sol** | Agentic Commerce protocol: minimal core plus hookable variant for Open → Funded → Submitted → Completed \| Rejected \| Expired jobs. |
| [Underwriting Settlement Layer](./settlement/README.md) | **hooks/underwriting/**, **settlement/**, **examples/UnderwritingHookSystemExample.sol** | Canonical underwriting hook integration where the hook owns workflow admission/evidence rules and the settlement layer owns premium, collateral, principal, expiry, and disputes. |

**Copyright (c) 2026 Virtuals Protocol.** Licensed under the MIT License.
