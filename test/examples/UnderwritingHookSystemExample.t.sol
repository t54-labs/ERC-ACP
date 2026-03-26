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
    bytes32 internal constant SUCCESS_DISPUTE_TYPEHASH = keccak256(
        "SuccessDisputeDecision(uint256 jobId,bytes32 disputeHash,uint8 outcome,bytes32 reason,bytes32 slashAttestationHash,uint64 deadline,uint256 nonce)"
    );

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
        example = new UnderwritingHookSystemExample(acp, collateralManager, 1 days);

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

    function testSingleStageDisputePathReleasesAfterSignedResolution() public {
        example.registerUnderwriter(underwriter);

        address predictedEscrow = vm.computeCreateAddress(address(example.coordinator()), 1);

        vm.startPrank(client);
        uint256 jobId = acp.createJob(
            provider,
            address(example.evaluator()),
            block.timestamp + 1 days,
            "underwriting root job",
            address(example.hook())
        );
        vm.stopPrank();

        UnderwritingTypes.UnderwriteCommit memory commit = example.buildCommit(_commitInputs(0, false));
        UnderwritingHookSystemExample.PermitInputs memory permitInputs = _permitInputs(7);
        _fundAndOrchestrateJob(jobId, commit, permitInputs, predictedEscrow);
        _submitAndCompleteJob(jobId, commit, "bundle", "approved", 11);

        vm.startPrank(provider);
        example.coordinator().requestCollateralRelease(jobId);
        vm.stopPrank();

        assertEq(
            uint256(example.coordinator().jobSettlementState(jobId)),
            uint256(SettlementTypes.SettlementState.SuccessPendingRelease)
        );

        bytes32 disputeHash = keccak256("success-dispute");
        vm.startPrank(client);
        example.coordinator().openSuccessDispute(jobId, disputeHash);
        vm.stopPrank();

        assertEq(
            uint256(example.coordinator().jobSettlementState(jobId)),
            uint256(SettlementTypes.SettlementState.DisputeOpen)
        );

        SettlementTypes.SuccessDisputeDecision memory disputeDecision = _successDisputeDecision(
            jobId,
            disputeHash,
            SettlementTypes.SuccessDisputeOutcome.ReleaseCollateral,
            "release",
            bytes32(0),
            17
        );

        example.evaluator().resolveSuccessDisputeBySig(
            disputeDecision, _emptySlashAttestation(), bytes(""), _signSuccessDisputeDecision(disputeDecision)
        );

        assertEq(
            uint256(example.coordinator().jobSettlementState(jobId)),
            uint256(SettlementTypes.SettlementState.ReleaseApproved)
        );

        vm.warp(block.timestamp + uint256(permitInputs.unlockIn) + 1);

        uint256 providerBalanceBefore = usdc.balanceOf(provider);
        example.coordinator().releaseCollateral(jobId);

        assertEq(
            uint256(example.coordinator().jobSettlementState(jobId)),
            uint256(SettlementTypes.SettlementState.SuccessSettled)
        );
        assertEq(collateralManager.lastReleasedSettlementJobId(), jobId);
        assertEq(usdc.balanceOf(provider), providerBalanceBefore + permitInputs.requiredCollateralUsdc);
    }

    function testTwoStageHappyPathOpenAndCloseShareSettlementAndFinalize() public {
        example.registerUnderwriter(underwriter);

        address predictedEscrow = vm.computeCreateAddress(address(example.coordinator()), 1);

        vm.startPrank(client);
        uint256 rootJobId = acp.createJob(
            provider,
            address(example.evaluator()),
            block.timestamp + 1 days,
            "underwriting root job",
            address(example.hook())
        );
        vm.stopPrank();

        UnderwritingTypes.UnderwriteCommit memory rootCommit = example.buildCommit(_commitInputs(0, true));
        UnderwritingHookSystemExample.PermitInputs memory rootPermitInputs = _permitInputs(7);
        _fundAndOrchestrateJob(rootJobId, rootCommit, rootPermitInputs, predictedEscrow);
        _submitAndCompleteJob(rootJobId, rootCommit, "root bundle", "root approved", 11);

        assertEq(
            uint256(example.hook().jobSidecarState(rootJobId)),
            uint256(UnderwritingTypes.SidecarState.AwaitingClose)
        );
        assertTrue(example.hook().isAwaitingClose(rootJobId));
        assertEq(example.coordinator().settlementEscrow(rootJobId), predictedEscrow);

        vm.startPrank(client);
        uint256 closeJobId = acp.createJob(
            provider,
            address(example.evaluator()),
            block.timestamp + 2 days,
            "underwriting close job",
            address(example.hook())
        );
        vm.stopPrank();

        UnderwritingTypes.UnderwriteCommit memory closeCommit = example.buildCommit(_commitInputs(rootJobId, false));
        UnderwritingHookSystemExample.PermitInputs memory closePermitInputs = _permitInputs(8);
        _fundAndOrchestrateJob(closeJobId, closeCommit, closePermitInputs, predictedEscrow);
        assertEq(example.hook().getParentJobId(closeJobId), rootJobId);
        assertEq(example.hook().getActiveCloseJobId(rootJobId), closeJobId);
        assertEq(example.hook().jobSettlementJobId(closeJobId), rootJobId);

        _submitAndCompleteJob(closeJobId, closeCommit, "close bundle", "close approved", 12);

        assertEq(example.coordinator().settlementEscrow(closeJobId), predictedEscrow);
        assertEq(
            uint256(example.hook().jobSidecarState(rootJobId)),
            uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation)
        );
        assertEq(
            uint256(example.hook().jobSidecarState(closeJobId)),
            uint256(UnderwritingTypes.SidecarState.SuccessPendingConfirmation)
        );
        assertFalse(example.hook().isAwaitingClose(rootJobId));
        assertEq(example.hook().getActiveCloseJobId(rootJobId), 0);

        vm.startPrank(provider);
        example.coordinator().requestCollateralRelease(closeJobId);
        vm.stopPrank();

        vm.warp(block.timestamp + uint256(closePermitInputs.unlockIn) + 1);

        uint256 providerBalanceBefore = usdc.balanceOf(provider);
        example.coordinator().releaseCollateral(closeJobId);

        assertEq(
            uint256(example.coordinator().jobSettlementState(closeJobId)),
            uint256(SettlementTypes.SettlementState.SuccessSettled)
        );
        assertEq(collateralManager.lastReleasedSettlementJobId(), rootJobId);
        assertEq(usdc.balanceOf(provider), providerBalanceBefore + rootPermitInputs.requiredCollateralUsdc);
    }

    function testTwoStageDisputePathCloseJobSlashUsesParentSettlement() public {
        example.registerUnderwriter(underwriter);

        address predictedEscrow = vm.computeCreateAddress(address(example.coordinator()), 1);

        vm.startPrank(client);
        uint256 rootJobId = acp.createJob(
            provider,
            address(example.evaluator()),
            block.timestamp + 1 days,
            "underwriting root job",
            address(example.hook())
        );
        vm.stopPrank();

        UnderwritingTypes.UnderwriteCommit memory rootCommit = example.buildCommit(_commitInputs(0, true));
        _fundAndOrchestrateJob(rootJobId, rootCommit, _permitInputs(7), predictedEscrow);
        _submitAndCompleteJob(rootJobId, rootCommit, "root bundle", "root approved", 11);

        vm.startPrank(client);
        uint256 closeJobId = acp.createJob(
            provider,
            address(example.evaluator()),
            block.timestamp + 2 days,
            "underwriting close job",
            address(example.hook())
        );
        vm.stopPrank();

        UnderwritingTypes.UnderwriteCommit memory closeCommit = example.buildCommit(_commitInputs(rootJobId, false));
        _fundAndOrchestrateJob(closeJobId, closeCommit, _permitInputs(8), predictedEscrow);
        _submitAndCompleteJob(closeJobId, closeCommit, "close bundle", "close approved", 12);

        vm.startPrank(provider);
        example.coordinator().requestCollateralRelease(closeJobId);
        vm.stopPrank();

        bytes32 disputeHash = keccak256("close-dispute");
        vm.startPrank(client);
        example.coordinator().openSuccessDispute(closeJobId, disputeHash);
        vm.stopPrank();

        ICollateralManager.SlashAttestation memory attestation = ICollateralManager.SlashAttestation({
            settlementJobId: rootJobId,
            safe: predictedEscrow,
            user: client,
            merchant: provider,
            slashAmountUsdc: 25e6,
            reasonCode: keccak256("slash"),
            validUntil: uint64(block.timestamp + 1 days),
            nonce: 21
        });
        SettlementTypes.SuccessDisputeDecision memory disputeDecision = _successDisputeDecision(
            closeJobId,
            disputeHash,
            SettlementTypes.SuccessDisputeOutcome.SlashCollateral,
            "slash",
            keccak256(abi.encode(attestation)),
            22
        );

        example.evaluator().resolveSuccessDisputeBySig(
            disputeDecision, attestation, bytes("slash-sig"), _signSuccessDisputeDecision(disputeDecision)
        );

        assertEq(
            uint256(example.coordinator().jobSettlementState(closeJobId)),
            uint256(SettlementTypes.SettlementState.SuccessSlashed)
        );
        assertTrue(collateralManager.slashCalled());
        assertEq(example.coordinator().settlementEscrow(closeJobId), predictedEscrow);

        (uint256 settlementJobId, address safe,,,,,,) = collateralManager.lastSlashAttestation();
        assertEq(settlementJobId, rootJobId);
        assertEq(safe, predictedEscrow);
    }

    function _commitInputs(uint256 parentJobId, bool allowCloseJob)
        internal
        view
        returns (UnderwritingHookSystemExample.CommitInputs memory)
    {
        return UnderwritingHookSystemExample.CommitInputs({
            parentJobId: parentJobId,
            underwriter: underwriter,
            validFor: 1 days,
            policyHash: keccak256("policy"),
            quoteIdHash: keccak256("quote"),
            termsHash: keccak256("terms"),
            allowCloseJob: allowCloseJob
        });
    }

    function _permitInputs(uint256 nonce)
        internal
        view
        returns (UnderwritingHookSystemExample.PermitInputs memory)
    {
        return UnderwritingHookSystemExample.PermitInputs({
            merchantExecutionWallet: merchantExecutionWallet,
            decisionFeeUsdc: 5e6,
            requiredCollateralUsdc: 100e6,
            fundedPrincipalUsdc: 80e6,
            coverageCapUsdc: 100e6,
            executeFor: 2 days,
            unlockIn: 3 days,
            nonce: nonce
        });
    }

    function _fundAndOrchestrateJob(
        uint256 jobId,
        UnderwritingTypes.UnderwriteCommit memory commit,
        UnderwritingHookSystemExample.PermitInputs memory permitInputs,
        address predictedEscrow
    ) internal returns (ICollateralManager.UnderwritePermit memory permit) {
        vm.startPrank(client);
        usdc.approve(address(acp), permitInputs.decisionFeeUsdc);
        if (commit.parentJobId == 0) {
            usdc.approve(address(collateralManager), permitInputs.decisionFeeUsdc);
            usdc.approve(predictedEscrow, permitInputs.fundedPrincipalUsdc);
        }
        acp.setBudget(jobId, permitInputs.decisionFeeUsdc, example.encodeCommit(commit));
        acp.fund(jobId, permitInputs.decisionFeeUsdc, bytes(""));
        vm.stopPrank();

        permit = example.buildPermit(jobId, client, predictedEscrow, commit, permitInputs);

        if (commit.parentJobId == 0) {
            vm.prank(provider);
            usdc.approve(predictedEscrow, permitInputs.requiredCollateralUsdc);
        }

        example.coordinator().orchestrateFunding(jobId, permit, bytes("permit-sig"));
    }

    function _submitAndCompleteJob(
        uint256 jobId,
        UnderwritingTypes.UnderwriteCommit memory commit,
        string memory bundleLabel,
        string memory reasonLabel,
        uint256 nonce
    ) internal {
        UnderwritingTypes.SubmitEvidence memory evidence = _evidence(commit, bundleLabel);
        bytes memory encodedEvidence = example.encodeSubmitEvidence(evidence);

        vm.prank(provider);
        acp.submit(jobId, evidence.bundleHash, encodedEvidence);

        UnderwritingTypes.CompleteDecision memory decision = _completeDecision(jobId, reasonLabel, nonce);
        example.evaluator().completeBySig(decision, _signCompleteDecision(decision));
    }

    function _evidence(UnderwritingTypes.UnderwriteCommit memory commit, string memory bundleLabel)
        internal
        pure
        returns (UnderwritingTypes.SubmitEvidence memory)
    {
        return UnderwritingTypes.SubmitEvidence({
            bundleHash: keccak256(bytes(bundleLabel)),
            policyHash: commit.policyHash,
            quoteIdHash: commit.quoteIdHash,
            termsHash: commit.termsHash
        });
    }

    function _completeDecision(uint256 jobId, string memory reasonLabel, uint256 nonce)
        internal
        view
        returns (UnderwritingTypes.CompleteDecision memory)
    {
        return UnderwritingTypes.CompleteDecision({
            jobId: jobId,
            reason: keccak256(bytes(reasonLabel)),
            deadline: uint64(block.timestamp + 1 days),
            nonce: nonce
        });
    }

    function _successDisputeDecision(
        uint256 jobId,
        bytes32 disputeHash,
        SettlementTypes.SuccessDisputeOutcome outcome,
        string memory reasonLabel,
        bytes32 slashAttestationHash,
        uint256 nonce
    ) internal view returns (SettlementTypes.SuccessDisputeDecision memory) {
        return SettlementTypes.SuccessDisputeDecision({
            jobId: jobId,
            disputeHash: disputeHash,
            outcome: outcome,
            reason: keccak256(bytes(reasonLabel)),
            slashAttestationHash: slashAttestationHash,
            deadline: uint64(block.timestamp + 1 days),
            nonce: nonce
        });
    }

    function _emptySlashAttestation() internal pure returns (ICollateralManager.SlashAttestation memory) {
        return ICollateralManager.SlashAttestation({
            settlementJobId: 0,
            safe: address(0),
            user: address(0),
            merchant: address(0),
            slashAmountUsdc: 0,
            reasonCode: bytes32(0),
            validUntil: 0,
            nonce: 0
        });
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

    function _signSuccessDisputeDecision(SettlementTypes.SuccessDisputeDecision memory decision)
        internal
        view
        returns (bytes memory)
    {
        bytes32 digest = keccak256(
            abi.encodePacked(
                "\x19\x01",
                _domainSeparator(),
                keccak256(
                    abi.encode(
                        SUCCESS_DISPUTE_TYPEHASH,
                        decision.jobId,
                        decision.disputeHash,
                        uint8(decision.outcome),
                        decision.reason,
                        decision.slashAttestationHash,
                        decision.deadline,
                        decision.nonce
                    )
                )
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
