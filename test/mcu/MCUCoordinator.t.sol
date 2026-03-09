// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/mcu/MCUCoordinator.sol";
import "../../contracts/mcu/MCUHookLite.sol";
import "../../contracts/mcu/MCUJobAdapter.sol";
import "../../contracts/mcu/IBondManager.sol";
import "../../contracts/mcu/IAgenticCommerceKernel.sol";
import "../../contracts/mcu/MCUTypes.sol";
import "../mocks/MockBondManager.sol";
import "../mocks/MockERC20.sol";

contract MockCoordinatorACP is IAgenticCommerceKernel {
    address public override paymentToken;
    Job internal job;

    constructor(address paymentToken_) {
        paymentToken = paymentToken_;
    }

    function setJob(Job memory job_) external {
        job = job_;
    }

    function getJob(uint256) external view override returns (Job memory) {
        return job;
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
    bool public markSuccessPendingBondReleaseCalled;
    bool public markSuccessDisputeOpenCalled;
    bool public markSuccessSlashedCalled;
    uint256 public lastMarkedJobId;
    address public lastMarkedAdapter;
    uint64 public completionObservedAt;
    address public underwriterEvaluatorAddress;

    mapping(uint256 jobId => MCUTypes.SidecarState) internal sidecarStates;
    mapping(uint256 jobId => MCUTypes.MCUCommit) internal commits;
    mapping(uint256 jobId => address) internal adapters;
    mapping(uint256 jobId => uint64) internal deliveryConfirmationDeadlines;
    mapping(uint256 jobId => bytes32) internal successDisputeHashes;

    function seedJob(
        uint256 jobId,
        MCUTypes.SidecarState sidecarState,
        MCUTypes.MCUCommit calldata commit,
        address adapter,
        uint64 completionObservedAt_,
        uint64 deliveryConfirmationDeadline_,
        bytes32 disputeHash
    ) external {
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

    function getCommit(uint256 jobId) external view returns (MCUTypes.MCUCommit memory) {
        return commits[jobId];
    }

    function jobAdapter(uint256 jobId) external view returns (address) {
        return adapters[jobId];
    }

    function jobMemoId(uint256 jobId) external view returns (bytes32) {
        return commits[jobId].memoId;
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

    function markSuccessPendingBondRelease(uint256 jobId) external {
        markSuccessPendingBondReleaseCalled = true;
        sidecarStates[jobId] = MCUTypes.SidecarState.SuccessPendingBondRelease;
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
}

contract MCUCoordinatorTest is Test {
    uint256 internal constant JOB_ID = 1;
    uint256 internal constant BOND_AMOUNT = 100e18;
    uint256 internal constant PRINCIPAL_AMOUNT = 80e18;
    uint256 internal constant PREMIUM_AMOUNT = 5e18;
    uint256 internal constant SERVICE_FEE = 12e18;
    bytes32 internal constant MEMO_ID = keccak256("memo-id");
    bytes32 internal constant SUCCESS_DISPUTE_HASH = keccak256("success-dispute");
    bytes32 internal constant SUCCESS_DISPUTE_REASON = keccak256("merchant-won");

    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal evaluator = makeAddr("evaluator");
    address internal underwriterEvaluator = makeAddr("underwriterEvaluator");
    address internal underwriter = makeAddr("underwriter");
    address internal merchantExecutionWallet = makeAddr("merchantExecutionWallet");

    MockERC20 internal usdc;
    MockBondManager internal bondManager;
    MockCoordinatorACP internal acp;
    MockCoordinatorHook internal hook;
    MCUCoordinator internal coordinator;
    MCUJobAdapter internal adapter;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        bondManager = new MockBondManager(usdc);
        acp = new MockCoordinatorACP(address(usdc));
        hook = new MockCoordinatorHook();
        coordinator = new MCUCoordinator(acp, MCUHookLite(address(hook)), bondManager);
        adapter = new MCUJobAdapter(address(usdc), bondManager, address(coordinator));

        vm.prank(address(coordinator));
        adapter.configure(JOB_ID, client, provider, MEMO_ID, merchantExecutionWallet);

        hook.setUnderwriterEvaluator(underwriterEvaluator);

        usdc.mint(client, 1_000e18);
        usdc.mint(provider, 1_000e18);
    }

    function testOrchestrateFundingUsesHookStateAndMarksJobProtected() public {
        vm.prank(provider);
        usdc.approve(address(adapter), BOND_AMOUNT);

        vm.prank(client);
        usdc.approve(address(adapter), PRINCIPAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(bondManager), PREMIUM_AMOUNT);

        MCUTypes.MCUCommit memory commit = _commit();
        hook.seedJob(JOB_ID, MCUTypes.SidecarState.FeeEscrowed, commit, address(adapter), 0, 0, bytes32(0));

        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: JOB_ID,
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

        coordinator.orchestrateFunding(JOB_ID, _permit(), bytes("permit-sig"));

        assertTrue(hook.markProtectedCalled());
        assertEq(hook.lastMarkedJobId(), JOB_ID);
        assertEq(hook.lastMarkedAdapter(), address(adapter));
        assertEq(uint256(hook.jobSidecarState(JOB_ID)), uint256(MCUTypes.SidecarState.Protected));

        assertTrue(bondManager.lockBondCalled());
        assertTrue(bondManager.releasePrincipalCalled());
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(bondManager)), BOND_AMOUNT + PREMIUM_AMOUNT);
        assertEq(usdc.balanceOf(merchantExecutionWallet), PRINCIPAL_AMOUNT);
    }

    function testOpenSuccessDisputeMarksHookAfterTimeoutForMerchant() public {
        _seedCompletedJob(MCUTypes.SidecarState.SuccessPendingConfirmation, uint64(block.timestamp - 1), bytes32(0));

        vm.prank(provider);
        coordinator.openSuccessDispute(JOB_ID, SUCCESS_DISPUTE_HASH);

        assertTrue(hook.markSuccessDisputeOpenCalled());
        assertEq(uint256(hook.jobSidecarState(JOB_ID)), uint256(MCUTypes.SidecarState.SuccessDisputeOpen));
        assertEq(hook.jobLastSuccessDisputeHash(JOB_ID), SUCCESS_DISPUTE_HASH);
    }

    function testOpenSuccessDisputeRevertsBeforeTimeout() public {
        uint64 deadline = uint64(block.timestamp + 1 days);
        _seedCompletedJob(MCUTypes.SidecarState.SuccessPendingConfirmation, deadline, bytes32(0));

        vm.expectRevert(
            abi.encodeWithSelector(MCUCoordinator.ConfirmationTimeoutNotReached.selector, deadline, uint64(block.timestamp))
        );
        vm.prank(provider);
        coordinator.openSuccessDispute(JOB_ID, SUCCESS_DISPUTE_HASH);
    }

    function testConfirmDeliveryStillWorksAfterTimeoutBeforeDisputeOpens() public {
        _seedCompletedJob(MCUTypes.SidecarState.SuccessPendingConfirmation, uint64(block.timestamp - 1), bytes32(0));

        coordinator.confirmDelivery(JOB_ID, 7, bytes("delivery-sig"));

        assertTrue(bondManager.confirmDeliveryCalled());
        assertTrue(hook.markSuccessPendingBondReleaseCalled());
        assertEq(uint256(hook.jobSidecarState(JOB_ID)), uint256(MCUTypes.SidecarState.SuccessPendingBondRelease));
    }

    function testApplySuccessDisputeDecisionReleaseMarksBondReleasePending() public {
        _seedCompletedJob(MCUTypes.SidecarState.SuccessDisputeOpen, uint64(block.timestamp - 1), SUCCESS_DISPUTE_HASH);

        vm.prank(underwriterEvaluator);
        coordinator.applySuccessDisputeDecision(
            _successDisputeDecision(MCUTypes.SuccessDisputeOutcome.ReleaseBond, SUCCESS_DISPUTE_HASH, bytes32(0)),
            _emptySlashAttestation(),
            bytes("")
        );

        assertTrue(hook.markSuccessPendingBondReleaseCalled());
        assertEq(uint256(hook.jobSidecarState(JOB_ID)), uint256(MCUTypes.SidecarState.SuccessPendingBondRelease));
    }

    function testApplySuccessDisputeDecisionSlashCallsBondManagerAndMarksSuccessSlashed() public {
        _seedCompletedJob(MCUTypes.SidecarState.SuccessDisputeOpen, uint64(block.timestamp - 1), SUCCESS_DISPUTE_HASH);

        IBondManager.SlashAttestation memory attestation = _slashAttestation();
        bytes32 attestationHash = _hashSlashAttestation(attestation);

        vm.prank(underwriterEvaluator);
        coordinator.applySuccessDisputeDecision(
            _successDisputeDecision(MCUTypes.SuccessDisputeOutcome.SlashBond, SUCCESS_DISPUTE_HASH, attestationHash),
            attestation,
            bytes("slash-sig")
        );

        assertTrue(bondManager.slashCalled());
        assertTrue(hook.markSuccessSlashedCalled());
        assertEq(uint256(hook.jobSidecarState(JOB_ID)), uint256(MCUTypes.SidecarState.SuccessSlashed));
    }

    function _commit() internal view returns (MCUTypes.MCUCommit memory) {
        return MCUTypes.MCUCommit({
            memoId: MEMO_ID,
            parentJobId: 0,
            underwriter: underwriter,
            merchantExecutionWallet: merchantExecutionWallet,
            decisionFeeUsdc: PREMIUM_AMOUNT,
            requiredBondUsdc: BOND_AMOUNT,
            fundedPrincipalUsdc: PRINCIPAL_AMOUNT,
            coverageCapUsdc: BOND_AMOUNT,
            validUntil: uint64(block.timestamp + 1 days),
            executeUntil: uint64(block.timestamp + 2 days),
            unlockAt: uint64(block.timestamp + 3 days),
            deliveryConfirmationTimeoutWindow: uint64(1 days),
            policyHash: keccak256("policy"),
            parentMemoId: bytes32(0),
            quoteIdHash: keccak256("quote"),
            releasePrincipal: true
        });
    }

    function _permit() internal view returns (IBondManager.UnderwritePermit memory) {
        return IBondManager.UnderwritePermit({
            memoId: MEMO_ID,
            jobId: JOB_ID,
            safe: address(adapter),
            user: client,
            merchant: address(adapter),
            underwriter: underwriter,
            decisionFeeUsdc: PREMIUM_AMOUNT,
            merchantExecutionWallet: merchantExecutionWallet,
            requiredBondUsdc: BOND_AMOUNT,
            fundedPrincipalUsdc: PRINCIPAL_AMOUNT,
            coverageCapUsdc: BOND_AMOUNT,
            validUntil: uint64(block.timestamp + 1 days),
            executeUntil: uint64(block.timestamp + 2 days),
            policyHash: keccak256("policy"),
            nonce: 1,
            unlockAt: uint64(block.timestamp + 3 days),
            parentMemoId: bytes32(0)
        });
    }

    function _seedCompletedJob(
        MCUTypes.SidecarState sidecarState,
        uint64 deliveryConfirmationDeadline,
        bytes32 disputeHash
    ) internal {
        hook.seedJob(
            JOB_ID,
            sidecarState,
            _commit(),
            address(adapter),
            uint64(block.timestamp),
            deliveryConfirmationDeadline,
            disputeHash
        );

        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: JOB_ID,
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
    }

    function _successDisputeDecision(
        MCUTypes.SuccessDisputeOutcome outcome,
        bytes32 disputeHash,
        bytes32 slashAttestationHash
    ) internal view returns (MCUTypes.SuccessDisputeDecision memory) {
        return MCUTypes.SuccessDisputeDecision({
            jobId: JOB_ID,
            memoId: MEMO_ID,
            disputeHash: disputeHash,
            outcome: outcome,
            reason: SUCCESS_DISPUTE_REASON,
            slashAttestationHash: slashAttestationHash,
            deadline: uint64(block.timestamp + 1 days),
            nonce: 1
        });
    }

    function _emptySlashAttestation() internal view returns (IBondManager.SlashAttestation memory) {
        return IBondManager.SlashAttestation({
            memoId: bytes32(0),
            jobId: 0,
            safe: address(0),
            user: address(0),
            merchant: address(0),
            slashAmountUsdc: 0,
            reasonCode: bytes32(0),
            validUntil: uint64(block.timestamp + 1 days),
            nonce: 0
        });
    }

    function _slashAttestation() internal view returns (IBondManager.SlashAttestation memory) {
        return IBondManager.SlashAttestation({
            memoId: MEMO_ID,
            jobId: JOB_ID,
            safe: address(adapter),
            user: client,
            merchant: provider,
            slashAmountUsdc: 25e18,
            reasonCode: SUCCESS_DISPUTE_REASON,
            validUntil: uint64(block.timestamp + 1 days),
            nonce: 9
        });
    }

    function _hashSlashAttestation(IBondManager.SlashAttestation memory attestation) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                attestation.memoId,
                attestation.jobId,
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
