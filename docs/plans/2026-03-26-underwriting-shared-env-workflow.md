# Underwriting Shared Env Workflow Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a deployable underwriting collateral manager and align the underwriting flow with the shared Tenderly Base environment semantics: immediate underwriting premium payout on underwriting acceptance, explicit client confirmation after provider submission, and underwriter-controlled collateral recovery on timeout/reject/slash.

**Purpose:** The current repo has underwriting workflow pieces, but it still lacks a deployable `CollateralManager`, a shared-environment deployment path, and a lifecycle that cleanly matches the intended business semantics. This change exists to turn the repo into a usable underwriting stack for a shared Tenderly Base environment where the money flow and the decision flow are both unambiguous: provider service fees stay in ACP, underwriting premium is earned when underwriting is accepted, provider submission has a real deadline, client confirmation has a bounded window, and collateral recovery belongs to the underwriter rather than being paid onchain to the client.

**Expected Outcome:** After implementation, the system should behave like this:
- A team can deploy `ACP core + UnderwritingHook + UnderwritingEvaluator + UnderwritingSettlementCoordinator + UnderwritingCollateralManager` into one shared Tenderly Base environment and reuse it across redeploys.
- `job.budget` remains the provider-facing service fee inside ACP, while underwriting premium is a distinct payment that is sent to the underwriter as soon as underwriting is formally accepted.
- `expiredAt` acts as the provider submission deadline; a timely submission blocks the old immediate refund path and moves the job into a client confirmation window instead.
- The client gets the first chance to accept a timely submission; only after that confirmation window expires does the underwriter step in to adjudicate with `completeBySig(...)` or `rejectBySig(...)`.
- `requiredCollateralUsdc` becomes onchain recovery collateral for the underwriter, routing to the underwriter's recovery address on timeout/reject/slash, while any client compensation above that amount is handled offchain under the agreed `coverageCapUsdc`.
- Each underwriter signer can self-manage the payout addresses used for premium collection and collateral recovery without relying on a central admin to reconfigure recipients per job.

**Terminal Outcome Summary:** The end states should be explicit after this change:
- `Success`: the provider submits before `expiredAt`, then either the client confirms inside `clientConfirmationWindow` through `confirmByClient(jobId, reason)` or the underwriter later completes through `completeBySig(...)`. On success, `job.budget` is paid to the provider, `fundedPrincipalUsdc` has already been released to `merchantExecutionWallet`, and `requiredCollateralUsdc` stays in the existing post-success release/dispute flow until it is either released back to the provider or later slashed.
- `Reject`: the provider has submitted, the client does not confirm, and the underwriter ultimately rejects through `rejectBySig(...)`. On reject, `job.budget` returns to the client through ACP, underwriting premium stays with the underwriter, `fundedPrincipalUsdc` is not unwound onchain, and `requiredCollateralUsdc` is routed to the underwriter's `recoveryRecipient`.
- `Timeout`: the provider fails to submit before `expiredAt`. On timeout, `job.budget` returns to the client through `claimRefund()`, underwriting premium stays with the underwriter because underwriting was already accepted, `fundedPrincipalUsdc` is not unwound onchain, and `requiredCollateralUsdc` is routed to the underwriter's `recoveryRecipient` for the offchain claims process.
- `Slash`: the job has already reached a successful completion path, but a later success dispute resolves to `SlashCollateral`. In that case the onchain collateral is not paid to the client directly; instead `requiredCollateralUsdc` is routed to the underwriter's `recoveryRecipient`, and any client compensation is handled by the underwriter offchain under `coverageCapUsdc`.

