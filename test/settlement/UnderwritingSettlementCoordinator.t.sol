// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/interfaces/IAgenticCommerceKernel.sol";
import "../../contracts/interfaces/ICollateralManager.sol";
import "../../contracts/hooks/underwriting/UnderwritingHook.sol";
import "../../contracts/hooks/underwriting/UnderwritingTypes.sol";
import "../../contracts/settlement/SettlementTypes.sol";
import "../../contracts/settlement/UnderwritingSettlementCoordinator.sol";
import "../../contracts/settlement/UnderwritingSettlementEscrow.sol";
import "../mocks/MockCollateralManager.sol";
import "../mocks/MockERC20.sol";

contract MockSettlementACP is IAgenticCommerceKernel {
    address public paymentToken;
    mapping(uint256 jobId => Job) internal jobs;

    constructor(address paymentToken_) {
        paymentToken = paymentToken_;
    }

    function setJob(Job memory job_) external {
        jobs[job_.id] = job_;
    }

    function getJob(uint256 jobId) external view override returns (Job memory) {
        return jobs[jobId];
    }

    function getJobKind(uint256) external pure override returns (JobKind) {
        return JobKind.Standalone;
    }

    function getParentJobId(uint256) external pure override returns (uint256) {
        return 0;
    }

    function getCloseJobId(uint256) external pure override returns (uint256) {
        return 0;
    }

    function setProvider(uint256, address, uint256) external pure override {
        revert("unused");
    }

    function setBudget(uint256, address, uint256, bytes calldata) external pure override {
        revert("unused");
    }

    function fund(uint256, uint256, bytes calldata) external pure override {
        revert("unused");
    }

    function submit(uint256, bytes32, bytes calldata) external pure override {
        revert("unused");
    }

    function complete(uint256, bytes32, bytes calldata) external pure override {
        revert("unused");
    }

    function reject(uint256, bytes32, bytes calldata) external pure override {
        revert("unused");
    }
}

contract MockUnderwritingHook {
    bool public markProtectedCalled;
    uint256 public lastMarkedJobId;
    address public evaluator;
    address public allowedSettlementToken;

    mapping(uint256 jobId => UnderwritingTypes.SidecarState) internal sidecarStates;
    mapping(uint256 jobId => bool) internal awaitingCloseByJobId;
    mapping(uint256 jobId => UnderwritingTypes.UnderwriteCommit) internal commits;
    mapping(uint256 jobId => uint256) internal settlementJobIds;

    function setEvaluator(address evaluator_) external {
        evaluator = evaluator_;
    }

    function setAllowedSettlementToken(address allowedSettlementToken_) external {
        allowedSettlementToken = allowedSettlementToken_;
    }

    function seedJob(
        uint256 jobId,
        UnderwritingTypes.SidecarState sidecarState,
        UnderwritingTypes.UnderwriteCommit calldata commit,
        uint256 settlementJobId
    ) external {
        sidecarStates[jobId] = sidecarState;
        awaitingCloseByJobId[jobId] = sidecarState == UnderwritingTypes.SidecarState.AwaitingClose;
        commits[jobId] = commit;
        settlementJobIds[jobId] = settlementJobId;
    }

    function setSidecarState(uint256 jobId, UnderwritingTypes.SidecarState sidecarState) external {
        sidecarStates[jobId] = sidecarState;
        awaitingCloseByJobId[jobId] = sidecarState == UnderwritingTypes.SidecarState.AwaitingClose;
    }

    function getCommit(uint256 jobId) external view returns (UnderwritingTypes.UnderwriteCommit memory) {
        return commits[jobId];
    }

    function jobSidecarState(uint256 jobId) external view returns (UnderwritingTypes.SidecarState) {
        return sidecarStates[jobId];
    }

    function jobSettlementJobId(uint256 jobId) external view returns (uint256) {
        return settlementJobIds[jobId];
    }

    function isAwaitingClose(uint256 jobId) external view returns (bool) {
        return awaitingCloseByJobId[jobId];
    }

    function markProtected(uint256 jobId) external {
        markProtectedCalled = true;
        lastMarkedJobId = jobId;
        sidecarStates[jobId] = UnderwritingTypes.SidecarState.Protected;
    }
}

