// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../contracts/AgenticCommerceHooked.sol";
import "../../../contracts/hooks/underwriting/UnderwritingCoordinator.sol";
import "../../../contracts/hooks/underwriting/UnderwritingEvaluator.sol";
import "../../../contracts/hooks/underwriting/UnderwritingHook.sol";
import "../../../contracts/hooks/underwriting/UnderwritingTypes.sol";
import "../../mocks/MockERC20.sol";

contract MockEvaluatorParitySettlementCoordinator {
    AgenticCommerceHooked public immutable acp;
    UnderwritingHook public immutable hook;
    address public immutable collateralManager;

    constructor(address acpContract_, address hook_) {
        acp = AgenticCommerceHooked(acpContract_);
        hook = UnderwritingHook(hook_);
        collateralManager = address(this);
    }

    function orchestrateFunding(uint256 jobId) external {
        AgenticCommerceHooked.Job memory job = acp.getJob(jobId);
        if (job.hook != address(hook)) revert UnderwritingCoordinator.WrongHook();
        if (job.status != AgenticCommerceHooked.JobStatus.Funded) revert UnderwritingCoordinator.WrongJobStatus();
        if (hook.jobSidecarState(jobId) != UnderwritingTypes.SidecarState.FeeEscrowed) {
            revert UnderwritingCoordinator.InvalidState();
        }

        hook.markProtected(jobId);
    }
}

contract UnderwritingEvaluatorParityTest is Test {
    bytes32 internal constant COMPLETE_TYPEHASH =
        keccak256("CompleteDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");

    uint256 internal constant JOB_BUDGET = 100e6;

    address internal treasury = makeAddr("treasury");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");

    uint256 internal underwriterPk;
    address internal underwriter;

    MockERC20 internal usdc;
    AgenticCommerceHooked internal acp;
    UnderwritingHook internal hook;
    MockEvaluatorParitySettlementCoordinator internal coordinator;
    UnderwritingEvaluator internal evaluator;

    function setUp() public {
        (underwriter, underwriterPk) = makeAddrAndKey("underwriter");

        usdc = new MockERC20("Mock USDC", "mUSDC");
        acp = new AgenticCommerceHooked(address(usdc), treasury);
        hook = new UnderwritingHook(address(acp), address(this));
        evaluator = new UnderwritingEvaluator(address(acp), address(hook));
        coordinator = new MockEvaluatorParitySettlementCoordinator(address(acp), address(hook));

        hook.setWiring(address(evaluator), address(coordinator));
        hook.registerUnderwriter(underwriter);

        usdc.mint(client, 1_000_000e6);

        vm.prank(client);
        usdc.approve(address(acp), type(uint256).max);
    }

    function testCompleteBySigRejectsBeforeSubmitted() public {
        uint256 jobId = _createCommittedFundedProtectedJob();

        UnderwritingTypes.CompleteDecision memory decision = UnderwritingTypes.CompleteDecision({
            jobId: jobId,
            reason: keccak256("complete"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: 1
        });

        vm.expectRevert(UnderwritingEvaluator.WrongDecisionStatus.selector);
        evaluator.completeBySig(decision, _signCompleteDecision(decision));
    }

    function testCompleteBySigSucceedsAfterSubmittedAndEvidenceSubmitted() public {
        uint256 jobId = _createCommittedFundedProtectedJob();
        UnderwritingTypes.SubmitEvidence memory evidence = _evidence();

        vm.prank(provider);
        acp.submit(jobId, evidence.bundleHash, abi.encode(evidence));

        UnderwritingTypes.CompleteDecision memory decision = UnderwritingTypes.CompleteDecision({
            jobId: jobId,
            reason: keccak256("complete"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: 2
        });

        evaluator.completeBySig(decision, _signCompleteDecision(decision));

        AgenticCommerceHooked.Job memory job = acp.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgenticCommerceHooked.JobStatus.Completed));
        assertEq(
            uint256(hook.jobSidecarState(jobId)),
            uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation)
        );
    }

    function _createCommittedFundedProtectedJob() internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = acp.createJob(provider, address(evaluator), block.timestamp + 1 days, "underwriting job", address(hook));

        vm.startPrank(client);
        acp.setBudget(jobId, JOB_BUDGET, abi.encode(_commit()));
        acp.fund(jobId, JOB_BUDGET, bytes(""));
        vm.stopPrank();

        coordinator.orchestrateFunding(jobId);
    }

    function _commit() internal view returns (UnderwritingTypes.UnderwriteCommit memory) {
        return UnderwritingTypes.UnderwriteCommit({
            parentJobId: 0,
            underwriter: underwriter,
            validUntil: uint64(block.timestamp + 1 days),
            policyHash: keccak256("policy"),
            quoteIdHash: keccak256("quote"),
            termsHash: keccak256("terms"),
            allowCloseJob: false
        });
    }

    function _evidence() internal pure returns (UnderwritingTypes.SubmitEvidence memory) {
        return UnderwritingTypes.SubmitEvidence({
            bundleHash: keccak256("bundle"),
            policyHash: keccak256("policy"),
            quoteIdHash: keccak256("quote"),
            termsHash: keccak256("terms")
        });
    }

    function _signCompleteDecision(UnderwritingTypes.CompleteDecision memory decision) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                keccak256(abi.encode(COMPLETE_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(underwriterPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Underwriting Evaluator")),
                keccak256(bytes("1")),
                block.chainid,
                address(evaluator)
            )
        );
    }
}
