// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/mcu/MCUSettlementEscrow.sol";
import "../../contracts/mcu/ICollateralManager.sol";
import "../mocks/MockCollateralManager.sol";
import "../mocks/MockERC20.sol";

contract MCUSettlementEscrowTest is Test {
    uint256 internal constant JOB_ID = 1;
    uint256 internal constant SETTLEMENT_JOB_ID = JOB_ID;
    uint256 internal constant COLLATERAL_AMOUNT = 100e18;
    uint256 internal constant PRINCIPAL_AMOUNT = 80e18;
    uint256 internal constant PREMIUM_AMOUNT = 5e18;

    address internal controller = address(this);
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal merchantExecutionWallet = makeAddr("merchantExecutionWallet");
    address internal underwriter = makeAddr("underwriter");

    MockERC20 internal usdc;
    MockCollateralManager internal collateralManager;
    MCUSettlementEscrow internal escrow;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        collateralManager = new MockCollateralManager(usdc);
        escrow = new MCUSettlementEscrow(address(usdc), collateralManager, controller);

        escrow.configure(JOB_ID, client, provider, SETTLEMENT_JOB_ID, merchantExecutionWallet);

        usdc.mint(client, 1_000e18);
        usdc.mint(provider, 1_000e18);
    }

    function testPullCollateralAndPrincipalTransferBalancesToEscrow() public {
        vm.prank(provider);
        usdc.approve(address(escrow), COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(escrow), PRINCIPAL_AMOUNT);

        escrow.pullCollateralFromProvider(COLLATERAL_AMOUNT);
        escrow.pullPrincipalFromClient(PRINCIPAL_AMOUNT);

        assertEq(usdc.balanceOf(address(escrow)), COLLATERAL_AMOUNT + PRINCIPAL_AMOUNT);
        assertEq(usdc.balanceOf(provider), 1_000e18 - COLLATERAL_AMOUNT);
        assertEq(usdc.balanceOf(client), 1_000e18 - PRINCIPAL_AMOUNT);
    }

    function testLockCollateralCallsCollateralManagerAndPullsCollateralAndPremium() public {
        ICollateralManager.UnderwritePermit memory permit = _permit();

        vm.prank(provider);
        usdc.approve(address(escrow), COLLATERAL_AMOUNT);
        escrow.pullCollateralFromProvider(COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        escrow.lockCollateral(permit, bytes("permit-sig"));

        assertTrue(collateralManager.lockCollateralCalled());
        assertEq(collateralManager.lastLockClaimant(), client);
        assertEq(collateralManager.lastLockUnlockAt(), permit.unlockAt);
        assertEq(collateralManager.lastLockJobId(), JOB_ID);
        assertEq(collateralManager.lastLockSettlementJobId(), SETTLEMENT_JOB_ID);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(address(collateralManager)), COLLATERAL_AMOUNT + PREMIUM_AMOUNT);
    }

    function testReleasePrincipalCallsCollateralManagerAndTransfersToMerchantWallet() public {
        ICollateralManager.UnderwritePermit memory permit = _permit();

        vm.prank(client);
        usdc.approve(address(escrow), PRINCIPAL_AMOUNT);
        escrow.pullPrincipalFromClient(PRINCIPAL_AMOUNT);

        escrow.releasePrincipal(permit, bytes("permit-sig"));

        assertTrue(collateralManager.releasePrincipalCalled());
        assertEq(collateralManager.lastReleasePrincipalJobId(), JOB_ID);
        assertEq(collateralManager.lastReleasePrincipalSettlementJobId(), SETTLEMENT_JOB_ID);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(merchantExecutionWallet), PRINCIPAL_AMOUNT);
    }

    function testConfirmDeliveryCallsCollateralManager() public {
        escrow.confirmDeliveryBySig(7, bytes("delivery-sig"));

        assertTrue(collateralManager.confirmDeliveryCalled());
        assertEq(collateralManager.lastConfirmSettlementJobId(), SETTLEMENT_JOB_ID);
        assertEq(collateralManager.lastConfirmDeliveryNonce(), 7);
    }

    function testReleaseCollateralAndForwardTransfersReleasedCollateralToProvider() public {
        ICollateralManager.UnderwritePermit memory permit = _permit();

        vm.prank(provider);
        usdc.approve(address(escrow), COLLATERAL_AMOUNT);
        escrow.pullCollateralFromProvider(COLLATERAL_AMOUNT);

        vm.prank(client);
        usdc.approve(address(collateralManager), PREMIUM_AMOUNT);

        escrow.lockCollateral(permit, bytes("permit-sig"));

        uint256 providerBalanceBefore = usdc.balanceOf(provider);
        escrow.releaseCollateralAndForward();

        assertTrue(collateralManager.releaseCollateralCalled());
        assertEq(collateralManager.lastReleasedSettlementJobId(), SETTLEMENT_JOB_ID);
        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(provider), providerBalanceBefore + COLLATERAL_AMOUNT);
    }

    function testClaimTimeoutCallsCollateralManager() public {
        escrow.claimTimeout();

        assertTrue(collateralManager.claimTimeoutCalled());
        assertEq(collateralManager.lastTimeoutSettlementJobId(), SETTLEMENT_JOB_ID);
    }

    function testSweepResidualToProviderTransfersBalance() public {
        usdc.mint(address(escrow), 33e18);

        uint256 providerBalanceBefore = usdc.balanceOf(provider);
        escrow.sweepResidualToProvider();

        assertEq(usdc.balanceOf(address(escrow)), 0);
        assertEq(usdc.balanceOf(provider), providerBalanceBefore + 33e18);
    }

    function _permit() internal view returns (ICollateralManager.UnderwritePermit memory permit) {
        permit = ICollateralManager.UnderwritePermit({
            jobId: JOB_ID,
            settlementJobId: SETTLEMENT_JOB_ID,
            safe: address(escrow),
            user: client,
            merchant: address(escrow),
            underwriter: underwriter,
            decisionFeeUsdc: PREMIUM_AMOUNT,
            merchantExecutionWallet: merchantExecutionWallet,
            requiredCollateralUsdc: COLLATERAL_AMOUNT,
            fundedPrincipalUsdc: PRINCIPAL_AMOUNT,
            coverageCapUsdc: COLLATERAL_AMOUNT,
            validUntil: uint64(block.timestamp + 1 days),
            executeUntil: uint64(block.timestamp + 2 days),
            policyHash: keccak256("policy"),
            nonce: 1,
            unlockAt: uint64(block.timestamp + 3 days)
        });
    }
}
