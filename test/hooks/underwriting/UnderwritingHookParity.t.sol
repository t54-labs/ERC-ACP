// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../../contracts/AgenticCommerceHooked.sol";
import "../../../contracts/hooks/underwriting/UnderwritingCoordinator.sol";
import "../../../contracts/hooks/underwriting/UnderwritingEvaluator.sol";
import "../../../contracts/hooks/underwriting/UnderwritingHook.sol";
import "../../../contracts/hooks/underwriting/UnderwritingTypes.sol";
import "../../../contracts/hooks/underwriting/UnderwritingWorkflowCore.sol";
import "../../mocks/MockERC20.sol";

contract UnderwritingHookParityTest is Test {
    uint256 internal constant JOB_BUDGET = 100e6;

    address internal treasury = makeAddr("treasury");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal otherProvider = makeAddr("otherProvider");

    uint256 internal underwriterPk;
    address internal underwriter;

    MockERC20 internal usdc;
    AgenticCommerceHooked internal acp;
    UnderwritingHook internal hook;
    UnderwritingCoordinator internal coordinator;
    UnderwritingEvaluator internal evaluator;

    function setUp() public {
        (underwriter, underwriterPk) = makeAddrAndKey("underwriter");

        usdc = new MockERC20("Mock USDC", "mUSDC");
        acp = new AgenticCommerceHooked(address(usdc), treasury);
        hook = new UnderwritingHook(address(acp), address(this));
        evaluator = new UnderwritingEvaluator(address(acp), address(hook));
        coordinator = new UnderwritingCoordinator(address(acp), address(hook));

        hook.setWiring(address(evaluator), address(coordinator));

        usdc.mint(client, 1_000_000e6);

        vm.prank(client);
        usdc.approve(address(acp), type(uint256).max);
    }

    function testRootAndCloseLifecycleMatchesCanonicalHookParity() public {
        uint256 rootJobId = _createJob(provider, "root underwriting job");

        vm.expectRevert(UnderwritingWorkflowCore.UnderwriterNotRegistered.selector);
        vm.prank(client);
        acp.setBudget(rootJobId, JOB_BUDGET, abi.encode(_commit(0, true)));

        hook.registerUnderwriter(underwriter);

        vm.prank(client);
        acp.setBudget(rootJobId, JOB_BUDGET, abi.encode(_commit(0, true)));

        assertEq(uint256(hook.jobSidecarState(rootJobId)), uint256(UnderwritingTypes.SidecarState.Committed));
        assertEq(hook.jobUnderwriter(rootJobId), underwriter);
        assertEq(hook.jobSettlementJobId(rootJobId), rootJobId);

        vm.prank(client);
        acp.fund(rootJobId, JOB_BUDGET, bytes(""));

        assertEq(uint256(hook.jobSidecarState(rootJobId)), uint256(UnderwritingTypes.SidecarState.FeeEscrowed));

        coordinator.orchestrateFunding(rootJobId);

        assertEq(uint256(hook.jobSidecarState(rootJobId)), uint256(UnderwritingTypes.SidecarState.Protected));

        UnderwritingTypes.SubmitEvidence memory rootEvidence = _evidence("root bundle");

        vm.expectRevert(UnderwritingWorkflowCore.EvidenceMismatch.selector);
        vm.prank(provider);
        acp.submit(rootJobId, keccak256("wrong bundle"), abi.encode(rootEvidence));

        vm.prank(provider);
        acp.submit(rootJobId, rootEvidence.bundleHash, abi.encode(rootEvidence));

        assertEq(uint256(hook.jobSidecarState(rootJobId)), uint256(UnderwritingTypes.SidecarState.EvidenceSubmitted));

        vm.prank(address(evaluator));
        acp.complete(rootJobId, keccak256("root approved"), bytes(""));

        assertEq(uint256(hook.jobSidecarState(rootJobId)), uint256(UnderwritingTypes.SidecarState.AwaitingClose));
        assertTrue(hook.isAwaitingClose(rootJobId));

        uint256 closeJobId = _createJob(provider, "close underwriting job");

        vm.prank(client);
        acp.setBudget(closeJobId, JOB_BUDGET / 2, abi.encode(_commit(rootJobId, false)));

        assertEq(hook.getParentJobId(closeJobId), rootJobId);
        assertEq(hook.getActiveCloseJobId(rootJobId), closeJobId);
        assertEq(hook.jobSettlementJobId(closeJobId), rootJobId);

        vm.prank(client);
        acp.fund(closeJobId, JOB_BUDGET / 2, bytes(""));

        coordinator.orchestrateFunding(closeJobId);

        UnderwritingTypes.SubmitEvidence memory closeEvidence = _evidence("close bundle");
        vm.prank(provider);
        acp.submit(closeJobId, closeEvidence.bundleHash, abi.encode(closeEvidence));

        vm.prank(address(evaluator));
        acp.complete(closeJobId, keccak256("close approved"), bytes(""));

        assertEq(uint256(hook.jobSidecarState(closeJobId)), uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation));
        assertEq(uint256(hook.jobSidecarState(rootJobId)), uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation));
        assertFalse(hook.isAwaitingClose(rootJobId));
        assertEq(hook.getActiveCloseJobId(rootJobId), 0);
    }

    function testCloseJobAdmissionRejectsProviderMismatch() public {
        hook.registerUnderwriter(underwriter);

        uint256 rootJobId = _createJob(provider, "root underwriting job");

        vm.startPrank(client);
        acp.setBudget(rootJobId, JOB_BUDGET, abi.encode(_commit(0, true)));
        acp.fund(rootJobId, JOB_BUDGET, bytes(""));
        vm.stopPrank();

        coordinator.orchestrateFunding(rootJobId);

        UnderwritingTypes.SubmitEvidence memory rootEvidence = _evidence("root bundle");
        vm.prank(provider);
        acp.submit(rootJobId, rootEvidence.bundleHash, abi.encode(rootEvidence));

        vm.prank(address(evaluator));
        acp.complete(rootJobId, keccak256("root approved"), bytes(""));

        uint256 badCloseJobId = _createJob(otherProvider, "bad close job");

        vm.expectRevert(UnderwritingWorkflowCore.ParentMismatch.selector);
        vm.prank(client);
        acp.setBudget(badCloseJobId, JOB_BUDGET / 2, abi.encode(_commit(rootJobId, false)));
    }

    function testCloseJobRejectClearsActiveLinkageAndAllowsReplacement() public {
        hook.registerUnderwriter(underwriter);

        uint256 rootJobId = _createJob(provider, "root underwriting job");

        vm.startPrank(client);
        acp.setBudget(rootJobId, JOB_BUDGET, abi.encode(_commit(0, true)));
        acp.fund(rootJobId, JOB_BUDGET, bytes(""));
        vm.stopPrank();

        coordinator.orchestrateFunding(rootJobId);

        UnderwritingTypes.SubmitEvidence memory rootEvidence = _evidence("root bundle");
        vm.prank(provider);
        acp.submit(rootJobId, rootEvidence.bundleHash, abi.encode(rootEvidence));

        vm.prank(address(evaluator));
        acp.complete(rootJobId, keccak256("root approved"), bytes(""));

        uint256 closeJobId = _createJob(provider, "close underwriting job");

        vm.prank(client);
        acp.setBudget(closeJobId, JOB_BUDGET / 2, abi.encode(_commit(rootJobId, false)));

        assertEq(hook.getActiveCloseJobId(rootJobId), closeJobId);

        vm.prank(client);
        acp.reject(closeJobId, keccak256("close rejected"), bytes(""));

        assertEq(uint256(hook.jobSidecarState(closeJobId)), uint256(UnderwritingTypes.SidecarState.RejectSettled));
        assertEq(hook.getActiveCloseJobId(rootJobId), 0);

        uint256 replacementCloseJobId = _createJob(provider, "replacement close underwriting job");

        vm.prank(client);
        acp.setBudget(replacementCloseJobId, JOB_BUDGET / 3, abi.encode(_commit(rootJobId, false)));

        assertEq(hook.getActiveCloseJobId(rootJobId), replacementCloseJobId);
        assertEq(hook.getParentJobId(replacementCloseJobId), rootJobId);
    }

    function _createJob(address provider_, string memory description) internal returns (uint256 jobId) {
        vm.prank(client);
        jobId = acp.createJob(provider_, address(evaluator), block.timestamp + 1 days, description, address(hook));
    }

    function _commit(uint256 parentJobId, bool allowCloseJob)
        internal
        view
        returns (UnderwritingTypes.UnderwriteCommit memory)
    {
        return UnderwritingTypes.UnderwriteCommit({
            parentJobId: parentJobId,
            underwriter: underwriter,
            validUntil: uint64(block.timestamp + 1 days),
            policyHash: keccak256("policy"),
            quoteIdHash: keccak256("quote"),
            termsHash: keccak256("terms"),
            allowCloseJob: allowCloseJob
        });
    }

    function _evidence(string memory label) internal pure returns (UnderwritingTypes.SubmitEvidence memory) {
        return UnderwritingTypes.SubmitEvidence({
            bundleHash: keccak256(bytes(label)),
            policyHash: keccak256("policy"),
            quoteIdHash: keccak256("quote"),
            termsHash: keccak256("terms")
        });
    }
}
