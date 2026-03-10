// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/mcu/UnderwriterEvaluator.sol";
import "../../contracts/mcu/IAgenticCommerceKernel.sol";
import "../../contracts/mcu/IBondManager.sol";
import "../../contracts/mcu/MCUTypes.sol";

contract MockEvaluatorACP is IAgenticCommerceKernel {
    address public override paymentToken;
    Job internal job;
    JobKind internal jobKind;
    bool public completeCalled;
    bool public rejectCalled;
    uint256 public lastCompletedJobId;
    uint256 public lastRejectedJobId;
    bytes32 public lastCompleteReason;
    bytes32 public lastRejectReason;

    constructor(address paymentToken_) {
        paymentToken = paymentToken_;
    }

    function setJob(Job memory job_) external {
        job = job_;
    }

    function getJob(uint256) external view override returns (Job memory) {
        return job;
    }

    function setJobKind(JobKind kind) external {
        jobKind = kind;
    }

    function getJobKind(uint256) external view override returns (JobKind) {
        return jobKind;
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

    function complete(uint256 jobId, bytes32 reason, bytes calldata) external override {
        completeCalled = true;
        lastCompletedJobId = jobId;
        lastCompleteReason = reason;
    }

    function reject(uint256 jobId, bytes32 reason, bytes calldata) external override {
        rejectCalled = true;
        lastRejectedJobId = jobId;
        lastRejectReason = reason;
    }
}

contract MockEvaluatorHook {
    address internal underwriter;
    bytes32 internal memoId;
    MCUTypes.SidecarState internal sidecarState;

    function seed(address underwriter_, bytes32 memoId_, MCUTypes.SidecarState sidecarState_) external {
        underwriter = underwriter_;
        memoId = memoId_;
        sidecarState = sidecarState_;
    }

    function jobUnderwriter(uint256) external view returns (address) {
        return underwriter;
    }

    function jobMemoId(uint256) external view returns (bytes32) {
        return memoId;
    }

    function jobSidecarState(uint256) external view returns (MCUTypes.SidecarState) {
        return sidecarState;
    }
}

contract MockSuccessDisputeCoordinator {
    bool public applyCalled;
    uint256 public lastJobId;
    bytes32 public lastMemoId;
    bytes32 public lastDisputeHash;
    uint8 public lastOutcome;
    bytes32 public lastSlashAttestationHash;
    bytes public lastSlashSig;

    function applySuccessDisputeDecision(
        MCUTypes.SuccessDisputeDecision calldata decision,
        IBondManager.SlashAttestation calldata,
        bytes calldata slashSig
    ) external {
        applyCalled = true;
        lastJobId = decision.jobId;
        lastMemoId = decision.memoId;
        lastDisputeHash = decision.disputeHash;
        lastOutcome = uint8(decision.outcome);
        lastSlashAttestationHash = decision.slashAttestationHash;
        lastSlashSig = slashSig;
    }
}

contract UnderwriterEvaluatorTest is Test {
    bytes32 internal constant COMPLETE_TYPEHASH =
        keccak256("CompleteDecision(uint256 jobId,bytes32 memoId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 internal constant REJECT_TYPEHASH = keccak256(
        "RejectDecision(uint256 jobId,bytes32 memoId,bytes32 reason,bytes32 slashAttestationHash,uint64 deadline,uint256 nonce)"
    );
    bytes32 internal constant SUCCESS_DISPUTE_TYPEHASH = keccak256(
        "SuccessDisputeDecision(uint256 jobId,bytes32 memoId,bytes32 disputeHash,uint8 outcome,bytes32 reason,bytes32 slashAttestationHash,uint64 deadline,uint256 nonce)"
    );

    uint256 internal constant JOB_ID = 1;
    bytes32 internal constant MEMO_ID = keccak256("memo-id");
    bytes32 internal constant DISPUTE_HASH = keccak256("success-dispute");
    bytes32 internal constant DISPUTE_REASON = keccak256("merchant-won");

    uint256 internal underwriterPk;
    address internal underwriter;
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal adapter = makeAddr("adapter");

    MockEvaluatorACP internal acp;
    MockEvaluatorHook internal hook;
    MockSuccessDisputeCoordinator internal coordinator;
    UnderwriterEvaluator internal evaluator;

    function setUp() public {
        (underwriter, underwriterPk) = makeAddrAndKey("underwriter");

        acp = new MockEvaluatorACP(address(0xBEEF));
        hook = new MockEvaluatorHook();
        coordinator = new MockSuccessDisputeCoordinator();
        evaluator = new UnderwriterEvaluator(acp, IMCUHookView(address(hook)), address(coordinator));

        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: JOB_ID,
                client: client,
                provider: provider,
                evaluator: address(evaluator),
                hook: address(hook),
                description: "mcu job",
                budget: 1,
                expiredAt: block.timestamp + 1 days,
                status: IAgenticCommerceKernel.JobStatus.Completed
            })
        );

        hook.seed(underwriter, MEMO_ID, MCUTypes.SidecarState.SuccessDisputeOpen);
    }

    function testCompleteBySigAllowsOpenJobsFromFundedWithoutSubmit() public {
        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: JOB_ID,
                client: client,
                provider: provider,
                evaluator: address(evaluator),
                hook: address(hook),
                description: "open mcu job",
                budget: 1,
                expiredAt: block.timestamp + 1 days,
                status: IAgenticCommerceKernel.JobStatus.Funded
            })
        );
        acp.setJobKind(IAgenticCommerceKernel.JobKind.Open);
        hook.seed(underwriter, MEMO_ID, MCUTypes.SidecarState.Protected);

        UnderwriterEvaluator.CompleteDecision memory decision = UnderwriterEvaluator.CompleteDecision({
            jobId: JOB_ID,
            memoId: MEMO_ID,
            reason: keccak256("principal-deployed"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: 11
        });

        evaluator.completeBySig(decision, _signCompleteDecision(decision));

        assertTrue(acp.completeCalled());
        assertEq(acp.lastCompletedJobId(), JOB_ID);
        assertEq(acp.lastCompleteReason(), decision.reason);
    }

    function testRejectBySigAllowsOpenJobsFromFundedWithoutSubmit() public {
        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: JOB_ID,
                client: client,
                provider: provider,
                evaluator: address(evaluator),
                hook: address(hook),
                description: "open mcu job",
                budget: 1,
                expiredAt: block.timestamp + 1 days,
                status: IAgenticCommerceKernel.JobStatus.Funded
            })
        );
        acp.setJobKind(IAgenticCommerceKernel.JobKind.Open);
        hook.seed(underwriter, MEMO_ID, MCUTypes.SidecarState.Protected);

        UnderwriterEvaluator.RejectDecision memory decision = UnderwriterEvaluator.RejectDecision({
            jobId: JOB_ID,
            memoId: MEMO_ID,
            reason: keccak256("deployment-rejected"),
            slashAttestationHash: bytes32(0),
            deadline: uint64(block.timestamp + 1 days),
            nonce: 12
        });

        evaluator.rejectBySig(decision, _signRejectDecision(decision));

        assertTrue(acp.rejectCalled());
        assertEq(acp.lastRejectedJobId(), JOB_ID);
        assertEq(acp.lastRejectReason(), decision.reason);
    }

    function testResolveSuccessDisputeBySigCallsCoordinatorForReleaseDecision() public {
        MCUTypes.SuccessDisputeDecision memory decision =
            _successDisputeDecision(MCUTypes.SuccessDisputeOutcome.ReleaseBond, bytes32(0), 1);

        evaluator.resolveSuccessDisputeBySig(
            decision, _emptySlashAttestation(), bytes(""), _signSuccessDisputeDecision(decision)
        );

        assertTrue(coordinator.applyCalled());
        assertEq(coordinator.lastJobId(), JOB_ID);
        assertEq(coordinator.lastMemoId(), MEMO_ID);
        assertEq(coordinator.lastDisputeHash(), DISPUTE_HASH);
        assertEq(coordinator.lastOutcome(), uint8(MCUTypes.SuccessDisputeOutcome.ReleaseBond));
        assertEq(coordinator.lastSlashAttestationHash(), bytes32(0));
    }

    function testResolveSuccessDisputeBySigCallsCoordinatorForSlashDecision() public {
        IBondManager.SlashAttestation memory attestation = _slashAttestation();
        bytes32 attestationHash = _hashSlashAttestation(attestation);
        MCUTypes.SuccessDisputeDecision memory decision =
            _successDisputeDecision(MCUTypes.SuccessDisputeOutcome.SlashBond, attestationHash, 2);

        evaluator.resolveSuccessDisputeBySig(
            decision, attestation, bytes("slash-sig"), _signSuccessDisputeDecision(decision)
        );

        assertTrue(coordinator.applyCalled());
        assertEq(coordinator.lastOutcome(), uint8(MCUTypes.SuccessDisputeOutcome.SlashBond));
        assertEq(coordinator.lastSlashAttestationHash(), attestationHash);
        assertEq(coordinator.lastSlashSig(), bytes("slash-sig"));
    }

    function testResolveSuccessDisputeBySigRevertsWhenDecisionExpired() public {
        MCUTypes.SuccessDisputeDecision memory decision =
            _successDisputeDecision(MCUTypes.SuccessDisputeOutcome.ReleaseBond, bytes32(0), 3);
        decision.deadline = uint64(block.timestamp - 1);

        vm.expectRevert(
            abi.encodeWithSelector(UnderwriterEvaluator.DecisionExpired.selector, decision.deadline, uint64(block.timestamp))
        );
        evaluator.resolveSuccessDisputeBySig(
            decision, _emptySlashAttestation(), bytes(""), _signSuccessDisputeDecision(decision)
        );
    }

    function _successDisputeDecision(
        MCUTypes.SuccessDisputeOutcome outcome,
        bytes32 slashAttestationHash,
        uint256 nonce
    ) internal view returns (MCUTypes.SuccessDisputeDecision memory) {
        return MCUTypes.SuccessDisputeDecision({
            jobId: JOB_ID,
            memoId: MEMO_ID,
            disputeHash: DISPUTE_HASH,
            outcome: outcome,
            reason: DISPUTE_REASON,
            slashAttestationHash: slashAttestationHash,
            deadline: uint64(block.timestamp + 1 days),
            nonce: nonce
        });
    }

    function _emptySlashAttestation() internal pure returns (IBondManager.SlashAttestation memory) {
        return IBondManager.SlashAttestation({
            memoId: bytes32(0),
            jobId: 0,
            safe: address(0),
            user: address(0),
            merchant: address(0),
            slashAmountUsdc: 0,
            reasonCode: bytes32(0),
            validUntil: 0,
            nonce: 0
        });
    }

    function _slashAttestation() internal view returns (IBondManager.SlashAttestation memory) {
        return IBondManager.SlashAttestation({
            memoId: MEMO_ID,
            jobId: JOB_ID,
            safe: adapter,
            user: client,
            merchant: provider,
            slashAmountUsdc: 25e6,
            reasonCode: DISPUTE_REASON,
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

    function _signSuccessDisputeDecision(MCUTypes.SuccessDisputeDecision memory decision)
        internal
        view
        returns (bytes memory)
    {
        bytes32 domainSeparator = _domainSeparator();
        bytes32 structHash = keccak256(
            abi.encode(
                SUCCESS_DISPUTE_TYPEHASH,
                decision.jobId,
                decision.memoId,
                decision.disputeHash,
                uint8(decision.outcome),
                decision.reason,
                decision.slashAttestationHash,
                decision.deadline,
                decision.nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(underwriterPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signCompleteDecision(UnderwriterEvaluator.CompleteDecision memory decision) internal view returns (bytes memory) {
        bytes32 domainSeparator = _domainSeparator();
        bytes32 structHash = keccak256(
            abi.encode(
                COMPLETE_TYPEHASH, decision.jobId, decision.memoId, decision.reason, decision.deadline, decision.nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(underwriterPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _signRejectDecision(UnderwriterEvaluator.RejectDecision memory decision) internal view returns (bytes memory) {
        bytes32 domainSeparator = _domainSeparator();
        bytes32 structHash = keccak256(
            abi.encode(
                REJECT_TYPEHASH,
                decision.jobId,
                decision.memoId,
                decision.reason,
                decision.slashAttestationHash,
                decision.deadline,
                decision.nonce
            )
        );
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(underwriterPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator() internal view returns (bytes32) {
        bytes32 domainSeparator = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("MCU Underwriter Evaluator")),
                keccak256(bytes("1")),
                block.chainid,
                address(evaluator)
            )
        );
        return domainSeparator;
    }
}
