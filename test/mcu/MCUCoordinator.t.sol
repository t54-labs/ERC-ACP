// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/mcu/MCUCoordinator.sol";
import "../../contracts/mcu/MCUHookLite.sol";
import "../../contracts/mcu/MCUSettlementEscrow.sol";
import "../../contracts/mcu/ICollateralManager.sol";
import "../../contracts/mcu/IAgenticCommerceKernel.sol";
import "../../contracts/mcu/MCUTypes.sol";
import "../mocks/MockCollateralManager.sol";
import "../mocks/MockERC20.sol";

interface IMCUCoordinatorSettlementActions {
    function requestCollateralRelease(uint256 jobId) external;
}

contract MockCoordinatorACP is IAgenticCommerceKernel {
    address public override paymentToken;
    mapping(uint256 jobId => Job) internal jobs;
    mapping(uint256 jobId => JobKind) internal jobKinds;
    mapping(uint256 jobId => uint256) internal parentJobIdByCloseJobId;
    mapping(uint256 jobId => uint256) internal closeJobIdByParentJobId;

    constructor(address paymentToken_) {
        paymentToken = paymentToken_;
    }

    function setJob(Job memory job_) external {
        jobs[job_.id] = job_;
    }

    function setJobKind(uint256 jobId, JobKind kind) external {
        jobKinds[jobId] = kind;
    }

    function linkCloseJob(uint256 parentJobId, uint256 closeJobId) external {
        parentJobIdByCloseJobId[closeJobId] = parentJobId;
        closeJobIdByParentJobId[parentJobId] = closeJobId;
    }

    function getJob(uint256 jobId) external view override returns (Job memory) {
        return jobs[jobId];
    }

    function getJobKind(uint256 jobId) external view override returns (JobKind) {
        return jobKinds[jobId];
    }

    function getParentJobId(uint256 jobId) external view override returns (uint256) {
        return parentJobIdByCloseJobId[jobId];
    }

    function getCloseJobId(uint256 jobId) external view override returns (uint256) {
        return closeJobIdByParentJobId[jobId];
    }

    function setProvider(uint256, address, bytes calldata) external pure override {
        revert("unused");
    }

    function setBudget(uint256, uint256, bytes calldata) external pure override {
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

contract MockCoordinatorHook {
    bool public markProtectedCalled;
    bool public markSuccessPendingCollateralReleaseCalled;
    bool public markSuccessDisputeOpenCalled;
    bool public markSuccessSlashedCalled;
    bool public markExpirySettledCalled;
    uint256 public lastMarkedJobId;
    address public lastMarkedAdapter;
    uint64 public completionObservedAt;
    address public underwriterEvaluatorAddress;

    mapping(uint256 jobId => MCUTypes.SidecarState) internal sidecarStates;
    mapping(uint256 jobId => MCUTypes.FlowKind) internal flowKinds;
    mapping(uint256 jobId => MCUTypes.MCUCommit) internal commits;
    mapping(uint256 jobId => address) internal adapters;
    mapping(uint256 jobId => uint64) internal deliveryConfirmationDeadlines;
    mapping(uint256 jobId => bytes32) internal successDisputeHashes;

    function seedJob(
        uint256 jobId,
        MCUTypes.FlowKind flowKind,
        MCUTypes.SidecarState sidecarState,
        MCUTypes.MCUCommit calldata commit,
        address adapter,
        uint64 completionObservedAt_,
        uint64 deliveryConfirmationDeadline_,
        bytes32 disputeHash
    ) external {
        flowKinds[jobId] = flowKind;
        sidecarStates[jobId] = sidecarState;
        commits[jobId] = commit;
        adapters[jobId] = adapter;
        completionObservedAt = completionObservedAt_;
        deliveryConfirmationDeadlines[jobId] = deliveryConfirmationDeadline_;
        successDisputeHashes[jobId] = disputeHash;
    }

    function setUnderwriterEvaluator(address underwriterEvaluator_) external {
        underwriterEvaluatorAddress = underwriterEvaluator_;
    }

    function jobSidecarState(uint256 jobId) external view returns (MCUTypes.SidecarState) {
        return sidecarStates[jobId];
    }

    function jobFlowKind(uint256 jobId) external view returns (MCUTypes.FlowKind) {
        return flowKinds[jobId];
    }

    function getCommit(uint256 jobId) external view returns (MCUTypes.MCUCommit memory) {
        return commits[jobId];
    }

    function jobAdapter(uint256 jobId) external view returns (address) {
        return adapters[jobId];
    }

    function jobSettlementJobId(uint256 jobId) external view returns (uint256) {
        MCUTypes.MCUCommit memory commit = commits[jobId];
        if (commit.parentJobId != 0) {
            return commit.parentJobId;
        }
        return jobId;
    }

    function jobDeliveryConfirmationDeadline(uint256 jobId) external view returns (uint64) {
        return deliveryConfirmationDeadlines[jobId];
    }

    function jobLastSuccessDisputeHash(uint256 jobId) external view returns (bytes32) {
        return successDisputeHashes[jobId];
    }

    function underwriterEvaluator() external view returns (address) {
        return underwriterEvaluatorAddress;
    }

    function markProtected(uint256 jobId, address adapter) external {
        markProtectedCalled = true;
        lastMarkedJobId = jobId;
        lastMarkedAdapter = adapter;
        adapters[jobId] = adapter;
        sidecarStates[jobId] = MCUTypes.SidecarState.Protected;
    }

    function markSuccessPendingCollateralRelease(uint256 jobId) external {
        markSuccessPendingCollateralReleaseCalled = true;
        if (sidecarStates[jobId] == MCUTypes.SidecarState.SuccessPendingConfirmation) {
            deliveryConfirmationDeadlines[jobId] =
                uint64(block.timestamp) + commits[jobId].deliveryConfirmationTimeoutWindow;
        }
        sidecarStates[jobId] = MCUTypes.SidecarState.SuccessPendingCollateralRelease;
    }

    function markSuccessDisputeOpen(uint256 jobId, bytes32 disputeHash) external {
        markSuccessDisputeOpenCalled = true;
        successDisputeHashes[jobId] = disputeHash;
        sidecarStates[jobId] = MCUTypes.SidecarState.SuccessDisputeOpen;
    }

    function markSuccessSlashed(uint256 jobId, bytes32 disputeHash, bytes32) external {
        markSuccessSlashedCalled = true;
        successDisputeHashes[jobId] = disputeHash;
        sidecarStates[jobId] = MCUTypes.SidecarState.SuccessSlashed;
    }

    function markSuccessSettled(uint256 jobId) external {
        sidecarStates[jobId] = MCUTypes.SidecarState.SuccessSettled;
    }

    function markExpiryPendingTimeout(uint256 jobId) external {
        sidecarStates[jobId] = MCUTypes.SidecarState.ExpiryPendingTimeout;
    }

    function markExpirySettled(uint256 jobId) external {
        markExpirySettledCalled = true;
        sidecarStates[jobId] = MCUTypes.SidecarState.ExpirySettled;
    }
}

contract MCUCoordinatorTest is Test {
    bytes4 internal constant ONLY_CLIENT_SELECTOR = bytes4(keccak256("OnlyClient()"));
    bytes4 internal constant ONLY_PROVIDER_SELECTOR = bytes4(keccak256("OnlyProvider()"));
    bytes4 internal constant DISPUTE_WINDOW_CLOSED_SELECTOR = bytes4(keccak256("DisputeWindowClosed(uint64,uint64)"));
    bytes4 internal constant DISPUTE_WINDOW_OPEN_SELECTOR = bytes4(keccak256("DisputeWindowOpen(uint64,uint64)"));

    uint256 internal constant OPEN_JOB_ID = 1;
    uint256 internal constant CLOSE_JOB_ID = 2;
    uint256 internal constant COLLATERAL_AMOUNT = 100e18;
    uint256 internal constant PRINCIPAL_AMOUNT = 80e18;
    uint256 internal constant PREMIUM_AMOUNT = 5e18;
    uint256 internal constant SERVICE_FEE = 12e18;
    bytes32 internal constant SUCCESS_DISPUTE_HASH = keccak256("success-dispute");
    bytes32 internal constant SUCCESS_DISPUTE_REASON = keccak256("merchant-won");

    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal evaluator = makeAddr("evaluator");
    address internal underwriterEvaluator = makeAddr("underwriterEvaluator");
    address internal underwriter = makeAddr("underwriter");
    address internal merchantExecutionWallet = makeAddr("merchantExecutionWallet");

    MockERC20 internal usdc;
    MockCollateralManager internal collateralManager;
    MockCoordinatorACP internal acp;
    MockCoordinatorHook internal hook;
    MCUCoordinator internal coordinator;
    MCUSettlementEscrow internal adapter;

    function _settlementActions() internal view returns (IMCUCoordinatorSettlementActions) {
        return IMCUCoordinatorSettlementActions(address(coordinator));
    }

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        collateralManager = new MockCollateralManager(usdc);
        acp = new MockCoordinatorACP(address(usdc));
        hook = new MockCoordinatorHook();
        coordinator = new MCUCoordinator(acp, MCUHookLite(address(hook)), collateralManager);
        adapter = new MCUSettlementEscrow(address(usdc), collateralManager, address(coordinator));

        vm.prank(address(coordinator));
        adapter.configure(OPEN_JOB_ID, client, provider, OPEN_JOB_ID, merchantExecutionWallet);

        hook.setUnderwriterEvaluator(underwriterEvaluator);

        usdc.mint(client, 1_000e18);
        usdc.mint(provider, 1_000e18);
    }

    function testOrchestrateFundingUsesHookStateAndMarksJobProtected() public {
        vm.prank(provider);
        usdc.approve(address(adapter), COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(adapter), PRINCIPAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        MCUTypes.MCUCommit memory commit = _commit(0);
        hook.seedJob(
            OPEN_JOB_ID,
            MCUTypes.FlowKind.TwoStageOpen,
            MCUTypes.SidecarState.FeeEscrowed,
            commit,
            address(adapter),
            0,
            0,
            bytes32(0)
        );

        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: OPEN_JOB_ID,
                client: client,
                provider: provider,
                evaluator: underwriterEvaluator,
                hook: address(hook),
                description: "mcu job",
                budget: SERVICE_FEE,
                expiredAt: block.timestamp + 1 days,
                status: IAgenticCommerceKernel.JobStatus.Funded
            })
        );
        acp.setJobKind(OPEN_JOB_ID, IAgenticCommerceKernel.JobKind.Open);

        coordinator.orchestrateFunding(OPEN_JOB_ID, _permit(OPEN_JOB_ID, OPEN_JOB_ID), bytes("permit-sig"));

        assertTrue(hook.markProtectedCalled());
        assertEq(hook.lastMarkedJobId(), OPEN_JOB_ID);
        assertEq(hook.lastMarkedAdapter(), address(adapter));
        assertEq(uint256(hook.jobSidecarState(OPEN_JOB_ID)), uint256(MCUTypes.SidecarState.Protected));

        assertTrue(collateralManager.lockCollateralCalled());
        assertTrue(collateralManager.releasePrincipalCalled());
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(collateralManager)), COLLATERAL_AMOUNT + PREMIUM_AMOUNT);
        assertEq(usdc.balanceOf(merchantExecutionWallet), PRINCIPAL_AMOUNT);
    }

    function testSingleStageOrchestrateFundingUsesStandaloneJobAndMarksJobProtected() public {
        vm.prank(provider);
        usdc.approve(address(adapter), COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(adapter), PRINCIPAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        MCUTypes.MCUCommit memory commit = _commit(0);
        hook.seedJob(
            OPEN_JOB_ID,
            MCUTypes.FlowKind.SingleStage,
            MCUTypes.SidecarState.FeeEscrowed,
            commit,
            address(adapter),
            0,
            0,
            bytes32(0)
        );

        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: OPEN_JOB_ID,
                client: client,
                provider: provider,
                evaluator: underwriterEvaluator,
                hook: address(hook),
                description: "single-stage mcu job",
                budget: SERVICE_FEE,
                expiredAt: block.timestamp + 1 days,
                status: IAgenticCommerceKernel.JobStatus.Funded
            })
        );
        acp.setJobKind(OPEN_JOB_ID, IAgenticCommerceKernel.JobKind.Standalone);

        coordinator.orchestrateFunding(OPEN_JOB_ID, _permit(OPEN_JOB_ID, OPEN_JOB_ID), bytes("permit-sig"));

        assertTrue(hook.markProtectedCalled());
        assertEq(hook.lastMarkedJobId(), OPEN_JOB_ID);
        assertEq(hook.lastMarkedAdapter(), address(adapter));
        assertEq(uint256(hook.jobSidecarState(OPEN_JOB_ID)), uint256(MCUTypes.SidecarState.Protected));
        assertTrue(collateralManager.lockCollateralCalled());
        assertTrue(collateralManager.releasePrincipalCalled());
    }

    function testCloseOrchestrateFundingMarksProtectedWithoutPullingNewCollateralOrPrincipal() public {
        MCUTypes.MCUCommit memory openCommit = _commit(0);
        MCUTypes.MCUCommit memory closeCommit = _commit(OPEN_JOB_ID);

        hook.seedJob(
            OPEN_JOB_ID,
            MCUTypes.FlowKind.TwoStageOpen,
            MCUTypes.SidecarState.AwaitingClose,
            openCommit,
            address(adapter),
            0,
            0,
            bytes32(0)
        );
        hook.seedJob(
            CLOSE_JOB_ID,
            MCUTypes.FlowKind.TwoStageClose,
            MCUTypes.SidecarState.FeeEscrowed,
            closeCommit,
            address(0),
            0,
            0,
            bytes32(0)
        );

        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: OPEN_JOB_ID,
                client: client,
                provider: provider,
                evaluator: underwriterEvaluator,
                hook: address(hook),
                description: "open mcu job",
                budget: SERVICE_FEE,
                expiredAt: block.timestamp + 1 days,
                status: IAgenticCommerceKernel.JobStatus.Completed
            })
        );
        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: CLOSE_JOB_ID,
                client: client,
                provider: provider,
                evaluator: underwriterEvaluator,
                hook: address(hook),
                description: "close mcu job",
                budget: SERVICE_FEE / 2,
                expiredAt: block.timestamp + 2 days,
                status: IAgenticCommerceKernel.JobStatus.Funded
            })
        );
        acp.setJobKind(OPEN_JOB_ID, IAgenticCommerceKernel.JobKind.Open);
        acp.setJobKind(CLOSE_JOB_ID, IAgenticCommerceKernel.JobKind.Standalone);

        coordinator.orchestrateFunding(CLOSE_JOB_ID, _permit(CLOSE_JOB_ID, OPEN_JOB_ID), bytes("unused"));

        assertTrue(hook.markProtectedCalled());
        assertEq(hook.lastMarkedJobId(), CLOSE_JOB_ID);
        assertFalse(collateralManager.lockCollateralCalled());
        assertFalse(collateralManager.releasePrincipalCalled());
        assertEq(usdc.balanceOf(address(collateralManager)), 0);
        assertEq(usdc.balanceOf(merchantExecutionWallet), 0);
    }

    function testProviderCanRequestCollateralReleaseAndStartClientDisputeWindow() public {
        _seedCompletedJob(MCUTypes.SidecarState.SuccessPendingConfirmation, 0, bytes32(0));

        vm.prank(provider);
        _settlementActions().requestCollateralRelease(OPEN_JOB_ID);

        assertTrue(hook.markSuccessPendingCollateralReleaseCalled());
        assertEq(uint256(hook.jobSidecarState(OPEN_JOB_ID)), uint256(MCUTypes.SidecarState.SuccessPendingCollateralRelease));
        assertEq(
            hook.jobDeliveryConfirmationDeadline(OPEN_JOB_ID),
            uint64(block.timestamp + _commit(0).deliveryConfirmationTimeoutWindow)
        );
    }

    function testClientCanOpenSuccessDisputeWithinWindowAfterProviderRequestsRelease() public {
        _seedCompletedJob(MCUTypes.SidecarState.SuccessPendingConfirmation, 0, bytes32(0));

        vm.prank(provider);
        _settlementActions().requestCollateralRelease(OPEN_JOB_ID);

        vm.prank(client);
        coordinator.openSuccessDispute(OPEN_JOB_ID, SUCCESS_DISPUTE_HASH);

        assertTrue(hook.markSuccessDisputeOpenCalled());
        assertEq(uint256(hook.jobSidecarState(OPEN_JOB_ID)), uint256(MCUTypes.SidecarState.SuccessDisputeOpen));
        assertEq(hook.jobLastSuccessDisputeHash(OPEN_JOB_ID), SUCCESS_DISPUTE_HASH);
    }

    function testOpenSuccessDisputeRevertsAfterWindowCloses() public {
        _seedCompletedJob(MCUTypes.SidecarState.SuccessPendingConfirmation, 0, bytes32(0));

        vm.prank(provider);
        _settlementActions().requestCollateralRelease(OPEN_JOB_ID);

        uint64 deadline = hook.jobDeliveryConfirmationDeadline(OPEN_JOB_ID);
        vm.warp(deadline + 1);

        vm.expectRevert(
            abi.encodeWithSelector(DISPUTE_WINDOW_CLOSED_SELECTOR, deadline, uint64(block.timestamp))
        );
        vm.prank(client);
        coordinator.openSuccessDispute(OPEN_JOB_ID, SUCCESS_DISPUTE_HASH);
    }

    function testOpenSuccessDisputeRevertsWhenCallerIsNotClient() public {
        _seedCompletedJob(MCUTypes.SidecarState.SuccessPendingConfirmation, 0, bytes32(0));

        vm.prank(provider);
        _settlementActions().requestCollateralRelease(OPEN_JOB_ID);

        vm.expectRevert(ONLY_CLIENT_SELECTOR);
        vm.prank(provider);
        coordinator.openSuccessDispute(OPEN_JOB_ID, SUCCESS_DISPUTE_HASH);
    }

    function testReleaseCollateralRevertsWhileClientDisputeWindowIsStillOpen() public {
        MCUTypes.MCUCommit memory longWindowCommit = _commit(0);
        longWindowCommit.deliveryConfirmationTimeoutWindow = uint64(5 days);

        hook.seedJob(
            OPEN_JOB_ID,
            MCUTypes.FlowKind.TwoStageOpen,
            MCUTypes.SidecarState.SuccessPendingConfirmation,
            longWindowCommit,
            address(adapter),
            uint64(block.timestamp),
            0,
            bytes32(0)
        );

        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: OPEN_JOB_ID,
                client: client,
                provider: provider,
                evaluator: underwriterEvaluator,
                hook: address(hook),
                description: "mcu job",
                budget: SERVICE_FEE,
                expiredAt: block.timestamp + 1 days,
                status: IAgenticCommerceKernel.JobStatus.Completed
            })
        );
        acp.setJobKind(OPEN_JOB_ID, IAgenticCommerceKernel.JobKind.Open);

        vm.prank(provider);
        _settlementActions().requestCollateralRelease(OPEN_JOB_ID);

        vm.warp(uint64(block.timestamp) + 4 days);

        vm.expectRevert();
        coordinator.releaseCollateral(OPEN_JOB_ID);
    }

    function testApplySuccessDisputeDecisionReleaseMarksCollateralReleasePending() public {
        _seedCompletedJob(MCUTypes.SidecarState.SuccessDisputeOpen, uint64(block.timestamp - 1), SUCCESS_DISPUTE_HASH);

        vm.prank(underwriterEvaluator);
        coordinator.applySuccessDisputeDecision(
            _successDisputeDecision(
                OPEN_JOB_ID, MCUTypes.SuccessDisputeOutcome.ReleaseCollateral, SUCCESS_DISPUTE_HASH, bytes32(0)
            ),
            _emptySlashAttestation(),
            bytes("")
        );

        assertTrue(hook.markSuccessPendingCollateralReleaseCalled());
        assertEq(uint256(hook.jobSidecarState(OPEN_JOB_ID)), uint256(MCUTypes.SidecarState.SuccessPendingCollateralRelease));
    }

    function testReleaseCollateralStillRevertsBeforeWindowClosesAfterReleaseSideDisputeResolution() public {
        MCUTypes.MCUCommit memory longWindowCommit = _commit(0);
        longWindowCommit.deliveryConfirmationTimeoutWindow = uint64(5 days);

        hook.seedJob(
            OPEN_JOB_ID,
            MCUTypes.FlowKind.TwoStageOpen,
            MCUTypes.SidecarState.SuccessPendingConfirmation,
            longWindowCommit,
            address(adapter),
            uint64(block.timestamp),
            0,
            bytes32(0)
        );

        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: OPEN_JOB_ID,
                client: client,
                provider: provider,
                evaluator: underwriterEvaluator,
                hook: address(hook),
                description: "mcu job",
                budget: SERVICE_FEE,
                expiredAt: block.timestamp + 1 days,
                status: IAgenticCommerceKernel.JobStatus.Completed
            })
        );
        acp.setJobKind(OPEN_JOB_ID, IAgenticCommerceKernel.JobKind.Open);

        vm.prank(provider);
        _settlementActions().requestCollateralRelease(OPEN_JOB_ID);

        vm.prank(client);
        coordinator.openSuccessDispute(OPEN_JOB_ID, SUCCESS_DISPUTE_HASH);

        vm.prank(underwriterEvaluator);
        coordinator.applySuccessDisputeDecision(
            _successDisputeDecision(
                OPEN_JOB_ID, MCUTypes.SuccessDisputeOutcome.ReleaseCollateral, SUCCESS_DISPUTE_HASH, bytes32(0)
            ),
            _emptySlashAttestation(),
            bytes("")
        );

        vm.warp(uint64(block.timestamp) + 4 days);
        vm.expectRevert();
        coordinator.releaseCollateral(OPEN_JOB_ID);
    }

    function testApplySuccessDisputeDecisionSlashCallsCollateralManagerAndMarksSuccessSlashed() public {
        _seedCompletedJob(MCUTypes.SidecarState.SuccessDisputeOpen, uint64(block.timestamp - 1), SUCCESS_DISPUTE_HASH);

        ICollateralManager.SlashAttestation memory attestation = _slashAttestation();
        bytes32 attestationHash = _hashSlashAttestation(attestation);

        vm.prank(underwriterEvaluator);
        coordinator.applySuccessDisputeDecision(
            _successDisputeDecision(
                OPEN_JOB_ID, MCUTypes.SuccessDisputeOutcome.SlashCollateral, SUCCESS_DISPUTE_HASH, attestationHash
            ),
            attestation,
            bytes("slash-sig")
        );

        assertTrue(collateralManager.slashCalled());
        assertTrue(hook.markSuccessSlashedCalled());
        assertEq(uint256(hook.jobSidecarState(OPEN_JOB_ID)), uint256(MCUTypes.SidecarState.SuccessSlashed));
    }

    function testCloseSuccessDisputeSlashUsesParentSettlementIdentity() public {
        MCUTypes.MCUCommit memory openCommit = _commit(0);
        MCUTypes.MCUCommit memory closeCommit = _commit(OPEN_JOB_ID);

        hook.seedJob(
            OPEN_JOB_ID,
            MCUTypes.FlowKind.TwoStageOpen,
            MCUTypes.SidecarState.AwaitingClose,
            openCommit,
            address(adapter),
            0,
            0,
            bytes32(0)
        );
        hook.seedJob(
            CLOSE_JOB_ID,
            MCUTypes.FlowKind.TwoStageClose,
            MCUTypes.SidecarState.SuccessDisputeOpen,
            closeCommit,
            address(adapter),
            uint64(block.timestamp),
            uint64(block.timestamp - 1),
            SUCCESS_DISPUTE_HASH
        );

        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: CLOSE_JOB_ID,
                client: client,
                provider: provider,
                evaluator: underwriterEvaluator,
                hook: address(hook),
                description: "close mcu job",
                budget: SERVICE_FEE / 2,
                expiredAt: block.timestamp + 2 days,
                status: IAgenticCommerceKernel.JobStatus.Completed
            })
        );
        acp.setJobKind(OPEN_JOB_ID, IAgenticCommerceKernel.JobKind.Open);
        acp.setJobKind(CLOSE_JOB_ID, IAgenticCommerceKernel.JobKind.Standalone);

        ICollateralManager.SlashAttestation memory attestation = ICollateralManager.SlashAttestation({
            settlementJobId: OPEN_JOB_ID,
            safe: address(adapter),
            user: client,
            merchant: provider,
            slashAmountUsdc: 25e18,
            reasonCode: SUCCESS_DISPUTE_REASON,
            validUntil: uint64(block.timestamp + 1 days),
            nonce: 33
        });
        bytes32 attestationHash = _hashSlashAttestation(attestation);

        vm.prank(underwriterEvaluator);
        coordinator.applySuccessDisputeDecision(
            _successDisputeDecision(
                CLOSE_JOB_ID, MCUTypes.SuccessDisputeOutcome.SlashCollateral, SUCCESS_DISPUTE_HASH, attestationHash
            ),
            attestation,
            bytes("slash-sig")
        );

        assertTrue(collateralManager.slashCalled());
        assertEq(uint256(hook.jobSidecarState(CLOSE_JOB_ID)), uint256(MCUTypes.SidecarState.SuccessSlashed));
    }

    function testCloseSettleExpiryDoesNotClaimTimeoutOnParentCollateral() public {
        MCUTypes.MCUCommit memory openCommit = _commit(0);
        MCUTypes.MCUCommit memory closeCommit = _commit(OPEN_JOB_ID);

        hook.seedJob(
            OPEN_JOB_ID,
            MCUTypes.FlowKind.TwoStageOpen,
            MCUTypes.SidecarState.AwaitingClose,
            openCommit,
            address(adapter),
            0,
            0,
            bytes32(0)
        );
        hook.seedJob(
            CLOSE_JOB_ID,
            MCUTypes.FlowKind.TwoStageClose,
            MCUTypes.SidecarState.Protected,
            closeCommit,
            address(adapter),
            0,
            0,
            bytes32(0)
        );

        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: CLOSE_JOB_ID,
                client: client,
                provider: provider,
                evaluator: underwriterEvaluator,
                hook: address(hook),
                description: "close mcu job",
                budget: SERVICE_FEE / 2,
                expiredAt: block.timestamp - 1,
                status: IAgenticCommerceKernel.JobStatus.Expired
            })
        );
        acp.setJobKind(OPEN_JOB_ID, IAgenticCommerceKernel.JobKind.Open);
        acp.setJobKind(CLOSE_JOB_ID, IAgenticCommerceKernel.JobKind.Standalone);

        coordinator.settleExpiry(CLOSE_JOB_ID);

        assertFalse(collateralManager.claimTimeoutCalled());
        assertEq(uint256(hook.jobSidecarState(CLOSE_JOB_ID)), uint256(MCUTypes.SidecarState.ExpirySettled));
    }

    function _commit(uint256 parentJobId) internal view returns (MCUTypes.MCUCommit memory) {
        return MCUTypes.MCUCommit({
            parentJobId: parentJobId,
            underwriter: underwriter,
            merchantExecutionWallet: merchantExecutionWallet,
            decisionFeeUsdc: PREMIUM_AMOUNT,
            requiredCollateralUsdc: COLLATERAL_AMOUNT,
            fundedPrincipalUsdc: PRINCIPAL_AMOUNT,
            coverageCapUsdc: COLLATERAL_AMOUNT,
            validUntil: uint64(block.timestamp + 1 days),
            executeUntil: uint64(block.timestamp + 2 days),
            unlockAt: uint64(block.timestamp + 3 days),
            deliveryConfirmationTimeoutWindow: uint64(1 days),
            policyHash: keccak256("policy"),
            quoteIdHash: keccak256("quote"),
            releasePrincipal: true
        });
    }

    function _permit(uint256 jobId, uint256 settlementJobId)
        internal
        view
        returns (ICollateralManager.UnderwritePermit memory)
    {
        return ICollateralManager.UnderwritePermit({
            jobId: jobId,
            settlementJobId: settlementJobId,
            safe: address(adapter),
            user: client,
            merchant: address(adapter),
            underwriter: underwriter,
            decisionFeeUsdc: PREMIUM_AMOUNT,
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

    function _seedCompletedJob(
        MCUTypes.SidecarState sidecarState,
        uint64 deliveryConfirmationDeadline,
        bytes32 disputeHash
    ) internal {
        hook.seedJob(
            OPEN_JOB_ID,
            MCUTypes.FlowKind.TwoStageOpen,
            sidecarState,
            _commit(0),
            address(adapter),
            uint64(block.timestamp),
            deliveryConfirmationDeadline,
            disputeHash
        );

        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: OPEN_JOB_ID,
                client: client,
                provider: provider,
                evaluator: underwriterEvaluator,
                hook: address(hook),
                description: "mcu job",
                budget: SERVICE_FEE,
                expiredAt: block.timestamp + 1 days,
                status: IAgenticCommerceKernel.JobStatus.Completed
            })
        );
        acp.setJobKind(OPEN_JOB_ID, IAgenticCommerceKernel.JobKind.Open);
    }

    function _successDisputeDecision(
        uint256 jobId,
        MCUTypes.SuccessDisputeOutcome outcome,
        bytes32 disputeHash,
        bytes32 slashAttestationHash
    ) internal view returns (MCUTypes.SuccessDisputeDecision memory) {
        return MCUTypes.SuccessDisputeDecision({
            jobId: jobId,
            disputeHash: disputeHash,
            outcome: outcome,
            reason: SUCCESS_DISPUTE_REASON,
            slashAttestationHash: slashAttestationHash,
            deadline: uint64(block.timestamp + 1 days),
            nonce: 1
        });
    }

    function _emptySlashAttestation() internal view returns (ICollateralManager.SlashAttestation memory) {
        return ICollateralManager.SlashAttestation({
            settlementJobId: 0,
            safe: address(0),
            user: address(0),
            merchant: address(0),
            slashAmountUsdc: 0,
            reasonCode: bytes32(0),
            validUntil: uint64(block.timestamp + 1 days),
            nonce: 0
        });
    }

    function _slashAttestation() internal view returns (ICollateralManager.SlashAttestation memory) {
        return ICollateralManager.SlashAttestation({
            settlementJobId: OPEN_JOB_ID,
            safe: address(adapter),
            user: client,
            merchant: provider,
            slashAmountUsdc: 25e18,
            reasonCode: SUCCESS_DISPUTE_REASON,
            validUntil: uint64(block.timestamp + 1 days),
            nonce: 9
        });
    }

    function _hashSlashAttestation(ICollateralManager.SlashAttestation memory attestation) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
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
    }
}
