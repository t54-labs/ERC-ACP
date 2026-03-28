// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@acp/AgenticCommerce.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../../contracts/hooks/underwriting/UnderwritingHook.sol";
import "../../../contracts/hooks/underwriting/UnderwritingTypes.sol";
import "../../mocks/MockERC20.sol";

interface IUpgradeableUnderwritingHook {
    function initialize(address acpContract_, address admin_) external;
    function acp() external view returns (address);
    function admin() external view returns (address);
    function evaluator() external view returns (address);
    function coordinator() external view returns (address);
    function allowedSettlementToken() external view returns (address);
    function setWiring(address evaluator_, address coordinator_) external;
    function registerUnderwriter(address underwriter) external;
    function registeredUnderwriters(address underwriter) external view returns (bool);
    function setAllowedSettlementToken(address allowedSettlementToken_) external;
    function jobSidecarState(uint256 jobId) external view returns (UnderwritingTypes.SidecarState);
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
    function markProtected(uint256 jobId) external;
}

contract MockUpgradeableHookWiringTarget {
    address public immutable acp;
    address public immutable hook;

    constructor(address acp_, address hook_) {
        acp = acp_;
        hook = hook_;
    }
}

contract MockUpgradeableHookCoordinator is MockUpgradeableHookWiringTarget {
    address public immutable collateralManager;

    constructor(address acp_, address hook_) MockUpgradeableHookWiringTarget(acp_, hook_) {
        collateralManager = address(this);
    }

    function protect(uint256 jobId) external {
        IUpgradeableUnderwritingHook(hook).markProtected(jobId);
    }
}

contract MockUpgradeableHookEvaluator is MockUpgradeableHookWiringTarget {
    constructor(address acp_, address hook_) MockUpgradeableHookWiringTarget(acp_, hook_) {}

    function completeJob(uint256 jobId, bytes32 reason) external {
        AgenticCommerce(acp).complete(jobId, reason, bytes(""));
    }
}

contract UnderwritingHookV2Mock is UnderwritingHook {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract UnderwritingHookUpgradeableTest is Test {
    uint256 internal constant JOB_BUDGET = 100e6;

    address internal treasury = makeAddr("treasury");
    address internal admin = makeAddr("admin");
    address internal attacker = makeAddr("attacker");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal underwriter = makeAddr("underwriter");

    MockERC20 internal usdc;
    AgenticCommerce internal acp;
    IUpgradeableUnderwritingHook internal hook;
    MockUpgradeableHookEvaluator internal evaluator;
    MockUpgradeableHookCoordinator internal coordinator;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        acp = _deployAcp(treasury);
        hook = _deployHookProxy(admin);
        evaluator = new MockUpgradeableHookEvaluator(address(acp), address(hook));
        coordinator = new MockUpgradeableHookCoordinator(address(acp), address(hook));

        vm.startPrank(admin);
        hook.setAllowedSettlementToken(address(usdc));
        hook.setWiring(address(evaluator), address(coordinator));
        hook.registerUnderwriter(underwriter);
        vm.stopPrank();

        usdc.mint(client, 1_000_000e6);
        vm.prank(client);
        usdc.approve(address(acp), type(uint256).max);
    }

    function testProxyInitializeSetsStorageAndAdminControls() public view {
        assertEq(hook.admin(), admin);
        assertEq(hook.acp(), address(acp));
        assertEq(hook.evaluator(), address(evaluator));
        assertEq(hook.coordinator(), address(coordinator));
        assertEq(hook.allowedSettlementToken(), address(usdc));
        assertTrue(hook.registeredUnderwriters(underwriter));
    }

    function testProxyInitializeCannotRunTwice() public {
        vm.prank(admin);
        vm.expectRevert();
        hook.initialize(address(acp), admin);
    }

    function testUnauthorizedUpgradeReverts() public {
        UnderwritingHookV2Mock upgradedImplementation = new UnderwritingHookV2Mock();

        vm.prank(attacker);
        vm.expectRevert();
        hook.upgradeToAndCall(address(upgradedImplementation), bytes(""));
    }

    function testAuthorizedUpgradePreservesStoredState() public {
        UnderwritingHookV2Mock upgradedImplementation = new UnderwritingHookV2Mock();

        vm.prank(admin);
        hook.upgradeToAndCall(address(upgradedImplementation), bytes(""));

        assertEq(UnderwritingHookV2Mock(address(hook)).version(), 2);
        assertEq(hook.admin(), admin);
        assertEq(hook.acp(), address(acp));
        assertEq(hook.evaluator(), address(evaluator));
        assertEq(hook.coordinator(), address(coordinator));
        assertEq(hook.allowedSettlementToken(), address(usdc));
        assertTrue(hook.registeredUnderwriters(underwriter));
    }

    function testProxyHookMustBeWhitelistedBeforeHookedJobsCanBeCreated() public {
        vm.startPrank(client);
        vm.expectRevert(AgenticCommerce.HookNotWhitelisted.selector);
        acp.createJob(provider, address(evaluator), block.timestamp + 1 days, "hooked job", address(hook), 0);
        vm.stopPrank();

        acp.setHookWhitelist(address(hook), true);

        vm.prank(client);
        uint256 jobId = acp.createJob(provider, address(evaluator), block.timestamp + 1 days, "hooked job", address(hook), 0);

        assertEq(jobId, 1);
    }

    function testProxyHookPreservesUnderwritingHappyPath() public {
        acp.setHookWhitelist(address(hook), true);

        vm.prank(client);
        uint256 jobId = acp.createJob(provider, address(evaluator), block.timestamp + 1 days, "underwriting job", address(hook), 0);

        vm.prank(client);
        acp.setBudget(jobId, address(usdc), JOB_BUDGET, abi.encode(_commit()));

        vm.prank(client);
        acp.fund(jobId, JOB_BUDGET, bytes(""));

        coordinator.protect(jobId);

        UnderwritingTypes.SubmitEvidence memory evidence = UnderwritingTypes.SubmitEvidence({
            bundleHash: keccak256("bundle"),
            policyHash: keccak256("policy"),
            quoteIdHash: keccak256("quote"),
            termsHash: keccak256("terms")
        });

        vm.prank(provider);
        acp.submit(jobId, evidence.bundleHash, abi.encode(evidence));

        evaluator.completeJob(jobId, keccak256("approved"));

        AgenticCommerce.Job memory job = acp.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgenticCommerce.JobStatus.Completed));
        assertEq(
            uint256(hook.jobSidecarState(jobId)),
            uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation)
        );
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

    function _deployAcp(address treasury_) internal returns (AgenticCommerce) {
        AgenticCommerce implementation = new AgenticCommerce();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), abi.encodeCall(AgenticCommerce.initialize, (treasury_)));
        return AgenticCommerce(address(proxy));
    }

    function _deployHookProxy(address admin_) internal returns (IUpgradeableUnderwritingHook) {
        UnderwritingHook implementation = new UnderwritingHook();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeWithSignature("initialize(address,address)", address(acp), admin_)
        );
        return IUpgradeableUnderwritingHook(address(proxy));
    }
}
