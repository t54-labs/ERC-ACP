// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/examples/MCUHookSystemExample.sol";
import "../../contracts/mcu/IAgenticCommerceKernel.sol";
import "../../contracts/mcu/IBondManager.sol";
import "../../contracts/mcu/MCUTypes.sol";
import "../mocks/MockBondManager.sol";
import "../mocks/MockERC20.sol";

contract MockExampleACP is IAgenticCommerceKernel {
    address public override paymentToken;

    constructor(address paymentToken_) {
        paymentToken = paymentToken_;
    }

    function getJob(uint256) external pure override returns (Job memory) {
        revert("unused");
    }

    function setProvider(uint256, address, bytes calldata) external pure override {
        revert("unused");
    }

    function setBudget(uint256, uint256, bytes calldata) external pure override {
        revert("unused");
    }

    function fund(uint256, uint256, bytes calldata) external pure override {
        revert("unused");
    }

    function submit(uint256, bytes32, bytes calldata) external pure override {
        revert("unused");
    }

    function complete(uint256, bytes32, bytes calldata) external pure override {
        revert("unused");
    }

    function reject(uint256, bytes32, bytes calldata) external pure override {
        revert("unused");
    }
}

contract MCUHookSystemExampleTest is Test {
    address internal underwriter = makeAddr("underwriter");
    address internal merchantExecutionWallet = makeAddr("merchantExecutionWallet");
    address internal client = makeAddr("client");
    address internal adapter = makeAddr("adapter");

    MockERC20 internal usdc;
    MockBondManager internal bondManager;
    MockExampleACP internal acp;
    MCUHookSystemExample internal example;

    function setUp() public {
        usdc = new MockERC20("Mock USDC", "mUSDC");
        bondManager = new MockBondManager(usdc);
        acp = new MockExampleACP(address(usdc));
        example = new MCUHookSystemExample(acp, bondManager);
    }

    function testConstructorDeploysAndWiresTheMCUSystem() public view {
        assertEq(address(example.acp()), address(acp));
        assertEq(address(example.bondManager()), address(bondManager));
        assertEq(address(example.hook().acp()), address(acp));
        assertEq(address(example.coordinator().acp()), address(acp));
        assertEq(address(example.coordinator().hook()), address(example.hook()));
        assertEq(address(example.coordinator().bondManager()), address(bondManager));
        assertEq(address(example.evaluator().acp()), address(acp));
        assertEq(address(example.evaluator().hook()), address(example.hook()));
        assertEq(address(example.evaluator().coordinator()), address(example.coordinator()));
        assertEq(example.hook().coordinator(), address(example.coordinator()));
        assertEq(example.hook().underwriterEvaluator(), address(example.evaluator()));
    }

    function testBuildCommitAndPermitHelpersMirrorTheMCUFieldMapping() public {
        vm.warp(1_700_000_000);

        MCUHookSystemExample.CommitInputs memory inputs = MCUHookSystemExample.CommitInputs({
            memoId: keccak256("memo-id"),
            parentJobId: 0,
            underwriter: underwriter,
            merchantExecutionWallet: merchantExecutionWallet,
            decisionFeeUsdc: 5e6,
            requiredBondUsdc: 100e6,
            fundedPrincipalUsdc: 80e6,
            coverageCapUsdc: 90e6,
            validFor: 1 days,
            executeFor: 2 days,
            unlockIn: 30 days,
            deliveryConfirmationTimeoutWindow: 3 days,
            policyHash: keccak256("policy"),
            parentMemoId: bytes32(0),
            quoteIdHash: keccak256("quote"),
            releasePrincipal: true
        });

        MCUTypes.MCUCommit memory commit = example.buildCommit(inputs);

        assertEq(commit.memoId, inputs.memoId);
        assertEq(commit.parentJobId, inputs.parentJobId);
        assertEq(commit.underwriter, inputs.underwriter);
        assertEq(commit.merchantExecutionWallet, inputs.merchantExecutionWallet);
        assertEq(commit.decisionFeeUsdc, inputs.decisionFeeUsdc);
        assertEq(commit.requiredBondUsdc, inputs.requiredBondUsdc);
        assertEq(commit.fundedPrincipalUsdc, inputs.fundedPrincipalUsdc);
        assertEq(commit.coverageCapUsdc, inputs.coverageCapUsdc);
        assertEq(commit.validUntil, uint64(block.timestamp + inputs.validFor));
        assertEq(commit.executeUntil, uint64(block.timestamp + inputs.executeFor));
        assertEq(commit.unlockAt, uint64(block.timestamp + inputs.unlockIn));
        assertEq(commit.deliveryConfirmationTimeoutWindow, inputs.deliveryConfirmationTimeoutWindow);
        assertEq(commit.policyHash, inputs.policyHash);
        assertEq(commit.parentMemoId, inputs.parentMemoId);
        assertEq(commit.quoteIdHash, inputs.quoteIdHash);
        assertEq(commit.releasePrincipal, inputs.releasePrincipal);

        IBondManager.UnderwritePermit memory permit = example.buildPermit(7, client, adapter, commit, 11);

        assertEq(permit.memoId, commit.memoId);
        assertEq(permit.jobId, 7);
        assertEq(permit.safe, adapter);
        assertEq(permit.user, client);
        assertEq(permit.merchant, adapter);
        assertEq(permit.underwriter, commit.underwriter);
        assertEq(permit.decisionFeeUsdc, commit.decisionFeeUsdc);
        assertEq(permit.merchantExecutionWallet, commit.merchantExecutionWallet);
        assertEq(permit.requiredBondUsdc, commit.requiredBondUsdc);
        assertEq(permit.fundedPrincipalUsdc, commit.fundedPrincipalUsdc);
        assertEq(permit.coverageCapUsdc, commit.coverageCapUsdc);
        assertEq(permit.validUntil, commit.validUntil);
        assertEq(permit.executeUntil, commit.executeUntil);
        assertEq(permit.policyHash, commit.policyHash);
        assertEq(permit.nonce, 11);
        assertEq(permit.unlockAt, commit.unlockAt);
        assertEq(permit.parentMemoId, commit.parentMemoId);
    }
}
