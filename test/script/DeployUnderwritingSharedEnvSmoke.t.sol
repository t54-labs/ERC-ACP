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
import "../../contracts/hooks/underwriting/IUnderwritingHookView.sol";
import "../mocks/MockERC20.sol";

/// @notice Smoke test that mirrors the deploy script's deployment order and
///         validates wiring invariants hold after construction.
contract DeployUnderwritingSharedEnvSmokeTest is Test {
    address internal deployer = makeAddr("deployer");
    address internal treasury = makeAddr("treasury");
    uint64 internal constant CLIENT_CONFIRMATION_WINDOW = 1 hours;

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

        UnderwritingEvaluator evaluator = new UnderwritingEvaluator(
            IAgenticCommerceKernel(address(acp)),
            IUnderwritingHookView(address(hook)),
            CLIENT_CONFIRMATION_WINDOW
        );

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
        address underwriter = makeAddr("underwriter");
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
        UnderwritingEvaluator evaluator = new UnderwritingEvaluator(
            IAgenticCommerceKernel(address(acp)),
            IUnderwritingHookView(address(hook)),
            CLIENT_CONFIRMATION_WINDOW
        );

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
}
