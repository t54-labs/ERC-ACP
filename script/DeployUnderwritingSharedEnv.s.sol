// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "contracts/AgenticCommerceHooked.sol";
import "contracts/hooks/underwriting/UnderwritingHook.sol";
import "contracts/settlement/UnderwritingSettlementCoordinator.sol";
import "contracts/settlement/UnderwritingEvaluator.sol";
import "contracts/settlement/UnderwritingCollateralManager.sol";
import "contracts/interfaces/IAgenticCommerceKernel.sol";
import "contracts/hooks/underwriting/IUnderwritingHookView.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DeployUnderwritingSharedEnv
 * @notice Deploys and wires the full underwriting stack for a shared Tenderly
 *         Base environment.
 *
 * Required environment variables:
 *   PRIVATE_KEY                 — Deployer private key (becomes hook admin).
 *   BASE_USDC                   — USDC token address on Base.
 *   ACP_TREASURY                — Platform treasury that receives ACP fees.
 *   CLIENT_CONFIRMATION_WINDOW  — Seconds the client has to confirm after submission.
 *
 * Deploy order:
 *   1. AgenticCommerceHooked
 *   2. UnderwritingCollateralManager
 *   3. UnderwritingHook
 *   4. UnderwritingSettlementCoordinator
 *   5. UnderwritingEvaluator
 *   6. Wire hook -> (evaluator, coordinator)
 *
 * Usage:
 *   forge script script/DeployUnderwritingSharedEnv.s.sol:DeployUnderwritingSharedEnv \
 *     --rpc-url $RPC_URL --broadcast
 */
contract DeployUnderwritingSharedEnv is Script {
    function run() external {
        address usdc = vm.envAddress("BASE_USDC");
        address treasury = vm.envAddress("ACP_TREASURY");
        uint64 clientConfirmationWindow = uint64(vm.envUint("CLIENT_CONFIRMATION_WINDOW"));

        uint256 deployerKey = vm.envUint("PRIVATE_KEY");

        vm.startBroadcast(deployerKey);

        // 1. ACP kernel
        AgenticCommerceHooked acp = new AgenticCommerceHooked(usdc, treasury);

        // 2. Collateral manager
        UnderwritingCollateralManager manager = new UnderwritingCollateralManager(IERC20(usdc));

        // 3. Underwriting hook (admin = deployer = msg.sender)
        UnderwritingHook hook = new UnderwritingHook(address(acp), msg.sender);

        // 4. Settlement coordinator
        UnderwritingSettlementCoordinator coordinator = new UnderwritingSettlementCoordinator(
            IAgenticCommerceKernel(address(acp)),
            hook,
            manager
        );

        // 5. Evaluator
        UnderwritingEvaluator evaluator = new UnderwritingEvaluator(
            IAgenticCommerceKernel(address(acp)),
            IUnderwritingHookView(address(hook)),
            clientConfirmationWindow
        );

        // 6. Wire hook to evaluator + coordinator (one-shot)
        hook.setWiring(address(evaluator), address(coordinator));

        vm.stopBroadcast();

        // Log deployed addresses for operator reference
        console.log("ACP:                ", address(acp));
        console.log("CollateralManager:  ", address(manager));
        console.log("UnderwritingHook:   ", address(hook));
        console.log("Coordinator:        ", address(coordinator));
        console.log("Evaluator:          ", address(evaluator));
    }
}
