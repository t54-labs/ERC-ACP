// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/mcu/IAgenticCommerceKernel.sol";
import "../../contracts/mcu/ICollateralManager.sol";
import "../../contracts/hooks/underwriting/IUnderwritingHookView.sol";
import "../../contracts/hooks/underwriting/UnderwritingTypes.sol";
import "../../contracts/settlement/SettlementTypes.sol";
import "../../contracts/settlement/UnderwritingEvaluator.sol";

contract MockSettlementEvaluatorACP is IAgenticCommerceKernel {
    address public override paymentToken;
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
}

contract MockSuccessDisputeCoordinator {
    bool public applyCalled;
    uint256 public lastJobId;

    function applySuccessDisputeDecision(
        SettlementTypes.SuccessDisputeDecision calldata decision,
        ICollateralManager.SlashAttestation calldata,
        bytes calldata
    ) external {
        applyCalled = true;
        lastJobId = decision.jobId;
    }
}

contract UnderwritingEvaluatorTest is Test {
    bytes32 internal constant COMPLETE_TYPEHASH =
        keccak256("CompleteDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 internal constant REJECT_TYPEHASH =
        keccak256("RejectDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 internal constant SUCCESS_DISPUTE_TYPEHASH = keccak256(
        "SuccessDisputeDecision(uint256 jobId,bytes32 disputeHash,uint8 outcome,bytes32 reason,bytes32 slashAttestationHash,uint64 deadline,uint256 nonce)"
    );

    uint256 internal rootUnderwriterPk;
    address internal rootUnderwriter;
    uint256 internal openUnderwriterPk;
    address internal openUnderwriter;
    uint256 internal closeUnderwriterPk;
    address internal closeUnderwriter;

    MockSettlementEvaluatorACP internal acp;
    MockSettlementEvaluatorHook internal hook;
    MockSuccessDisputeCoordinator internal coordinator;
    UnderwritingEvaluator internal evaluator;

    function setUp() public {
        (rootUnderwriter, rootUnderwriterPk) = makeAddrAndKey("root-underwriter");
        (openUnderwriter, openUnderwriterPk) = makeAddrAndKey("open-underwriter");
        (closeUnderwriter, closeUnderwriterPk) = makeAddrAndKey("close-underwriter");

        acp = new MockSettlementEvaluatorACP(address(0xBEEF));
        hook = new MockSettlementEvaluatorHook();
        coordinator = new MockSuccessDisputeCoordinator();
        evaluator = new UnderwritingEvaluator(acp, hook, address(coordinator));
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

    function testResolveSuccessDisputeBySigRejectsBeforeCompleted() public {
        _seedJob(21, IAgenticCommerceKernel.JobStatus.Submitted, rootUnderwriter);

        SettlementTypes.SuccessDisputeDecision memory decision = _successDisputeDecision(21);

        vm.expectRevert(UnderwritingEvaluator.WrongDecisionStatus.selector);
        evaluator.resolveSuccessDisputeBySig(
            decision, _emptySlashAttestation(), bytes(""), _signSuccessDisputeDecision(decision, rootUnderwriterPk)
        );
    }

    function testResolveSuccessDisputeBySigCallsCoordinatorAfterCompleted() public {
        _seedJob(22, IAgenticCommerceKernel.JobStatus.Completed, rootUnderwriter);

        SettlementTypes.SuccessDisputeDecision memory decision = _successDisputeDecision(22);

        evaluator.resolveSuccessDisputeBySig(
            decision, _emptySlashAttestation(), bytes(""), _signSuccessDisputeDecision(decision, rootUnderwriterPk)
        );

        assertTrue(coordinator.applyCalled());
        assertEq(coordinator.lastJobId(), 22);
    }

    function _seedJob(uint256 jobId, IAgenticCommerceKernel.JobStatus status_, address underwriter) internal {
        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: jobId,
                client: makeAddr("client"),
                provider: makeAddr("provider"),
                evaluator: address(evaluator),
                hook: address(hook),
                description: "settlement evaluator job",
                budget: 1,
                expiredAt: block.timestamp + 1 days,
                status: status_
            })
        );
        hook.seed(jobId, UnderwritingTypes.SidecarState.EvidenceSubmitted, underwriter, jobId);
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

    function _successDisputeDecision(uint256 jobId) internal view returns (SettlementTypes.SuccessDisputeDecision memory) {
        return SettlementTypes.SuccessDisputeDecision({
            jobId: jobId,
            disputeHash: keccak256("dispute"),
            outcome: SettlementTypes.SuccessDisputeOutcome.ReleaseCollateral,
            reason: keccak256("release"),
            slashAttestationHash: bytes32(0),
            deadline: uint64(block.timestamp + 1 days),
            nonce: jobId
        });
    }

    function _emptySlashAttestation() internal pure returns (ICollateralManager.SlashAttestation memory) {
        return ICollateralManager.SlashAttestation({
            settlementJobId: 0,
            safe: address(0),
            user: address(0),
            merchant: address(0),
            slashAmountUsdc: 0,
            reasonCode: bytes32(0),
            validUntil: 0,
            nonce: 0
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

    function _signSuccessDisputeDecision(SettlementTypes.SuccessDisputeDecision memory decision, uint256 signerPk)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                keccak256(
                    abi.encode(
                        SUCCESS_DISPUTE_TYPEHASH,
                        decision.jobId,
                        decision.disputeHash,
                        uint8(decision.outcome),
                        decision.reason,
                        decision.slashAttestationHash,
                        decision.deadline,
                        decision.nonce
                    )
                )
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
