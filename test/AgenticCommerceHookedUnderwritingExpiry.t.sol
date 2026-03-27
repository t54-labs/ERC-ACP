// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/AgenticCommerceHooked.sol";
import "../contracts/IACPHook.sol";
import "./mocks/MockERC20.sol";

/// @dev Minimal no-op hook so that jobs have hook != address(0).
contract NoOpHook is IACPHook {
    function beforeAction(uint256, bytes4, bytes calldata) external override {}
    function afterAction(uint256, bytes4, bytes calldata) external override {}
}

/// @title AgenticCommerceHookedUnderwritingExpiryTest
/// @notice Tests that `expiredAt` acts as a provider submission deadline for hooked jobs.
///         When a hooked job has a timely submission (before expiredAt), claimRefund is blocked.
contract AgenticCommerceHookedUnderwritingExpiryTest is Test {
    MockERC20 internal usdc;
    AgenticCommerceHooked internal acp;
    NoOpHook internal hook;

    address internal treasury = makeAddr("treasury");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal evaluator = makeAddr("evaluator");

    uint256 internal constant BUDGET = 100e6;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        acp = new AgenticCommerceHooked(address(usdc), treasury);
        hook = new NoOpHook();

        usdc.mint(client, 1_000_000e6);
    }

    /// @dev Helper: create a funded standalone job with the hook attached.
    function _createFundedHookedJob(uint256 expiry) internal returns (uint256 jobId) {
        vm.startPrank(client);
        jobId = acp.createJob(provider, evaluator, expiry, "hooked job", address(hook));
        acp.setBudget(jobId, BUDGET, bytes(""));
        usdc.approve(address(acp), BUDGET);
        acp.fund(jobId, BUDGET, bytes(""));
        vm.stopPrank();
    }

    /// @dev Helper: create a funded standalone job WITHOUT a hook.
    function _createFundedUnhookedJob(uint256 expiry) internal returns (uint256 jobId) {
        vm.startPrank(client);
        jobId = acp.createJob(provider, evaluator, expiry, "no-hook job", address(0));
        acp.setBudget(jobId, BUDGET, bytes(""));
        usdc.approve(address(acp), BUDGET);
        acp.fund(jobId, BUDGET, bytes(""));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------
    // Test 1: Unsubmitted hooked job CAN claim refund after expiredAt
    // ---------------------------------------------------------------
    function testUnsubmittedHookedJobCanClaimRefundAfterExpiredAt() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 jobId = _createFundedHookedJob(expiry);

        // Warp past expiry — no submission was made
        vm.warp(expiry + 1);

        uint256 clientBalBefore = usdc.balanceOf(client);
        acp.claimRefund(jobId);

        AgenticCommerceHooked.Job memory job = acp.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgenticCommerceHooked.JobStatus.Expired));
        assertEq(usdc.balanceOf(client), clientBalBefore + BUDGET);
    }

    // ---------------------------------------------------------------
    // Test 2: Timely-submitted hooked job CANNOT claim refund
    // ---------------------------------------------------------------
    function testTimelySubmittedHookedJobCannotClaimRefundAfterExpiredAt() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 jobId = _createFundedHookedJob(expiry);

        // Provider submits BEFORE expiry (timely)
        vm.prank(provider);
        acp.submit(jobId, keccak256("deliverable"), bytes(""));

        // Warp past expiry
        vm.warp(expiry + 1);

        // claimRefund should revert — the submission was timely
        vm.expectRevert(AgenticCommerceHooked.WrongStatus.selector);
        acp.claimRefund(jobId);

        // Verify job is still Submitted (not Expired)
        AgenticCommerceHooked.Job memory job = acp.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgenticCommerceHooked.JobStatus.Submitted));
    }

    // ---------------------------------------------------------------
    // Test 3: Late-submitted hooked job CAN still claim refund
    // ---------------------------------------------------------------
    function testLateSubmittedHookedJobCanClaimRefundAfterExpiredAt() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 jobId = _createFundedHookedJob(expiry);

        // Warp to AFTER expiry, then submit (late submission)
        vm.warp(expiry + 1);

        vm.prank(provider);
        acp.submit(jobId, keccak256("deliverable"), bytes(""));

        // claimRefund should succeed — submission was late
        uint256 clientBalBefore = usdc.balanceOf(client);
        acp.claimRefund(jobId);

        AgenticCommerceHooked.Job memory job = acp.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgenticCommerceHooked.JobStatus.Expired));
        assertEq(usdc.balanceOf(client), clientBalBefore + BUDGET);
    }

    // ---------------------------------------------------------------
    // Test 4: Non-hooked submitted job CAN still claim refund (no change)
    // ---------------------------------------------------------------
    function testNonHookedSubmittedJobCanClaimRefundAfterExpiredAt() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 jobId = _createFundedUnhookedJob(expiry);

        // Provider submits before expiry
        vm.prank(provider);
        acp.submit(jobId, keccak256("deliverable"), bytes(""));

        // Warp past expiry
        vm.warp(expiry + 1);

        // claimRefund should succeed — no hook, existing behavior preserved
        uint256 clientBalBefore = usdc.balanceOf(client);
        acp.claimRefund(jobId);

        AgenticCommerceHooked.Job memory job = acp.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgenticCommerceHooked.JobStatus.Expired));
        assertEq(usdc.balanceOf(client), clientBalBefore + BUDGET);
    }

    // ---------------------------------------------------------------
    // Test 5: Funded (not submitted) hooked job CAN claim refund after expiry
    // ---------------------------------------------------------------
    function testFundedNotSubmittedHookedJobCanClaimRefundAfterExpiredAt() public {
        uint256 expiry = block.timestamp + 1 days;
        uint256 jobId = _createFundedHookedJob(expiry);

        // Warp past expiry — still Funded, never submitted
        vm.warp(expiry + 1);

        uint256 clientBalBefore = usdc.balanceOf(client);
        acp.claimRefund(jobId);

        AgenticCommerceHooked.Job memory job = acp.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgenticCommerceHooked.JobStatus.Expired));
        assertEq(usdc.balanceOf(client), clientBalBefore + BUDGET);
    }
}