**Detailed Business Context:** This section is here so a reader understands the intended product semantics, not just the code changes.
- `Success flow context`: when the provider submits before `expiredAt`, the job does not immediately settle. It first enters a global fixed `clientConfirmationWindow`. If the client actively confirms during that window, the happy-path success route is `confirmByClient(jobId, reason)`, which should complete the ACP job without waiting for the underwriter. If the client stays silent past that window, the underwriter becomes the fallback adjudicator and may call `completeBySig(...)`. In both success cases, `job.budget` goes to the provider, `fundedPrincipalUsdc` was already released earlier to `merchantExecutionWallet`, and `requiredCollateralUsdc` is not paid out at completion time. Instead, that collateral remains inside the existing release/dispute machinery and only returns to the provider if no later dispute is opened or the later dispute resolves to release.
- `Reject flow context`: if the provider has already submitted but the client does not confirm, and the underwriter later resolves the case with `rejectBySig(...)`, the product meaning is that the delivery was not accepted. In that case, `job.budget` should unwind through ACP back to the client. The underwriting premium does not unwind because the underwriter already accepted and serviced the underwriting engagement. `fundedPrincipalUsdc` is also not rolled back onchain because it was intentionally advanced earlier to `merchantExecutionWallet`. The chain-level recovery asset is therefore the locked `requiredCollateralUsdc`, and that collateral should be sent to the underwriter's `recoveryRecipient`, with any client-facing make-whole process happening offchain under the policy.
- `Timeout flow context`: `expiredAt` should be treated as the provider's submission deadline, not the underwriter's decision deadline. If the provider fails to submit before `expiredAt`, that is a true delivery timeout. The ACP-side `job.budget` should then refund to the client through `claimRefund()`. The underwriting premium still stays with the underwriter because underwriting was already accepted. `fundedPrincipalUsdc` is not automatically clawed back onchain. The locked `requiredCollateralUsdc` should instead move to the underwriter's `recoveryRecipient`, after which the underwriter handles the real client compensation process offchain up to `coverageCapUsdc`.
- `Slash flow context`: slash only applies after the job has already reached a success path and then enters the later success-dispute stage. If that later dispute resolves to `SlashCollateral`, the protocol should not send the collateral directly to the client. The correct chain-level action is to move `requiredCollateralUsdc` to the underwriter's `recoveryRecipient`. The underwriting premium remains with the underwriter. Any actual customer payout above or beyond the recovered collateral remains an offchain underwriting obligation up to the agreed `coverageCapUsdc`.

**Architecture:** Introduce a concrete `UnderwritingCollateralManager` that owns underwriter payout/recovery routing, permit verification, premium collection, principal release, collateral release, and collateral recovery. Extend the underwriting hook/evaluator/core flow so `expiredAt` acts as the provider submission deadline, timely submissions enter a global client confirmation window, and underwriter adjudication only starts after that window expires.

**Tech Stack:** Solidity 0.8.24, Foundry, OpenZeppelin, Tenderly Virtual TestNet, Base Mainnet USDC.

**Git note:** Do not create commits unless the user explicitly asks for them.

**Assumption for v1:** Once `clientConfirmationWindow` expires, the job stays frozen until the underwriter resolves it with `completeBySig(...)` or `rejectBySig(...)`. This plan does not add an automatic fallback if the underwriter also goes silent.

---

### Task 1: Add A Concrete Underwriting Collateral Manager

**Files:**
- Create: `contracts/settlement/UnderwritingCollateralManager.sol`
- Create: `test/settlement/UnderwritingCollateralManager.t.sol`
- Modify: `contracts/interfaces/ICollateralManager.sol`
- Modify: `test/mocks/MockCollateralManager.sol`

**Step 1: Write the failing tests**

