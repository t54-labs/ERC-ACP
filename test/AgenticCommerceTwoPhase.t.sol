// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "@acp/IACPHook.sol";
import "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import "../contracts/AgenticCommerce.sol";
import "../contracts/AgenticCommerceHooked.sol";
import "./mocks/MockERC20.sol";

error InvalidParentJob();
error ParentJobNotCompleted();
error CloseJobAlreadyExists();
error SubmitNotAllowedForOpenJob();

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

contract NoopHook is ERC165, IACPHook {
    function beforeAction(uint256, bytes4, bytes calldata) external pure override {}

    function afterAction(uint256, bytes4, bytes calldata) external pure override {}

    function supportsInterface(bytes4 interfaceId) public view virtual override(ERC165, IERC165) returns (bool) {
        return interfaceId == type(IACPHook).interfaceId || super.supportsInterface(interfaceId);
    }
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

    function testOpenJobCanCompleteDirectlyFromFundedWithoutSubmit() public {
        vm.startPrank(client);
        uint256 openJobId = twoPhaseAcp.createOpenJob(provider, evaluator, block.timestamp + 1 days, "open yield position");
        acp.setBudget(openJobId, JOB_BUDGET);
        token.approve(address(acp), JOB_BUDGET);
        acp.fund(openJobId, JOB_BUDGET);
        vm.stopPrank();

        vm.prank(evaluator);
        acp.complete(openJobId, keccak256("principal-deployed"));

        AgenticCommerce.Job memory openJob = acp.getJob(openJobId);
        assertEq(uint256(openJob.status), uint256(AgenticCommerce.JobStatus.Completed));
    }

    function testHookedOpenJobCanCompleteDirectlyFromFundedWithoutSubmit() public {
        vm.startPrank(client);
        uint256 openJobId = twoPhaseHookedAcp.createOpenJob(
            provider, evaluator, block.timestamp + 1 days, "open yield position", address(noopHook)
        );
        hookedAcp.setBudget(openJobId, JOB_BUDGET, bytes(""));
        token.approve(address(hookedAcp), JOB_BUDGET);
        hookedAcp.fund(openJobId, JOB_BUDGET, bytes(""));
        vm.stopPrank();

        vm.prank(evaluator);
        hookedAcp.complete(openJobId, keccak256("principal-deployed"), bytes(""));

        AgenticCommerceHooked.Job memory openJob = hookedAcp.getJob(openJobId);
        assertEq(uint256(openJob.status), uint256(AgenticCommerceHooked.JobStatus.Completed));
    }

    function testOpenJobSubmitRevertsForPlainACP() public {
        vm.startPrank(client);
        uint256 openJobId = twoPhaseAcp.createOpenJob(provider, evaluator, block.timestamp + 1 days, "open yield position");
        acp.setBudget(openJobId, JOB_BUDGET);
        token.approve(address(acp), JOB_BUDGET);
        acp.fund(openJobId, JOB_BUDGET);
        vm.stopPrank();

        vm.expectRevert(SubmitNotAllowedForOpenJob.selector);
        vm.prank(provider);
        acp.submit(openJobId, keccak256("should-not-submit"));
    }

    function testOpenJobSubmitRevertsForHookedACP() public {
        vm.startPrank(client);
        uint256 openJobId = twoPhaseHookedAcp.createOpenJob(
            provider, evaluator, block.timestamp + 1 days, "open yield position", address(noopHook)
        );
        hookedAcp.setBudget(openJobId, JOB_BUDGET, bytes(""));
        token.approve(address(hookedAcp), JOB_BUDGET);
        hookedAcp.fund(openJobId, JOB_BUDGET, bytes(""));
        vm.stopPrank();

        vm.expectRevert(SubmitNotAllowedForOpenJob.selector);
        vm.prank(provider);
        hookedAcp.submit(openJobId, keccak256("should-not-submit"), bytes(""));
    }

    function testCloseJobStillRequiresSubmitBeforeComplete() public {
        uint256 openJobId = _createAndCompleteOpenJob();

        vm.prank(client);
        uint256 closeJobId = twoPhaseAcp.createCloseJob(openJobId, block.timestamp + 2 days, "close yield position");

        vm.startPrank(client);
        acp.setBudget(closeJobId, JOB_BUDGET / 2);
        token.approve(address(acp), JOB_BUDGET / 2);
        acp.fund(closeJobId, JOB_BUDGET / 2);
        vm.stopPrank();

        vm.expectRevert(abi.encodeWithSelector(AgenticCommerce.WrongStatus.selector));
        vm.prank(evaluator);
        acp.complete(closeJobId, keccak256("close-complete"));
    }

    function testCreateCloseJobAllowsReplacementAfterRejectedCloseRequest() public {
        uint256 openJobId = _createAndCompleteOpenJob();

        vm.prank(client);
        uint256 firstCloseJobId = twoPhaseAcp.createCloseJob(openJobId, block.timestamp + 2 days, "close yield position");

        vm.prank(client);
        acp.reject(firstCloseJobId, keccak256("cancel close request"));

        vm.prank(client);
        uint256 replacementCloseJobId =
            twoPhaseAcp.createCloseJob(openJobId, block.timestamp + 3 days, "replacement close request");

        assertTrue(replacementCloseJobId != firstCloseJobId);
        assertEq(twoPhaseAcp.getCloseJobId(openJobId), replacementCloseJobId);
        assertEq(twoPhaseAcp.getParentJobId(replacementCloseJobId), openJobId);
    }

    function testCreateCloseJobAllowsReplacementAfterExpiredCloseRequest() public {
        uint256 openJobId = _createAndCompleteOpenJob();

        vm.prank(client);
        uint256 firstCloseJobId = twoPhaseAcp.createCloseJob(openJobId, block.timestamp + 1 days, "close yield position");

        vm.startPrank(client);
        acp.setBudget(firstCloseJobId, JOB_BUDGET / 2);
        token.approve(address(acp), JOB_BUDGET / 2);
        acp.fund(firstCloseJobId, JOB_BUDGET / 2);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 days);
        acp.claimRefund(firstCloseJobId);

        vm.prank(client);
        uint256 replacementCloseJobId =
            twoPhaseAcp.createCloseJob(openJobId, block.timestamp + 3 days, "replacement close request");

        assertTrue(replacementCloseJobId != firstCloseJobId);
        assertEq(twoPhaseAcp.getCloseJobId(openJobId), replacementCloseJobId);
        assertEq(twoPhaseAcp.getParentJobId(replacementCloseJobId), openJobId);
    }

    function _createAndCompleteOpenJob() internal returns (uint256 openJobId) {
        vm.startPrank(client);
        openJobId = twoPhaseAcp.createOpenJob(provider, evaluator, block.timestamp + 1 days, "open yield position");
        acp.setBudget(openJobId, JOB_BUDGET);
        token.approve(address(acp), JOB_BUDGET);
        acp.fund(openJobId, JOB_BUDGET);
        vm.stopPrank();

        vm.prank(evaluator);
        acp.complete(openJobId, keccak256("principal-deployed"));
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

        vm.prank(evaluator);
        hookedAcp.complete(openJobId, keccak256("principal-deployed"), bytes(""));
    }
}
