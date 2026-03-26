# ERC-ACP

**Agentic Commerce** — job escrow with evaluator attestation for trustless agent-to-agent commerce.

## Contents

- **[ERC-agentic-commerce.md](./ERC-agentic-commerce.md)** — Specification: Open → Funded → Submitted → Completed | Rejected | Expired; only the evaluator can complete a job.
- **contracts/** — Reference implementations for the ACP core, canonical underwriting hook integration, and settlement-side economic modules. See [contracts/README.md](./contracts/README.md).

## Quick start

1. Read the spec: [ERC-agentic-commerce.md](./ERC-agentic-commerce.md).
2. Use or extend the reference implementation: [contracts/AgenticCommerce.sol](./contracts/AgenticCommerce.sol).
3. For underwriting workflows, treat `contracts/hooks/underwriting/` as the workflow authority and `contracts/settlement/` as the premium/collateral/principal/dispute layer.

## License

MIT. Copyright (c) 2026 Virtuals Protocol.