```solidity
function testUnderwriterSignerCanSetRecipients() public {
    vm.prank(underwriter);
    manager.setUnderwriterRecipients(premiumRecipient, recoveryRecipient);

    assertEq(manager.premiumRecipientOf(underwriter), premiumRecipient);
    assertEq(manager.recoveryRecipientOf(underwriter), recoveryRecipient);
}

function testLockCollateralPaysPremiumImmediatelyAndStoresPosition() public {
    vm.prank(underwriter);
    manager.setUnderwriterRecipients(premiumRecipient, recoveryRecipient);

    vm.prank(client);
    usdc.approve(address(manager), permit.underwritingPremiumUsdc);

    vm.prank(address(escrow));
    usdc.approve(address(manager), permit.requiredCollateralUsdc);

    vm.prank(address(escrow));
    manager.lockCollateral(permit, client, permit.unlockAt, underwriterPermitSig);

    assertEq(usdc.balanceOf(premiumRecipient), permit.underwritingPremiumUsdc);
    assertEq(manager.lockedCollateralOf(permit.settlementJobId), permit.requiredCollateralUsdc);
}

function testClaimTimeoutRoutesLockedCollateralToRecoveryRecipient() public {
    // Arrange a funded position first, then time out.
    // Expect all locked collateral to move to recoveryRecipient.
}

function testReleaseCollateralReturnsLockedCollateralToEscrowCaller() public {
    // Arrange a funded position first, then release for success.
    // Expect manager to return the locked amount to the escrow.
}
```

**Step 2: Run test to verify it fails**

Run: `forge test --match-contract UnderwritingCollateralManagerTest -vv`

Expected: FAIL with missing contract/functions such as `UnderwritingCollateralManager`, `setUnderwriterRecipients`, `premiumRecipientOf`, or renamed fee fields.

**Step 3: Write the minimal implementation**

```solidity
contract UnderwritingCollateralManager is ICollateralManager, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct UnderwriterRecipients {
        address premiumRecipient;
        address recoveryRecipient;
    }

    struct Position {
        address underwriter;
        address safe;
        address user;
        address merchantExecutionWallet;
        uint256 lockedCollateralUsdc;
        bool premiumPaid;
        bool principalReleased;
        bool collateralRecovered;
        bool collateralReleased;
    }

    mapping(address underwriter => UnderwriterRecipients recipients) internal recipientsByUnderwriter;
    mapping(uint256 settlementJobId => Position position) internal positionBySettlementJobId;

    function setUnderwriterRecipients(address premiumRecipient, address recoveryRecipient) external { ... }
    function lockCollateral(UnderwritePermit calldata permit, address claimant, uint64 unlockAt, bytes calldata permitSig) external { ... }
    function releasePrincipalToMerchant(UnderwritePermit calldata permit, bytes calldata permitSig) external { ... }
    function releaseCollateral(uint256 settlementJobId) external { ... }
    function claimTimeout(uint256 settlementJobId) external { ... }
    function slash(SlashAttestation calldata attestation, bytes calldata slashSig) external { ... }
}
```

Implementation requirements:
- Verify the `UnderwritePermit` EIP-712 signature against `permit.underwriter`.
- Let `underwriter` self-register `premiumRecipient` and `recoveryRecipient`.
- Pull the underwriting premium from `permit.user` and immediately forward it to `premiumRecipient`.
- Pull collateral from `msg.sender` (the escrow) and store it against `settlementJobId`.
- Route timeout/slash recovery to `recoveryRecipient`, not to the client.
- Keep `claimant` as a recorded field for traceability even though v1 does not pay the client onchain.

**Step 4: Run test to verify it passes**

Run: `forge test --match-contract UnderwritingCollateralManagerTest -vv`

Expected: PASS

**Step 5: Verify compatibility with the mock path**

Run: `forge test --match-contract UnderwritingSettlementEscrowTest -vv`

Expected: PASS after updating the mock and interface to the new naming/comments without changing the legacy call shape.

---

### Task 2: Separate Provider Budget From Underwriting Premium

**Files:**
- Modify: `contracts/interfaces/ICollateralManager.sol`
- Modify: `contracts/examples/UnderwritingHookSystemExample.sol`
- Modify: `test/examples/UnderwritingHookSystemExample.t.sol`
- Modify: `test/settlement/UnderwritingSettlementCoordinator.t.sol`
- Modify: `test/settlement/UnderwritingSettlementEscrow.t.sol`

**Step 1: Write the failing tests**

