# ACP Submodule Migration Implementation Checklist

**Companion plan:** `docs/plans/2026-03-27-acp-submodule-b-now-migration-plan.md`

**Purpose:** Break the agreed migration into file-level work items so implementation can proceed in a controlled order without losing track of interface drift, proxy requirements, underwriting settlement invariants, and cleanup boundaries.

**Working assumptions:**

- ACP core comes from `contracts/acp` via `@acp/`.
- Parent/close lineage lives entirely in underwriting hook state.
- ACP is per-job-token capable.
- Protected underwriting settlement is USDC-only in v1.
- Upgradeable now: ACP core, `UnderwritingHook`, canonical settlement `UnderwritingEvaluator`.
- Direct-deployed for now: settlement coordinator, collateral manager, settlement escrows.

---

## Review Findings On The Original Order

The original checklist was directionally right, but the execution order had three problems:

1. Cleanup tasks appeared too early.
   - Local ACP deletion and hook-interface cleanup were mixed into the middle of the migration, which creates needless risk while interfaces are still moving.

2. Tests were treated as a trailing phase.
   - For this migration, tests need to be phase gates. If parity tests come only at the end, callback-shape or ABI mistakes will be discovered far too late.

3. The canonical runtime was not pruned early enough.
   - `contracts/hooks/underwriting/UnderwritingCoordinator.sol` and `contracts/hooks/underwriting/UnderwritingEvaluator.sol` should be marked non-canonical early so they do not absorb migration work that should go into the settlement path.

This tightened version fixes those issues by:

- quarantining stale runtime paths early,
- moving verification into every phase,
- pushing destructive cleanup to the very end.

---

## Tightened Execution Order

1. Dependency and build alignment
2. Freeze the canonical runtime path and quarantine legacy runtime paths
3. Port the hook protocol surface and early invariants
4. Convert `UnderwritingHook` to the new ACP model and make it upgradeable
5. Adapt the settlement boundary interfaces and mocks
6. Convert the canonical settlement `UnderwritingEvaluator`
7. Adapt `UnderwritingSettlementCoordinator` and enforce the defensive USDC check
8. Rewrite deployment and smoke tests
9. Rewrite or retire legacy tests and examples
10. Delete local ACP copies and stale runtime paths

The key rule is: **no cleanup before parity, and no phase advances without focused tests passing.**

---

## Phase 1: Dependency And Build Alignment

### `/.gitmodules`

**Likely edits**

- Create or update the root `.gitmodules`.
- Add `contracts/acp` pointing at the ACP base-contracts repository.
- If the repo moves dependency management toward submodules for upgradeable OZ as well, document that explicitly here instead of relying on ad hoc local state.

**Verification gate**

- `git submodule status --recursive`
- Fresh checkout bootstrap works from zero state.

**Migration risks**

- A missing or mispointed submodule leaves the repo in a half-working state where local ACP copies still compile but new imports silently fail later.

### `/foundry.toml`

**Likely edits**

- Add `@acp/=contracts/acp/contracts/`.
- Add `@openzeppelin/contracts-upgradeable/=lib/openzeppelin-contracts-upgradeable/contracts/`.
- Align compiler settings with upstream ACP core if required, including `solc_version` and possibly `evm_version`.
- Keep local `contracts/` remapping only as long as legacy files still exist.

**Verification gate**

- `forge build`
- Build a single smoke contract that imports both `@acp/AgenticCommerce.sol` and `@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol`.

**Migration risks**

- Compiler version drift between local contracts and upstream ACP causes misleading parser or ABI issues.
- Both local ACP and `@acp` imports compiling at once can mask which core is actually being used.

### `/lib/openzeppelin-contracts-upgradeable`

**Likely edits**

- Add the dependency if the repo does not already contain it.
- Keep installation/bootstrap instructions consistent with the chosen dependency management style.

**Verification gate**

- `forge build`

**Migration risks**

- Partial local installation can make one machine pass while fresh environments fail.

**Phase 1 exit criteria**

- The repo can compile `@acp` imports plus upgradeable OZ imports in the same build.
- A fresh checkout can bootstrap dependencies without relying on undocumented local state.

