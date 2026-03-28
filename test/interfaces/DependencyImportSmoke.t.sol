// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import "@acp/AgenticCommerce.sol";
import "@acp/IACPHook.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

contract UpgradeableImportHarness is UUPSUpgradeable {
    function _authorizeUpgrade(address) internal override {}
}

contract DependencyImportSmokeTest is Test {
    function testPhase1DependenciesCompileTogether() public pure {
        IERC165 erc165CompatibleHook = IACPHook(address(0xBEEF));

        assertGt(type(AgenticCommerce).creationCode.length, 0);
        assertEq(address(erc165CompatibleHook), address(0xBEEF));
        assertGt(type(UpgradeableImportHarness).creationCode.length, 0);
    }
}
