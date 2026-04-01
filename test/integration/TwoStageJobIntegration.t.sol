// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@acp/AgenticCommerce.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../contracts/hooks/underwriting/UnderwritingHook.sol";
import "../../contracts/hooks/underwriting/UnderwritingTypes.sol";
import "../../contracts/settlement/SettlementTypes.sol";
import "../../contracts/settlement/UnderwritingSettlementCoordinator.sol";
import "../../contracts/settlement/UnderwritingSettlementEscrow.sol";
import "../../contracts/settlement/UnderwritingEvaluator.sol";
import "../../contracts/interfaces/ICollateralManager.sol";
import "../mocks/MockCollateralManager.sol";
import "../mocks/MockERC20.sol";

/**
 * @title TwoStageJobIntegrationTest
 * @notice End-to-end integration tests for 2-stage underwriting jobs.
 * @dev Wires real ACP, real hook, real evaluator, real coordinator with a mock
 *      collateral manager. Tests the full open-leg → close-leg lifecycle
 *      including the happy path (collateral release) and dispute path (slash).
 */
contract TwoStageJobIntegrationTest is Test {
    uint256 internal constant ROOT_BUDGET = 100e6;
    uint256 internal constant CLOSE_BUDGET = 50e6;
    uint256 internal constant COLLATERAL_AMOUNT = 200e6;
    uint256 internal constant PRINCIPAL_AMOUNT = 150e6;
    uint256 internal constant PREMIUM_AMOUNT = 10e6;
    uint256 internal constant COVERAGE_CAP = 200e6;
    uint64 internal constant CLIENT_CONFIRM_WINDOW = 1 hours;

    bytes32 internal constant COMPLETE_TYPEHASH =
        keccak256("CompleteDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 internal constant REJECT_TYPEHASH =
        keccak256("RejectDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 internal constant SLASH_ATTESTATION_TYPEHASH = keccak256(
        "SlashAttestation(uint256 settlementJobId,address safe,address user,address merchant,uint256 slashAmountUsdc,bytes32 reasonCode,uint64 validUntil,uint256 nonce)"
    );

    address internal treasury = makeAddr("treasury");
    address internal admin = makeAddr("admin");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal merchantWallet = makeAddr("merchantWallet");

    uint256 internal underwriterPk;
    address internal underwriter;

    MockERC20 internal usdc;
    AgenticCommerce internal acp;
    UnderwritingHook internal hook;
    UnderwritingEvaluator internal evaluator;
    UnderwritingSettlementCoordinator internal coordinator;
    MockCollateralManager internal collateralManager;

    function setUp() public {
        (underwriter, underwriterPk) = makeAddrAndKey("underwriter");

        usdc = new MockERC20("Mock USDC", "mUSDC");

        // Deploy ACP
        AgenticCommerce acpImpl = new AgenticCommerce();
        acp = AgenticCommerce(
            address(new ERC1967Proxy(address(acpImpl), abi.encodeCall(AgenticCommerce.initialize, (treasury))))
        );

        // Deploy Hook
        UnderwritingHook hookImpl = new UnderwritingHook();
        hook = UnderwritingHook(
            address(new ERC1967Proxy(address(hookImpl), abi.encodeCall(UnderwritingHook.initialize, (address(acp), admin))))
        );

        // Deploy Collateral Manager + Coordinator + Evaluator
        collateralManager = new MockCollateralManager(usdc);
        coordinator = new UnderwritingSettlementCoordinator(IAgenticCommerceKernel(address(acp)), hook, collateralManager);

        UnderwritingEvaluator evalImpl = new UnderwritingEvaluator();
        evaluator = UnderwritingEvaluator(
            address(
                new ERC1967Proxy(
                    address(evalImpl),
                    abi.encodeCall(
                        UnderwritingEvaluator.initialize,
                        (address(acp), address(hook), CLIENT_CONFIRM_WINDOW, admin)
                    )
                )
            )
        );

        // Wire ACP (test contract is ACP admin via initialize)
        acp.setHookWhitelist(address(hook), true);

        // Wire hook (admin is hook admin via initialize)
        vm.startPrank(admin);
        hook.setAllowedSettlementToken(address(usdc));
        hook.setWiring(address(evaluator), address(coordinator));
        hook.registerUnderwriter(underwriter);
        vm.stopPrank();

        // Fund actors
        usdc.mint(client, 10_000e6);
        usdc.mint(provider, 10_000e6);

        // Approvals
        vm.prank(client);
        usdc.approve(address(acp), type(uint256).max);
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Happy Path: Open → Close → Success → Collateral Release
    // ─────────────────────────────────────────────────────────────────────────

    function testTwoStageHappyPath() public {
        // ── Step 1: Create and configure root job ──
        vm.prank(client);
        uint256 rootJobId =
            acp.createJob(provider, address(evaluator), block.timestamp + 7 days, "root job", address(hook), 0);

        vm.prank(client);
        acp.setBudget(rootJobId, address(usdc), ROOT_BUDGET, abi.encode(_rootCommit()));

        assertEq(uint256(hook.jobSidecarState(rootJobId)), uint256(UnderwritingTypes.SidecarState.Committed));
        assertEq(hook.jobUnderwriter(rootJobId), underwriter);
        assertEq(hook.jobSettlementJobId(rootJobId), rootJobId);

        // ── Step 2: Fund root job ──
        vm.prank(client);
        acp.fund(rootJobId, ROOT_BUDGET, bytes(""));
        assertEq(uint256(hook.jobSidecarState(rootJobId)), uint256(UnderwritingTypes.SidecarState.FeeEscrowed));

        // ── Step 3: Orchestrate funding (collateral lock + principal release) ──
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), vm.getNonce(address(coordinator)));

        vm.prank(provider);
        usdc.approve(predictedEscrow, COLLATERAL_AMOUNT);
        vm.prank(client);
        usdc.approve(predictedEscrow, PRINCIPAL_AMOUNT);
        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        ICollateralManager.UnderwritePermit memory rootPermit =
            _permit(rootJobId, rootJobId, predictedEscrow, block.timestamp + 3 days);
        coordinator.orchestrateFunding(rootJobId, rootPermit, bytes("permit-sig"));

        assertEq(uint256(hook.jobSidecarState(rootJobId)), uint256(UnderwritingTypes.SidecarState.Protected));
        assertEq(coordinator.settlementEscrow(rootJobId), predictedEscrow);
        assertEq(
            uint256(coordinator.jobSettlementState(rootJobId)),
            uint256(SettlementTypes.SettlementState.PrincipalReleased)
        );
        assertEq(usdc.balanceOf(merchantWallet), PRINCIPAL_AMOUNT);

        // ── Step 4: Provider submits root evidence ──
        UnderwritingTypes.SubmitEvidence memory rootEvidence = _evidence("root-delivery-bundle");
        vm.prank(provider);
        acp.submit(rootJobId, rootEvidence.bundleHash, abi.encode(rootEvidence));
        assertEq(uint256(hook.jobSidecarState(rootJobId)), uint256(UnderwritingTypes.SidecarState.EvidenceSubmitted));

        // ── Step 5: Underwriter completes root job → AwaitingClose ──
        vm.warp(block.timestamp + CLIENT_CONFIRM_WINDOW + 1);
        UnderwritingTypes.CompleteDecision memory rootComplete = UnderwritingTypes.CompleteDecision({
            jobId: rootJobId,
            reason: keccak256("root approved"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: 1
        });
        evaluator.completeBySig(rootComplete, _signComplete(rootComplete, underwriterPk));

        assertEq(uint256(hook.jobSidecarState(rootJobId)), uint256(UnderwritingTypes.SidecarState.AwaitingClose));
        assertTrue(hook.isAwaitingClose(rootJobId));
        assertEq(uint256(acp.getJob(rootJobId).status), uint256(AgenticCommerce.JobStatus.Completed));

        // ── Step 6: Create and configure close job ──
        vm.prank(client);
        uint256 closeJobId =
            acp.createJob(provider, address(evaluator), block.timestamp + 7 days, "close job", address(hook), 0);

        vm.prank(client);
        acp.setBudget(closeJobId, address(usdc), CLOSE_BUDGET, abi.encode(_closeCommit(rootJobId)));

        assertEq(hook.getParentJobId(closeJobId), rootJobId);
        assertEq(hook.getActiveCloseJobId(rootJobId), closeJobId);
        assertEq(hook.jobSettlementJobId(closeJobId), rootJobId, "close job shares root settlement id");

        // ── Step 7: Fund close job ──
        vm.prank(client);
        acp.fund(closeJobId, CLOSE_BUDGET, bytes(""));

        // ── Step 8: Orchestrate close funding (reuses parent escrow, no new collateral) ──
        ICollateralManager.UnderwritePermit memory closePermit =
            _permit(closeJobId, rootJobId, predictedEscrow, block.timestamp + 3 days);
        coordinator.orchestrateFunding(closeJobId, closePermit, bytes("permit-sig"));

        assertEq(coordinator.settlementEscrow(closeJobId), predictedEscrow, "close reuses root escrow");

        // ── Step 9: Provider submits close evidence ──
        UnderwritingTypes.SubmitEvidence memory closeEvidence = _evidence("close-delivery-bundle");
        vm.prank(provider);
        acp.submit(closeJobId, closeEvidence.bundleHash, abi.encode(closeEvidence));

        // ── Step 10: Underwriter completes close job → SuccessPendingConfirmation ──
        vm.warp(block.timestamp + CLIENT_CONFIRM_WINDOW + 1);
        UnderwritingTypes.CompleteDecision memory closeComplete = UnderwritingTypes.CompleteDecision({
            jobId: closeJobId,
            reason: keccak256("close approved"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: 2
        });
        evaluator.completeBySig(closeComplete, _signComplete(closeComplete, underwriterPk));

        assertEq(
            uint256(hook.jobSidecarState(rootJobId)),
            uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation)
        );
        assertEq(
            uint256(hook.jobSidecarState(closeJobId)),
            uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation)
        );
        assertFalse(hook.isAwaitingClose(rootJobId));
        assertEq(hook.getActiveCloseJobId(rootJobId), 0);

        // ── Step 11: Request collateral release (via close job) ──
        coordinator.requestCollateralRelease(closeJobId);
        assertEq(
            uint256(coordinator.jobSettlementState(closeJobId)),
            uint256(SettlementTypes.SettlementState.SuccessPendingRelease)
        );

        // ── Step 12: Wait past unlock, release collateral ──
        vm.warp(block.timestamp + 3 days + 1);
        uint256 providerBalanceBefore = usdc.balanceOf(provider);
        coordinator.releaseCollateral(closeJobId);

        assertTrue(collateralManager.releaseCollateralCalled());
        assertEq(usdc.balanceOf(provider), providerBalanceBefore + COLLATERAL_AMOUNT);
        assertEq(
            uint256(coordinator.jobSettlementState(closeJobId)),
            uint256(SettlementTypes.SettlementState.SuccessSettled)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Dispute Path: Open → Close → Success → Dispute → Slash
    // ─────────────────────────────────────────────────────────────────────────

    function testTwoStageDisputePath() public {
        // ── Steps 1-10: Same as happy path up through close job completion ──
        (uint256 rootJobId, uint256 closeJobId, address escrowAddr) = _completeTwoStageFlow();

        // ── Step 11: Request collateral release ──
        coordinator.requestCollateralRelease(closeJobId);
        assertEq(
            uint256(coordinator.jobSettlementState(closeJobId)),
            uint256(SettlementTypes.SettlementState.SuccessPendingRelease)
        );

        // ── Step 12: Client opens dispute within unlock window ──
        vm.prank(client);
        coordinator.openSuccessDispute(closeJobId, keccak256("merchant did not deliver"));
        assertEq(
            uint256(coordinator.jobSettlementState(closeJobId)),
            uint256(SettlementTypes.SettlementState.DisputeOpen)
        );

        // ── Step 13: Verify collateral release is blocked during dispute ──
        vm.warp(block.timestamp + 3 days + 1);
        vm.expectRevert(UnderwritingSettlementCoordinator.InvalidState.selector);
        coordinator.releaseCollateral(closeJobId);

        // ── Step 14: Underwriter resolves dispute via slash ──
        uint256 slashAmount = 100e6;
        ICollateralManager.SlashAttestation memory attestation = ICollateralManager.SlashAttestation({
            settlementJobId: rootJobId,
            safe: escrowAddr,
            user: client,
            merchant: escrowAddr,
            slashAmountUsdc: slashAmount,
            reasonCode: keccak256("delivery-failure"),
            validUntil: uint64(block.timestamp + 1 days),
            nonce: 99
        });
        bytes memory slashSig = _signSlash(attestation, underwriterPk);

        coordinator.applySuccessDisputeSlash(closeJobId, attestation, slashSig);

        assertTrue(collateralManager.slashCalled());
        assertEq(
            uint256(coordinator.jobSettlementState(closeJobId)),
            uint256(SettlementTypes.SettlementState.RecoverySettled)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Dispute Edge Case: Non-client cannot open dispute
    // ─────────────────────────────────────────────────────────────────────────

    function testDisputeOnlyByClient() public {
        (, uint256 closeJobId,) = _completeTwoStageFlow();

        coordinator.requestCollateralRelease(closeJobId);

        vm.prank(provider);
        vm.expectRevert(UnderwritingSettlementCoordinator.OnlyClient.selector);
        coordinator.openSuccessDispute(closeJobId, keccak256("attempt"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Dispute Edge Case: Dispute after unlock window is too late
    // ─────────────────────────────────────────────────────────────────────────

    function testDisputeAfterUnlockWindowReverts() public {
        (, uint256 closeJobId,) = _completeTwoStageFlow();

        coordinator.requestCollateralRelease(closeJobId);

        vm.warp(block.timestamp + 3 days + 1);

        vm.prank(client);
        vm.expectRevert(UnderwritingSettlementCoordinator.TooLate.selector);
        coordinator.openSuccessDispute(closeJobId, keccak256("too late"));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Reject Path: Open → Close → Reject close → Replace close → Complete
    // ─────────────────────────────────────────────────────────────────────────

    function testTwoStageCloseRejectAndReplacement() public {
        // Complete root job to AwaitingClose
        (uint256 rootJobId, address escrowAddr) = _completeRootJob();

        // Create close job
        vm.prank(client);
        uint256 closeJobId =
            acp.createJob(provider, address(evaluator), block.timestamp + 7 days, "close job", address(hook), 0);
        vm.prank(client);
        acp.setBudget(closeJobId, address(usdc), CLOSE_BUDGET, abi.encode(_closeCommit(rootJobId)));

        assertEq(hook.getActiveCloseJobId(rootJobId), closeJobId);

        // Fund close job
        vm.prank(client);
        acp.fund(closeJobId, CLOSE_BUDGET, bytes(""));

        // Provider submits bad evidence
        UnderwritingTypes.SubmitEvidence memory badEvidence = _evidence("bad-close-evidence");

        ICollateralManager.UnderwritePermit memory closePermit =
            _permit(closeJobId, rootJobId, escrowAddr, block.timestamp + 3 days);
        coordinator.orchestrateFunding(closeJobId, closePermit, bytes("permit-sig"));

        vm.prank(provider);
        acp.submit(closeJobId, badEvidence.bundleHash, abi.encode(badEvidence));

        // Underwriter rejects close job
        vm.warp(block.timestamp + CLIENT_CONFIRM_WINDOW + 1);
        UnderwritingTypes.RejectDecision memory rejectDecision = UnderwritingTypes.RejectDecision({
            jobId: closeJobId,
            reason: keccak256("poor execution"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: 10
        });
        evaluator.rejectBySig(rejectDecision, _signReject(rejectDecision, underwriterPk));

        assertEq(uint256(hook.jobSidecarState(closeJobId)), uint256(UnderwritingTypes.SidecarState.RejectSettled));
        assertEq(hook.getActiveCloseJobId(rootJobId), 0, "linkage cleared on reject");
        assertTrue(hook.isAwaitingClose(rootJobId), "root still awaiting close");

        // Create replacement close job
        vm.prank(client);
        uint256 replaceCloseJobId =
            acp.createJob(provider, address(evaluator), block.timestamp + 7 days, "replacement close", address(hook), 0);
        vm.prank(client);
        acp.setBudget(replaceCloseJobId, address(usdc), CLOSE_BUDGET, abi.encode(_closeCommit(rootJobId)));

        assertEq(hook.getActiveCloseJobId(rootJobId), replaceCloseJobId);
        assertEq(hook.getParentJobId(replaceCloseJobId), rootJobId);

        // Complete replacement close job successfully
        vm.prank(client);
        acp.fund(replaceCloseJobId, CLOSE_BUDGET, bytes(""));

        ICollateralManager.UnderwritePermit memory replacePermit =
            _permit(replaceCloseJobId, rootJobId, escrowAddr, block.timestamp + 3 days);
        coordinator.orchestrateFunding(replaceCloseJobId, replacePermit, bytes("permit-sig"));

        UnderwritingTypes.SubmitEvidence memory goodEvidence = _evidence("good-close-evidence");
        vm.prank(provider);
        acp.submit(replaceCloseJobId, goodEvidence.bundleHash, abi.encode(goodEvidence));

        vm.warp(block.timestamp + CLIENT_CONFIRM_WINDOW + 1);
        UnderwritingTypes.CompleteDecision memory completeDecision = UnderwritingTypes.CompleteDecision({
            jobId: replaceCloseJobId,
            reason: keccak256("replacement approved"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: 11
        });
        evaluator.completeBySig(completeDecision, _signComplete(completeDecision, underwriterPk));

        assertEq(
            uint256(hook.jobSidecarState(rootJobId)),
            uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation)
        );
        assertEq(
            uint256(hook.jobSidecarState(replaceCloseJobId)),
            uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation)
        );
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Helper: Complete both legs of a 2-stage flow
    // ─────────────────────────────────────────────────────────────────────────

    function _completeTwoStageFlow()
        internal
        returns (uint256 rootJobId, uint256 closeJobId, address escrowAddr)
    {
        (rootJobId, escrowAddr) = _completeRootJob();

        // Create and complete close job
        vm.prank(client);
        closeJobId =
            acp.createJob(provider, address(evaluator), block.timestamp + 7 days, "close job", address(hook), 0);
        vm.prank(client);
        acp.setBudget(closeJobId, address(usdc), CLOSE_BUDGET, abi.encode(_closeCommit(rootJobId)));
        vm.prank(client);
        acp.fund(closeJobId, CLOSE_BUDGET, bytes(""));

        ICollateralManager.UnderwritePermit memory closePermit =
            _permit(closeJobId, rootJobId, escrowAddr, block.timestamp + 3 days);
        coordinator.orchestrateFunding(closeJobId, closePermit, bytes("permit-sig"));

        UnderwritingTypes.SubmitEvidence memory closeEvidence = _evidence("close-delivery");
        vm.prank(provider);
        acp.submit(closeJobId, closeEvidence.bundleHash, abi.encode(closeEvidence));

        vm.warp(block.timestamp + CLIENT_CONFIRM_WINDOW + 1);
        UnderwritingTypes.CompleteDecision memory closeComplete = UnderwritingTypes.CompleteDecision({
            jobId: closeJobId,
            reason: keccak256("close approved"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: 2
        });
        evaluator.completeBySig(closeComplete, _signComplete(closeComplete, underwriterPk));
    }

    function _completeRootJob() internal returns (uint256 rootJobId, address escrowAddr) {
        vm.prank(client);
        rootJobId =
            acp.createJob(provider, address(evaluator), block.timestamp + 7 days, "root job", address(hook), 0);
        vm.prank(client);
        acp.setBudget(rootJobId, address(usdc), ROOT_BUDGET, abi.encode(_rootCommit()));
        vm.prank(client);
        acp.fund(rootJobId, ROOT_BUDGET, bytes(""));

        escrowAddr = vm.computeCreateAddress(address(coordinator), vm.getNonce(address(coordinator)));

        vm.prank(provider);
        usdc.approve(escrowAddr, COLLATERAL_AMOUNT);
        vm.prank(client);
        usdc.approve(escrowAddr, PRINCIPAL_AMOUNT);
        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        ICollateralManager.UnderwritePermit memory rootPermit =
            _permit(rootJobId, rootJobId, escrowAddr, block.timestamp + 3 days);
        coordinator.orchestrateFunding(rootJobId, rootPermit, bytes("permit-sig"));

        UnderwritingTypes.SubmitEvidence memory rootEvidence = _evidence("root-delivery");
        vm.prank(provider);
        acp.submit(rootJobId, rootEvidence.bundleHash, abi.encode(rootEvidence));

        vm.warp(block.timestamp + CLIENT_CONFIRM_WINDOW + 1);
        UnderwritingTypes.CompleteDecision memory rootComplete = UnderwritingTypes.CompleteDecision({
            jobId: rootJobId,
            reason: keccak256("root approved"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: 1
        });
        evaluator.completeBySig(rootComplete, _signComplete(rootComplete, underwriterPk));

        assertEq(uint256(hook.jobSidecarState(rootJobId)), uint256(UnderwritingTypes.SidecarState.AwaitingClose));
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Commit / Evidence / Permit Builders
    // ─────────────────────────────────────────────────────────────────────────

    function _rootCommit() internal view returns (UnderwritingTypes.UnderwriteCommit memory) {
        return UnderwritingTypes.UnderwriteCommit({
            parentJobId: 0,
            underwriter: underwriter,
            validUntil: uint64(block.timestamp + 1 days),
            policyHash: keccak256("policy"),
            quoteIdHash: keccak256("quote"),
            termsHash: keccak256("terms"),
            allowCloseJob: true
        });
    }

    function _closeCommit(uint256 parentJobId) internal view returns (UnderwritingTypes.UnderwriteCommit memory) {
        return UnderwritingTypes.UnderwriteCommit({
            parentJobId: parentJobId,
            underwriter: underwriter,
            validUntil: uint64(block.timestamp + 1 days),
            policyHash: keccak256("policy"),
            quoteIdHash: keccak256("quote"),
            termsHash: keccak256("terms"),
            allowCloseJob: false
        });
    }

    function _evidence(string memory label) internal pure returns (UnderwritingTypes.SubmitEvidence memory) {
        return UnderwritingTypes.SubmitEvidence({
            bundleHash: keccak256(bytes(label)),
            policyHash: keccak256("policy"),
            quoteIdHash: keccak256("quote"),
            termsHash: keccak256("terms")
        });
    }

    function _permit(uint256 jobId, uint256 settlementJobId, address escrow, uint256 unlockAt_)
        internal
        view
        returns (ICollateralManager.UnderwritePermit memory)
    {
        return ICollateralManager.UnderwritePermit({
            jobId: jobId,
            settlementJobId: settlementJobId,
            safe: escrow,
            user: client,
            merchant: escrow,
            underwriter: underwriter,
            underwritingPremiumUsdc: PREMIUM_AMOUNT,
            merchantExecutionWallet: merchantWallet,
            requiredCollateralUsdc: COLLATERAL_AMOUNT,
            fundedPrincipalUsdc: PRINCIPAL_AMOUNT,
            coverageCapUsdc: COVERAGE_CAP,
            validUntil: uint64(block.timestamp + 1 days),
            executeUntil: uint64(block.timestamp + 2 days),
            policyHash: keccak256("policy"),
            nonce: jobId,
            unlockAt: uint64(unlockAt_)
        });
    }

    // ─────────────────────────────────────────────────────────────────────────
    // EIP-712 Signature Helpers
    // ─────────────────────────────────────────────────────────────────────────

    function _signComplete(UnderwritingTypes.CompleteDecision memory decision, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _evaluatorDomain(),
                keccak256(abi.encode(COMPLETE_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signReject(UnderwritingTypes.RejectDecision memory decision, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _evaluatorDomain(),
                keccak256(abi.encode(REJECT_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signSlash(ICollateralManager.SlashAttestation memory att, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _coordinatorDomain(),
                keccak256(
                    abi.encode(
                        SLASH_ATTESTATION_TYPEHASH,
                        att.settlementJobId,
                        att.safe,
                        att.user,
                        att.merchant,
                        att.slashAmountUsdc,
                        att.reasonCode,
                        att.validUntil,
                        att.nonce
                    )
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _evaluatorDomain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Underwriting Settlement Evaluator")),
                keccak256(bytes("1")),
                block.chainid,
                address(evaluator)
            )
        );
    }

    function _coordinatorDomain() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Underwriting Settlement Coordinator")),
                keccak256(bytes("1")),
                block.chainid,
                address(coordinator)
            )
        );
    }
}
