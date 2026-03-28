// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@acp/AgenticCommerce.sol";
import "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import "../interfaces/IAgenticCommerceKernel.sol";
import "../interfaces/ICollateralManager.sol";
import "../hooks/underwriting/UnderwritingHook.sol";
import "../hooks/underwriting/UnderwritingTypes.sol";
import "../settlement/UnderwritingSettlementCoordinator.sol";
import "../settlement/UnderwritingEvaluator.sol";

/**
 * @title UnderwritingHookSystemExample
 * @notice Legacy example helper for tests and local integrations.
 * @dev This contract is not part of the canonical shared-environment or production deployment path.
 *      Use `script/DeployUnderwritingSharedEnv.s.sol` for the canonical runtime wiring.
 *      This helper remains as migration-era glue for tests that want a ready-made underwriting
 *      stack on top of the canonical ACP runtime.
 */
contract UnderwritingHookSystemExample {
    error ZeroAddress();
    error OnlyOwner();

    /// @notice Inputs used to assemble an underwriting commit.
    struct CommitInputs {
        uint256 parentJobId;
        address underwriter;
        uint64 validFor;
        bytes32 policyHash;
        bytes32 quoteIdHash;
        bytes32 termsHash;
        bool allowCloseJob;
    }

    /// @notice Inputs used to assemble an underwriting permit.
    struct PermitInputs {
        address merchantExecutionWallet;
        uint256 underwritingPremiumUsdc;
        uint256 requiredCollateralUsdc;
        uint256 fundedPrincipalUsdc;
        uint256 coverageCapUsdc;
        uint64 executeFor;
        uint64 unlockIn;
        uint256 nonce;
    }

    AgenticCommerce public immutable acp;
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

    /// @notice Deploys and wires a full underwriting hook stack for the supplied ACP kernel.
    /// @param acp_ The ACP contract to integrate with.
    /// @param collateralManager_ The collateral manager used by settlement escrows.
    /// @param settlementToken_ The only token protected underwriting jobs may use.
    /// @param clientConfirmationWindowSeconds_ Duration after submission during which only the client may confirm.
    constructor(
        AgenticCommerce acp_,
        ICollateralManager collateralManager_,
        address settlementToken_,
        uint64 clientConfirmationWindowSeconds_
    ) {
        if (
            address(acp_) == address(0) || address(collateralManager_) == address(0) || settlementToken_ == address(0)
        ) revert ZeroAddress();

        acp = acp_;
        collateralManager = collateralManager_;
        owner = msg.sender;

        UnderwritingHook hookImplementation = new UnderwritingHook();
        ERC1967Proxy hookProxy =
            new ERC1967Proxy(address(hookImplementation), abi.encodeCall(UnderwritingHook.initialize, (address(acp_), address(this))));
        hook = UnderwritingHook(address(hookProxy));
        hook.setAllowedSettlementToken(settlementToken_);
        coordinator = new UnderwritingSettlementCoordinator(
            IAgenticCommerceKernel(address(acp_)), hook, collateralManager_
        );
        evaluator = new UnderwritingEvaluator(IAgenticCommerceKernel(address(acp_)), hook, clientConfirmationWindowSeconds_);

        hook.setWiring(address(evaluator), address(coordinator));

        emit HookSystemDeployed(address(acp_), address(collateralManager_), address(hook), address(coordinator), address(evaluator));
    }

    /// @notice Registers an underwriter through the example-owned hook.
    /// @param underwriter The underwriter address to register.
    function registerUnderwriter(address underwriter) external onlyOwner {
        hook.registerUnderwriter(underwriter);
    }

    /// @notice Unregisters an underwriter through the example-owned hook.
    /// @param underwriter The underwriter address to unregister.
    function unregisterUnderwriter(address underwriter) external onlyOwner {
        hook.unregisterUnderwriter(underwriter);
    }

    /// @notice Builds an underwriting commit using relative validity inputs.
    /// @param inputs The user-friendly commit inputs.
    /// @return commit The assembled underwriting commit.
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

    /// @notice ABI-encodes an underwriting commit for `setBudget` hook parameters.
    /// @param commit The underwriting commit to encode.
    /// @return The ABI-encoded commit payload.
    function encodeCommit(UnderwritingTypes.UnderwriteCommit memory commit) external pure returns (bytes memory) {
        return abi.encode(commit);
    }

    /// @notice ABI-encodes submit evidence for ACP `submit` hook parameters.
    /// @param evidence The submit evidence payload to encode.
    /// @return The ABI-encoded evidence payload.
    function encodeSubmitEvidence(UnderwritingTypes.SubmitEvidence memory evidence) external pure returns (bytes memory) {
        return abi.encode(evidence);
    }

    /// @notice Builds an underwriting permit using relative timing inputs.
    /// @param jobId The ACP job being protected.
    /// @param client The client funding the job.
    /// @param escrow The settlement escrow that will act as safe and merchant.
    /// @param commit The previously chosen underwriting commit.
    /// @param inputs The user-friendly permit inputs.
    /// @return permit The assembled collateral-manager permit.
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
            underwritingPremiumUsdc: inputs.underwritingPremiumUsdc,
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
