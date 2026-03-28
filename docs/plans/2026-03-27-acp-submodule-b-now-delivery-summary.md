# ACP Submodule Migration Delivery Summary

**Related docs:**
- `docs/plans/2026-03-27-acp-submodule-b-now-migration-plan.md`
- `docs/plans/2026-03-27-acp-submodule-b-now-implementation-checklist.md`

## Purpose

This document records what the ACP submodule migration changed, why the work was done,
and how the underwriting runtime looks before versus after the migration.

The main goal of the change set was to move `ERC-ACP` onto the submodule-backed ACP
core used by `hook-contracts`, while preserving the underwriting settlement behavior
already built in this repository and keeping the highest-churn pieces upgradeable for
fast iteration.

## What These Changes Were For

These changes were made to solve four concrete problems:

1. The repo had two ACP stories at once.
   - Local ACP copies still existed in-tree, while the target architecture was moving
     toward the shared ACP base-contracts source.

2. The underwriting runtime still depended on deleted or legacy ACP behavior.
   - Parent/close lineage and some tests still assumed `AgenticCommerceHooked` era
     behavior that no longer matched the canonical ACP model.

3. The deployment path was not aligned with the intended shared environment.
   - The repo needed one deployable stack that matched the canonical runtime shape,
     hook whitelist flow, and proxy initialization requirements.

4. The first-pass upgradeability boundary was not yet implemented.
   - ACP core, `UnderwritingHook`, and the canonical settlement `UnderwritingEvaluator`
     needed to become proxy-deployable, while the coordinator, collateral manager,
     and settlement escrows remained direct-deployed for speed.

## Before

Before this migration, the repo looked like this:

- ACP core existed as local checked-in contracts, including
  `contracts/AgenticCommerce.sol` and `contracts/AgenticCommerceHooked.sol`.
- Production-path and test-path code still mixed legacy ACP assumptions with the
  planned submodule-backed architecture.
- Some underwriting logic and tests relied on ACP-core lineage concepts instead of
  treating parent/close relationships as hook-owned state.
- The canonical runtime path was not clearly separated from lightweight legacy helper
  contracts such as the hook-side coordinator and evaluator.
- The deploy flow was not fully aligned with the shared-environment target stack or
  the proxy-based admin/wiring model.
- The repo did not yet have full regression coverage for the post-submit refund grace
  period and expired-close replacement behavior in the canonical runtime.

## After

After this migration, the repo now looks like this:

- ACP core comes from `contracts/acp` and is consumed through `@acp/...`.
- Local ACP runtime copies and stale legacy runtime paths have been removed from the
  production code path.
- Parent/close lineage lives in underwriting hook state rather than ACP core.
- ACP supports per-job payment tokens at the core level.
- Protected underwriting settlement is explicitly USDC-only in v1.
- The canonical phase-B deployed stack is:
  - ACP core proxy backed by `contracts/acp/contracts/AgenticCommerce.sol`
  - `UnderwritingHook` proxy
  - canonical `contracts/settlement/UnderwritingEvaluator.sol` proxy
  - direct-deployed `UnderwritingSettlementCoordinator`
  - direct-deployed `UnderwritingCollateralManager`
  - direct-deployed per-settlement `UnderwritingSettlementEscrow`
- The deploy script and smoke coverage are aligned to the real proxy/deployer path.
- Tests now assert the migrated architecture rather than the deleted
  `AgenticCommerceHooked` architecture.

## What Was Done

The delivered work can be grouped into ten areas.

### 1. Dependency And Build Convergence

- Added the ACP base-contracts submodule at `contracts/acp`.
- Added Foundry remappings for `@acp` and OpenZeppelin upgradeable contracts.
- Pinned bootstrap dependency installs so fresh environments are reproducible.
- Aligned build settings so the repo compiles cleanly against the upstream ACP core.

### 2. Canonical Runtime Path Freeze

- Marked the hook-side coordinator and hook-side evaluator as non-canonical during the
  migration instead of continuing to build new work on top of them.
- Updated documentation so the canonical runtime path is the `@acp` core plus the
  hook/settlement stack.

### 3. Hook Protocol Surface Migration

