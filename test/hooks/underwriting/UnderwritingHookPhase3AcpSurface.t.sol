// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "../../../contracts/BaseACPHook.sol";
import "../../../contracts/hooks/underwriting/UnderwritingHook.sol";
import "../../../contracts/hooks/underwriting/UnderwritingTypes.sol";
import "../../../contracts/hooks/underwriting/UnderwritingWorkflowCore.sol";

library Phase3AcpTypes {
    enum JobStatus {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    struct Job {
        uint256 id;
        address client;
        address provider;
        address evaluator;
        string description;
        uint256 budget;
        uint256 expiredAt;
        JobStatus status;
        address hook;
        address paymentToken;
        uint256 providerAgentId;
        uint256 submittedAt;
    }
}

contract MockPhase3AcpCaller {
    mapping(uint256 => Phase3AcpTypes.Job) internal jobs;

    function setJob(Phase3AcpTypes.Job memory job) external {
        jobs[job.id] = job;
    }

    function getJob(uint256 jobId) external view returns (Phase3AcpTypes.Job memory) {
        return jobs[jobId];
    }

    function callBeforeAction(IACPHook hook, uint256 jobId, bytes4 selector, bytes memory data) external {
        hook.beforeAction(jobId, selector, data);
    }
}

contract MockPhase3WiringTarget {
    address public immutable acp;
    address public immutable hook;

    constructor(address acp_, address hook_) {
        acp = acp_;
        hook = hook_;
    }
}

contract MockPhase3CoordinatorTarget is MockPhase3WiringTarget {
    address public immutable collateralManager;

    constructor(address acp_, address hook_) MockPhase3WiringTarget(acp_, hook_) {
        collateralManager = address(this);
    }
}

contract RecordingBaseACPHook is BaseACPHook {
    address public lastCaller;
    address public lastToken;
    uint256 public lastAmount;
    bytes public lastOptParams;

    constructor(address acpContract_) {
        _initializeBaseACPHook(acpContract_);
    }

    function _preSetBudget(
        uint256,
        address caller,
        address token,
        uint256 amount,
        bytes memory optParams
    ) internal override {
        lastCaller = caller;
        lastToken = token;
        lastAmount = amount;
        lastOptParams = optParams;
    }
}

contract UnderwritingHookPhase3AcpSurfaceTest is Test {
    uint256 internal constant JOB_ID = 1;
    uint256 internal constant AMOUNT = 100e6;

    address internal constant CLIENT = address(0xCA11);
    address internal constant PROVIDER = address(0xBEEF);
    address internal constant USDC = address(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
    address internal constant OTHER_TOKEN = address(0xC0FFEE);
    address internal constant UNDERWRITER = address(0xFEE1);

    MockPhase3AcpCaller internal acp;
    RecordingBaseACPHook internal recordingHook;
    UnderwritingHook internal hook;
    MockPhase3WiringTarget internal evaluator;
    MockPhase3CoordinatorTarget internal coordinator;

    function setUp() public {
        acp = new MockPhase3AcpCaller();
        recordingHook = new RecordingBaseACPHook(address(acp));

        hook = _deployHook(address(acp), address(this));
        evaluator = new MockPhase3WiringTarget(address(acp), address(hook));
        coordinator = new MockPhase3CoordinatorTarget(address(acp), address(hook));

        hook.setWiring(address(evaluator), address(coordinator));
        hook.registerUnderwriter(UNDERWRITER);
        hook.setAllowedSettlementToken(USDC);

        acp.setJob(
            Phase3AcpTypes.Job({
                id: JOB_ID,
                client: CLIENT,
                provider: PROVIDER,
                evaluator: address(evaluator),
                description: "underwriting job",
                budget: 0,
                expiredAt: block.timestamp + 1 days,
                status: Phase3AcpTypes.JobStatus.Open,
                hook: address(hook),
                paymentToken: address(0),
                providerAgentId: 0,
                submittedAt: 0
            })
        );
    }

    function test_baseHook_beforeAction_setBudget_decodesCallerAndPaymentToken() public {
        bytes memory optParams = abi.encode("phase3");

        acp.callBeforeAction(
            recordingHook,
            JOB_ID,
            bytes4(keccak256("setBudget(uint256,address,uint256,bytes)")),
            abi.encode(CLIENT, USDC, AMOUNT, optParams)
        );

        assertEq(recordingHook.lastCaller(), CLIENT);
        assertEq(recordingHook.lastToken(), USDC);
        assertEq(recordingHook.lastAmount(), AMOUNT);
        assertEq(recordingHook.lastOptParams(), optParams);
        assertTrue(recordingHook.supportsInterface(type(IACPHook).interfaceId));
        assertTrue(recordingHook.supportsInterface(type(IERC165).interfaceId));
    }

    function test_underwritingHook_beforeAction_setBudget_acceptsAllowedSettlementToken() public {
        acp.callBeforeAction(
            hook,
            JOB_ID,
            bytes4(keccak256("setBudget(uint256,address,uint256,bytes)")),
            abi.encode(CLIENT, USDC, AMOUNT, abi.encode(_commit()))
        );

        assertEq(uint256(hook.jobSidecarState(JOB_ID)), uint256(UnderwritingTypes.SidecarState.Committed));
        assertEq(hook.jobUnderwriter(JOB_ID), UNDERWRITER);
    }

    function test_underwritingHook_beforeAction_setBudget_rejectsNonAllowedSettlementToken() public {
        vm.expectRevert(UnderwritingWorkflowCore.UnsupportedSettlementToken.selector);
        acp.callBeforeAction(
            hook,
            JOB_ID,
            bytes4(keccak256("setBudget(uint256,address,uint256,bytes)")),
            abi.encode(CLIENT, OTHER_TOKEN, AMOUNT, abi.encode(_commit()))
        );
    }

    function test_underwritingHook_beforeAction_setBudget_requiresSettlementTokenConfiguration() public {
        UnderwritingHook unconfiguredHook = _deployHook(address(acp), address(this));
        MockPhase3WiringTarget unconfiguredEvaluator = new MockPhase3WiringTarget(address(acp), address(unconfiguredHook));
        MockPhase3CoordinatorTarget unconfiguredCoordinator =
            new MockPhase3CoordinatorTarget(address(acp), address(unconfiguredHook));

        unconfiguredHook.setWiring(address(unconfiguredEvaluator), address(unconfiguredCoordinator));
        unconfiguredHook.registerUnderwriter(UNDERWRITER);

        acp.setJob(
            Phase3AcpTypes.Job({
                id: JOB_ID + 1,
                client: CLIENT,
                provider: PROVIDER,
                evaluator: address(unconfiguredEvaluator),
                description: "underwriting job without token config",
                budget: 0,
                expiredAt: block.timestamp + 1 days,
                status: Phase3AcpTypes.JobStatus.Open,
                hook: address(unconfiguredHook),
                paymentToken: address(0),
                providerAgentId: 0,
                submittedAt: 0
            })
        );

        vm.expectRevert(UnderwritingWorkflowCore.SettlementTokenNotConfigured.selector);
        acp.callBeforeAction(
            unconfiguredHook,
            JOB_ID + 1,
            bytes4(keccak256("setBudget(uint256,address,uint256,bytes)")),
            abi.encode(CLIENT, USDC, AMOUNT, abi.encode(_commit()))
        );
    }

    function _commit() internal view returns (UnderwritingTypes.UnderwriteCommit memory) {
        return UnderwritingTypes.UnderwriteCommit({
            parentJobId: 0,
            underwriter: UNDERWRITER,
            validUntil: uint64(block.timestamp + 1 days),
            policyHash: keccak256("policy"),
            quoteIdHash: keccak256("quote"),
            termsHash: keccak256("terms"),
            allowCloseJob: false
        });
    }

    function _deployHook(address acp_, address admin_) internal returns (UnderwritingHook) {
        UnderwritingHook implementation = new UnderwritingHook();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(UnderwritingHook.initialize, (acp_, admin_)));
        return UnderwritingHook(address(proxy));
    }
}
