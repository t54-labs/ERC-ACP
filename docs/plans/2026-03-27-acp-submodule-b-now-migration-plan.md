# ACP Submodule Migration Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Converge `ERC-ACP` onto the submodule-backed ACP core used by `hook-contracts`, while preserving the underwriting settlement flow and optimizing for fast iteration by making only the most change-prone contracts upgradeable in the first pass.

**Architecture:** `ERC-ACP` will consume `@acp` from `contracts/acp`, move parent/close lineage fully into hook-owned state, and adopt per-job payment tokens at the ACP level. Underwriting settlement v1 remains explicitly USDC-only, enforced during the underwriting path rather than by ACP core. In phase `B`, ACP core, `UnderwritingHook`, and the canonical settlement `UnderwritingEvaluator` become upgradeable; the settlement coordinator, collateral manager, and per-settlement escrows remain direct-deployed to keep iteration fast.

**Tech Stack:** Foundry, ACP base-contracts submodule, OpenZeppelin, OpenZeppelin Upgradeable, Solidity aligned with upstream ACP core, Tenderly/shared-environment deployment scripts.

**Git note:** Do not create commits unless the user explicitly asks for them.

---

## Decision Summary

- ACP core should come from the `contracts/acp` submodule and be treated as the shared source of truth.
- Parent/close lineage should no longer live in ACP core; it should live entirely in underwriting hook state.
- ACP should support per-job payment tokens.
- Underwriting settlement v1 should support only USDC, enforced explicitly for protected underwriting jobs.
- The first migration pass should use upgradeability scope `B`:
  - Upgradeable now: ACP core, `contracts/hooks/underwriting/UnderwritingHook.sol`, `contracts/settlement/UnderwritingEvaluator.sol`
  - Direct-deployed for now: `contracts/settlement/UnderwritingSettlementCoordinator.sol`, `contracts/settlement/UnderwritingCollateralManager.sol`, `contracts/settlement/UnderwritingSettlementEscrow.sol`

## Scope

This migration is intended to:

- Replace the local ACP core copies with the `@acp` submodule dependency.
- Rebase the underwriting stack onto the newer ACP callback and job model.
- Preserve the settlement behavior already implemented in `ERC-ACP`.
- Keep development speed high by avoiding a full upgradeability conversion of settlement contracts in the first pass.

This migration is not intended to:

- Generalize underwriting settlement to arbitrary ERC20s in the first pass.
- Preserve ACP-level parent/close primitives as a public kernel responsibility.
- Introduce upgradeability into per-settlement escrows unless later evidence shows it is necessary.

## Target Runtime After Phase `B`

The canonical deployed stack after this migration should be:

1. ACP core proxy backed by `contracts/acp/contracts/AgenticCommerce.sol`
2. `UnderwritingHook` proxy
3. `contracts/settlement/UnderwritingEvaluator.sol` proxy
4. Direct-deployed `UnderwritingSettlementCoordinator`
5. Direct-deployed `UnderwritingCollateralManager`
6. Direct-deployed `UnderwritingSettlementEscrow` instances created per settlement flow

The canonical underwriting runtime rules should be:

- ACP itself may support arbitrary per-job tokens.
- Protected underwriting jobs must use USDC.
- Parent/close linkage exists only in `UnderwritingWorkflowCore`.
- The settlement stack uses hook-owned settlement identity via `jobSettlementJobId`.
- The shared-environment deploy flow must explicitly whitelist the hook inside ACP before hook-backed jobs can be created.

## Phase 1: Adopt The ACP Submodule

The first phase is dependency convergence, not behavior change.

- Add `contracts/acp` as a git submodule.
- Add the `@acp` remapping in `foundry.toml`.
- Add `@openzeppelin/contracts-upgradeable` support to the dependency graph and remappings.
- Align compiler settings with the upstream ACP core if needed so the repo can compile the imported ACP contracts cleanly.
- Keep local ACP files temporarily so the repo does not require a flag day during the middle of the port.

Exit criteria for this phase:

- The repo can compile a minimal contract that imports `@acp/AgenticCommerce.sol` and `@acp/IACPHook.sol`.
- CI or local Foundry builds no longer depend on the local ACP files for new migration work.

## Phase 2: Port The Hook Foundation

The second phase moves the underwriting stack onto the new ACP callback surface.

