// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/mcu/MCUJobAdapter.sol";
import "../../contracts/mcu/IBondManager.sol";
import "../mocks/MockBondManager.sol";
import "../mocks/MockERC20.sol";

contract MCUJobAdapterTest is Test {
    uint256 internal constant JOB_ID = 1;
    uint256 internal constant BOND_AMOUNT = 100e18;
    uint256 internal constant PRINCIPAL_AMOUNT = 80e18;
    uint256 internal constant PREMIUM_AMOUNT = 5e18;
    bytes32 internal constant MEMO_ID = keccak256("memo-id");

    address internal controller = address(this);
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal merchantExecutionWallet = makeAddr("merchantExecutionWallet");
    address internal underwriter = makeAddr("underwriter");

    MockERC20 internal usdc;
    MockBondManager internal bondManager;
    MCUJobAdapter internal adapter;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        bondManager = new MockBondManager(usdc);
        adapter = new MCUJobAdapter(address(usdc), bondManager, controller);

        adapter.configure(JOB_ID, client, provider, MEMO_ID, merchantExecutionWallet);

        usdc.mint(client, 1_000e18);
        usdc.mint(provider, 1_000e18);
    }

    function testPullBondAndPrincipalTransferBalancesToAdapter() public {
        vm.prank(provider);
        usdc.approve(address(adapter), BOND_AMOUNT);

        vm.prank(client);
        usdc.approve(address(adapter), PRINCIPAL_AMOUNT);

        adapter.pullBondFromProvider(BOND_AMOUNT);
        adapter.pullPrincipalFromClient(PRINCIPAL_AMOUNT);

        assertEq(usdc.balanceOf(address(adapter)), BOND_AMOUNT + PRINCIPAL_AMOUNT);
        assertEq(usdc.balanceOf(provider), 1_000e18 - BOND_AMOUNT);
        assertEq(usdc.balanceOf(client), 1_000e18 - PRINCIPAL_AMOUNT);
    }

    function testLockBondCallsBondManagerAndPullsBondAndPremium() public {
        IBondManager.UnderwritePermit memory permit = _permit();

        vm.prank(provider);
        usdc.approve(address(adapter), BOND_AMOUNT);
        adapter.pullBondFromProvider(BOND_AMOUNT);

        vm.prank(client);
        usdc.approve(address(bondManager), PREMIUM_AMOUNT);

        adapter.lockBond(permit, bytes("permit-sig"));

        assertTrue(bondManager.lockBondCalled());
        assertEq(bondManager.lastLockClaimant(), client);
        assertEq(bondManager.lastLockUnlockAt(), permit.unlockAt);
        assertEq(bondManager.lastLockJobId(), JOB_ID);
        assertEq(bondManager.lastLockMemoId(), MEMO_ID);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(address(bondManager)), BOND_AMOUNT + PREMIUM_AMOUNT);
    }

    function testReleasePrincipalCallsBondManagerAndTransfersToMerchantWallet() public {
        IBondManager.UnderwritePermit memory permit = _permit();

        vm.prank(client);
        usdc.approve(address(adapter), PRINCIPAL_AMOUNT);
        adapter.pullPrincipalFromClient(PRINCIPAL_AMOUNT);

        adapter.releasePrincipal(permit, bytes("permit-sig"));

        assertTrue(bondManager.releasePrincipalCalled());
        assertEq(bondManager.lastReleasePrincipalJobId(), JOB_ID);
        assertEq(bondManager.lastReleasePrincipalMemoId(), MEMO_ID);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(merchantExecutionWallet), PRINCIPAL_AMOUNT);
    }

    function testConfirmDeliveryCallsBondManager() public {
        adapter.confirmDeliveryBySig(7, bytes("delivery-sig"));

        assertTrue(bondManager.confirmDeliveryCalled());
        assertEq(bondManager.lastConfirmMemoId(), MEMO_ID);
        assertEq(bondManager.lastConfirmDeliveryNonce(), 7);
    }

    function testReleaseBondAndForwardTransfersReleasedBondToProvider() public {
        IBondManager.UnderwritePermit memory permit = _permit();

        vm.prank(provider);
        usdc.approve(address(adapter), BOND_AMOUNT);
        adapter.pullBondFromProvider(BOND_AMOUNT);

        vm.prank(client);
        usdc.approve(address(bondManager), PREMIUM_AMOUNT);

        adapter.lockBond(permit, bytes("permit-sig"));

        uint256 providerBalanceBefore = usdc.balanceOf(provider);
        adapter.releaseBondAndForward();

        assertTrue(bondManager.releaseBondCalled());
        assertEq(bondManager.lastReleasedMemoId(), MEMO_ID);
        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(provider), providerBalanceBefore + BOND_AMOUNT);
    }

    function testClaimTimeoutCallsBondManager() public {
        adapter.claimTimeout();

        assertTrue(bondManager.claimTimeoutCalled());
        assertEq(bondManager.lastTimeoutMemoId(), MEMO_ID);
    }

    function testSweepResidualToProviderTransfersBalance() public {
        usdc.mint(address(adapter), 33e18);

        uint256 providerBalanceBefore = usdc.balanceOf(provider);
        adapter.sweepResidualToProvider();

        assertEq(usdc.balanceOf(address(adapter)), 0);
        assertEq(usdc.balanceOf(provider), providerBalanceBefore + 33e18);
    }

    function _permit() internal view returns (IBondManager.UnderwritePermit memory permit) {
        permit = IBondManager.UnderwritePermit({
            memoId: MEMO_ID,
            jobId: JOB_ID,
            safe: address(adapter),
            user: client,
            merchant: address(adapter),
            underwriter: underwriter,
            decisionFeeUsdc: PREMIUM_AMOUNT,
            merchantExecutionWallet: merchantExecutionWallet,
            requiredBondUsdc: BOND_AMOUNT,
            fundedPrincipalUsdc: PRINCIPAL_AMOUNT,
            coverageCapUsdc: BOND_AMOUNT,
            validUntil: uint64(block.timestamp + 1 days),
            executeUntil: uint64(block.timestamp + 2 days),
            policyHash: keccak256("policy"),
            nonce: 1,
            unlockAt: uint64(block.timestamp + 3 days),
            parentMemoId: bytes32(0)
        });
    }
}