---

## Phase 2: Freeze The Canonical Runtime Path

This phase is about avoiding wasted effort.

### Files To Freeze As Non-Canonical Early

- `/contracts/hooks/underwriting/UnderwritingCoordinator.sol`
- `/contracts/hooks/underwriting/UnderwritingEvaluator.sol`
- `/contracts/examples/UnderwritingHookSystemExample.sol`

**Likely edits**

- Do not port these first.
- Add doc comments or issue notes if needed so future work does not accidentally keep them in the main runtime path.
- Treat the canonical runtime as:
  - `@acp/AgenticCommerce.sol`
  - `contracts/hooks/underwriting/UnderwritingHook.sol`
  - `contracts/settlement/UnderwritingEvaluator.sol`
  - `contracts/settlement/UnderwritingSettlementCoordinator.sol`
  - `contracts/settlement/UnderwritingCollateralManager.sol`
  - `contracts/settlement/UnderwritingSettlementEscrow.sol`

**Verification gate**

- The migration work list no longer assumes the lightweight hook-side coordinator/evaluator are part of the production deployment.

**Migration risks**

- If the legacy hook-side runtime stays "half alive," implementation time will be lost rebasing code that should be deleted later.

**Phase 2 exit criteria**

- Everyone working from the checklist knows which runtime is canonical and which paths are legacy or optional.

---

## Phase 3: Hook Protocol Surface And Early Invariants

This phase should land behavioral parity before any proxy complexity is introduced.

### `/contracts/BaseACPHook.sol`

**Likely edits**

- Import `@acp/IACPHook.sol` instead of the local interface.
- Implement ERC165 compatibility if required by upstream ACP hook validation.
- Replace the old callback decoding with the newer caller-aware, token-aware payload shapes.
- Remove selector logic tied to the local `AgenticCommerceHooked` signatures.

**Verification gate**

- Focused hook unit tests compile and pass.
- Add a test that a hooked `setBudget(...)` call decodes the caller and payment token correctly.

**Migration risks**

- Callback payload mismatch is a high-risk failure mode: hooks may compile but decode the wrong bytes and corrupt underwriting state.

### `/contracts/hooks/underwriting/UnderwritingWorkflowCore.sol`

**Likely edits**

- Switch the ACP type from local `AgenticCommerceHooked` to `@acp/AgenticCommerce`.
- Accept and persist the committed payment token during `setBudget(...)`.
- Move all parent/close linkage assumptions fully into hook state.
- Keep `jobSettlementJobId` support.
- Keep `submittedAtByJobId` support for the client confirmation window.
- Enforce the underwriting-settlement token invariant early, ideally during commit locking or `setBudget(...)`.

**Verification gate**

- Rewrite or add tests for:
  - parent job can admit one close job
  - stale close job can be cleared once terminal
  - non-USDC underwritten job rejects before funding
  - root and close jobs preserve lineage entirely through hook state

**Migration risks**

- Forgetting to persist `submittedAt` breaks the canonical settlement evaluator.
- Token invariant checks added too late allow unsupported jobs to reach settlement before reverting.

### `/contracts/hooks/underwriting/IUnderwritingHookView.sol`

**Likely edits**

- Preserve the view surface needed by the settlement stack:
  - `getCommit(...)`
  - `jobUnderwriter(...)`
  - `jobSidecarState(...)`
  - `jobSettlementJobId(...)`
  - `isAwaitingClose(...)`
  - `getParentJobId(...)`
  - `getActiveCloseJobId(...)`
  - `jobSubmittedAt(...)`

**Verification gate**

- Settlement contracts compile strictly against this interface, not the concrete hook type unless truly necessary.

**Migration risks**

- Accidentally dropping `jobSubmittedAt(...)` or settlement identity helpers will force awkward concrete-type dependencies later.

**Phase 3 exit criteria**

- Hook callback decoding matches upstream ACP.
- Parent/close lineage exists only in hook state.
- Underwritten non-USDC jobs fail early.

---

## Phase 4: Upgradeable `UnderwritingHook`

Only after hook behavior is correct should proxy mechanics be introduced.

