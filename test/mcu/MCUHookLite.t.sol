// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/IACPHook.sol";
import "../../contracts/mcu/MCUHookLite.sol";
import "../../contracts/mcu/IAgenticCommerceKernel.sol";
import "../../contracts/mcu/MCUTypes.sol";

interface IMCUHookLiteLinkageView {
    function getJobIdByMemoId(bytes32 memoId) external view returns (uint256);
    function getParentJobId(uint256 jobId) external view returns (uint256);
    function getCloseJobId(uint256 jobId) external view returns (uint256);
}

contract MockHookACP is IAgenticCommerceKernel {
    address public override paymentToken;
    mapping(uint256 jobId => Job) internal jobs;

    constructor(address paymentToken_) {
        paymentToken = paymentToken_;
    }

    function setJob(Job memory job_) external {
        jobs[job_.id] = job_;
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
    uint256 internal constant OPEN_JOB_ID = 1;
    uint256 internal constant CLOSE_JOB_ID = 2;
    uint256 internal constant BAD_CLOSE_JOB_ID = 3;
    bytes32 internal constant OPEN_MEMO_ID = keccak256("open-memo-id");
    bytes32 internal constant CLOSE_MEMO_ID = keccak256("close-memo-id");
    bytes32 internal constant SUCCESS_DISPUTE_HASH = keccak256("success-dispute");
    bytes32 internal constant SLASH_ATTESTATION_HASH = keccak256("slash-attestation");

    struct FutureCommit {
        bytes32 memoId;
        uint256 parentJobId;
        address underwriter;
        address merchantExecutionWallet;
        uint256 decisionFeeUsdc;
        uint256 requiredBondUsdc;
        uint256 fundedPrincipalUsdc;
        uint256 coverageCapUsdc;
        uint64 validUntil;
        uint64 executeUntil;
        uint64 unlockAt;
        uint64 deliveryConfirmationTimeoutWindow;
        bytes32 policyHash;
        bytes32 parentMemoId;
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
        acp.setJob(_job(BAD_CLOSE_JOB_ID, otherProvider));
    }

    function testCloseCommitLinksToParentJobAndBackfillsParentMemoId() public {
        acp.callBeforeAction(address(hook), OPEN_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(OPEN_MEMO_ID, 0, bytes32(0))));
        acp.callBeforeAction(
            address(hook), CLOSE_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(CLOSE_MEMO_ID, OPEN_JOB_ID, bytes32(0)))
        );

        assertEq(IMCUHookLiteLinkageView(address(hook)).getParentJobId(CLOSE_JOB_ID), OPEN_JOB_ID);
        assertEq(IMCUHookLiteLinkageView(address(hook)).getCloseJobId(OPEN_JOB_ID), CLOSE_JOB_ID);
        assertEq(IMCUHookLiteLinkageView(address(hook)).getJobIdByMemoId(OPEN_MEMO_ID), OPEN_JOB_ID);
        assertEq(IMCUHookLiteLinkageView(address(hook)).getJobIdByMemoId(CLOSE_MEMO_ID), CLOSE_JOB_ID);

        (bool ok, bytes memory returndata) =
            address(hook).staticcall(abi.encodeWithSignature("getCommit(uint256)", CLOSE_JOB_ID));
        assertTrue(ok);

        FutureCommit memory commit = abi.decode(returndata, (FutureCommit));
        assertEq(commit.parentJobId, OPEN_JOB_ID);
        assertEq(commit.parentMemoId, OPEN_MEMO_ID);
    }

    function testCloseCommitRevertsWhenProviderDiffersFromParent() public {
        acp.callBeforeAction(address(hook), OPEN_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(OPEN_MEMO_ID, 0, bytes32(0))));

        vm.expectRevert(MCUHookLite.InvalidParentJob.selector);
        acp.callBeforeAction(
            address(hook),
            BAD_CLOSE_JOB_ID,
            SEL_SET_BUDGET,
            _setBudgetData(_commit(keccak256("bad-close-memo-id"), OPEN_JOB_ID, bytes32(0)))
        );
    }

    function testCloseFundRevertsUntilParentJobIsCompletedAndSettled() public {
        _commitOpenAndCloseJobs();

        vm.expectRevert(MCUHookLite.InvalidState.selector);
        acp.callBeforeAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));
    }

    function testCloseFundRevertsWhenParentJobIsCompletedButNotSettled() public {
        _commitOpenAndCloseJobs();
        _completeParentOpenJobWithoutSettlement();

        vm.expectRevert(MCUHookLite.InvalidState.selector);
        acp.callBeforeAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));
    }

    function testCloseFundRevertsWhenParentSidecarSettledButAcpStatusIsNotCompleted() public {
        _commitOpenAndCloseJobs();
        _settleParentOpenJob();
        acp.setJob(_job(OPEN_JOB_ID, provider, IAgenticCommerceKernel.JobStatus.Funded));

        vm.expectRevert(MCUHookLite.InvalidState.selector);
        acp.callBeforeAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));
    }

    function testCloseSubmitRevertsUntilParentJobIsCompletedAndSettled() public {
        _commitOpenAndCloseJobs();
        acp.callAfterAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));

        vm.prank(coordinator);
        hook.markProtected(CLOSE_JOB_ID, adapter);

        vm.expectRevert(MCUHookLite.InvalidState.selector);
        acp.callBeforeAction(address(hook), CLOSE_JOB_ID, SEL_SUBMIT, bytes(""));
    }

    function testCloseFundAndSubmitAllowedOnceParentJobIsCompletedAndSettled() public {
        _commitOpenAndCloseJobs();
        _settleParentOpenJob();

        acp.callBeforeAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));
        acp.callAfterAction(address(hook), CLOSE_JOB_ID, SEL_FUND, bytes(""));

        vm.prank(coordinator);
        hook.markProtected(CLOSE_JOB_ID, adapter);

        acp.callBeforeAction(address(hook), CLOSE_JOB_ID, SEL_SUBMIT, _submitActionData());
    }

    function testOpenJobFundAndSubmitDoNotRequireParentSettlement() public {
        acp.callBeforeAction(address(hook), OPEN_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(OPEN_MEMO_ID, 0, bytes32(0))));

        acp.callBeforeAction(address(hook), OPEN_JOB_ID, SEL_FUND, bytes(""));
        acp.callAfterAction(address(hook), OPEN_JOB_ID, SEL_FUND, bytes(""));

        vm.prank(coordinator);
        hook.markProtected(OPEN_JOB_ID, adapter);

        acp.callBeforeAction(address(hook), OPEN_JOB_ID, SEL_SUBMIT, _submitActionData());
    }

    function testCompleteSetsDeliveryConfirmationDeadlineAndAllowsSuccessDisputeOpen() public {
        acp.callBeforeAction(address(hook), OPEN_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(OPEN_MEMO_ID, 0, bytes32(0))));
        acp.callAfterAction(address(hook), OPEN_JOB_ID, SEL_FUND, bytes(""));

        vm.prank(coordinator);
        hook.markProtected(OPEN_JOB_ID, adapter);

        acp.callAfterAction(address(hook), OPEN_JOB_ID, SEL_SUBMIT, _submitActionData());
        acp.setJob(_job(OPEN_JOB_ID, provider, IAgenticCommerceKernel.JobStatus.Completed));

        uint64 completionTime = uint64(block.timestamp);
        acp.callAfterAction(address(hook), OPEN_JOB_ID, SEL_COMPLETE, _completeActionData());

        assertEq(hook.jobCompletionObservedAt(OPEN_JOB_ID), completionTime);
        assertEq(
            hook.jobDeliveryConfirmationDeadline(OPEN_JOB_ID),
            completionTime + _commit(OPEN_MEMO_ID, 0, bytes32(0)).deliveryConfirmationTimeoutWindow
        );

        vm.prank(coordinator);
        hook.markSuccessDisputeOpen(OPEN_JOB_ID, SUCCESS_DISPUTE_HASH);

        assertEq(uint256(hook.jobSidecarState(OPEN_JOB_ID)), uint256(MCUTypes.SidecarState.SuccessDisputeOpen));
        assertEq(hook.jobLastSuccessDisputeHash(OPEN_JOB_ID), SUCCESS_DISPUTE_HASH);
    }

    function testSuccessPendingBondReleaseCanBeEnteredFromSuccessDisputeOpen() public {
        acp.callBeforeAction(address(hook), OPEN_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(OPEN_MEMO_ID, 0, bytes32(0))));
        _completeParentOpenJobWithoutSettlement();

        vm.startPrank(coordinator);
        hook.markSuccessDisputeOpen(OPEN_JOB_ID, SUCCESS_DISPUTE_HASH);
        hook.markSuccessPendingBondRelease(OPEN_JOB_ID);
        vm.stopPrank();

        assertEq(
            uint256(hook.jobSidecarState(OPEN_JOB_ID)), uint256(MCUTypes.SidecarState.SuccessPendingBondRelease)
        );
    }

    function testSuccessDisputeCanBeMarkedSlashed() public {
        acp.callBeforeAction(address(hook), OPEN_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(OPEN_MEMO_ID, 0, bytes32(0))));
        _completeParentOpenJobWithoutSettlement();

        vm.startPrank(coordinator);
        hook.markSuccessDisputeOpen(OPEN_JOB_ID, SUCCESS_DISPUTE_HASH);
        hook.markSuccessSlashed(OPEN_JOB_ID, SUCCESS_DISPUTE_HASH, SLASH_ATTESTATION_HASH);
        vm.stopPrank();

        assertEq(uint256(hook.jobSidecarState(OPEN_JOB_ID)), uint256(MCUTypes.SidecarState.SuccessSlashed));
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

    function _commit(bytes32 memoId, uint256 parentJobId, bytes32 parentMemoId)
        internal
        view
        returns (FutureCommit memory)
    {
        return FutureCommit({
            memoId: memoId,
            parentJobId: parentJobId,
            underwriter: underwriter,
            merchantExecutionWallet: merchantExecutionWallet,
            decisionFeeUsdc: 5e6,
            requiredBondUsdc: 100e6,
            fundedPrincipalUsdc: 80e6,
            coverageCapUsdc: 100e6,
            validUntil: uint64(block.timestamp + 1 days),
            executeUntil: uint64(block.timestamp + 2 days),
            unlockAt: uint64(block.timestamp + 3 days),
            deliveryConfirmationTimeoutWindow: uint64(2 days),
            policyHash: keccak256("policy"),
            parentMemoId: parentMemoId,
            quoteIdHash: keccak256("quote"),
            releasePrincipal: true
        });
    }

    function _setBudgetData(FutureCommit memory commit) internal pure returns (bytes memory) {
        return abi.encode(uint256(1), abi.encode(commit));
    }

    function _commitOpenAndCloseJobs() internal {
        acp.callBeforeAction(address(hook), OPEN_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(OPEN_MEMO_ID, 0, bytes32(0))));
        acp.callBeforeAction(
            address(hook), CLOSE_JOB_ID, SEL_SET_BUDGET, _setBudgetData(_commit(CLOSE_MEMO_ID, OPEN_JOB_ID, bytes32(0)))
        );
    }

    function _settleParentOpenJob() internal {
        _completeParentOpenJobWithoutSettlement();

        vm.startPrank(coordinator);
        hook.markSuccessPendingBondRelease(OPEN_JOB_ID);
        hook.markSuccessSettled(OPEN_JOB_ID);
        vm.stopPrank();
    }

    function _completeParentOpenJobWithoutSettlement() internal {
        acp.callAfterAction(address(hook), OPEN_JOB_ID, SEL_FUND, bytes(""));

        vm.prank(coordinator);
        hook.markProtected(OPEN_JOB_ID, adapter);

        acp.callAfterAction(address(hook), OPEN_JOB_ID, SEL_SUBMIT, _submitActionData());
        acp.setJob(_job(OPEN_JOB_ID, provider, IAgenticCommerceKernel.JobStatus.Completed));
        acp.callAfterAction(address(hook), OPEN_JOB_ID, SEL_COMPLETE, _completeActionData());
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
}