- Rebase `contracts/BaseACPHook.sol` onto the caller-aware, token-aware `IACPHook` callback encoding used by `@acp/AgenticCommerce.sol`.
- Port `contracts/hooks/underwriting/UnderwritingHook.sol` and `contracts/hooks/underwriting/UnderwritingWorkflowCore.sol` to use `@acp/AgenticCommerce.sol`.
- Preserve hook-owned state for:
  - parent/close lineage
  - `jobSettlementJobId`
  - `jobSubmittedAt`
- Remove dependence on legacy ACP core features such as:
  - `createOpenJob(...)`
  - `createCloseJob(...)`
  - `getJobKind(...)`
  - `getParentJobId(...)`
  - `getCloseJobId(...)`

Exit criteria for this phase:

- The underwriting hook compiles against `@acp/AgenticCommerce.sol`.
- Two-phase underwriting behavior is represented entirely in hook state.
- No production-path hook code imports `contracts/AgenticCommerce.sol` or `contracts/AgenticCommerceHooked.sol`.

## Phase 3: Enforce USDC-Only Underwriting Settlement

This is the speed-optimized compromise for v1.

- ACP remains per-job-token capable.
- Plain ACP jobs can continue to use whatever token the upstream core permits.
- Protected underwriting jobs must use USDC.

Enforcement should be layered:

1. Primary enforcement in the underwriting hook or workflow core during `setBudget(...)`
2. Defensive enforcement in the settlement coordinator before escrow creation or settlement orchestration

This phase should introduce an explicit configured payment token for protected underwriting flows rather than relying on an implied assumption.

Exit criteria for this phase:

- Underwritten non-USDC jobs fail before they can enter the protected settlement path.
- Plain ACP non-USDC jobs remain allowed outside underwriting.
- Settlement contracts never discover unsupported tokens late in the lifecycle.

## Phase 4: Make `UnderwritingHook` Upgradeable

This phase follows the tightened checklist ordering: upgrade the hook only after its
behavior is already correct, and defer the canonical settlement evaluator proxy work
 until after the settlement boundary is frozen.

Implementation requirements:

- Convert `contracts/hooks/underwriting/UnderwritingHook.sol` to `Initializable` + `UUPSUpgradeable`.
- Replace constructor/immutables with initializer-set storage.
- Call `_disableInitializers()` in the implementation constructor.
- Use explicit admin/upgrader access control.
- Preserve append-only storage layout with a gap.
- Keep the current underwriting behavior unchanged while moving the hook behind a proxy.

Exit criteria for this phase:

- `UnderwritingHook` can be deployed behind a proxy in focused local tests.
- Initialization can occur exactly once.
- Upgrade authorization is explicit and test-covered.
- The hook preserves the Phase 3 underwriting semantics when called through the proxy.

## Phase 5: Adapt The Settlement Boundary Interfaces And Mocks

The fifth phase freezes the settlement-facing ABI before the canonical settlement
 evaluator itself becomes upgradeable.

- Rewrite `contracts/interfaces/IAgenticCommerceKernel.sol` to the minimum surface actually required after the migration.
- Update settlement mocks to use the upstream ACP job tuple layout exactly.
- Ensure settlement tests consume `job.paymentToken` from job state rather than a kernel-global token assumption.
- Preserve the hook view surface needed by settlement contracts without reintroducing removed ACP core primitives.

Exit criteria for this phase:

- Settlement-facing contracts and tests compile against a single kernel ABI.
- Local mocks decode `getJob(...)` exactly like upstream ACP.
- No settlement-facing code depends on removed ACP core lineage helpers.

## Phase 6: Make The Canonical Settlement `UnderwritingEvaluator` Upgradeable

Once the settlement boundary is stable, convert the canonical evaluator.

- Convert `contracts/settlement/UnderwritingEvaluator.sol` to `Initializable` + `UUPSUpgradeable`.
- Replace constructor/immutables with initializer storage.
- Preserve client confirmation window behavior and the migrated hook/kernel interfaces.
- Keep the lighter hook-side evaluator explicitly non-canonical.

Exit criteria for this phase:

- The canonical settlement evaluator can be deployed behind a proxy in focused tests.
- Initialization and upgrade authorization are explicit and test-covered.
- `completeBySig(...)`, `rejectBySig(...)`, and `confirmByClient(...)` continue to work against the migrated hook.

## Phase 7: Adapt The Settlement Coordinator And Defensive USDC Check

