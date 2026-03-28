// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@acp/AgenticCommerce.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../../contracts/hooks/underwriting/UnderwritingHook.sol";
import "../../contracts/settlement/UnderwritingSettlementCoordinator.sol";
import "../../contracts/settlement/UnderwritingEvaluator.sol";
import "../../contracts/settlement/UnderwritingCollateralManager.sol";
import "../../contracts/interfaces/IAgenticCommerceKernel.sol";
import "../../contracts/hooks/underwriting/UnderwritingTypes.sol";
import "../../contracts/hooks/underwriting/IUnderwritingHookView.sol";
import "../mocks/MockERC20.sol";

/// @notice Smoke test that mirrors the deploy script's deployment order and
///         validates wiring invariants hold after construction.
contract DeployUnderwritingSharedEnvSmokeTest is Test {
    address internal deployer = makeAddr("deployer");
    address internal treasury = makeAddr("treasury");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal underwriter = makeAddr("underwriter");
    uint64 internal constant CLIENT_CONFIRMATION_WINDOW = 1 hours;
    uint256 internal constant JOB_BUDGET = 100e18;

    function testDeployAndWireProducesValidStack() public {
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC");

        vm.startPrank(deployer);

        AgenticCommerce acp = _deployAcp(treasury);
        UnderwritingCollateralManager manager = new UnderwritingCollateralManager(IERC20(address(usdc)));
        UnderwritingHook hook = _deployHook(address(acp), deployer);
        acp.setHookWhitelist(address(hook), true);
        hook.setAllowedSettlementToken(address(usdc));

        UnderwritingSettlementCoordinator coordinator = new UnderwritingSettlementCoordinator(
            IAgenticCommerceKernel(address(acp)), hook, manager
        );

        UnderwritingEvaluator evaluator =
            _deployEvaluator(address(acp), address(hook), CLIENT_CONFIRMATION_WINDOW, deployer);

        hook.setWiring(address(evaluator), address(coordinator));

        vm.stopPrank();

        assertEq(address(coordinator.acp()), address(acp));
        assertEq(address(coordinator.hook()), address(hook));
        assertEq(address(coordinator.collateralManager()), address(manager));

        assertEq(address(evaluator.acp()), address(acp));
        assertEq(address(evaluator.hook()), address(hook));
        assertEq(evaluator.clientConfirmationWindowSeconds(), CLIENT_CONFIRMATION_WINDOW);

        assertEq(hook.evaluator(), address(evaluator));
        assertEq(hook.coordinator(), address(coordinator));
        assertEq(hook.allowedSettlementToken(), address(usdc));
        assertTrue(acp.whitelistedHooks(address(hook)));
    }

    function testRegisterUnderwriterAndConfigureRecipients() public {
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC");
        address premiumRecipient = makeAddr("premiumRecipient");
        address recoveryRecipient = makeAddr("recoveryRecipient");

        vm.startPrank(deployer);

        AgenticCommerce acp = _deployAcp(treasury);
        UnderwritingCollateralManager manager = new UnderwritingCollateralManager(IERC20(address(usdc)));
        UnderwritingHook hook = _deployHook(address(acp), deployer);
        acp.setHookWhitelist(address(hook), true);
        hook.setAllowedSettlementToken(address(usdc));

        UnderwritingSettlementCoordinator coordinator = new UnderwritingSettlementCoordinator(
            IAgenticCommerceKernel(address(acp)), hook, manager
        );
        UnderwritingEvaluator evaluator =
            _deployEvaluator(address(acp), address(hook), CLIENT_CONFIRMATION_WINDOW, deployer);

        hook.setWiring(address(evaluator), address(coordinator));
        hook.registerUnderwriter(underwriter);

        vm.stopPrank();

        assertTrue(hook.registeredUnderwriters(underwriter));

        vm.prank(underwriter);
        manager.setUnderwriterRecipients(premiumRecipient, recoveryRecipient);

        (address storedPremium, address storedRecovery) = manager.recipientsByUnderwriter(underwriter);
        assertEq(storedPremium, premiumRecipient);
        assertEq(storedRecovery, recoveryRecipient);
    }

    function testFreshDeploymentSupportsImmediateHookedJobCreationAndBudgeting() public {
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC");

        vm.startPrank(deployer);

        AgenticCommerce acp = _deployAcp(treasury);
        UnderwritingCollateralManager manager = new UnderwritingCollateralManager(IERC20(address(usdc)));
        UnderwritingHook hook = _deployHook(address(acp), deployer);
        acp.setHookWhitelist(address(hook), true);
        hook.setAllowedSettlementToken(address(usdc));

        UnderwritingSettlementCoordinator coordinator = new UnderwritingSettlementCoordinator(
            IAgenticCommerceKernel(address(acp)), hook, manager
        );
        UnderwritingEvaluator evaluator =
            _deployEvaluator(address(acp), address(hook), CLIENT_CONFIRMATION_WINDOW, deployer);

        hook.setWiring(address(evaluator), address(coordinator));
        hook.registerUnderwriter(underwriter);

        vm.stopPrank();

        vm.prank(client);
        uint256 jobId =
            acp.createJob(provider, address(evaluator), block.timestamp + 1 days, "shared env smoke job", address(hook), 0);

        vm.prank(client);
        acp.setBudget(jobId, address(usdc), JOB_BUDGET, abi.encode(_commit()));

        AgenticCommerce.Job memory job = acp.getJob(jobId);
        UnderwritingTypes.UnderwriteCommit memory commit = hook.getCommit(jobId);

        assertEq(job.hook, address(hook));
        assertEq(job.evaluator, address(evaluator));
        assertEq(job.paymentToken, address(usdc));
        assertEq(job.budget, JOB_BUDGET);
        assertEq(commit.underwriter, underwriter);
        assertEq(hook.jobUnderwriter(jobId), underwriter);
        assertEq(uint256(hook.jobSidecarState(jobId)), uint256(UnderwritingTypes.SidecarState.Committed));
    }

    function _deployAcp(address treasury_) internal returns (AgenticCommerce) {
        AgenticCommerce implementation = new AgenticCommerce();
        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), abi.encodeCall(AgenticCommerce.initialize, (treasury_)));
        return AgenticCommerce(address(proxy));
    }

    function _deployHook(address acp_, address admin_) internal returns (UnderwritingHook) {
        UnderwritingHook implementation = new UnderwritingHook();
        ERC1967Proxy proxy =
            new ERC1967Proxy(address(implementation), abi.encodeCall(UnderwritingHook.initialize, (acp_, admin_)));
        return UnderwritingHook(address(proxy));
    }

    function _deployEvaluator(address acp_, address hook_, uint64 clientConfirmationWindowSeconds_, address admin_)
        internal
        returns (UnderwritingEvaluator)
    {
        UnderwritingEvaluator implementation = new UnderwritingEvaluator();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(implementation),
            abi.encodeCall(UnderwritingEvaluator.initialize, (acp_, hook_, clientConfirmationWindowSeconds_, admin_))
        );
        return UnderwritingEvaluator(address(proxy));
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
}
