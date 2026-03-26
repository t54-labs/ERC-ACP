// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/interfaces/ICollateralManager.sol";

contract ICollateralManagerPathTest is Test {
    function testInterfacePathExposesUnderwritePermit() public pure {
        ICollateralManager.UnderwritePermit memory permit;
        assertEq(permit.jobId, 0);
    }
}