contract UnderwritingSettlementCoordinatorTest is Test {
    uint256 internal constant ROOT_JOB_ID = 1;
    uint256 internal constant CLOSE_JOB_ID = 2;
    uint256 internal constant COLLATERAL_AMOUNT = 100e18;
    uint256 internal constant PRINCIPAL_AMOUNT = 80e18;
    uint256 internal constant PREMIUM_AMOUNT = 5e18;
    uint256 internal constant PROVIDER_BUDGET = 40e18;

    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal evaluatorAddr = makeAddr("evaluator");
    address internal underwriter = makeAddr("underwriter");
    address internal merchantExecutionWallet = makeAddr("merchantExecutionWallet");
    address internal otherToken = makeAddr("otherToken");

    MockERC20 internal usdc;
    MockCollateralManager internal collateralManager;
    MockSettlementACP internal acp;
    MockUnderwritingHook internal hook;
    UnderwritingSettlementCoordinator internal coordinator;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        collateralManager = new MockCollateralManager(usdc);
        acp = new MockSettlementACP(address(usdc));
        hook = new MockUnderwritingHook();
        coordinator =
            new UnderwritingSettlementCoordinator(acp, UnderwritingHook(address(hook)), collateralManager);
        hook.setEvaluator(evaluatorAddr);
        hook.setAllowedSettlementToken(address(usdc));

        usdc.mint(client, 1_000e18);
        usdc.mint(provider, 1_000e18);
    }

    function testOrchestrateFundingCreatesEscrowAndMarksProtectedForRootJob() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        hook.seedJob(ROOT_JOB_ID, UnderwritingTypes.SidecarState.FeeEscrowed, _commit(0), ROOT_JOB_ID);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Funded));

        vm.prank(provider);
        usdc.approve(predictedEscrow, COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(predictedEscrow, PRINCIPAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        coordinator.orchestrateFunding(ROOT_JOB_ID, _permit(ROOT_JOB_ID, ROOT_JOB_ID, predictedEscrow), bytes("permit-sig"));

        assertTrue(hook.markProtectedCalled());
        assertEq(hook.lastMarkedJobId(), ROOT_JOB_ID);
        assertEq(coordinator.settlementEscrow(ROOT_JOB_ID), predictedEscrow);
        assertEq(
            uint256(coordinator.jobSettlementState(ROOT_JOB_ID)),
            uint256(SettlementTypes.SettlementState.PrincipalReleased)
        );
        assertTrue(collateralManager.lockCollateralCalled());
        assertTrue(collateralManager.releasePrincipalCalled());
        assertEq(usdc.balanceOf(address(collateralManager)), COLLATERAL_AMOUNT + PREMIUM_AMOUNT);
        assertEq(usdc.balanceOf(merchantExecutionWallet), PRINCIPAL_AMOUNT);
    }

    function testOrchestrateFundingRevertsForUnsupportedSettlementTokenBeforeEscrowCreation() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        hook.seedJob(ROOT_JOB_ID, UnderwritingTypes.SidecarState.FeeEscrowed, _commit(0), ROOT_JOB_ID);
        acp.setJob(_jobWithToken(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Funded, otherToken));

        vm.expectRevert(UnderwritingSettlementCoordinator.UnsupportedSettlementToken.selector);
        coordinator.orchestrateFunding(ROOT_JOB_ID, _permit(ROOT_JOB_ID, ROOT_JOB_ID, predictedEscrow), bytes("permit-sig"));

        assertFalse(hook.markProtectedCalled());
        assertFalse(collateralManager.lockCollateralCalled());
        assertEq(coordinator.settlementEscrow(ROOT_JOB_ID), address(0));
        assertEq(uint256(coordinator.jobSettlementState(ROOT_JOB_ID)), uint256(SettlementTypes.SettlementState.None));
    }

    function testCloseOrchestrateFundingReusesParentSettlementIdentityWithoutFreshCollateralPull() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        hook.seedJob(ROOT_JOB_ID, UnderwritingTypes.SidecarState.FeeEscrowed, _commit(0), ROOT_JOB_ID);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Funded));

        vm.prank(provider);
        usdc.approve(predictedEscrow, COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(predictedEscrow, PRINCIPAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        coordinator.orchestrateFunding(ROOT_JOB_ID, _permit(ROOT_JOB_ID, ROOT_JOB_ID, predictedEscrow), bytes("permit-sig"));

        uint256 providerBalanceBefore = usdc.balanceOf(provider);
        uint256 clientBalanceBefore = usdc.balanceOf(client);
        uint256 collateralManagerBalanceBefore = usdc.balanceOf(address(collateralManager));
        uint256 merchantBalanceBefore = usdc.balanceOf(merchantExecutionWallet);

        hook.markProtectedCalled();
        hook.seedJob(CLOSE_JOB_ID, UnderwritingTypes.SidecarState.FeeEscrowed, _commit(ROOT_JOB_ID), ROOT_JOB_ID);
        acp.setJob(_job(CLOSE_JOB_ID, IAgenticCommerceKernel.JobStatus.Funded));

        coordinator.orchestrateFunding(CLOSE_JOB_ID, _permit(CLOSE_JOB_ID, ROOT_JOB_ID, predictedEscrow), bytes("permit-sig"));

        assertEq(coordinator.settlementEscrow(CLOSE_JOB_ID), predictedEscrow);
        assertEq(
            uint256(coordinator.jobSettlementState(CLOSE_JOB_ID)),
            uint256(SettlementTypes.SettlementState.None)
        );
        assertEq(usdc.balanceOf(provider), providerBalanceBefore);
        assertEq(usdc.balanceOf(client), clientBalanceBefore);
        assertEq(usdc.balanceOf(address(collateralManager)), collateralManagerBalanceBefore);
        assertEq(usdc.balanceOf(merchantExecutionWallet), merchantBalanceBefore);
    }

    function testSettleExpiryClaimsTimeoutForProtectedRootJob() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        hook.seedJob(ROOT_JOB_ID, UnderwritingTypes.SidecarState.FeeEscrowed, _commit(0), ROOT_JOB_ID);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Funded));

        vm.prank(provider);
        usdc.approve(predictedEscrow, COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(predictedEscrow, PRINCIPAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        coordinator.orchestrateFunding(ROOT_JOB_ID, _permit(ROOT_JOB_ID, ROOT_JOB_ID, predictedEscrow), bytes("permit-sig"));

        hook.setSidecarState(ROOT_JOB_ID, UnderwritingTypes.SidecarState.Protected);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Expired));

        coordinator.settleExpiry(ROOT_JOB_ID);

        assertTrue(collateralManager.claimTimeoutCalled());
        assertEq(
            uint256(coordinator.jobSettlementState(ROOT_JOB_ID)),
            uint256(SettlementTypes.SettlementState.ExpirySettled)
        );
    }

    function testSettleExpiryRevertsWhenAlreadySettled() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        hook.seedJob(ROOT_JOB_ID, UnderwritingTypes.SidecarState.FeeEscrowed, _commit(0), ROOT_JOB_ID);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Funded));

        vm.prank(provider);
        usdc.approve(predictedEscrow, COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(predictedEscrow, PRINCIPAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        coordinator.orchestrateFunding(ROOT_JOB_ID, _permit(ROOT_JOB_ID, ROOT_JOB_ID, predictedEscrow), bytes("permit-sig"));

        hook.setSidecarState(ROOT_JOB_ID, UnderwritingTypes.SidecarState.Protected);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Expired));

        coordinator.settleExpiry(ROOT_JOB_ID);

        vm.expectRevert(UnderwritingSettlementCoordinator.InvalidState.selector);
        coordinator.settleExpiry(ROOT_JOB_ID);
    }

    function testSettleExpiryForCloseJobSkipsTimeoutClaim() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        hook.seedJob(ROOT_JOB_ID, UnderwritingTypes.SidecarState.FeeEscrowed, _commit(0), ROOT_JOB_ID);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Funded));

        vm.prank(provider);
        usdc.approve(predictedEscrow, COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(predictedEscrow, PRINCIPAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        coordinator.orchestrateFunding(ROOT_JOB_ID, _permit(ROOT_JOB_ID, ROOT_JOB_ID, predictedEscrow), bytes("permit-sig"));

        hook.seedJob(CLOSE_JOB_ID, UnderwritingTypes.SidecarState.Protected, _commit(ROOT_JOB_ID), ROOT_JOB_ID);
        acp.setJob(_job(CLOSE_JOB_ID, IAgenticCommerceKernel.JobStatus.Expired));

        coordinator.settleExpiry(CLOSE_JOB_ID);

        assertFalse(collateralManager.claimTimeoutCalled());
        assertEq(
            uint256(coordinator.jobSettlementState(CLOSE_JOB_ID)),
            uint256(SettlementTypes.SettlementState.ExpirySettled)
        );
    }

    function testFinalizeRejectedJobRoutesCollateralToRecovery() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        hook.seedJob(ROOT_JOB_ID, UnderwritingTypes.SidecarState.FeeEscrowed, _commit(0), ROOT_JOB_ID);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Funded));

        vm.prank(provider);
        usdc.approve(predictedEscrow, COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(predictedEscrow, PRINCIPAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        coordinator.orchestrateFunding(ROOT_JOB_ID, _permit(ROOT_JOB_ID, ROOT_JOB_ID, predictedEscrow), bytes("permit-sig"));

        hook.setSidecarState(ROOT_JOB_ID, UnderwritingTypes.SidecarState.RejectSettled);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Rejected));

        coordinator.finalizeRejectedJob(ROOT_JOB_ID);

        assertTrue(collateralManager.claimTimeoutCalled());
        assertEq(collateralManager.lastTimeoutSettlementJobId(), ROOT_JOB_ID);
        assertEq(
            uint256(coordinator.jobSettlementState(ROOT_JOB_ID)),
            uint256(SettlementTypes.SettlementState.RejectSettled)
        );
    }

    function _job(uint256 jobId, IAgenticCommerceKernel.JobStatus status_)
        internal
        view
        returns (IAgenticCommerceKernel.Job memory)
    {
        return _jobWithToken(jobId, status_, acp.paymentToken());
    }

    function _jobWithToken(uint256 jobId, IAgenticCommerceKernel.JobStatus status_, address paymentToken_)
        internal
        view
        returns (IAgenticCommerceKernel.Job memory)
    {
        return IAgenticCommerceKernel.Job({
            id: jobId,
            client: client,
            provider: provider,
            evaluator: evaluatorAddr,
            description: "underwriting settlement job",
            budget: PROVIDER_BUDGET,
            expiredAt: block.timestamp + 1 days,
            status: status_,
            hook: address(hook),
            paymentToken: paymentToken_,
            providerAgentId: 0,
            submittedAt: 0
        });
    }

    function _commit(uint256 parentJobId) internal view returns (UnderwritingTypes.UnderwriteCommit memory) {
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

    function testTimeoutMovesCollateralToRecoveryRecipient() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        hook.seedJob(ROOT_JOB_ID, UnderwritingTypes.SidecarState.FeeEscrowed, _commit(0), ROOT_JOB_ID);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Funded));

        vm.prank(provider);
        usdc.approve(predictedEscrow, COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(predictedEscrow, PRINCIPAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        coordinator.orchestrateFunding(ROOT_JOB_ID, _permit(ROOT_JOB_ID, ROOT_JOB_ID, predictedEscrow), bytes("permit-sig"));

        // Move to expired
        hook.setSidecarState(ROOT_JOB_ID, UnderwritingTypes.SidecarState.Protected);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Expired));

        coordinator.settleExpiry(ROOT_JOB_ID);

        // Verify claimTimeout was called (routes to recovery recipient in real collateral manager)
        assertTrue(collateralManager.claimTimeoutCalled());
        assertEq(collateralManager.lastTimeoutSettlementJobId(), ROOT_JOB_ID);
        assertEq(
            uint256(coordinator.jobSettlementState(ROOT_JOB_ID)),
            uint256(SettlementTypes.SettlementState.ExpirySettled)
        );
    }

    function testRejectRoutesCollateralToRecoveryRecipient() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        hook.seedJob(ROOT_JOB_ID, UnderwritingTypes.SidecarState.FeeEscrowed, _commit(0), ROOT_JOB_ID);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Funded));

        vm.prank(provider);
        usdc.approve(predictedEscrow, COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(predictedEscrow, PRINCIPAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        coordinator.orchestrateFunding(ROOT_JOB_ID, _permit(ROOT_JOB_ID, ROOT_JOB_ID, predictedEscrow), bytes("permit-sig"));

        // Move to rejected
        hook.setSidecarState(ROOT_JOB_ID, UnderwritingTypes.SidecarState.RejectSettled);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Rejected));

        coordinator.finalizeRejectedJob(ROOT_JOB_ID);

        // Verify claimTimeout was called (routes collateral to recovery recipient)
        assertTrue(collateralManager.claimTimeoutCalled());
        assertEq(collateralManager.lastTimeoutSettlementJobId(), ROOT_JOB_ID);
        assertEq(
            uint256(coordinator.jobSettlementState(ROOT_JOB_ID)),
            uint256(SettlementTypes.SettlementState.RejectSettled)
        );
    }

    function testSuccessReleasesCollateralBackToProvider() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);

        hook.seedJob(ROOT_JOB_ID, UnderwritingTypes.SidecarState.FeeEscrowed, _commit(0), ROOT_JOB_ID);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Funded));

        vm.prank(provider);
        usdc.approve(predictedEscrow, COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(predictedEscrow, PRINCIPAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        coordinator.orchestrateFunding(ROOT_JOB_ID, _permit(ROOT_JOB_ID, ROOT_JOB_ID, predictedEscrow), bytes("permit-sig"));

        hook.setSidecarState(ROOT_JOB_ID, UnderwritingTypes.SidecarState.SuccessPendingConfirmation);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Completed));

        coordinator.requestCollateralRelease(ROOT_JOB_ID);
        assertEq(
            uint256(coordinator.jobSettlementState(ROOT_JOB_ID)),
            uint256(SettlementTypes.SettlementState.SuccessPendingRelease)
        );

        vm.warp(block.timestamp + 3 days + 1);

        uint256 providerBalanceBefore = usdc.balanceOf(provider);
        coordinator.releaseCollateral(ROOT_JOB_ID);

        assertTrue(collateralManager.releaseCollateralCalled());
        assertEq(collateralManager.lastReleasedSettlementJobId(), ROOT_JOB_ID);
        assertEq(usdc.balanceOf(provider), providerBalanceBefore + COLLATERAL_AMOUNT);
        assertEq(
            uint256(coordinator.jobSettlementState(ROOT_JOB_ID)),
            uint256(SettlementTypes.SettlementState.SuccessSettled)
        );
    }

    function _setupFundedJobCompletedSuccess(address predictedEscrow) internal {
        hook.seedJob(ROOT_JOB_ID, UnderwritingTypes.SidecarState.FeeEscrowed, _commit(0), ROOT_JOB_ID);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Funded));

        vm.prank(provider);
        usdc.approve(predictedEscrow, COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(predictedEscrow, PRINCIPAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        coordinator.orchestrateFunding(ROOT_JOB_ID, _permit(ROOT_JOB_ID, ROOT_JOB_ID, predictedEscrow), bytes("permit-sig"));

        hook.setSidecarState(ROOT_JOB_ID, UnderwritingTypes.SidecarState.SuccessPendingConfirmation);
        acp.setJob(_job(ROOT_JOB_ID, IAgenticCommerceKernel.JobStatus.Completed));
    }

    function testReleaseRevertsWithoutPriorRequest() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);
        _setupFundedJobCompletedSuccess(predictedEscrow);

        vm.expectRevert(UnderwritingSettlementCoordinator.InvalidState.selector);
        coordinator.releaseCollateral(ROOT_JOB_ID);
    }

    function testOpenDisputeRevertsWhenNotSuccessPendingRelease() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);
        _setupFundedJobCompletedSuccess(predictedEscrow);

        vm.prank(client);
        vm.expectRevert(UnderwritingSettlementCoordinator.InvalidState.selector);
        coordinator.openSuccessDispute(ROOT_JOB_ID, bytes32("reason"));
    }

    function testOpenDisputeRevertsAfterUnlockAt() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);
        _setupFundedJobCompletedSuccess(predictedEscrow);

        coordinator.requestCollateralRelease(ROOT_JOB_ID);
        vm.warp(block.timestamp + 3 days + 1);

        vm.prank(client);
        vm.expectRevert(UnderwritingSettlementCoordinator.TooLate.selector);
        coordinator.openSuccessDispute(ROOT_JOB_ID, bytes32("reason"));
    }

    function testOpenDisputeRevertsWhenCallerIsNotClient() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);
        _setupFundedJobCompletedSuccess(predictedEscrow);

        coordinator.requestCollateralRelease(ROOT_JOB_ID);

        vm.prank(provider);
        vm.expectRevert(UnderwritingSettlementCoordinator.OnlyClient.selector);
        coordinator.openSuccessDispute(ROOT_JOB_ID, bytes32("reason"));
    }

    function testReleaseRevertsWhenDisputeIsOpen() public {
        address predictedEscrow = vm.computeCreateAddress(address(coordinator), 1);
        _setupFundedJobCompletedSuccess(predictedEscrow);

        coordinator.requestCollateralRelease(ROOT_JOB_ID);

        vm.prank(client);
        coordinator.openSuccessDispute(ROOT_JOB_ID, bytes32("reason"));

        vm.expectRevert(UnderwritingSettlementCoordinator.InvalidState.selector);
        coordinator.releaseCollateral(ROOT_JOB_ID);
    }

    function _permit(uint256 jobId, uint256 settlementJobId, address escrowAddress)
        internal
        view
        returns (ICollateralManager.UnderwritePermit memory)
    {
        return ICollateralManager.UnderwritePermit({
            jobId: jobId,
            settlementJobId: settlementJobId,
            safe: escrowAddress,
            user: client,
            merchant: escrowAddress,
            underwriter: underwriter,
            underwritingPremiumUsdc: PREMIUM_AMOUNT,
            merchantExecutionWallet: merchantExecutionWallet,
            requiredCollateralUsdc: COLLATERAL_AMOUNT,
            fundedPrincipalUsdc: PRINCIPAL_AMOUNT,
            coverageCapUsdc: COLLATERAL_AMOUNT,
            validUntil: uint64(block.timestamp + 1 days),
            executeUntil: uint64(block.timestamp + 2 days),
            policyHash: keccak256("policy"),
            nonce: 1,
            unlockAt: uint64(block.timestamp + 3 days)
        });
    }
}
