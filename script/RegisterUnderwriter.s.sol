// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "contracts/hooks/underwriting/UnderwritingHook.sol";

/**
 * @title RegisterUnderwriter
 * @notice Registers an underwriter address on the deployed underwriting hook.
 *         Must be called by the hook admin.
 *
 * Required environment variables:
 *   PRIVATE_KEY          — Private key of the hook admin.
 *   UNDERWRITING_HOOK    — Deployed UnderwritingHook address.
 *   UNDERWRITER_ADDRESS  — Address to register as an underwriter.
 *
 * Usage:
 *   forge script script/RegisterUnderwriter.s.sol:RegisterUnderwriter \
 *     --rpc-url $RPC_URL --broadcast
 */
contract RegisterUnderwriter is Script {
    function run() external {
        address hookAddr = vm.envAddress("UNDERWRITING_HOOK");
        address underwriter = vm.envAddress("UNDERWRITER_ADDRESS");

        vm.startBroadcast(vm.envUint("PRIVATE_KEY"));

        UnderwritingHook(hookAddr).registerUnderwriter(underwriter);

        vm.stopBroadcast();

        console.log("Registered underwriter:", underwriter);
        console.log("  on hook:", hookAddr);
    }
}
