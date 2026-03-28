// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@acp/AgenticCommerce.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../contracts/interfaces/IAgenticCommerceKernel.sol";
import "../../contracts/interfaces/ICollateralManager.sol";
import "../../contracts/hooks/underwriting/UnderwritingHook.sol";
import "../../contracts/hooks/underwriting/UnderwritingTypes.sol";
import "../../contracts/settlement/SettlementTypes.sol";
import "../../contracts/settlement/UnderwritingSettlementCoordinator.sol";
import "../../contracts/settlement/UnderwritingSettlementEscrow.sol";
import "../../contracts/settlement/UnderwritingCollateralManager.sol";
import "../../contracts/settlement/UnderwritingEvaluator.sol";
import "../mocks/MockERC20.sol";

/**
 * @title UnderwritingSharedEnvFlowTest
 * @notice End-to-end regression tests that deploy the REAL UnderwritingCollateralManager
 *         (not the mock) and track actual USDC balances through every lifecycle path.
 *
 *         Three scenarios are covered:
 *         1. Client confirms inside the confirmation window -> collateral released to provider.
 *         2. Client does NOT confirm; underwriter rejects -> budget refunded, collateral to recovery.
 *         3. Provider never submits; job times out -> budget refunded, collateral to recovery.
 */
contract UnderwritingSharedEnvFlowTest is Test {
    // ── EIP-712 typehashes ──────────────────────────────────────────────

    bytes32 internal constant COMPLETE_TYPEHASH =
        keccak256("CompleteDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 internal constant REJECT_TYPEHASH =
        keccak256("RejectDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 internal constant UNDERWRITE_PERMIT_TYPEHASH = keccak256(
        "UnderwritePermit(uint256 jobId,uint256 settlementJobId,address safe,address user,address merchant,address underwriter,uint256 underwritingPremiumUsdc,address merchantExecutionWallet,uint256 requiredCollateralUsdc,uint256 fundedPrincipalUsdc,uint256 coverageCapUsdc,uint64 validUntil,uint64 executeUntil,bytes32 policyHash,uint256 nonce,uint64 unlockAt)"
    );
    bytes32 internal constant SLASH_ATTESTATION_TYPEHASH = keccak256(
        "SlashAttestation(uint256 settlementJobId,address safe,address user,address merchant,uint256 slashAmountUsdc,bytes32 reasonCode,uint64 validUntil,uint256 nonce)"
    );

    // ── amounts ─────────────────────────────────────────────────────────

    uint256 internal constant PROVIDER_BUDGET = 40e6;
    uint256 internal constant UNDERWRITING_PREMIUM = 5e6;
    uint256 internal constant FUNDED_PRINCIPAL = 80e6;
    uint256 internal constant REQUIRED_COLLATERAL = 100e6;
    uint256 internal constant COVERAGE_CAP = 250e6;

    // ── timing ──────────────────────────────────────────────────────────

    uint64 internal constant CLIENT_CONFIRM_WINDOW = 1 hours;

    // ── actors ──────────────────────────────────────────────────────────

    address internal treasury = makeAddr("treasury");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal merchantExecutionWallet = makeAddr("merchantExecutionWallet");
    address internal premiumRecipient = makeAddr("premiumRecipient");
    address internal recoveryRecipient = makeAddr("recoveryRecipient");

    uint256 internal underwriterPk;
    address internal underwriter;

    // ── contracts ───────────────────────────────────────────────────────

    MockERC20 internal usdc;
    UnderwritingCollateralManager internal collateralManager;
    AgenticCommerce internal acp;
    UnderwritingHook internal hook;
    UnderwritingSettlementCoordinator internal coordinator;
    UnderwritingEvaluator internal evaluator;

    function setUp() public {
        (underwriter, underwriterPk) = makeAddrAndKey("underwriter");

        // Deploy token and core ACP
        usdc = new MockERC20("Mock USDC", "mUSDC");
        acp = _deployAcp(treasury);

        // Deploy the REAL collateral manager
        collateralManager = new UnderwritingCollateralManager(usdc);

        // Deploy underwriting stack manually so we control CLIENT_CONFIRM_WINDOW
        // admin = address(this) so we can call registerUnderwriter directly
        hook = _deployHook(address(acp), address(this));
        acp.setHookWhitelist(address(hook), true);
        hook.setAllowedSettlementToken(address(usdc));
        coordinator = new UnderwritingSettlementCoordinator(
            IAgenticCommerceKernel(address(acp)),
            hook,
            collateralManager
        );
        evaluator = _deployEvaluator(address(acp), address(hook), CLIENT_CONFIRM_WINDOW, address(this));
        hook.setWiring(address(evaluator), address(coordinator));

        // Register the underwriter
        hook.registerUnderwriter(underwriter);

        // Set underwriter recipients on the real collateral manager
        vm.prank(underwriter);
        collateralManager.setUnderwriterRecipients(premiumRecipient, recoveryRecipient);

        // Mint generous USDC
        usdc.mint(client, 10_000_000e6);
        usdc.mint(provider, 10_000_000e6);
    }

    // ════════════════════════════════════════════════════════════════════
    // Test 1: Client confirmation -> collateral released to provider
    // ════════════════════════════════════════════════════════════════════

    function testClientConfirmationPathPaysPremiumThenCompletesAndReleasesCollateral() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        // ── Create job ──
        vm.startPrank(client);
        uint256 jobId = acp.createJob(
            provider,
            address(evaluator),
            block.timestamp + 1 days,
            "shared env e2e confirm",
            address(hook),
            0
        );
        vm.stopPrank();

        // ── Build commit & permit ──
        UnderwritingTypes.UnderwriteCommit memory commit = _buildCommit(0, false);
        ICollateralManager.UnderwritePermit memory permit =
            _buildPermit(jobId, client, predictedEscrow, commit, 7, 0);

        // ── Approve & fund ──
        vm.startPrank(client);
        usdc.approve(address(acp), PROVIDER_BUDGET);
        usdc.approve(address(collateralManager), UNDERWRITING_PREMIUM);
        usdc.approve(predictedEscrow, FUNDED_PRINCIPAL);
        acp.setBudget(jobId, address(usdc), PROVIDER_BUDGET, abi.encode(commit));
        acp.fund(jobId, PROVIDER_BUDGET, bytes(""));
        vm.stopPrank();

        vm.prank(provider);
        usdc.approve(predictedEscrow, REQUIRED_COLLATERAL);

        // ── Record balances ──
        uint256 premiumRecipientBefore = usdc.balanceOf(premiumRecipient);
        uint256 merchantWalletBefore = usdc.balanceOf(merchantExecutionWallet);

        // ── Orchestrate funding (with real EIP-712 signed permit) ──
        bytes memory permitSig = _signPermit(permit);
        coordinator.orchestrateFunding(jobId, permit, permitSig);

        // Assert premium paid immediately to premiumRecipient
        assertEq(
            usdc.balanceOf(premiumRecipient) - premiumRecipientBefore,
            UNDERWRITING_PREMIUM,
            "premium not paid to recipient"
        );
        // Assert funded principal released to merchantExecutionWallet
        assertEq(
            usdc.balanceOf(merchantExecutionWallet) - merchantWalletBefore,
            FUNDED_PRINCIPAL,
            "principal not released to merchant"
        );

        // ── Provider submits evidence on time ──
        UnderwritingTypes.SubmitEvidence memory evidence = _evidence(commit, "bundle");
        vm.prank(provider);
        acp.submit(jobId, evidence.bundleHash, abi.encode(evidence));

        // ── Client confirms inside the confirmation window ──
        vm.prank(client);
        evaluator.confirmByClient(jobId, keccak256("client-happy"));

        // Verify job completed and ACP budget released to provider
        AgenticCommerce.Job memory job = acp.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgenticCommerce.JobStatus.Completed), "job not completed");
        assertEq(
            uint256(hook.jobSidecarState(jobId)),
            uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation),
            "wrong sidecar state"
        );

        // ── Release collateral (unlockAt from permit is 0; no dispute window) ──
        uint256 providerBefore = usdc.balanceOf(provider);
        coordinator.requestCollateralRelease(jobId);
        coordinator.releaseCollateral(jobId);

        // Assert collateral returned to provider
        assertEq(
            usdc.balanceOf(provider) - providerBefore,
            REQUIRED_COLLATERAL,
            "collateral not returned to provider"
        );
        assertEq(
            uint256(coordinator.jobSettlementState(jobId)),
            uint256(SettlementTypes.SettlementState.SuccessSettled),
            "settlement not finalized"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Test 2: Underwriter reject after confirmation window -> recovery
    // ════════════════════════════════════════════════════════════════════

    function testUnderwriterRejectPathAfterConfirmationWindowRoutesCollateralToRecovery() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        // ── Create job ──
        vm.startPrank(client);
        uint256 jobId = acp.createJob(
            provider,
            address(evaluator),
            block.timestamp + 1 days,
            "shared env e2e reject",
            address(hook),
            0
        );
        vm.stopPrank();

        // ── Fund and orchestrate ──
        UnderwritingTypes.UnderwriteCommit memory commit = _buildCommit(0, false);
        _fundAndOrchestrateJob(jobId, commit, 7, 0, predictedEscrow);

        // ── Provider submits on time ──
        UnderwritingTypes.SubmitEvidence memory evidence = _evidence(commit, "bundle");
        vm.prank(provider);
        acp.submit(jobId, evidence.bundleHash, abi.encode(evidence));

        // ── Client does NOT confirm — warp past confirmation window ──
        vm.warp(block.timestamp + uint256(CLIENT_CONFIRM_WINDOW) + 1);

        // ── Record balances ──
        uint256 clientBefore = usdc.balanceOf(client);
        uint256 recoveryBefore = usdc.balanceOf(recoveryRecipient);

        // ── Underwriter rejects by signature ──
        UnderwritingTypes.RejectDecision memory decision = UnderwritingTypes.RejectDecision({
            jobId: jobId,
            reason: keccak256("underwriter-reject"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: 11
        });
        evaluator.rejectBySig(decision, _signRejectDecision(decision));

        // ACP budget refunded to client
        assertEq(usdc.balanceOf(client) - clientBefore, PROVIDER_BUDGET, "budget not refunded to client");

        // Job should be rejected
        AgenticCommerce.Job memory job = acp.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgenticCommerce.JobStatus.Rejected), "job not rejected");

        // ── Finalize rejected job — collateral goes to recoveryRecipient ──
        coordinator.finalizeRejectedJob(jobId);

        assertEq(
            usdc.balanceOf(recoveryRecipient) - recoveryBefore,
            REQUIRED_COLLATERAL,
            "collateral not sent to recovery"
        );
        assertEq(
            uint256(coordinator.jobSettlementState(jobId)),
            uint256(SettlementTypes.SettlementState.RejectSettled),
            "settlement not finalized as reject"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Test 3: Pre-submit timeout -> budget refund + collateral to recovery
    // ════════════════════════════════════════════════════════════════════

    function testPreSubmitTimeoutRefundsBudgetAndRoutesCollateralToRecovery() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        // ── Create job ──
        vm.startPrank(client);
        uint256 jobId = acp.createJob(
            provider,
            address(evaluator),
            block.timestamp + 1 days,
            "shared env e2e timeout",
            address(hook),
            0
        );
        vm.stopPrank();

        // ── Fund and orchestrate — do NOT submit ──
        UnderwritingTypes.UnderwriteCommit memory commit = _buildCommit(0, false);
        _fundAndOrchestrateJob(jobId, commit, 7, 0, predictedEscrow);

        // Verify sidecar state is Protected
        assertEq(
            uint256(hook.jobSidecarState(jobId)),
            uint256(UnderwritingTypes.SidecarState.Protected),
            "should be protected"
        );

        // ── Warp past expiredAt ──
        vm.warp(block.timestamp + 1 days + 1);

        // ── Client claims refund ──
        // claimRefund is NOT hookable. Since provider never submitted (submittedAt=0),
        // the hooked-job guard does not block the refund.
        uint256 clientBefore = usdc.balanceOf(client);
        vm.prank(client);
        acp.claimRefund(jobId);

        assertEq(usdc.balanceOf(client) - clientBefore, PROVIDER_BUDGET, "budget not refunded");
        AgenticCommerce.Job memory job = acp.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgenticCommerce.JobStatus.Expired), "job not expired");

        // ── Settle expiry — collateral goes to recoveryRecipient ──
        uint256 recoveryBefore = usdc.balanceOf(recoveryRecipient);
        coordinator.settleExpiry(jobId);

        assertEq(
            usdc.balanceOf(recoveryRecipient) - recoveryBefore,
            REQUIRED_COLLATERAL,
            "collateral not sent to recovery"
        );
        assertEq(
            uint256(coordinator.jobSettlementState(jobId)),
            uint256(SettlementTypes.SettlementState.ExpirySettled),
            "settlement not finalized as expiry"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Test 4: Success -> dispute slash -> collateral to recovery
    // ════════════════════════════════════════════════════════════════════

    function testSuccessDisputeSlashRoutesCollateralToRecovery() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        vm.startPrank(client);
        uint256 jobId = acp.createJob(
            provider,
            address(evaluator),
            block.timestamp + 1 days,
            "shared env e2e dispute slash",
            address(hook),
            0
        );
        vm.stopPrank();

        UnderwritingTypes.UnderwriteCommit memory commit = _buildCommit(0, false);
        _fundAndOrchestrateJob(jobId, commit, 7, 1 hours, predictedEscrow);

        UnderwritingTypes.SubmitEvidence memory evidence = _evidence(commit, "bundle");
        vm.prank(provider);
        acp.submit(jobId, evidence.bundleHash, abi.encode(evidence));

        vm.prank(client);
        evaluator.confirmByClient(jobId, keccak256("client-happy"));

        AgenticCommerce.Job memory job = acp.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgenticCommerce.JobStatus.Completed), "job not completed");

        vm.prank(provider);
        coordinator.requestCollateralRelease(jobId);
        vm.prank(client);
        coordinator.openSuccessDispute(jobId, keccak256("success-dispute"));

        uint256 recoveryBefore = usdc.balanceOf(recoveryRecipient);
        uint256 providerBefore = usdc.balanceOf(provider);

        ICollateralManager.SlashAttestation memory attestation = ICollateralManager.SlashAttestation({
            settlementJobId: jobId,
            safe: predictedEscrow,
            user: client,
            merchant: predictedEscrow,
            slashAmountUsdc: REQUIRED_COLLATERAL,
            reasonCode: keccak256("dispute-reason"),
            validUntil: uint64(block.timestamp + 1 days),
            nonce: 42
        });

        bytes memory slashSig = _signSlashAttestation(attestation);
        coordinator.applySuccessDisputeSlash(jobId, attestation, slashSig);

        assertEq(
            usdc.balanceOf(recoveryRecipient) - recoveryBefore,
            REQUIRED_COLLATERAL,
            "collateral not sent to recovery"
        );
        assertEq(usdc.balanceOf(provider), providerBefore, "provider should receive nothing on full slash");
        assertEq(
            uint256(coordinator.jobSettlementState(jobId)),
            uint256(SettlementTypes.SettlementState.RecoverySettled),
            "settlement not finalized as recovery"
        );
    }

    // ════════════════════════════════════════════════════════════════════
    // Test 5: Funding semantics — budget in ACP, premium to recipient,
    //         manager holds no premium
    // ════════════════════════════════════════════════════════════════════

    function testFundingSemanticsShowPremiumImmediatelyRoutedAndBudgetStaysInACP() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        vm.startPrank(client);
        uint256 jobId = acp.createJob(
            provider,
            address(evaluator),
            block.timestamp + 1 days,
            "shared env funding semantics",
            address(hook),
            0
        );
        vm.stopPrank();

        UnderwritingTypes.UnderwriteCommit memory commit = _buildCommit(0, false);

        uint256 acpBefore = usdc.balanceOf(address(acp));
        uint256 premiumRecipientBefore = usdc.balanceOf(premiumRecipient);
        uint256 managerBefore = usdc.balanceOf(address(collateralManager));

        _fundAndOrchestrateJob(jobId, commit, 7, 0, predictedEscrow);

        assertEq(
            usdc.balanceOf(address(acp)) - acpBefore,
            PROVIDER_BUDGET,
            "job.budget should stay in ACP path"
        );
        assertEq(
            usdc.balanceOf(premiumRecipient) - premiumRecipientBefore,
            UNDERWRITING_PREMIUM,
            "premium should go immediately to premiumRecipient"
        );
        assertEq(
            usdc.balanceOf(address(collateralManager)) - managerBefore,
            REQUIRED_COLLATERAL,
            "manager should hold only collateral, not premium"
        );
    }

    function testSlashRevertsWithoutOpenDispute() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        vm.startPrank(client);
        uint256 jobId = acp.createJob(
            provider,
            address(evaluator),
            block.timestamp + 1 days,
            "slash without dispute",
            address(hook),
            0
        );
        vm.stopPrank();

        UnderwritingTypes.UnderwriteCommit memory commit = _buildCommit(0, false);
        _fundAndOrchestrateJob(jobId, commit, 7, 1 hours, predictedEscrow);

        UnderwritingTypes.SubmitEvidence memory evidence = _evidence(commit, "bundle");
        vm.prank(provider);
        acp.submit(jobId, evidence.bundleHash, abi.encode(evidence));

        vm.prank(client);
        evaluator.confirmByClient(jobId, keccak256("client-happy"));

        vm.prank(provider);
        coordinator.requestCollateralRelease(jobId);

        ICollateralManager.SlashAttestation memory attestation = ICollateralManager.SlashAttestation({
            settlementJobId: jobId,
            safe: predictedEscrow,
            user: client,
            merchant: predictedEscrow,
            slashAmountUsdc: REQUIRED_COLLATERAL,
            reasonCode: keccak256("dispute-reason"),
            validUntil: uint64(block.timestamp + 1 days),
            nonce: 99
        });
        bytes memory slashSig = _signSlashAttestation(attestation);

        vm.expectRevert(UnderwritingSettlementCoordinator.InvalidState.selector);
        coordinator.applySuccessDisputeSlash(jobId, attestation, slashSig);
    }

    function testOpenDisputeRevertsAfterUnlockAt() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        vm.startPrank(client);
        uint256 jobId = acp.createJob(
            provider,
            address(evaluator),
            block.timestamp + 1 days,
            "dispute too late",
            address(hook),
            0
        );
        vm.stopPrank();

        UnderwritingTypes.UnderwriteCommit memory commit = _buildCommit(0, false);
        _fundAndOrchestrateJob(jobId, commit, 7, 1 hours, predictedEscrow);

        UnderwritingTypes.SubmitEvidence memory evidence = _evidence(commit, "bundle");
        vm.prank(provider);
        acp.submit(jobId, evidence.bundleHash, abi.encode(evidence));

        vm.prank(client);
        evaluator.confirmByClient(jobId, keccak256("client-happy"));

        vm.prank(provider);
        coordinator.requestCollateralRelease(jobId);

        vm.warp(block.timestamp + uint256(1 hours) + 1);

        vm.expectRevert(UnderwritingSettlementCoordinator.TooLate.selector);
        vm.prank(client);
        coordinator.openSuccessDispute(jobId, keccak256("success-dispute"));
    }

    function testReleaseRevertsWhenDisputeOpen() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        vm.startPrank(client);
        uint256 jobId = acp.createJob(
            provider,
            address(evaluator),
            block.timestamp + 1 days,
            "release blocked dispute",
            address(hook),
            0
        );
        vm.stopPrank();

        UnderwritingTypes.UnderwriteCommit memory commit = _buildCommit(0, false);
        _fundAndOrchestrateJob(jobId, commit, 7, 1 hours, predictedEscrow);

        UnderwritingTypes.SubmitEvidence memory evidence = _evidence(commit, "bundle");
        vm.prank(provider);
        acp.submit(jobId, evidence.bundleHash, abi.encode(evidence));

        vm.prank(client);
        evaluator.confirmByClient(jobId, keccak256("client-happy"));

        vm.prank(provider);
        coordinator.requestCollateralRelease(jobId);
        vm.prank(client);
        coordinator.openSuccessDispute(jobId, keccak256("success-dispute"));

        vm.warp(block.timestamp + uint256(1 hours) + 1);

        vm.expectRevert(UnderwritingSettlementCoordinator.InvalidState.selector);
        coordinator.releaseCollateral(jobId);
    }

    // ════════════════════════════════════════════════════════════════════
    // Internal helpers
    // ════════════════════════════════════════════════════════════════════

    function _buildCommit(uint256 parentJobId, bool allowCloseJob)
        internal
        view
        returns (UnderwritingTypes.UnderwriteCommit memory)
    {
        return UnderwritingTypes.UnderwriteCommit({
            parentJobId: parentJobId,
            underwriter: underwriter,
            validUntil: uint64(block.timestamp) + 1 days,
            policyHash: keccak256("policy"),
            quoteIdHash: keccak256("quote"),
            termsHash: keccak256("terms"),
            allowCloseJob: allowCloseJob
        });
    }

    function _buildPermit(
        uint256 jobId,
        address client_,
        address escrow,
        UnderwritingTypes.UnderwriteCommit memory commit,
        uint256 nonce,
        uint64 unlockIn
    ) internal view returns (ICollateralManager.UnderwritePermit memory) {
        uint256 settlementJobId_ = commit.parentJobId != 0 ? commit.parentJobId : jobId;
        return ICollateralManager.UnderwritePermit({
            jobId: jobId,
            settlementJobId: settlementJobId_,
            safe: escrow,
            user: client_,
            merchant: escrow,
            underwriter: commit.underwriter,
            underwritingPremiumUsdc: UNDERWRITING_PREMIUM,
            merchantExecutionWallet: merchantExecutionWallet,
            requiredCollateralUsdc: REQUIRED_COLLATERAL,
            fundedPrincipalUsdc: FUNDED_PRINCIPAL,
            coverageCapUsdc: COVERAGE_CAP,
            validUntil: commit.validUntil,
            executeUntil: uint64(block.timestamp) + 2 days,
            policyHash: commit.policyHash,
            nonce: nonce,
            unlockAt: uint64(block.timestamp) + unlockIn
        });
    }

    function _evidence(UnderwritingTypes.UnderwriteCommit memory commit, string memory bundleLabel)
        internal
        pure
        returns (UnderwritingTypes.SubmitEvidence memory)
    {
        return UnderwritingTypes.SubmitEvidence({
            bundleHash: keccak256(bytes(bundleLabel)),
            policyHash: commit.policyHash,
            quoteIdHash: commit.quoteIdHash,
            termsHash: commit.termsHash
        });
    }

    function _fundAndOrchestrateJob(
        uint256 jobId,
        UnderwritingTypes.UnderwriteCommit memory commit,
        uint256 nonce,
        uint64 unlockIn,
        address predictedEscrow
    ) internal {
        vm.startPrank(client);
        usdc.approve(address(acp), PROVIDER_BUDGET);
        if (commit.parentJobId == 0) {
            usdc.approve(address(collateralManager), UNDERWRITING_PREMIUM);
            usdc.approve(predictedEscrow, FUNDED_PRINCIPAL);
        }
        acp.setBudget(jobId, address(usdc), PROVIDER_BUDGET, abi.encode(commit));
        acp.fund(jobId, PROVIDER_BUDGET, bytes(""));
        vm.stopPrank();

        ICollateralManager.UnderwritePermit memory permit =
            _buildPermit(jobId, client, predictedEscrow, commit, nonce, unlockIn);

        if (commit.parentJobId == 0) {
            vm.prank(provider);
            usdc.approve(predictedEscrow, REQUIRED_COLLATERAL);
        }

        bytes memory permitSig = _signPermit(permit);
        coordinator.orchestrateFunding(jobId, permit, permitSig);
    }

    // ── EIP-712 signing helpers ─────────────────────────────────────────

    function _signPermit(ICollateralManager.UnderwritePermit memory permit) internal view returns (bytes memory) {
        bytes32 structHash = keccak256(
            abi.encode(
                UNDERWRITE_PERMIT_TYPEHASH,
                permit.jobId,
                permit.settlementJobId,
                permit.safe,
                permit.user,
                permit.merchant,
                permit.underwriter,
                permit.underwritingPremiumUsdc,
                permit.merchantExecutionWallet,
                permit.requiredCollateralUsdc,
                permit.fundedPrincipalUsdc,
                permit.coverageCapUsdc,
                permit.validUntil,
                permit.executeUntil,
                permit.policyHash,
                permit.nonce,
                permit.unlockAt
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _collateralManagerDomainSeparator(), structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(underwriterPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signCompleteDecision(UnderwritingTypes.CompleteDecision memory decision)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _evaluatorDomainSeparator(),
                keccak256(
                    abi.encode(COMPLETE_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce)
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(underwriterPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signRejectDecision(UnderwritingTypes.RejectDecision memory decision)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _evaluatorDomainSeparator(),
                keccak256(
                    abi.encode(REJECT_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce)
                )
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(underwriterPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _evaluatorDomainSeparator() internal view returns (bytes32) {
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

    function _collateralManagerDomainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Underwriting Collateral Manager")),
                keccak256(bytes("1")),
                block.chainid,
                address(collateralManager)
            )
        );
    }

    function _signSlashAttestation(ICollateralManager.SlashAttestation memory attestation)
        internal
        view
        returns (bytes memory)
    {
        bytes32 structHash = keccak256(
            abi.encode(
                SLASH_ATTESTATION_TYPEHASH,
                attestation.settlementJobId,
                attestation.safe,
                attestation.user,
                attestation.merchant,
                attestation.slashAmountUsdc,
                attestation.reasonCode,
                attestation.validUntil,
                attestation.nonce
            )
        );

        bytes32 digest = keccak256(
            abi.encodePacked("\x19\x01", _coordinatorDomainSeparator(), structHash)
        );

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(underwriterPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _coordinatorDomainSeparator() internal view returns (bytes32) {
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

    function _deployAcp(address treasury_) internal returns (AgenticCommerce) {
        AgenticCommerce implementation = new AgenticCommerce();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), abi.encodeCall(AgenticCommerce.initialize, (treasury_)));
        return AgenticCommerce(address(proxy));
    }

    function _deployHook(address acp_, address admin_) internal returns (UnderwritingHook) {
        UnderwritingHook implementation = new UnderwritingHook();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(UnderwritingHook.initialize, (acp_, admin_)));
        return UnderwritingHook(address(proxy));
    }

    function _deployEvaluator(address acp_, address hook_, uint64 clientConfirmationWindowSeconds_, address admin_)
        internal
        returns (UnderwritingEvaluator)
    {
        UnderwritingEvaluator implementation = new UnderwritingEvaluator();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(UnderwritingEvaluator.initialize, (acp_, hook_, clientConfirmationWindowSeconds_, admin_))
        );
        return UnderwritingEvaluator(address(proxy));
    }
}