### `/contracts/hooks/underwriting/UnderwritingHook.sol`

**Likely edits**

- Import and use `@acp/AgenticCommerce.sol`.
- Convert from constructor/immutables to `Initializable`, `AccessControlUpgradeable`, and `UUPSUpgradeable`.
- Store ACP address, admin role, evaluator, coordinator, and allowed settlement token in storage.
- Add initializer and `_authorizeUpgrade(...)`.
- Keep wiring validation against coordinator/evaluator getters.
- Enforce USDC-only for protected underwriting jobs.

**Verification gate**

- Proxy deployment test.
- Reinitialization revert test.
- Upgrade authorization test.
- End-to-end underwriting happy path using the proxy hook.
- Hook-whitelist flow test against ACP.

**Migration risks**

- Storage layout mistakes or missing `_disableInitializers()` will create long-lived upgrade hazards.
- If hook wiring validation assumes direct deployments only, proxy-backed coordinator/evaluator addresses may fail unexpectedly.

**Phase 4 exit criteria**

- The hook works correctly behind a proxy and preserves the same underwriting semantics established in Phase 3.

---

## Phase 5: Settlement Boundary Interfaces And Mocks

This phase should happen before porting the canonical settlement evaluator and coordinator, because it freezes the ABI boundary they both depend on.

### `/contracts/interfaces/IAgenticCommerceKernel.sol`

**Likely edits**

- Remove legacy ACP-specific functions that no longer exist in the upstream core:
  - `paymentToken()`
  - `getJobKind(...)`
  - `getParentJobId(...)`
  - `getCloseJobId(...)`
- Redefine the `Job` struct to match the upstream ACP ABI exactly, including field order.
- Keep only the methods the local settlement/evaluator stack truly needs.

**Verification gate**

- Add or update a mock kernel that uses the new tuple layout.
- Settlement tests using mocks should still compile and decode `getJob(...)` correctly.

**Migration risks**

- This file is a critical ABI risk. If the local `Job` struct layout does not exactly match the upstream ACP contract, every `getJob(...)` call may decode incorrectly or revert.

### Settlement test mocks

**Likely edits**

- Update any settlement mocks that emulate `getJob(...)`.
- Remove assumptions about global `paymentToken()` from mocks.
- Add `job.paymentToken` to mock job fixtures.

**Verification gate**

- Focused mock-backed settlement tests compile before production settlement contracts are ported.

**Migration risks**

- If the mocks lag the real ABI, settlement tests may pass while production code is broken.

**Phase 5 exit criteria**

- Settlement-facing contracts and tests agree on a single kernel ABI and single hook view surface.

---

## Phase 6: Canonical Settlement `UnderwritingEvaluator`

Once the settlement boundary is stable, port the canonical evaluator.

### `/contracts/settlement/UnderwritingEvaluator.sol`

**Likely edits**

- Keep this as the canonical evaluator and retire the lighter hook-side evaluator.
- Convert to `Initializable` + `UUPSUpgradeable`.
- Replace constructor/immutables with initializer storage.
- Keep client confirmation window behavior.
- Compile against the updated kernel interface and hook view interface.

**Verification gate**

- Proxy initialization test.
- `completeBySig(...)` / `rejectBySig(...)` tests against migrated hook + ACP.
- `confirmByClient(...)` tests using `jobSubmittedAt(...)`.

**Migration risks**

- If the evaluator switches to proxy deployment but tests still instantiate the old constructor version, false confidence is likely.

**Phase 6 exit criteria**

- The canonical evaluator works against the migrated hook and kernel ABI and is proxy-safe.

---

## Phase 7: Settlement Coordinator And Defensive USDC Enforcement

Only after the kernel ABI and canonical evaluator are stable should the coordinator be ported.

### `/contracts/settlement/UnderwritingSettlementCoordinator.sol`

**Likely edits**

- Keep direct-deployed in phase `B`.
- Read the payment token from `job.paymentToken`, not from global kernel state.
- Add an explicit USDC-only assertion for protected underwriting settlement.
- Keep hook-owned settlement identity via `jobSettlementJobId(...)`.
- Preserve current dispute, timeout, and slash behavior.

