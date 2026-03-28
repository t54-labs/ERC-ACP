// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/interfaces/IAgenticCommerceKernel.sol";
import "../../contracts/hooks/underwriting/IUnderwritingHookView.sol";
import "../../contracts/hooks/underwriting/UnderwritingTypes.sol";
import "../../contracts/settlement/UnderwritingEvaluator.sol";

contract MockSettlementEvaluatorACP is IAgenticCommerceKernel {
    address public paymentToken;
    mapping(uint256 jobId => Job) internal jobs;
    bool public completeCalled;
    bool public rejectCalled;
    uint256 public lastCompletedJobId;
    uint256 public lastRejectedJobId;

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

    function complete(uint256 jobId, bytes32, bytes calldata) external override {
        completeCalled = true;
        lastCompletedJobId = jobId;
    }

    function reject(uint256 jobId, bytes32, bytes calldata) external override {
        rejectCalled = true;
        lastRejectedJobId = jobId;
    }
}

contract MockSettlementEvaluatorHook is IUnderwritingHookView {
    mapping(uint256 jobId => UnderwritingTypes.SidecarState) internal sidecarStates;
    mapping(uint256 jobId => address) internal underwriters;
    mapping(uint256 jobId => uint256) internal settlementJobIds;
    mapping(uint256 jobId => uint64) internal submittedAts;

    function seed(
        uint256 jobId,
        UnderwritingTypes.SidecarState sidecarState,
        address underwriter,
        uint256 settlementJobId
    ) external {
        sidecarStates[jobId] = sidecarState;
        underwriters[jobId] = underwriter;
        settlementJobIds[jobId] = settlementJobId;
    }

    function setSubmittedAt(uint256 jobId, uint64 submittedAt) external {
        submittedAts[jobId] = submittedAt;
    }

    function getCommit(uint256) external pure returns (UnderwritingTypes.UnderwriteCommit memory) {
        revert("unused");
    }

    function jobUnderwriter(uint256 jobId) external view returns (address) {
        return underwriters[jobId];
    }

    function jobSidecarState(uint256 jobId) external view returns (UnderwritingTypes.SidecarState) {
        return sidecarStates[jobId];
    }

    function jobSettlementJobId(uint256 jobId) external view returns (uint256) {
        return settlementJobIds[jobId];
    }

    function isAwaitingClose(uint256) external pure returns (bool) {
        return false;
    }

    function getParentJobId(uint256) external pure returns (uint256) {
        return 0;
    }

    function getActiveCloseJobId(uint256) external pure returns (uint256) {
        return 0;
    }

    function jobSubmittedAt(uint256 jobId) external view returns (uint64) {
        return submittedAts[jobId];
    }
}