```solidity
function testHappyPathUsesSeparateBudgetAndPremiumAmounts() public {
    uint256 providerBudget = 40e6;
    uint256 underwritingPremium = 5e6;

    vm.prank(client);
    acp.setBudget(jobId, providerBudget, example.encodeCommit(commit));

    permit.underwritingPremiumUsdc = underwritingPremium;

    // Expect provider budget to remain inside ACP escrow.
    // Expect underwriting premium to be paid immediately to premiumRecipient.
}
```

**Step 2: Run test to verify it fails**

Run: `forge test --match-contract UnderwritingHookSystemExampleTest -vv`

Expected: FAIL because the current example/tests still use one shared amount for both ACP job budget and underwriting premium.

**Step 3: Update the example helper and test fixtures**

```solidity
struct PermitInputs {
    address merchantExecutionWallet;
    uint256 underwritingPremiumUsdc;
    uint256 requiredCollateralUsdc;
    uint256 fundedPrincipalUsdc;
    uint256 coverageCapUsdc;
    uint64 executeFor;
    uint64 unlockIn;
    uint256 nonce;
}

permit = ICollateralManager.UnderwritePermit({
    jobId: jobId,
    settlementJobId: settlementJobId,
    safe: escrow,
    user: client,
    merchant: escrow,
    underwriter: commit.underwriter,
    underwritingPremiumUsdc: inputs.underwritingPremiumUsdc,
    merchantExecutionWallet: inputs.merchantExecutionWallet,
    requiredCollateralUsdc: inputs.requiredCollateralUsdc,
    fundedPrincipalUsdc: inputs.fundedPrincipalUsdc,
    coverageCapUsdc: inputs.coverageCapUsdc,
    validUntil: commit.validUntil,
    executeUntil: uint64(block.timestamp) + inputs.executeFor,
    policyHash: commit.policyHash,
    nonce: inputs.nonce,
    unlockAt: uint64(block.timestamp) + inputs.unlockIn
});
```

Also update tests so:
- `job.budget` is the provider payment.
- `underwritingPremiumUsdc` is a distinct client-to-underwriter payment.
- Shared-env fixtures use the real funding shape instead of the old single-value shortcut.

**Step 4: Run focused tests**

Run: `forge test --match-contract UnderwritingHookSystemExampleTest -vv`

Expected: PASS

**Step 5: Run settlement regression tests**

Run: `forge test --match-contract UnderwritingSettlementCoordinatorTest -vv`

Expected: PASS with assertions updated to check separate provider budget vs underwriting premium flows.

---

### Task 3: Add Provider Submission Timestamps And A Client Confirmation Window

**Files:**
- Modify: `contracts/hooks/underwriting/IUnderwritingHookView.sol`
- Modify: `contracts/hooks/underwriting/UnderwritingWorkflowCore.sol`
- Modify: `contracts/hooks/underwriting/UnderwritingHook.sol`
- Modify: `contracts/settlement/UnderwritingEvaluator.sol`
- Modify: `test/settlement/UnderwritingEvaluator.t.sol`

**Step 1: Write the failing tests**

```solidity
function testClientCanConfirmWithinConfirmationWindow() public {
    _submitEvidenceOnTime(jobId);

    vm.prank(client);
    evaluator.confirmByClient(jobId, keccak256("client-accepted"));

    assertEq(uint256(acp.getJob(jobId).status), uint256(IAgenticCommerceKernel.JobStatus.Completed));
}

function testUnderwriterCannotResolveBeforeClientWindowExpires() public {
    _submitEvidenceOnTime(jobId);

    vm.expectRevert(UnderwritingEvaluator.ClientConfirmationStillOpen.selector);
    evaluator.completeBySig(decision, signature);
}

function testUnderwriterCanResolveAfterClientWindowExpires() public {
    _submitEvidenceOnTime(jobId);
    vm.warp(block.timestamp + evaluator.clientConfirmationWindowSeconds() + 1);

    evaluator.completeBySig(decision, signature);
    assertEq(uint256(acp.getJob(jobId).status), uint256(IAgenticCommerceKernel.JobStatus.Completed));
}
```