**Verification gate**

- Focused settlement coordinator tests for:
  - funded USDC underwriting flow succeeds
  - non-USDC protected job reverts before escrow configuration
  - close-leg and root-leg settlement continue to behave correctly

**Migration risks**

- If the coordinator becomes the only place enforcing USDC, unsupported jobs will fail too late.
- If the coordinator assumes an upstream `Job` layout incorrectly, all settlement state reads become suspect.

### `/contracts/settlement/UnderwritingCollateralManager.sol`

**Likely edits**

- Minimal behavior change in phase `B`.
- Keep direct deployment and USDC-centric design.
- Consider only small surface adjustments needed by the coordinator or script changes.
- Keep constructor arguments and config structure close to future initializer shapes so the path to `C` stays short.

**Verification gate**

- Existing collateral manager tests should still pass after the rest of the stack migrates.

**Migration risks**

- If per-job-token logic leaks into this contract during phase `B`, scope will expand sharply and slow the migration.

### `/contracts/settlement/UnderwritingSettlementEscrow.sol`

**Likely edits**

- Minimal behavior change in phase `B`.
- Keep non-upgradeable and per-settlement.
- Ensure it still works with the updated coordinator token checks and permit matching.

**Verification gate**

- Existing escrow tests plus integration coverage from the coordinator.

**Migration risks**

- Attempting to make escrows upgradeable during the same migration will increase proxy complexity with little iteration upside.

**Phase 7 exit criteria**

- Settlement coordination works against the migrated hook and evaluator, and the defensive USDC check is in place.

---

## Phase 8: Deployment, Smoke Tests, And Runtime Wiring

Only after the contracts are individually stable should the deploy path be rewritten.

### `/script/DeployUnderwritingSharedEnv.s.sol`

**Likely edits**

- Replace direct ACP deployment with implementation + proxy deployment and initialization.
- Deploy `UnderwritingHook` and canonical settlement `UnderwritingEvaluator` behind proxies.
- Keep settlement coordinator and collateral manager direct-deployed.
- Whitelist the hook in ACP after deployment.
- Wire hook to the canonical evaluator and settlement coordinator.
- Pass USDC explicitly into all settlement-side components.

**Verification gate**

- `forge script ... --sig "run()"` style dry-run or local script test.
- Shared-environment smoke test proves every deployed address is usable immediately.

**Migration risks**

- Missing the hook whitelist step will break hook-backed job creation even if deployment appears successful.
- Mixed proxy/direct deployment makes address wiring errors more likely than in the old all-direct flow.

### `/test/script/DeployUnderwritingSharedEnvSmoke.t.sol`

**Likely edits**

- Rewrite around proxy deployment and ACP hook whitelisting.
- Assert the deployed hook is actually usable for job creation.

**Verification gate**

- Shared-environment wiring succeeds in a smoke test before broad integration tests are rewritten.

**Phase 8 exit criteria**

- The canonical runtime can be deployed and wired from a single script without manual fixups.

---

## Phase 9: Rewrite Or Retire Legacy Tests And Examples

By this point, the runtime should be stable enough to decide which old tests and examples are worth porting.

### Rewrite Or Remove

- `/test/AgenticCommerceTwoPhase.t.sol`
  - Old ACP-core two-phase assumptions should move into hook-state tests or this file should be removed.
- `/test/AgenticCommerceHookedUnderwritingExpiry.t.sol`
  - Port away from `AgenticCommerceHooked`.
- `/test/integration/UnderwritingSharedEnvFlow.t.sol`
  - Deploy proxies, whitelist hook, assert USDC-only underwriting.
- `/test/examples/UnderwritingHookSystemExample.t.sol`
  - Port or retire depending on whether the example remains canonical.
- `/test/hooks/underwriting/UnderwritingHookParity.t.sol`
  - Rebase to `@acp` and hook-owned lineage.
- `/test/hooks/underwriting/UnderwritingEvaluatorParity.t.sol`
  - Rebase or remove in favor of the canonical settlement evaluator.
