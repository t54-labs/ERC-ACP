// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import "../../contracts/AgenticCommerceHooked.sol";
import "../../contracts/examples/UnderwritingHookSystemExample.sol";
import "../../contracts/hooks/underwriting/UnderwritingTypes.sol";
import "../../contracts/settlement/SettlementTypes.sol";
import "../mocks/MockCollateralManager.sol";
import "../mocks/MockERC20.sol";

contract UnderwritingHookSystemExampleTest is Test {
    bytes32 internal constant COMPLETE_TYPEHASH =
        keccak256("CompleteDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");

    address internal treasury = makeAddr("treasury");
    address internal client = makeAddr("client");
    address internal provider = makeAddr("provider");
    address internal merchantExecutionWallet = makeAddr("merchantExecutionWallet");

    uint256 internal underwriterPk;
    address internal underwriter;

    MockERC20 internal usdc;
    MockCollateralManager internal collateralManager;
    AgenticCommerceHooked internal acp;
    UnderwritingHookSystemExample internal example;

    function setUp() public {
        (underwriter, underwriterPk) = makeAddrAndKey("underwriter");

        usdc = new MockERC20("Mock USDC", "mUSDC");
        collateralManager = new MockCollateralManager(usdc);
        acp = new AgenticCommerceHooked(address(usdc), treasury);
        example = new UnderwritingHookSystemExample(acp, collateralManager);

        usdc.mint(client, 1_000_000e6);
        usdc.mint(provider, 1_000_000e6);
    }

    function testHappyPathDeploysFundsSubmitsAndFinalizes() public {
        example.registerUnderwriter(underwriter);

        uint256 escrowAddressNonce = 1;
        address predictedEscrow = vm.computeCreateAddress(address(example.coordinator()), escrowAddressNonce);

        vm.startPrank(client);
        uint256 jobId = acp.createJob(
            provider,
            address(example.evaluator()),
            block.timestamp + 1 days,
            "underwriting root job",
            address(example.hook())
        );

        UnderwritingHookSystemExample.CommitInputs memory commitInputs = UnderwritingHookSystemExample.CommitInputs({
            parentJobId: 0,
            underwriter: underwriter,
            validFor: 1 days,
            policyHash: keccak256("policy"),
            quoteIdHash: keccak256("quote"),
            termsHash: keccak256("terms"),
            allowCloseJob: false
        });

        UnderwritingHookSystemExample.PermitInputs memory permitInputs = UnderwritingHookSystemExample.PermitInputs({
            merchantExecutionWallet: merchantExecutionWallet,
            decisionFeeUsdc: 5e6,
            requiredCollateralUsdc: 100e6,
            fundedPrincipalUsdc: 80e6,
            coverageCapUsdc: 100e6,
            executeFor: 2 days,
            unlockIn: 3 days,
            nonce: 7
        });

        UnderwritingTypes.UnderwriteCommit memory commit = example.buildCommit(commitInputs);
        ICollateralManager.UnderwritePermit memory permit =
            example.buildPermit(jobId, client, predictedEscrow, commit, permitInputs);

        usdc.approve(address(acp), permitInputs.decisionFeeUsdc);
        usdc.approve(address(collateralManager), permitInputs.decisionFeeUsdc);
        usdc.approve(predictedEscrow, permitInputs.fundedPrincipalUsdc);
        acp.setBudget(jobId, permitInputs.decisionFeeUsdc, example.encodeCommit(commit));
        acp.fund(jobId, permitInputs.decisionFeeUsdc, bytes(""));
        vm.stopPrank();

        vm.prank(provider);
        usdc.approve(predictedEscrow, permitInputs.requiredCollateralUsdc);

        example.coordinator().orchestrateFunding(jobId, permit, bytes("permit-sig"));

        UnderwritingTypes.SubmitEvidence memory evidence = UnderwritingTypes.SubmitEvidence({
            bundleHash: keccak256("bundle"),
            policyHash: commit.policyHash,
            quoteIdHash: commit.quoteIdHash,
            termsHash: commit.termsHash
        });
        bytes memory encodedEvidence = example.encodeSubmitEvidence(evidence);

        vm.prank(provider);
        acp.submit(jobId, evidence.bundleHash, encodedEvidence);

        UnderwritingTypes.CompleteDecision memory decision = UnderwritingTypes.CompleteDecision({
            jobId: jobId,
            reason: keccak256("approved"),
            deadline: uint64(block.timestamp + 1 days),
            nonce: 11
        });

        example.evaluator().completeBySig(decision, _signCompleteDecision(decision));

        AgenticCommerceHooked.Job memory job = acp.getJob(jobId);
        assertEq(uint256(job.status), uint256(AgenticCommerceHooked.JobStatus.Completed));
        assertEq(
            uint256(example.hook().jobSidecarState(jobId)),
            uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation)
        );
        assertEq(example.coordinator().settlementEscrow(jobId), predictedEscrow);
        assertEq(
            uint256(example.coordinator().jobSettlementState(jobId)),
            uint256(SettlementTypes.SettlementState.PrincipalReleased)
        );
        assertTrue(collateralManager.lockCollateralCalled());
        assertTrue(collateralManager.releasePrincipalCalled());
    }

    function _signCompleteDecision(UnderwritingTypes.CompleteDecision memory decision) internal view returns (bytes memory) {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                keccak256(abi.encode(COMPLETE_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce))
            )
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(underwriterPk, digest);
        return abi.encodePacked(r, s, v);
    }

    function _domainSeparator() internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes("Underwriting Settlement Evaluator")),
                keccak256(bytes("1")),
                block.chainid,
                address(example.evaluator())
            )
        );
    }
}