**Step 2: Run test to verify it fails**

Run: `forge test --match-contract UnderwritingEvaluatorTest -vv`

Expected: FAIL with missing `confirmByClient`, missing submission timestamp getter, or missing client window enforcement.

**Step 3: Implement the hook/evaluator changes**

```solidity
mapping(uint256 jobId => uint64 submittedAt) internal submittedAtByJobId;

function _postSubmitWorkflow(uint256 jobId, bytes32 deliverable, bytes memory optParams) internal {
    // existing evidence checks...
    submittedAtByJobId[jobId] = uint64(block.timestamp);
    sidecarStateByJobId[jobId] = UnderwritingTypes.SidecarState.EvidenceSubmitted;
}

function jobSubmittedAt(uint256 jobId) external view returns (uint64) {
    return submittedAtByJobId[jobId];
}

function confirmByClient(uint256 jobId, bytes32 reason) external {
    IAgenticCommerceKernel.Job memory job = acp.getJob(jobId);
    if (msg.sender != job.client) revert OnlyClient();
    if (block.timestamp > hook.jobSubmittedAt(jobId) + clientConfirmationWindowSeconds) {
        revert ClientConfirmationWindowElapsed();
    }
    acp.complete(jobId, reason, bytes(""));
}
```

Evaluator requirements:
- Add immutable `clientConfirmationWindowSeconds`.
- Gate `completeBySig(...)` and `rejectBySig(...)` so they only work after the client window has elapsed.
- Keep the underwriter signature path as the fallback, not the default success path.

**Step 4: Run focused tests**

Run: `forge test --match-contract UnderwritingEvaluatorTest -vv`

Expected: PASS

**Step 5: Re-run example integration**

Run: `forge test --match-contract UnderwritingHookSystemExampleTest -vv`

Expected: PASS after tests are updated to choose either `confirmByClient(...)` or the post-window underwriter path.

---

### Task 4: Make `expiredAt` A Provider Submission Deadline For Hooked Underwriting Jobs

**Files:**
- Modify: `contracts/AgenticCommerceHooked.sol`
- Create: `test/AgenticCommerceHookedUnderwritingExpiry.t.sol`
- Modify: `test/examples/UnderwritingHookSystemExample.t.sol`

**Step 1: Write the failing tests**

```solidity
function testUnsubmittedHookedJobCanClaimRefundAfterExpiredAt() public {
    vm.warp(job.expiredAt + 1);
    acp.claimRefund(jobId);

    assertEq(uint256(acp.getJob(jobId).status), uint256(IAgenticCommerceKernel.JobStatus.Expired));
}

function testTimelySubmittedHookedJobCannotClaimRefundAfterExpiredAt() public {
    _submitEvidenceOnTime(jobId);
    vm.warp(job.expiredAt + 1);

    vm.expectRevert(AgenticCommerceHooked.WrongStatus.selector);
    acp.claimRefund(jobId);
}
```

**Step 2: Run test to verify it fails**

Run: `forge test --match-contract AgenticCommerceHookedUnderwritingExpiryTest -vv`

Expected: FAIL because the current core allows `claimRefund()` from `Submitted` after `expiredAt`.

**Step 3: Implement the minimal core change**

```solidity
mapping(uint256 jobId => uint64 submittedAt) internal submittedAtByJobId;

function submit(uint256 jobId, bytes32 deliverable, bytes calldata optParams) external nonReentrant {
    // existing validation...
    job.status = JobStatus.Submitted;
    submittedAtByJobId[jobId] = uint64(block.timestamp);
    emit JobSubmitted(jobId, msg.sender, deliverable);
    _afterHook(job.hook, jobId, msg.sig, data);
}

function claimRefund(uint256 jobId) external nonReentrant {
    Job storage job = jobs[jobId];
    if (job.status == JobStatus.Submitted && job.hook != address(0)) {
        uint64 submittedAt = submittedAtByJobId[jobId];
        if (submittedAt != 0 && submittedAt <= job.expiredAt) revert WrongStatus();
    }
    // existing refund path...
}
```

