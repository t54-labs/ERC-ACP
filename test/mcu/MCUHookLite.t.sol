// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/IACPHook.sol";
import "../../contracts/mcu/MCUHookLite.sol";
import "../../contracts/mcu/IAgenticCommerceKernel.sol";
import "../../contracts/mcu/MCUTypes.sol";

interface IMCUHookLiteFlowAdminView {
    function jobSettlementJobId(uint256 jobId) external view returns (uint256);
    function getParentJobId(uint256 jobId) external view returns (uint256);
    function getCloseJobId(uint256 jobId) external view returns (uint256);
    function jobFlowKind(uint256 jobId) external view returns (uint8);
    function registerUnderwriter(address underwriter) external;
    function unregisterUnderwriter(address underwriter) external;
    function isRegisteredUnderwriter(address underwriter) external view returns (bool);
}

contract MockHookACP is IAgenticCommerceKernel {
    address public override paymentToken;
    mapping(uint256 jobId => Job) internal jobs;
    mapping(uint256 jobId => JobKind) internal jobKinds;

    constructor(address paymentToken_) {
        paymentToken = paymentToken_;
    }

    function setJob(Job memory job_) external {
        jobs[job_.id] = job_;
    }

    function setJobKind(uint256 jobId, JobKind kind) external {
        jobKinds[jobId] = kind;
    }

    function callBeforeAction(address hook, uint256 jobId, bytes4 selector, bytes calldata data) external {
        IACPHook(hook).beforeAction(jobId, selector, data);
    }

    function callAfterAction(address hook, uint256 jobId, bytes4 selector, bytes calldata data) external {
        IACPHook(hook).afterAction(jobId, selector, data);
    }

    function getJob(uint256 jobId) external view override returns (Job memory) {
        return jobs[jobId];
    }

    function getJobKind(uint256 jobId) external view override returns (JobKind) {
        return jobKinds[jobId];
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

contract MCUHookLiteTest is Test {
    bytes4 internal constant SEL_SET_BUDGET = bytes4(keccak256("setBudget(uint256,uint256,bytes)"));
    bytes4 internal constant SEL_FUND = bytes4(keccak256("fund(uint256,uint256,bytes)"));
    bytes4 internal constant SEL_SUBMIT = bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    bytes4 internal constant SEL_COMPLETE = bytes4(keccak256("complete(uint256,bytes32,bytes)"));
    bytes4 internal constant SEL_REJECT = bytes4(keccak256("reject(uint256,bytes32,bytes)"));

    bytes4 internal constant UNDERWRITER_NOT_REGISTERED_SELECTOR =
        bytes4(keccak256("UnderwriterNotRegistered()"));
    bytes4 internal constant UNSUPPORTED_JOB_KIND_SELECTOR = bytes4(keccak256("UnsupportedJobKind()"));

    uint8 internal constant FLOW_SINGLE_STAGE = 0;
    uint8 internal constant FLOW_TWO_STAGE_OPEN = 1;
    uint8 internal constant FLOW_TWO_STAGE_CLOSE = 2;

    uint256 internal constant OPEN_JOB_ID = 1;
    uint256 internal constant CLOSE_JOB_ID = 2;
    uint256 internal constant SINGLE_STAGE_JOB_ID = 3;
    uint256 internal constant BAD_CLOSE_JOB_ID = 4;
    uint256 internal constant LEGACY_CLOSE_JOB_ID = 5;
    uint256 internal constant REPLACEMENT_CLOSE_JOB_ID = 6;

    bytes32 internal constant SUCCESS_DISPUTE_HASH = keccak256("success-dispute");
    bytes32 internal constant SLASH_ATTESTATION_HASH = keccak256("slash-attestation");

    struct FutureCommit {
        uint256 parentJobId;
        address underwriter;
        address merchantExecutionWallet;
        uint256 decisionFeeUsdc;
        uint256 requiredCollateralUsdc;
        uint256 fundedPrincipalUsdc;
        uint256 coverageCapUsdc;
        uint64 validUntil;
        uint64 executeUntil;
        uint64 unlockAt;
        uint64 deliveryConfirmationTimeoutWindow;
        bytes32 policyHash;
        bytes32 quoteIdHash;
        bool releasePrincipal;
    }

    address internal admin = makeAddr("admin");
    address internal coordinator = makeAddr("coordinator");
    address internal evaluator = makeAddr("underwriterEvaluator");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal otherProvider = makeAddr("otherProvider");
    address internal underwriter = makeAddr("underwriter");
    address internal merchantExecutionWallet = makeAddr("merchantExecutionWallet");
    address internal adapter = makeAddr("adapter");

    MockHookACP internal acp;
    MCUHookLite internal hook;

    function setUp() public {
        acp = new MockHookACP(address(0xBEEF));
        hook = new MCUHookLite(acp, admin);

        vm.prank(admin);
        hook.setWiring(coordinator, evaluator);

        acp.setJob(_job(OPEN_JOB_ID, provider));
        acp.setJob(_job(CLOSE_JOB_ID, provider));
        acp.setJob(_job(SINGLE_STAGE_JOB_ID, provider));
        acp.setJob(_job(BAD_CLOSE_JOB_ID, otherProvider));
        acp.setJob(_job(LEGACY_CLOSE_JOB_ID, provider));
        acp.setJob(_job(REPLACEMENT_CLOSE_JOB_ID, provider));

        acp.setJobKind(OPEN_JOB_ID, IAgenticCommerceKernel.JobKind.Open);
        acp.setJobKind(CLOSE_JOB_ID, IAgenticCommerceKernel.JobKind.Standalone);
        acp.setJobKind(SINGLE_STAGE_JOB_ID, IAgenticCommerceKernel.JobKind.Standalone);
        acp.setJobKind(BAD_CLOSE_JOB_ID, IAgenticCommerceKernel.JobKind.Standalone);
        acp.setJobKind(LEGACY_CLOSE_JOB_ID, IAgenticCommerceKernel.JobKind.Close);
        acp.setJobKind(REPLACEMENT_CLOSE_JOB_ID, IAgenticCommerceKernel.JobKind.Standalone);
    }

    function testSingleStageCommitRequiresRegisteredUnderwriter() public {
        vm.expectRevert(UNDERWRITER_NOT_REGISTERED_SELECTOR);
        acp.callBeforeAction(
            address(hook), SINGLE_STAGE_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(0))
        );
    }

    function testRegisteredUnderwriterSingleStageCommitStoresSingleStageFlowKind() public {
        _registerUnderwriter();

        acp.callBeforeAction(
            address(hook), SINGLE_STAGE_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(0))
        );

        assertTrue(_flowView().isRegisteredUnderwriter(underwriter));
        assertEq(_flowView().jobFlowKind(SINGLE_STAGE_JOB_ID), FLOW_SINGLE_STAGE);
        assertEq(_flowView().getParentJobId(SINGLE_STAGE_JOB_ID), 0);
        assertEq(_flowView().getCloseJobId(SINGLE_STAGE_JOB_ID), 0);
        assertEq(_flowView().jobSettlementJobId(SINGLE_STAGE_JOB_ID), SINGLE_STAGE_JOB_ID);
    }

    function testTwoStageOpenCommitStoresTwoStageOpenFlowKind() public {
        _registerUnderwriter();

        acp.callBeforeAction(address(hook), OPEN_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(0)));

        assertEq(_flowView().jobFlowKind(OPEN_JOB_ID), FLOW_TWO_STAGE_OPEN);
    }

    function testTwoStageCloseCommitLinksToParentSettlementJobIdWithoutCoreLinkage() public {
        _registerUnderwriter();
        _commitOpenJob();
        _completeOpenJobReadyForClose();

        acp.callBeforeAction(
            address(hook), CLOSE_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(OPEN_JOB_ID))
        );

        assertEq(_flowView().jobFlowKind(CLOSE_JOB_ID), FLOW_TWO_STAGE_CLOSE);
        assertEq(_flowView().getParentJobId(CLOSE_JOB_ID), OPEN_JOB_ID);
        assertEq(_flowView().getCloseJobId(OPEN_JOB_ID), CLOSE_JOB_ID);
        assertEq(_flowView().jobSettlementJobId(OPEN_JOB_ID), OPEN_JOB_ID);
        assertEq(_flowView().jobSettlementJobId(CLOSE_JOB_ID), OPEN_JOB_ID);

        FutureCommit memory commit = abi.decode(abi.encode(hook.getCommit(CLOSE_JOB_ID)), (FutureCommit));
        assertEq(commit.parentJobId, OPEN_JOB_ID);
        assertEq(commit.unlockAt, _commit(0).unlockAt);
    }

    function testTwoStageCloseCommitWorksAfterUnderwriterRemovedFromRegistryWhenParentMatches() public {
        _registerUnderwriter();
        _commitOpenJob();
        _completeOpenJobReadyForClose();

        vm.prank(admin);
        _flowView().unregisterUnderwriter(underwriter);

        acp.callBeforeAction(
            address(hook), CLOSE_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(OPEN_JOB_ID))
        );

        assertEq(_flowView().jobFlowKind(CLOSE_JOB_ID), FLOW_TWO_STAGE_CLOSE);
        assertFalse(_flowView().isRegisteredUnderwriter(underwriter));
    }

    function testTwoStageCloseCommitRevertsWhenProviderDiffersFromParent() public {
        _registerUnderwriter();
        _commitOpenJob();
        _completeOpenJobReadyForClose();

        vm.expectRevert(MCUHookLite.InvalidParentJob.selector);
        acp.callBeforeAction(
            address(hook),
            BAD_CLOSE_JOB_ID,
            SEL_SET_BUDGET,
            _setBudgetData(_commit(OPEN_JOB_ID))
        );
    }

    function testTwoStageCloseCommitRevertsUntilParentJobIsCompletedAndAwaitingClose() public {
        _registerUnderwriter();
        _commitOpenJob();

        vm.expectRevert(MCUHookLite.InvalidState.selector);
        acp.callBeforeAction(
            address(hook), CLOSE_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(OPEN_JOB_ID))
        );
    }

    function testLegacyCoreCloseJobKindIsRejectedByMCUHook() public {
        _registerUnderwriter();
        _commitOpenJob();
        _completeOpenJobReadyForClose();

        vm.expectRevert(UNSUPPORTED_JOB_KIND_SELECTOR);
        acp.callBeforeAction(
            address(hook),
            LEGACY_CLOSE_JOB_ID,
            SEL_SET_BUDGET,
            _setBudgetData(_commit(OPEN_JOB_ID))
        );
    }

    function testOpenJobCompleteTransitionsToAwaitingCloseWithoutSubmit() public {
        _registerUnderwriter();
        _commitOpenJob();
        _completeOpenJobReadyForClose();

        assertEq(uint256(hook.jobSidecarState(OPEN_JOB_ID)), uint256(MCUTypes.SidecarState.AwaitingClose));
        assertEq(hook.jobCompletionObservedAt(OPEN_JOB_ID), 0);
    }

    function testSingleStageSettlementWindowStartsWhenProviderRequestsReleaseAndThenAllowsClientDispute() public {
        _registerUnderwriter();
        _completeSingleStageJobWithoutSettlement();

        assertEq(uint256(hook.jobSidecarState(SINGLE_STAGE_JOB_ID)), uint256(MCUTypes.SidecarState.SuccessPendingConfirmation));
        assertEq(hook.jobDeliveryConfirmationDeadline(SINGLE_STAGE_JOB_ID), 0);

        uint64 requestTime = uint64(block.timestamp);
        vm.prank(coordinator);
        hook.markSuccessPendingCollateralRelease(SINGLE_STAGE_JOB_ID);

        assertEq(
            hook.jobDeliveryConfirmationDeadline(SINGLE_STAGE_JOB_ID),
            requestTime + _commit(0).deliveryConfirmationTimeoutWindow
        );

        vm.prank(coordinator);
        hook.markSuccessDisputeOpen(SINGLE_STAGE_JOB_ID, SUCCESS_DISPUTE_HASH);

        assertEq(uint256(hook.jobSidecarState(SINGLE_STAGE_JOB_ID)), uint256(MCUTypes.SidecarState.SuccessDisputeOpen));
        assertEq(hook.jobLastSuccessDisputeHash(SINGLE_STAGE_JOB_ID), SUCCESS_DISPUTE_HASH);
    }

    function testTwoStageCloseFundAndSubmitAllowedOnceParentJobIsCompletedAndAwaitingClose() public {
        _registerUnderwriter();
        _commitOpenAndCloseJobs();

        acp.callBeforeAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));
        acp.callAfterAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));

        vm.prank(coordinator);
        hook.markProtected(CLOSE_JOB_ID, adapter);

        acp.callBeforeAction(address(hook), CLOSE_JOB_ID, SEL_SUBMIT, _submitActionData());
    }

    function testTwoStageCloseSuccessPendingCollateralReleaseCanBeEnteredFromSuccessDisputeOpen() public {
        _registerUnderwriter();
        _completeCloseJobWithoutSettlement();

        vm.startPrank(coordinator);
        hook.markSuccessPendingCollateralRelease(CLOSE_JOB_ID);
        hook.markSuccessDisputeOpen(CLOSE_JOB_ID, SUCCESS_DISPUTE_HASH);
        hook.markSuccessPendingCollateralRelease(CLOSE_JOB_ID);
        vm.stopPrank();

        assertEq(
            uint256(hook.jobSidecarState(CLOSE_JOB_ID)), uint256(MCUTypes.SidecarState.SuccessPendingCollateralRelease)
        );
    }

    function testTwoStageCloseSuccessDisputeCanBeMarkedSlashed() public {
        _registerUnderwriter();
        _completeCloseJobWithoutSettlement();

        vm.startPrank(coordinator);
        hook.markSuccessPendingCollateralRelease(CLOSE_JOB_ID);
        hook.markSuccessDisputeOpen(CLOSE_JOB_ID, SUCCESS_DISPUTE_HASH);
        hook.markSuccessSlashed(CLOSE_JOB_ID, SUCCESS_DISPUTE_HASH, SLASH_ATTESTATION_HASH);
        vm.stopPrank();

        assertEq(uint256(hook.jobSidecarState(CLOSE_JOB_ID)), uint256(MCUTypes.SidecarState.SuccessSlashed));
    }

    function testTwoStageCloseRejectUsesParentSettlementJobIdAndClearsActiveLinkageWhenSettled() public {
        _registerUnderwriter();
        _commitOpenAndCloseJobs();
        acp.callBeforeAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));
        acp.callAfterAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));

        vm.prank(coordinator);
        hook.markProtected(CLOSE_JOB_ID, adapter);

        acp.callAfterAction(address(hook), CLOSE_JOB_ID, SEL_SUBMIT, _submitActionData());
        acp.callAfterAction(address(hook), CLOSE_JOB_ID, SEL_REJECT, _rejectActionData());

        assertEq(uint256(hook.jobSidecarState(CLOSE_JOB_ID)), uint256(MCUTypes.SidecarState.RejectPendingSlash));

        vm.prank(coordinator);
        hook.markRejectSettled(CLOSE_JOB_ID);

        assertEq(_flowView().getCloseJobId(OPEN_JOB_ID), 0);
    }

    function testTwoStageCloseOpenStateRejectClearsActiveLinkageImmediately() public {
        _registerUnderwriter();
        _commitOpenAndCloseJobs();

        acp.callAfterAction(address(hook), CLOSE_JOB_ID, SEL_REJECT, _rejectActionData());

        assertEq(uint256(hook.jobSidecarState(CLOSE_JOB_ID)), uint256(MCUTypes.SidecarState.RejectSettled));
        assertEq(_flowView().getCloseJobId(OPEN_JOB_ID), 0);

        acp.callBeforeAction(
            address(hook),
            REPLACEMENT_CLOSE_JOB_ID,
            SEL_SET_BUDGET,
            _setBudgetData(_commit(OPEN_JOB_ID))
        );

        assertEq(_flowView().getCloseJobId(OPEN_JOB_ID), REPLACEMENT_CLOSE_JOB_ID);
    }

    function testTwoStageCloseExpirySettlementClearsActiveLinkage() public {
        _registerUnderwriter();
        _commitOpenAndCloseJobs();
        acp.callBeforeAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));
        acp.callAfterAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));

        vm.prank(coordinator);
        hook.markExpirySettled(CLOSE_JOB_ID);

        assertEq(_flowView().getCloseJobId(OPEN_JOB_ID), 0);
    }

    function testTwoStageCloseReplacementCanBeCommittedAfterPriorCloseSettledAway() public {
        _registerUnderwriter();
        _commitOpenAndCloseJobs();
        acp.callBeforeAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));
        acp.callAfterAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));

        vm.prank(coordinator);
        hook.markExpirySettled(CLOSE_JOB_ID);

        acp.callBeforeAction(
            address(hook),
            REPLACEMENT_CLOSE_JOB_ID,
            SEL_SET_BUDGET,
            _setBudgetData(_commit(OPEN_JOB_ID))
        );

        assertEq(_flowView().getCloseJobId(OPEN_JOB_ID), REPLACEMENT_CLOSE_JOB_ID);
    }

    function _job(uint256 jobId, address provider_) internal view returns (IAgenticCommerceKernel.Job memory) {
        return _job(jobId, provider_, IAgenticCommerceKernel.JobStatus.Open);
    }

    function _job(uint256 jobId, address provider_, IAgenticCommerceKernel.JobStatus status_)
        internal
        view
        returns (IAgenticCommerceKernel.Job memory)
    {
        return IAgenticCommerceKernel.Job({
            id: jobId,
            client: client,
            provider: provider_,
            evaluator: evaluator,
            hook: address(hook),
            description: "mcu job",
            budget: 1,
            expiredAt: block.timestamp + 1 days,
            status: status_
        });
    }

    function _commit(uint256 parentJobId) internal view returns (FutureCommit memory) {
        return FutureCommit({
            parentJobId: parentJobId,
            underwriter: underwriter,
            merchantExecutionWallet: merchantExecutionWallet,
            decisionFeeUsdc: 5e6,
            requiredCollateralUsdc: 100e6,
            fundedPrincipalUsdc: 80e6,
            coverageCapUsdc: 100e6,
            validUntil: uint64(block.timestamp + 1 days),
            executeUntil: uint64(block.timestamp + 2 days),
            unlockAt: uint64(block.timestamp + 3 days),
            deliveryConfirmationTimeoutWindow: uint64(2 days),
            policyHash: keccak256("policy"),
            quoteIdHash: keccak256("quote"),
            releasePrincipal: true
        });
    }

    function _flowView() internal view returns (IMCUHookLiteFlowAdminView) {
        return IMCUHookLiteFlowAdminView(address(hook));
    }

    function _registerUnderwriter() internal {
        vm.prank(admin);
        _flowView().registerUnderwriter(underwriter);
    }

    function _setBudgetData(FutureCommit memory commit) internal pure returns (bytes memory) {
        return abi.encode(uint256(1), abi.encode(commit));
    }

    function _commitOpenJob() internal {
        acp.callBeforeAction(address(hook), OPEN_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(0)));
    }

    function _commitSingleStageJob() internal {
        acp.callBeforeAction(
            address(hook),
            SINGLE_STAGE_JOB_ID,
            SEL_SET_BUDGET,
            _setBudgetData(_commit(0))
        );
    }

    function _commitOpenAndCloseJobs() internal {
        _commitOpenJob();
        _completeOpenJobReadyForClose();
        acp.callBeforeAction(
            address(hook), CLOSE_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(OPEN_JOB_ID))
        );
    }

    function _protectOpenJob() internal {
        acp.callAfterAction(address(hook), OPEN_JOB_ID, SEL_FUND, bytes(""));

        vm.prank(coordinator);
        hook.markProtected(OPEN_JOB_ID, adapter);
    }

    function _completeOpenJobReadyForClose() internal {
        _protectOpenJob();
        acp.setJob(_job(OPEN_JOB_ID, provider, IAgenticCommerceKernel.JobStatus.Completed));
        acp.callAfterAction(address(hook), OPEN_JOB_ID, SEL_COMPLETE, _completeActionData());
    }

    function _completeSingleStageJobWithoutSettlement() internal {
        _commitSingleStageJob();
        acp.callBeforeAction(address(hook), SINGLE_STAGE_JOB_ID, SEL_FUND, bytes(""));
        acp.callAfterAction(address(hook), SINGLE_STAGE_JOB_ID, SEL_FUND, bytes(""));

        vm.prank(coordinator);
        hook.markProtected(SINGLE_STAGE_JOB_ID, adapter);

        acp.callAfterAction(address(hook), SINGLE_STAGE_JOB_ID, SEL_SUBMIT, _submitActionData());
        acp.setJob(_job(SINGLE_STAGE_JOB_ID, provider, IAgenticCommerceKernel.JobStatus.Completed));
        acp.callAfterAction(address(hook), SINGLE_STAGE_JOB_ID, SEL_COMPLETE, _completeActionData());
    }

    function _completeCloseJobWithoutSettlement() internal {
        _commitOpenAndCloseJobs();
        acp.callBeforeAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));
        acp.callAfterAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));

        vm.prank(coordinator);
        hook.markProtected(CLOSE_JOB_ID, adapter);

        acp.callAfterAction(address(hook), CLOSE_JOB_ID, SEL_SUBMIT, _submitActionData());
        acp.setJob(_job(CLOSE_JOB_ID, provider, IAgenticCommerceKernel.JobStatus.Completed));
        acp.callAfterAction(address(hook), CLOSE_JOB_ID, SEL_COMPLETE, _completeActionData());
    }

    function _submitActionData() internal pure returns (bytes memory) {
        bytes32 bundleHash = keccak256("bundle");
        return abi.encode(
            bundleHash,
            abi.encode(
                MCUTypes.SubmitEvidence({
                    bundleHash: bundleHash,
                    permitDigest: bytes32(0),
                    execRequestHash: bytes32(0),
                    execResultHash: bytes32(0),
                    quoteIdHash: keccak256("quote"),
                    policyHash: keccak256("policy")
                })
            )
        );
    }

    function _completeActionData() internal pure returns (bytes memory) {
        return abi.encode(keccak256("complete-reason"), bytes(""));
    }

    function _rejectActionData() internal pure returns (bytes memory) {
        return abi.encode(
            keccak256("reject-reason"),
            abi.encode(
                MCUTypes.RejectContext({
                    slashAttestationHash: bytes32(0),
                    reasonCode: keccak256("reject-reason")
                })
            )
        );
    }
}
