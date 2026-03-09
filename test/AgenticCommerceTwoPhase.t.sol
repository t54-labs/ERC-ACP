// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../contracts/AgenticCommerce.sol";
import "../contracts/AgenticCommerceHooked.sol";
import "../contracts/IACPHook.sol";
import "./mocks/MockERC20.sol";

error InvalidParentJob();
error ParentJobNotCompleted();
error CloseJobAlreadyExists();

interface ITwoPhaseAgenticCommerce {
    enum JobKind {
        Standalone,
        Open,
        Close
    }

    function createOpenJob(address provider, address evaluator, uint256 expiredAt, string calldata description)
        external
        returns (uint256);
    function createCloseJob(uint256 parentJobId, uint256 expiredAt, string calldata description)
        external
        returns (uint256);
    function getJobKind(uint256 jobId) external view returns (JobKind);
    function getParentJobId(uint256 jobId) external view returns (uint256);
    function getCloseJobId(uint256 jobId) external view returns (uint256);
}

interface ITwoPhaseAgenticCommerceHooked {
    enum JobKind {
        Standalone,
        Open,
        Close
    }

    function createOpenJob(
        address provider,
        address evaluator,
        uint256 expiredAt,
        string calldata description,
        address hook
    ) external returns (uint256);
    function createCloseJob(uint256 parentJobId, uint256 expiredAt, string calldata description)
        external
        returns (uint256);
    function getJobKind(uint256 jobId) external view returns (JobKind);
    function getParentJobId(uint256 jobId) external view returns (uint256);
    function getCloseJobId(uint256 jobId) external view returns (uint256);
}

contract NoopHook is IACPHook {
    function beforeAction(uint256, bytes4, bytes calldata) external pure override {}

    function afterAction(uint256, bytes4, bytes calldata) external pure override {}
}

contract AgenticCommerceTwoPhaseTest is Test {
    uint256 internal constant JOB_BUDGET = 100e18;

    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal evaluator = makeAddr("evaluator");
    address internal treasury = makeAddr("treasury");

    MockERC20 internal token;
    AgenticCommerce internal acp;
    AgenticCommerceHooked internal hookedAcp;
    ITwoPhaseAgenticCommerce internal twoPhaseAcp;
    ITwoPhaseAgenticCommerceHooked internal twoPhaseHookedAcp;
    NoopHook internal noopHook;

    function setUp() public {
        token = new MockERC20("Mock USDC", "mUSDC");
        acp = new AgenticCommerce(address(token), treasury);
        hookedAcp = new AgenticCommerceHooked(address(token), treasury);
        twoPhaseAcp = ITwoPhaseAgenticCommerce(address(acp));
        twoPhaseHookedAcp = ITwoPhaseAgenticCommerceHooked(address(hookedAcp));
        noopHook = new NoopHook();

        token.mint(client, 1_000_000e18);
    }

    function testCreateCloseJobInheritsActorsAndLinkage() public {
        uint256 openJobId = _createAndCompleteOpenJob();

        vm.prank(client);
        uint256 closeJobId = twoPhaseAcp.createCloseJob(openJobId, block.timestamp + 2 days, "close yield position");

        AgenticCommerce.Job memory openJob = acp.getJob(openJobId);
        AgenticCommerce.Job memory closeJob = acp.getJob(closeJobId);

        assertEq(uint256(twoPhaseAcp.getJobKind(openJobId)), uint256(ITwoPhaseAgenticCommerce.JobKind.Open));
        assertEq(uint256(twoPhaseAcp.getJobKind(closeJobId)), uint256(ITwoPhaseAgenticCommerce.JobKind.Close));
        assertEq(twoPhaseAcp.getParentJobId(closeJobId), openJobId);
        assertEq(twoPhaseAcp.getCloseJobId(openJobId), closeJobId);
        assertEq(closeJob.client, openJob.client);
        assertEq(closeJob.provider, openJob.provider);
        assertEq(closeJob.evaluator, openJob.evaluator);
    }

    function testCreateCloseJobRevertsUntilParentCompleted() public {
        vm.prank(client);
        uint256 openJobId = twoPhaseAcp.createOpenJob(provider, evaluator, block.timestamp + 1 days, "open yield position");

        vm.expectRevert(ParentJobNotCompleted.selector);
        vm.prank(client);
        twoPhaseAcp.createCloseJob(openJobId, block.timestamp + 2 days, "close yield position");
    }

    function testCreateCloseJobRevertsWhenCloseAlreadyExists() public {
        uint256 openJobId = _createAndCompleteOpenJob();

        vm.prank(client);
        twoPhaseAcp.createCloseJob(openJobId, block.timestamp + 2 days, "close yield position");

        vm.expectRevert(CloseJobAlreadyExists.selector);
        vm.prank(client);
        twoPhaseAcp.createCloseJob(openJobId, block.timestamp + 3 days, "second close attempt");
    }

    function testHookedCreateCloseJobInheritsParentHook() public {
        uint256 openJobId = _createAndCompleteHookedOpenJob();

        vm.prank(client);
        uint256 closeJobId =
            twoPhaseHookedAcp.createCloseJob(openJobId, block.timestamp + 2 days, "close yield position");

        AgenticCommerceHooked.Job memory openJob = hookedAcp.getJob(openJobId);
        AgenticCommerceHooked.Job memory closeJob = hookedAcp.getJob(closeJobId);

        assertEq(uint256(twoPhaseHookedAcp.getJobKind(openJobId)), uint256(ITwoPhaseAgenticCommerceHooked.JobKind.Open));
        assertEq(
            uint256(twoPhaseHookedAcp.getJobKind(closeJobId)), uint256(ITwoPhaseAgenticCommerceHooked.JobKind.Close)
        );
        assertEq(twoPhaseHookedAcp.getParentJobId(closeJobId), openJobId);
        assertEq(twoPhaseHookedAcp.getCloseJobId(openJobId), closeJobId);
        assertEq(closeJob.hook, address(noopHook));
        assertEq(closeJob.client, openJob.client);
        assertEq(closeJob.provider, openJob.provider);
        assertEq(closeJob.evaluator, openJob.evaluator);
    }

    function _createAndCompleteOpenJob() internal returns (uint256 openJobId) {
        vm.startPrank(client);
        openJobId = twoPhaseAcp.createOpenJob(provider, evaluator, block.timestamp + 1 days, "open yield position");
        acp.setBudget(openJobId, JOB_BUDGET);
        token.approve(address(acp), JOB_BUDGET);
        acp.fund(openJobId, JOB_BUDGET);
        vm.stopPrank();

        vm.prank(provider);
        acp.submit(openJobId, keccak256("open-position-deliverable"));

        vm.prank(evaluator);
        acp.complete(openJobId, keccak256("position-opened"));
    }

    function _createAndCompleteHookedOpenJob() internal returns (uint256 openJobId) {
        vm.startPrank(client);
        openJobId = twoPhaseHookedAcp.createOpenJob(
            provider, evaluator, block.timestamp + 1 days, "open yield position", address(noopHook)
        );
        hookedAcp.setBudget(openJobId, JOB_BUDGET, bytes(""));
        token.approve(address(hookedAcp), JOB_BUDGET);
        hookedAcp.fund(openJobId, JOB_BUDGET, bytes(""));
        vm.stopPrank();

        vm.prank(provider);
        hookedAcp.submit(openJobId, keccak256("open-position-deliverable"), bytes(""));

        vm.prank(evaluator);
        hookedAcp.complete(openJobId, keccak256("position-opened"), bytes(""));
    }
}
