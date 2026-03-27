// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "contracts/settlement/UnderwritingCollateralManager.sol";

/**
 * @title ConfigureUnderwriterRecipients
 * @notice Sets the premium and recovery recipient addresses for an underwriter
 *         on the deployed collateral manager.
 *
 * Required environment variables:
 *   PRIVATE_KEY          — Private key of the underwriter setting recipients.
 *   COLLATERAL_MANAGER   — Deployed UnderwritingCollateralManager address.
 *   PREMIUM_RECIPIENT    — Address that receives underwriting premiums.
 *   RECOVERY_RECIPIENT   — Address that receives recovered/slashed collateral.
 *
 * Usage:
 *   forge script script/ConfigureUnderwriterRecipients.s.sol:ConfigureUnderwriterRecipients \
 *     --rpc-url $RPC_URL --broadcast
 */
contract ConfigureUnderwriterRecipients is Script {
    function run() external {
        address managerAddr = vm.envAddress("COLLATERAL_MANAGER");
        address premiumRecipient = vm.envAddress("PREMIUM_RECIPIENT");
        address recoveryRecipient = vm.envAddress("RECOVERY_RECIPIENT");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        UnderwritingCollateralManager(managerAddr).setUnderwriterRecipients(
            premiumRecipient,
            recoveryRecipient
        );

        vm.stopBroadcast();

        console.log("Recipients configured on CollateralManager:", managerAddr);
        console.log("  Premium  ->", premiumRecipient);
        console.log("  Recovery ->", recoveryRecipient);
    }
}