- Rebased `BaseACPHook` and the underwriting hook stack onto the upstream ACP callback
  shape and job model.
- Moved parent/close lineage responsibility fully into hook-owned state.
- Preserved settlement-facing hook view helpers needed by the canonical settlement
  path.

### 4. Underwriting Hook Upgradeability

- Converted `UnderwritingHook` to an initializer-based UUPS deployment model.
- Added explicit admin/upgrader controls.
- Added focused tests for initialization, authorization, proxy deployment, and state
  preservation across upgrades.

### 5. Settlement Boundary Alignment

- Updated the local kernel interface and mocks to match the upstream ACP `Job` layout.
- Switched settlement code to rely on `job.paymentToken` instead of legacy global token
  assumptions.

### 6. Canonical Evaluator Upgradeability

- Converted the canonical `contracts/settlement/UnderwritingEvaluator.sol` to UUPS.
- Preserved client confirmation window behavior and the migrated hook/kernel
  integration.
- Added focused upgradeability and decision-path tests.

### 7. Defensive Settlement Enforcement

- Kept underwriting settlement explicitly USDC-only in v1.
- Added defensive enforcement in the settlement path so unsupported protected jobs fail
  before escrow creation.
- Preserved plain ACP support for non-USDC budgets outside underwriting.

### 8. Deployment And Smoke Coverage Rewrite

- Reworked the shared-environment deployment script around proxy-backed ACP, hook, and
  evaluator deployment.
- Fixed deployer/admin initialization so script broadcasting sets the intended admin.
- Bound the smoke test to the real deploy script path rather than a mirrored local
  deployment sequence.

### 9. Legacy Test Retirement And Replacement Coverage

- Retired or rebased tests that only described the deleted `AgenticCommerceHooked`
  architecture.
- Added replacement regression coverage for:
  - expired close-job replacement after terminal failure
  - submitted-job refund grace-period behavior in canonical ACP
  - plain ACP non-USDC budgets outside underwriting

### 10. Legacy Runtime Cleanup

- Deleted local ACP runtime copies and duplicate interfaces once parity and migration
  coverage were in place.
- Removed the lightweight legacy coordinator/evaluator path from the checked-in
  runtime.
- Updated docs and examples so they point to the canonical ACP path and current test
  locations.

## Concrete Before/After Changes

### ACP source of truth

- Before: ACP behavior was split between local checked-in contracts and the intended
  submodule direction.
- After: production-path code imports `@acp/...`, and the checked-in local ACP copies
  are gone.

### Parent/close lineage

- Before: lineage assumptions still leaked into ACP-core-era behaviors and older tests.
- After: lineage is hook-owned state, and parity tests assert that directly.

### Payment token behavior

- Before: older underwriting paths assumed a more global token model.
- After: ACP is per-job-token capable, but protected underwriting settlement is pinned
  to USDC in v1 with explicit enforcement and regression coverage.

### Upgradeability

- Before: the repo had not yet implemented the intended mixed proxy/direct deployment
  boundary.
- After: ACP core, `UnderwritingHook`, and the canonical evaluator are proxy-backed;
  the settlement coordinator, collateral manager, and settlement escrows remain
  direct-deployed.

### Deployment path

- Before: deployment and smoke coverage were not fully locked to the canonical shared
  environment stack.
- After: the deploy script, proxy initialization, hook whitelist step, and admin
  ownership are exercised through the real script path.

### Tests

- Before: several tests still described the legacy hooked ACP architecture, and two
  important refund/expiry regressions were not covered in the canonical runtime.
- After: the suite covers the migrated architecture, including the canonical refund
  grace period and stale close-job replacement behavior.

## Result

The repo now matches the intended phase-B architecture:

- shared ACP core through the submodule
- hook-owned underwriting lineage
- proxy-backed ACP, hook, and canonical evaluator
- direct-deployed settlement coordination components
- explicit USDC-only underwriting settlement guardrails
- regression coverage and docs aligned to the migrated runtime

In short, the repo moved from a mixed migration state with duplicate ACP paths and
legacy runtime leftovers to a single canonical ACP integration path with the
underwriting stack migrated, tested, and documented around it.