- `/test/settlement/UnderwritingSettlementCoordinator.t.sol`
  - Update kernel mock and USDC-only assertions.
- `/test/settlement/UnderwritingEvaluator.t.sol`
  - Add proxy initialization path and migrated hook/kernel interaction.

### Add New Focused Tests

- Underwritten non-USDC `setBudget(...)` reverts early.
- Plain ACP non-USDC jobs still succeed outside underwriting.
- Hook-owned parent/close lineage supports replacement close jobs after terminal failure.
- Proxy hook can initialize once and upgrade only through authorized roles.
- Proxy settlement evaluator can initialize once and upgrade only through authorized roles.
- Deploy script smoke covers hook whitelist setup.

**Phase 9 exit criteria**

- The test suite asserts the new architecture, not the deleted one.
- Examples no longer block migration decisions.

---

## Phase 10: Cleanup Legacy ACP And Stale Runtime Paths

Cleanup should happen only after parity, deployment, and smoke coverage are in place.

### Likely Legacy Files To Remove After Parity

- `/contracts/AgenticCommerce.sol`
- `/contracts/AgenticCommerceHooked.sol`
- `/contracts/IACPHook.sol`
- `/contracts/hooks/underwriting/UnderwritingCoordinator.sol` if no longer canonical
- `/contracts/hooks/underwriting/UnderwritingEvaluator.sol` if no longer canonical

### Documentation Cleanup

#### `/README.md`
#### `/contracts/README.md`

**Likely edits**

- Update the repo story so ACP core is documented as an external submodule dependency rather than an in-tree source of truth.
- Document the `B now` runtime shape.
- Document the USDC-only underwriting settlement restriction explicitly.
- Document bootstrap steps for the ACP submodule and upgradeable OZ dependency.

**Verification gate**

- Fresh-reader sanity check: setup instructions should be executable without tribal knowledge.

**Migration risks**

- Stale docs will cause future contributors to reintroduce local ACP assumptions.

**Phase 10 exit criteria**

- There is only one ACP source of truth in production code.
- The docs describe the migrated runtime accurately.

---

## Migration Risk Register

### High Risk

- **ABI mismatch in `IAgenticCommerceKernel.Job`:** incorrect tuple shape will break all `getJob(...)` decodes.
- **Hook callback payload mismatch:** old `BaseACPHook` decode logic may silently mis-handle caller/token-aware ACP callbacks.
- **Upgrade safety regressions:** missing `_disableInitializers()`, bad `_authorizeUpgrade(...)`, or storage layout mistakes in the hook/evaluator proxies.
- **Late USDC enforcement:** unsupported tokens entering protected underwriting too far downstream will create hard-to-debug partial state.

### Medium Risk

- **Dual ACP source confusion:** local ACP copies and submodule ACP both compiling during the transition can hide the real dependency path.
- **Mixed deployment wiring mistakes:** proxy/direct address wiring can break hook validation or evaluator/coordinator references.
- **Test suite drift:** legacy tests may continue asserting ACP-core parent/close behavior that no longer exists by design.

### Low Risk

- **Docs/bootstrap drift:** contributors forget `git submodule update --init --recursive` or miss the upgradeable OZ dependency.
- **Future path to `C`:** if constructor signatures diverge too far from future initializer shapes, later settlement upgradeability gets more expensive.

---

## Tightened Recommended Implementation Order

1. Add submodule and Foundry/remapping support.
2. Freeze the canonical runtime and stop treating the lightweight hook-side runtime as production.
3. Port `BaseACPHook`.
4. Port `UnderwritingWorkflowCore` and `IUnderwritingHookView`.
5. Convert `UnderwritingHook` to the new ACP model and make it upgradeable.
6. Update `IAgenticCommerceKernel` and settlement mocks.
7. Convert canonical settlement `UnderwritingEvaluator` to the new interfaces and make it upgradeable.
8. Adapt `UnderwritingSettlementCoordinator` to `job.paymentToken` plus the defensive USDC-only enforcement.
9. Rewrite deployment script and shared-environment smoke tests.
10. Rewrite or retire legacy tests and examples.
11. Delete local ACP copies and stale runtime paths.