Implementation note:
- Scope the refund freeze to hooked jobs in v1 so non-hooked ACP behavior stays unchanged.
- The underwriting flow can then treat `expiredAt` as the provider submission deadline without letting a timely submission be refunded out from under the post-submit confirmation/adjudication flow.

**Step 4: Run focused tests**

Run: `forge test --match-contract AgenticCommerceHookedUnderwritingExpiryTest -vv`

Expected: PASS

**Step 5: Run regression coverage**

Run: `forge test --match-contract UnderwritingHookSystemExampleTest -vv`

Expected: PASS with the new expiry behavior enforced.

---

### Task 5: Route Reject/Timeout/Slash Collateral To Underwriter Recovery While Preserving Success Release/Dispute Flow

**Files:**
- Modify: `contracts/settlement/SettlementTypes.sol`
- Modify: `contracts/settlement/UnderwritingSettlementCoordinator.sol`
- Modify: `contracts/settlement/UnderwritingSettlementEscrow.sol`
- Modify: `contracts/settlement/README.md`
- Modify: `test/settlement/UnderwritingSettlementCoordinator.t.sol`
- Modify: `test/examples/UnderwritingHookSystemExample.t.sol`

**Step 1: Write the failing tests**

```solidity
function testTimeoutMovesCollateralToRecoveryRecipient() public {
    _fundProtectedJob(jobId);
    vm.warp(job.expiredAt + 1);

    acp.claimRefund(jobId);
    coordinator.settleExpiry(jobId);

    assertEq(usdc.balanceOf(recoveryRecipient), requiredCollateralUsdc);
}

function testRejectRoutesCollateralToRecoveryRecipient() public {
    _submitEvidenceOnTime(jobId);
    vm.warp(block.timestamp + evaluator.clientConfirmationWindowSeconds() + 1);

    evaluator.rejectBySig(rejectDecision, rejectSig);

    assertEq(usdc.balanceOf(recoveryRecipient), requiredCollateralUsdc);
}

function testSuccessReleasesCollateralBackToProvider() public {
    _submitEvidenceOnTime(jobId);
    vm.prank(client);
    evaluator.confirmByClient(jobId, keccak256("accepted"));

    coordinator.releaseCollateral(jobId);

    assertEq(usdc.balanceOf(provider), providerBalanceBefore + requiredCollateralUsdc);
}

function testSlashRoutesCollateralToRecoveryRecipient() public {
    _submitEvidenceOnTime(jobId);
    vm.prank(client);
    evaluator.confirmByClient(jobId, keccak256("accepted"));

    vm.prank(provider);
    coordinator.requestCollateralRelease(jobId);

    vm.prank(client);
    coordinator.openSuccessDispute(jobId, keccak256("success-dispute"));

    evaluator.resolveSuccessDisputeBySig(disputeDecision, attestation, slashSig, underwriterDecisionSig);

    assertEq(usdc.balanceOf(recoveryRecipient), requiredCollateralUsdc);
}
```

**Step 2: Run test to verify it fails**

Run: `forge test --match-contract UnderwritingSettlementCoordinatorTest -vv`

Expected: FAIL because the current coordinator still routes recovery and release according to the old assumptions and does not yet reflect the new recovery-recipient rules end-to-end.

**Step 3: Implement the settlement state changes**

