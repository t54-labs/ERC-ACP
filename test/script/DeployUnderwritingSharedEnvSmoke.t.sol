// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/AgenticCommerceHooked.sol";
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

        AgenticCommerceHooked acp = new AgenticCommerceHooked(address(usdc), treasury);
        UnderwritingCollateralManager manager = new UnderwritingCollateralManager(IERC20(address(usdc)));
        UnderwritingHook hook = new UnderwritingHook(address(acp), deployer);

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
    }

    function testRegisterUnderwriterAndConfigureRecipients() public {
        MockERC20 usdc = new MockERC20("Mock USDC", "mUSDC");
        address underwriter = makeAddr("underwriter");
        address premiumRecipient = makeAddr("premiumRecipient");
        address recoveryRecipient = makeAddr("recoveryRecipient");

        vm.startPrank(deployer);

        AgenticCommerceHooked acp = new AgenticCommerceHooked(address(usdc), treasury);
        UnderwritingCollateralManager manager = new UnderwritingCollateralManager(IERC20(address(usdc)));
        UnderwritingHook hook = new UnderwritingHook(address(acp), deployer);

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
}
