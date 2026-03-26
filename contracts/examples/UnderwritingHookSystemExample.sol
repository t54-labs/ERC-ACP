// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../AgenticCommerceHooked.sol";
import "../mcu/IAgenticCommerceKernel.sol";
import "../mcu/ICollateralManager.sol";
import "../hooks/underwriting/UnderwritingHook.sol";
import "../hooks/underwriting/UnderwritingTypes.sol";
import "../settlement/UnderwritingSettlementCoordinator.sol";
import "../settlement/UnderwritingEvaluator.sol";

contract UnderwritingHookSystemExample {
    error ZeroAddress();
    error OnlyOwner();

    struct CommitInputs {
        uint256 parentJobId;
        address underwriter;
        uint64 validFor;
        bytes32 policyHash;
        bytes32 quoteIdHash;
        bytes32 termsHash;
        bool allowCloseJob;
    }

    struct PermitInputs {
        address merchantExecutionWallet;
        uint256 decisionFeeUsdc;
        uint256 requiredCollateralUsdc;
        uint256 fundedPrincipalUsdc;
        uint256 coverageCapUsdc;
        uint64 executeFor;
        uint64 unlockIn;
        uint256 nonce;
    }

    AgenticCommerceHooked public immutable acp;
    ICollateralManager public immutable collateralManager;
    UnderwritingHook public immutable hook;
    UnderwritingSettlementCoordinator public immutable coordinator;
    UnderwritingEvaluator public immutable evaluator;
    address public immutable owner;

    event HookSystemDeployed(
        address indexed acp,
        address indexed collateralManager,
        address hook,
        address coordinator,
        address evaluator
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert OnlyOwner();
        _;
    }

    constructor(AgenticCommerceHooked acp_, ICollateralManager collateralManager_, uint64 disputeWindowSeconds_) {
        if (address(acp_) == address(0) || address(collateralManager_) == address(0)) revert ZeroAddress();

        acp = acp_;
        collateralManager = collateralManager_;
        owner = msg.sender;

        hook = new UnderwritingHook(address(acp_), address(this));
        coordinator = new UnderwritingSettlementCoordinator(
            IAgenticCommerceKernel(address(acp_)), hook, collateralManager_, disputeWindowSeconds_
        );
        evaluator = new UnderwritingEvaluator(IAgenticCommerceKernel(address(acp_)), hook, address(coordinator));

        hook.setWiring(address(evaluator), address(coordinator));

        emit HookSystemDeployed(address(acp_), address(collateralManager_), address(hook), address(coordinator), address(evaluator));
    }

    function registerUnderwriter(address underwriter) external onlyOwner {
        hook.registerUnderwriter(underwriter);
    }

    function unregisterUnderwriter(address underwriter) external onlyOwner {
        hook.unregisterUnderwriter(underwriter);
    }

    function buildCommit(CommitInputs memory inputs) external view returns (UnderwritingTypes.UnderwriteCommit memory commit) {
        commit = UnderwritingTypes.UnderwriteCommit({
            parentJobId: inputs.parentJobId,
            underwriter: inputs.underwriter,
            validUntil: uint64(block.timestamp) + inputs.validFor,
            policyHash: inputs.policyHash,
            quoteIdHash: inputs.quoteIdHash,
            termsHash: inputs.termsHash,
            allowCloseJob: inputs.allowCloseJob
        });
    }

    function encodeCommit(UnderwritingTypes.UnderwriteCommit memory commit) external pure returns (bytes memory) {
        return abi.encode(commit);
    }

    function encodeSubmitEvidence(UnderwritingTypes.SubmitEvidence memory evidence) external pure returns (bytes memory) {
        return abi.encode(evidence);
    }

    function buildPermit(
        uint256 jobId,
        address client,
        address escrow,
        UnderwritingTypes.UnderwriteCommit memory commit,
        PermitInputs memory inputs
    ) external view returns (ICollateralManager.UnderwritePermit memory permit) {
        uint256 settlementJobId = commit.parentJobId != 0 ? commit.parentJobId : jobId;

        permit = ICollateralManager.UnderwritePermit({
            jobId: jobId,
            settlementJobId: settlementJobId,
            safe: escrow,
            user: client,
            merchant: escrow,
            underwriter: commit.underwriter,
            decisionFeeUsdc: inputs.decisionFeeUsdc,
            merchantExecutionWallet: inputs.merchantExecutionWallet,
            requiredCollateralUsdc: inputs.requiredCollateralUsdc,
            fundedPrincipalUsdc: inputs.fundedPrincipalUsdc,
            coverageCapUsdc: inputs.coverageCapUsdc,
            validUntil: commit.validUntil,
            executeUntil: uint64(block.timestamp) + inputs.executeFor,
            policyHash: commit.policyHash,
            nonce: inputs.nonce,
            unlockAt: uint64(block.timestamp) + inputs.unlockIn
        });
    }
}