Only after the kernel ABI and canonical evaluator are stable should the coordinator
 be treated as the next migration gate.

- Keep `contracts/settlement/UnderwritingSettlementCoordinator.sol` direct-deployed in phase `B`.
- Read the payment token from `job.paymentToken`.
- Keep the defensive USDC-only assertion for protected underwriting settlement.
- Preserve current timeout, recovery, dispute, slash, and settlement-identity behavior.
- Keep `UnderwritingCollateralManager` and `UnderwritingSettlementEscrow` direct-deployed.

Exit criteria for this phase:

- Settlement coordination works against the migrated hook and canonical evaluator.
- Non-USDC protected jobs fail before settlement orchestration.
- Root-leg and close-leg settlement behavior remain intact.

## Phase 8: Rewrite Deployment And Smoke Tests

The deployment script becomes mixed-mode only after the contract boundaries are individually stable.

- Proxy deploy ACP.
- Proxy deploy `UnderwritingHook`.
- Proxy deploy canonical settlement `UnderwritingEvaluator`.
- Direct deploy `UnderwritingSettlementCoordinator`.
- Direct deploy `UnderwritingCollateralManager`.
- Create direct escrows per settlement.

The deploy flow must also:

- initialize ACP
- initialize hook and evaluator
- whitelist the hook in ACP
- wire hook to the canonical evaluator and settlement coordinator
- pass USDC explicitly to the settlement-side contracts

Tests should be reorganized so they reflect the new architecture:

- ACP reference behavior tests should validate the upstream ACP integration points
- Hook tests should validate parent/close lineage in hook state
- Settlement tests should validate protected USDC underwriting flows
- Deployment smoke tests should validate proxy initialization and wiring

Exit criteria for this phase:

- Shared-environment deployment works end-to-end using the new stack.
- Deployment smoke tests prove proxy initialization and wiring.
- The canonical runtime can be brought up from one script without manual fixups.

## Phase 9: Rewrite Or Retire Legacy Tests And Examples

By this point the runtime should be stable enough to remove or rebase tests that still
 describe the deleted architecture rather than the migrated one.

- Rebase or retire tests that still assume direct `AgenticCommerceHooked` instantiation in the underwriting runtime path.
- Rebase hook tests onto hook-owned lineage rather than ACP-core lineage.
- Rebase settlement tests onto the canonical evaluator and migrated kernel ABI.
- Port or retire example helpers depending on whether they remain useful after the migration.

Exit criteria for this phase:

- The test suite asserts the new architecture, not the deleted one.
- Legacy examples no longer block migration decisions.

## Phase 10: Remove Legacy ACP Copies And Stale Runtime Paths

After parity is proven, delete or archive:

- `contracts/AgenticCommerce.sol`
- `contracts/AgenticCommerceHooked.sol`
- local ACP interface duplicates such as `contracts/IACPHook.sol`
- any lightweight legacy underwriting coordinator/evaluator paths that are no longer part of the canonical deployment

The repo should finish in a state where:

- new ACP work always imports `@acp/...`
- underwriting settlement docs describe the mixed upgradeability model clearly
- local ACP copies are not a second source of truth

## Path To `C` Later

This plan intentionally leaves a short path to full long-lived-contract upgradeability once settlement semantics stabilize.

The likely next-step contracts for a later `C` migration are:

- `contracts/settlement/UnderwritingSettlementCoordinator.sol`
- `contracts/settlement/UnderwritingCollateralManager.sol`

The likely contract that should remain non-upgradeable unless proven otherwise is:

- `contracts/settlement/UnderwritingSettlementEscrow.sol`

To keep the path to `C` short:

- keep constructor signatures close to future initializer signatures
- avoid unnecessary deployment indirection in scripts
- keep the settlement interfaces stable now, even while the implementations remain direct-deployed

## Success Criteria

This migration should be considered complete for phase `B` when all of the following are true:

- The repo consumes ACP core through `contracts/acp` and `@acp`.
- Parent/close lineage is implemented in hook state, not ACP core.
- Protected underwriting jobs are explicitly USDC-only.
- ACP, `UnderwritingHook`, and the canonical settlement `UnderwritingEvaluator` are proxy-deployable and verified.
- Settlement behavior remains functionally intact for the shared-environment use case.
- Local ACP copies are removed or clearly marked as non-canonical.