```solidity
enum SettlementState {
    None,
    EscrowConfigured,
    CollateralLocked,
    PrincipalReleased,
    SuccessPendingRelease,
    DisputeOpen,
    ReleaseApproved,
    SuccessSettled,
    SuccessSlashed,
    RejectSettled,
    ExpirySettled
}

function settleExpiry(uint256 jobId) external {
    IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
    if (job.status != IAgenticCommerceKernel.JobStatus.Expired) revert WrongJobStatus();

    UnderwritingSettlementEscrow escrow = _escrow(jobId);
    escrow.claimTimeout();
    jobSettlementState[jobId] = SettlementTypes.SettlementState.ExpirySettled;
}

function finalizeRejectedJob(uint256 jobId) external {
    IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
    if (job.status != IAgenticCommerceKernel.JobStatus.Rejected) revert WrongJobStatus();

    UnderwritingSettlementEscrow escrow = _escrow(jobId);
    escrow.forfeitCollateralToRecovery();
    jobSettlementState[jobId] = SettlementTypes.SettlementState.RejectSettled;
}

function releaseCollateral(uint256 jobId) external {
    IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
    if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();

    UnderwritingSettlementEscrow escrow = _escrow(jobId);
    escrow.releaseCollateralAndForward();
    jobSettlementState[jobId] = SettlementTypes.SettlementState.SuccessSettled;
}
```

Implementation requirements:
- Preserve the post-success collateral release/dispute flow for successful jobs.
- Treat client confirmation + underwriter adjudication as the pre-completion decision stage before a job becomes successful.
- Route timeout, reject, and slash recovery through the underwriter's `recoveryRecipient`.
- Add an escrow entrypoint such as `forfeitCollateralToRecovery()` if `claimTimeout()` is too narrow semantically for reject handling.

**Step 4: Run focused tests**

Run: `forge test --match-contract UnderwritingSettlementCoordinatorTest -vv`

Expected: PASS

**Step 5: Run full example coverage**

Run: `forge test --match-contract UnderwritingHookSystemExampleTest -vv`

Expected: PASS with success, reject, and timeout assertions updated to the new terminal routing.

---

### Task 6: Add Shared-Environment Deployment And Operator Scripts

**Files:**
- Create: `script/DeployUnderwritingSharedEnv.s.sol`
- Create: `script/ConfigureUnderwriterRecipients.s.sol`
- Create: `script/RegisterUnderwriter.s.sol`
- Modify: `README.md`
- Modify: `contracts/README.md`
- Modify: `contracts/settlement/README.md`

**Step 1: Write the failing operator smoke test**

```solidity
function testDeployScriptWiresAcpHookCoordinatorEvaluatorAndManager() public {
    // Broadcast-script smoke test or dry-run test using vm.envAddress/vm.envUint.
    // Expect deployed contracts to point at the same ACP and concrete manager.
}
```

**Step 2: Run script in dry-run mode to verify it currently does not exist**

Run: `forge script script/DeployUnderwritingSharedEnv.s.sol:DeployUnderwritingSharedEnv --sig "run()" --rpc-url $TENDERLY_VIRTUAL_TESTNET_RPC`

Expected: FAIL because the script does not exist yet.

**Step 3: Implement the scripts**

```solidity
contract DeployUnderwritingSharedEnv is Script {
    function run() external {
        address usdc = vm.envAddress("BASE_USDC");
        address treasury = vm.envAddress("ACP_TREASURY");
        uint64 clientConfirmationWindow = uint64(vm.envUint("CLIENT_CONFIRMATION_WINDOW"));
        uint64 disputeWindowDeprecated = 0;

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        AgenticCommerceHooked acp = new AgenticCommerceHooked(usdc, treasury);
        UnderwritingCollateralManager manager = new UnderwritingCollateralManager(usdc);
        UnderwritingHook hook = new UnderwritingHook(address(acp), msg.sender);
        UnderwritingSettlementCoordinator coordinator =
            new UnderwritingSettlementCoordinator(IAgenticCommerceKernel(address(acp)), hook, manager, disputeWindowDeprecated);
        UnderwritingEvaluator evaluator =
            new UnderwritingEvaluator(IAgenticCommerceKernel(address(acp)), hook, address(coordinator), clientConfirmationWindow);

        hook.setWiring(address(evaluator), address(coordinator));

        vm.stopBroadcast();
    }
}
```