contract UnderwritingEvaluatorTest is Test {
    bytes32 internal constant COMPLETE_TYPEHASH =
        keccak256("CompleteDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 internal constant REJECT_TYPEHASH =
        keccak256("RejectDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");

    uint256 internal rootUnderwriterPk;
    address internal rootUnderwriter;
    uint256 internal openUnderwriterPk;
    address internal openUnderwriter;
    uint256 internal closeUnderwriterPk;
    address internal closeUnderwriter;

    MockSettlementEvaluatorACP internal acp;
    MockSettlementEvaluatorHook internal hook;
    UnderwritingEvaluator internal evaluator;

    function setUp() public {
        (rootUnderwriter, rootUnderwriterPk) = makeAddrAndKey("root-underwriter");
        (openUnderwriter, openUnderwriterPk) = makeAddrAndKey("open-underwriter");
        (closeUnderwriter, closeUnderwriterPk) = makeAddrAndKey("close-underwriter");

        acp = new MockSettlementEvaluatorACP(address(0xBEEF));
        hook = new MockSettlementEvaluatorHook();
        evaluator = new UnderwritingEvaluator(acp, hook, 1 hours);
    }

    function testCompleteBySigRejectsRootOpenAndCloseBeforeSubmit() public {
        _seedJob(1, IAgenticCommerceKernel.JobStatus.Funded, rootUnderwriter);
        _seedJob(2, IAgenticCommerceKernel.JobStatus.Funded, openUnderwriter);
        _seedJob(3, IAgenticCommerceKernel.JobStatus.Funded, closeUnderwriter);

        vm.expectRevert(UnderwritingEvaluator.WrongDecisionStatus.selector);
        evaluator.completeBySig(_completeDecision(1), _signCompleteDecision(_completeDecision(1), rootUnderwriterPk));

        vm.expectRevert(UnderwritingEvaluator.WrongDecisionStatus.selector);
        evaluator.completeBySig(_completeDecision(2), _signCompleteDecision(_completeDecision(2), openUnderwriterPk));

        vm.expectRevert(UnderwritingEvaluator.WrongDecisionStatus.selector);
        evaluator.completeBySig(_completeDecision(3), _signCompleteDecision(_completeDecision(3), closeUnderwriterPk));
    }

    function testRejectBySigRejectsRootOpenAndCloseBeforeSubmit() public {
        _seedJob(4, IAgenticCommerceKernel.JobStatus.Funded, rootUnderwriter);
        _seedJob(5, IAgenticCommerceKernel.JobStatus.Funded, openUnderwriter);
        _seedJob(6, IAgenticCommerceKernel.JobStatus.Funded, closeUnderwriter);

        vm.expectRevert(UnderwritingEvaluator.WrongDecisionStatus.selector);
        evaluator.rejectBySig(_rejectDecision(4), _signRejectDecision(_rejectDecision(4), rootUnderwriterPk));

        vm.expectRevert(UnderwritingEvaluator.WrongDecisionStatus.selector);
        evaluator.rejectBySig(_rejectDecision(5), _signRejectDecision(_rejectDecision(5), openUnderwriterPk));

        vm.expectRevert(UnderwritingEvaluator.WrongDecisionStatus.selector);
        evaluator.rejectBySig(_rejectDecision(6), _signRejectDecision(_rejectDecision(6), closeUnderwriterPk));
    }

    function testCompleteBySigSucceedsAfterSubmittedAndEvidenceSubmitted() public {
        _seedJob(11, IAgenticCommerceKernel.JobStatus.Submitted, rootUnderwriter);

        UnderwritingTypes.CompleteDecision memory decision = _completeDecision(11);
        evaluator.completeBySig(decision, _signCompleteDecision(decision, rootUnderwriterPk));

        assertTrue(acp.completeCalled());
        assertEq(acp.lastCompletedJobId(), 11);
    }

    function testRejectBySigSucceedsAfterSubmittedAndEvidenceSubmitted() public {
        _seedJob(12, IAgenticCommerceKernel.JobStatus.Submitted, rootUnderwriter);

        UnderwritingTypes.RejectDecision memory decision = _rejectDecision(12);
        evaluator.rejectBySig(decision, _signRejectDecision(decision, rootUnderwriterPk));

        assertTrue(acp.rejectCalled());
        assertEq(acp.lastRejectedJobId(), 12);
    }

    function testCompleteBySigRejectsSubmittedWithoutEvidenceSubmittedState() public {
        _seedJobWithState(13, IAgenticCommerceKernel.JobStatus.Submitted, rootUnderwriter, UnderwritingTypes.SidecarState.Protected);

        UnderwritingTypes.CompleteDecision memory decision = _completeDecision(13);

        vm.expectRevert(UnderwritingEvaluator.WrongDecisionState.selector);
        evaluator.completeBySig(decision, _signCompleteDecision(decision, rootUnderwriterPk));
    }

    function testRejectBySigRejectsSubmittedWithoutEvidenceSubmittedState() public {
        _seedJobWithState(14, IAgenticCommerceKernel.JobStatus.Submitted, rootUnderwriter, UnderwritingTypes.SidecarState.Protected);

        UnderwritingTypes.RejectDecision memory decision = _rejectDecision(14);

        vm.expectRevert(UnderwritingEvaluator.WrongDecisionState.selector);
        evaluator.rejectBySig(decision, _signRejectDecision(decision, rootUnderwriterPk));
    }

    function testClientCanConfirmWithinConfirmationWindow() public {
        uint256 jobId = 100;
        _seedJob(jobId, IAgenticCommerceKernel.JobStatus.Submitted, rootUnderwriter);
        hook.setSubmittedAt(jobId, uint64(block.timestamp));

        address client = makeAddr("client");
        vm.prank(client);
        evaluator.confirmByClient(jobId, keccak256("client-confirmed"));

        assertTrue(acp.completeCalled());
        assertEq(acp.lastCompletedJobId(), jobId);
    }

    function testUnderwriterCannotResolveBeforeClientWindowExpires() public {
        uint256 jobId = 101;
        _seedJob(jobId, IAgenticCommerceKernel.JobStatus.Submitted, rootUnderwriter);
        hook.setSubmittedAt(jobId, uint64(block.timestamp));

        UnderwritingTypes.CompleteDecision memory decision = _completeDecision(jobId);

        vm.expectRevert(UnderwritingEvaluator.ClientConfirmationStillOpen.selector);
        evaluator.completeBySig(decision, _signCompleteDecision(decision, rootUnderwriterPk));
    }

    function testUnderwriterCanResolveAfterClientWindowExpires() public {
        uint256 jobId = 102;
        _seedJob(jobId, IAgenticCommerceKernel.JobStatus.Submitted, rootUnderwriter);
        hook.setSubmittedAt(jobId, uint64(block.timestamp));

        vm.warp(block.timestamp + 1 hours + 1);

        UnderwritingTypes.CompleteDecision memory decision = UnderwritingTypes.CompleteDecision({
            jobId: jobId,
            reason: keccak256("complete"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: jobId
        });

        evaluator.completeBySig(decision, _signCompleteDecision(decision, rootUnderwriterPk));

        assertTrue(acp.completeCalled());
        assertEq(acp.lastCompletedJobId(), jobId);
    }

    function _seedJob(uint256 jobId, IAgenticCommerceKernel.JobStatus status_, address underwriter) internal {
        _seedJobWithState(jobId, status_, underwriter, UnderwritingTypes.SidecarState.EvidenceSubmitted);
    }

    function _seedJobWithState(
        uint256 jobId,
        IAgenticCommerceKernel.JobStatus status_,
        address underwriter,
        UnderwritingTypes.SidecarState sidecarState
    ) internal {
        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: jobId,
                client: makeAddr("client"),
                provider: makeAddr("provider"),
                evaluator: address(evaluator),
                description: "settlement evaluator job",
                budget: 1,
                expiredAt: block.timestamp + 1 days,
                status: status_,
                hook: address(hook),
                paymentToken: acp.paymentToken(),
                providerAgentId: 0,
                submittedAt: 0
            })
        );
        hook.seed(jobId, sidecarState, underwriter, jobId);
    }

    function _completeDecision(uint256 jobId) internal view returns (UnderwritingTypes.CompleteDecision memory) {
        return UnderwritingTypes.CompleteDecision({
            jobId: jobId,
            reason: keccak256("complete"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: jobId
        });
    }

    function _rejectDecision(uint256 jobId) internal view returns (UnderwritingTypes.RejectDecision memory) {
        return UnderwritingTypes.RejectDecision({
            jobId: jobId,
            reason: keccak256("reject"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: jobId
        });
    }

    function _signCompleteDecision(UnderwritingTypes.CompleteDecision memory decision, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                keccak256(abi.encode(COMPLETE_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signRejectDecision(UnderwritingTypes.RejectDecision memory decision, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                keccak256(abi.encode(REJECT_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator() internal view returns (bytes32) {
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
}
