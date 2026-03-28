// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../contracts/interfaces/IAgenticCommerceKernel.sol";
import "../../contracts/hooks/underwriting/IUnderwritingHookView.sol";
import "../../contracts/hooks/underwriting/UnderwritingTypes.sol";
import "../../contracts/settlement/UnderwritingEvaluator.sol";

interface IUpgradeableUnderwritingEvaluator {
    function initialize(address acp_, address hook_, uint64 clientConfirmationWindowSeconds_, address admin_) external;
    function acp() external view returns (address);
    function hook() external view returns (address);
    function admin() external view returns (address);
    function clientConfirmationWindowSeconds() external view returns (uint64);
    function completeBySig(UnderwritingTypes.CompleteDecision calldata decision, bytes calldata underwriterDecisionSig)
        external;
    function confirmByClient(uint256 jobId, bytes32 reason) external;
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract MockUpgradeableEvaluatorACP is IAgenticCommerceKernel {
    mapping(uint256 jobId => Job) internal jobs;
    bool public completeCalled;
    bool public rejectCalled;
    uint256 public lastCompletedJobId;
    uint256 public lastRejectedJobId;

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

contract MockUpgradeableEvaluatorHook is IUnderwritingHookView {
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

contract UnderwritingEvaluatorV2Mock is UnderwritingEvaluator {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract UnderwritingEvaluatorUpgradeableTest is Test {
    bytes32 internal constant COMPLETE_TYPEHASH =
        keccak256("CompleteDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");

    address internal admin = makeAddr("admin");
    address internal attacker = makeAddr("attacker");
    address internal client = makeAddr("client");
    address internal underwriter;
    uint256 internal underwriterPk;

    MockUpgradeableEvaluatorACP internal acp;
    MockUpgradeableEvaluatorHook internal hook;
    IUpgradeableUnderwritingEvaluator internal evaluator;

    function setUp() public {
        (underwriter, underwriterPk) = makeAddrAndKey("underwriter");

        acp = new MockUpgradeableEvaluatorACP();
        hook = new MockUpgradeableEvaluatorHook();
        evaluator = _deployEvaluatorProxy(address(acp), address(hook), 1 hours, admin);
    }

    function testProxyInitializeSetsStorageAndAdminControls() public view {
        assertEq(evaluator.acp(), address(acp));
        assertEq(evaluator.hook(), address(hook));
        assertEq(evaluator.admin(), admin);
        assertEq(evaluator.clientConfirmationWindowSeconds(), 1 hours);
    }

    function testProxyInitializeCannotRunTwice() public {
        vm.prank(admin);
        vm.expectRevert();
        evaluator.initialize(address(acp), address(hook), 1 hours, admin);
    }

    function testUnauthorizedUpgradeReverts() public {
        UnderwritingEvaluatorV2Mock upgradedImplementation = new UnderwritingEvaluatorV2Mock();

        vm.prank(attacker);
        vm.expectRevert();
        evaluator.upgradeToAndCall(address(upgradedImplementation), bytes(""));
    }

    function testAuthorizedUpgradePreservesStoredState() public {
        UnderwritingEvaluatorV2Mock upgradedImplementation = new UnderwritingEvaluatorV2Mock();

        vm.prank(admin);
        evaluator.upgradeToAndCall(address(upgradedImplementation), bytes(""));

        assertEq(UnderwritingEvaluatorV2Mock(address(evaluator)).version(), 2);
        assertEq(evaluator.acp(), address(acp));
        assertEq(evaluator.hook(), address(hook));
        assertEq(evaluator.admin(), admin);
        assertEq(evaluator.clientConfirmationWindowSeconds(), 1 hours);
    }

    function testProxyEvaluatorCompleteBySigPreservesDecisionFlow() public {
        _seedSubmittedJob(1);

        UnderwritingTypes.CompleteDecision memory decision = UnderwritingTypes.CompleteDecision({
            jobId: 1,
            reason: keccak256("complete"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: 1
        });

        vm.warp(block.timestamp + 1 hours + 1);
        evaluator.completeBySig(decision, _signCompleteDecision(decision));

        assertTrue(acp.completeCalled());
        assertEq(acp.lastCompletedJobId(), 1);
    }

    function testProxyEvaluatorConfirmByClientPreservesClientWindowBehavior() public {
        _seedSubmittedJob(2);
        hook.setSubmittedAt(2, uint64(block.timestamp));

        vm.prank(client);
        evaluator.confirmByClient(2, keccak256("client-confirmed"));

        assertTrue(acp.completeCalled());
        assertEq(acp.lastCompletedJobId(), 2);
    }

    function _seedSubmittedJob(uint256 jobId) internal {
        acp.setJob(
            IAgenticCommerceKernel.Job({
                id: jobId,
                client: client,
                provider: makeAddr("provider"),
                evaluator: address(evaluator),
                description: "upgradeable evaluator job",
                budget: 1,
                expiredAt: block.timestamp + 1 days,
                status: IAgenticCommerceKernel.JobStatus.Submitted,
                hook: address(hook),
                paymentToken: address(0xBEEF),
                providerAgentId: 0,
                submittedAt: 0
            })
        );
        hook.seed(jobId, UnderwritingTypes.SidecarState.EvidenceSubmitted, underwriter, jobId);
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
                keccak256(bytes("Underwriting Settlement Evaluator")),
                keccak256(bytes("1")),
                block.chainid,
                address(evaluator)
            )
        );
    }

    function _deployEvaluatorProxy(address acp_, address hook_, uint64 clientConfirmationWindowSeconds_, address admin_)
        internal
        returns (IUpgradeableUnderwritingEvaluator)
    {
        UnderwritingEvaluator implementation = new UnderwritingEvaluator();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeWithSignature(
                "initialize(address,address,uint64,address)", acp_, hook_, clientConfirmationWindowSeconds_, admin_
            )
        );
        return IUpgradeableUnderwritingEvaluator(address(proxy));
    }
}