Also add scripts for:
- registering an underwriter in the hook
- setting `premiumRecipient` and `recoveryRecipient` from the underwriter signer

**Step 4: Run the dry-run deployment**

Run: `forge script script/DeployUnderwritingSharedEnv.s.sol:DeployUnderwritingSharedEnv --rpc-url $TENDERLY_VIRTUAL_TESTNET_RPC`

Expected: local simulation succeeds and prints deployed addresses.

**Step 5: Document the operator flow**

Document:
- required env vars (`BASE_USDC`, `PRIVATE_KEY`, `ACP_TREASURY`, `CLIENT_CONFIRMATION_WINDOW`, `TENDERLY_VIRTUAL_TESTNET_RPC`)
- deploy order
- underwriter registration
- recipient configuration
- how to redeploy safely into the shared Tenderly environment without losing track of active addresses

---

### Task 7: Add End-To-End Regression Coverage For The New Workflow

**Files:**
- Create: `test/integration/UnderwritingSharedEnvFlow.t.sol`
- Modify: `test/examples/UnderwritingHookSystemExample.t.sol`

**Step 1: Write the end-to-end failing tests**

```solidity
function testClientConfirmationPathPaysPremiumThenCompletesAndReleasesCollateral() public {
    // 1. Fund and orchestrate funding.
    // 2. Assert premiumRecipient got underwriting premium immediately.
    // 3. Provider submits on time.
    // 4. Client confirms inside the confirmation window.
    // 5. Assert budget went to provider and collateral returned to provider.
}

function testUnderwriterRejectPathAfterConfirmationWindowRoutesCollateralToRecovery() public {
    // 1. Fund and orchestrate funding.
    // 2. Provider submits on time.
    // 3. Client does not confirm.
    // 4. Window expires.
    // 5. Underwriter rejects by signature.
    // 6. Assert budget refunded to client and collateral moved to recoveryRecipient.
}

function testPreSubmitTimeoutRefundsBudgetAndRoutesCollateralToRecovery() public {
    // 1. Fund and orchestrate funding.
    // 2. Do not submit.
    // 3. Warp past expiredAt and call claimRefund.
    // 4. Assert budget refunded and collateral moved to recoveryRecipient.
}
```

**Step 2: Run the new suite**

Run: `forge test --match-contract UnderwritingSharedEnvFlowTest -vv`

Expected: FAIL until all prior tasks are in place.

**Step 3: Update fixtures to use the real concrete manager and distinct amounts**

```solidity
uint256 providerBudget = 40e6;
uint256 underwritingPremium = 5e6;
uint256 fundedPrincipal = 80e6;
uint256 requiredCollateral = 100e6;
uint256 coverageCap = 250e6;
```

**Step 4: Run the complete relevant test suite**

Run: `forge test --match-path "test/settlement/*.t.sol" --match-path "test/examples/*.t.sol" --match-path "test/integration/*.t.sol" -vv`

Expected: PASS

**Step 5: Smoke-test the deploy script against Tenderly**

Run: `forge script script/DeployUnderwritingSharedEnv.s.sol:DeployUnderwritingSharedEnv --rpc-url $TENDERLY_VIRTUAL_TESTNET_RPC --private-key $PRIVATE_KEY --broadcast`

Expected: contracts deploy, the hook wires successfully, and the output can be copied into the team’s shared address registry.

---

## Execution Notes

- Keep the concrete manager limited to the agreed shared-env semantics:
  - premium is earned immediately on underwriting acceptance
  - collateral recovery goes to the underwriter, not to the client
  - `coverageCapUsdc` is an offchain liability ceiling, not an onchain escrow amount
- Prefer adding new tests before removing the old post-success dispute assertions, so regressions show up as intentional state-machine changes instead of vague failures.
- If field renaming from `decisionFeeUsdc` to `underwritingPremiumUsdc` causes too much churn in one pass, keep the storage layout/order unchanged and land the behavior first, then do a naming cleanup pass.

