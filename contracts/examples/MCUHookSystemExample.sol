// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../mcu/IAgenticCommerceKernel.sol";
import "../mcu/ICollateralManager.sol";
import "../mcu/MCUTypes.sol";
import "../mcu/MCUHookLite.sol";
import "../mcu/MCUCoordinator.sol";
import "../mcu/UnderwriterEvaluator.sol";

/**
 * @title MCUHookSystemExample
 * @notice Example wiring helper for the multi-contract MCU hook system.
 *
 * USE CASE
 * --------
 * `FundTransferHook` and `BiddingHook` are good examples of single-contract ACP
 * hook profiles. The MCU system is different: the hook is only one part of a
 * larger flow that also uses a coordinator, evaluator, per-job adapters, and a
 * CollateralManager integration.
 *
 * This example demonstrates the intended deployment and payload-building shape
 * without pretending the MCU system is a one-file `BaseACPHook` pattern.
 *
 * FLOW
 * ----
 *  1. Deploy or reference an existing `AgenticCommerceHooked`-compatible ACP
 *     kernel and a `CollateralManager`.
 *
 *  2. Deploy this helper:
 *       `new MCUHookSystemExample(acp, collateralManager)`
 *
 *     The constructor deploys:
 *       - `MCUHookLite`
 *       - `MCUCoordinator`
 *       - `UnderwriterEvaluator`
 *
 *     and wires the hook to the coordinator + evaluator once.
 *
 *  3. Create an ACP parent open job using the deployed evaluator and hook addresses:
 *       `createOpenJob(provider, address(example.evaluator()), expiredAt, description, address(example.hook()))`
 *
 *  3a. The deployer / owner registers any underwriter signer that should be
 *      allowed to back new single-stage or two-stage open commits:
 *       `example.registerUnderwriter(underwriter)`
 *
 *  4. Build the MCU commitment off-chain or via the helper:
 *       `MCUTypes.MCUCommit memory commit = example.buildCommit(inputs);`
 *       `bytes memory optParams = example.encodeCommit(commit);`
 *
 *     Then commit it during `setBudget(...)`.
 *
 *  5. Build the matching `UnderwritePermit` for the later funding step:
 *       `ICollateralManager.UnderwritePermit memory permit =`
 *       `    example.buildPermit(jobId, client, adapter, commit, nonce);`
 *
 *     The permit must mirror the same settlement/collateral/principal/policy values stored
 *     in the committed MCU profile.
 *
 *  6. Continue with the normal MCU flow:
 *       Open leg:
 *         `fund(...)`
 *         `coordinator.orchestrateFunding(...)`
 *         `evaluator.completeBySig(...)` or `rejectBySig(...)`
 *
 *       Later, if the client requests a two-stage close leg:
 *         `createJob(..., hook = address(example.hook()))`
 *         `setBudget(..., abi.encode(closeCommit{ parentJobId = openJobId }))`
 *         `fund(...)`
 *         `coordinator.orchestrateFunding(...)`
 *         `submit(...)`
 *         `evaluator.completeBySig(...)` or `rejectBySig(...)`
 *
 * IMPORTANT
 * ---------
 * This contract is an example wiring helper, not a production façade. It does
 * not submit jobs, move funds, or hide the MCU lifecycle behind wrapper calls.
 *
 * The helper also does not compute a per-job adapter address for you. The
 * `UnderwritePermit` requires the adapter address because `safe` and `merchant`
 * must match the `MCUJobAdapter` used by the coordinator.
 */
contract MCUHookSystemExample {
    error ZeroAddress();
    error OnlyOwner();

    /// @dev Relative-time inputs used to produce a valid MCU commit from the
    ///      current block timestamp.
    struct CommitInputs {
        uint256 parentJobId;
        address underwriter;
        address merchantExecutionWallet;
        uint256 decisionFeeUsdc;
        uint256 requiredCollateralUsdc;
        uint256 fundedPrincipalUsdc;
        uint256 coverageCapUsdc;
        uint64 validFor;
        uint64 executeFor;
        uint64 unlockIn;
        uint64 deliveryConfirmationTimeoutWindow;
        bytes32 policyHash;
        bytes32 quoteIdHash;
        bool releasePrincipal;
    }

    IAgenticCommerceKernel public immutable acp;
    ICollateralManager public immutable collateralManager;
    MCUHookLite public immutable hook;
    MCUCoordinator public immutable coordinator;
    UnderwriterEvaluator public immutable evaluator;
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

    constructor(IAgenticCommerceKernel acp_, ICollateralManager collateralManager_) {
        if (address(acp_) == address(0) || address(collateralManager_) == address(0)) revert ZeroAddress();

        acp = acp_;
        collateralManager = collateralManager_;
        owner = msg.sender;

        // The example contract is the temporary hook admin so it can wire the
        // coordinator and evaluator exactly once during construction.
        hook = new MCUHookLite(acp_, address(this));
        coordinator = new MCUCoordinator(acp_, hook, collateralManager_);
        evaluator = new UnderwriterEvaluator(acp_, IMCUHookView(address(hook)), address(coordinator));

        hook.setWiring(address(coordinator), address(evaluator));

        emit HookSystemDeployed(address(acp_), address(collateralManager_), address(hook), address(coordinator), address(evaluator));
    }

    /// @notice Build an `MCUTypes.MCUCommit` using relative time offsets.
    /// @dev The returned struct is suitable for `abi.encode(commit)` and then
    ///      passing as `setBudget(..., abi.encode(commit))` optParams.
    function buildCommit(CommitInputs memory inputs) external view returns (MCUTypes.MCUCommit memory commit) {
        uint64 nowTs = uint64(block.timestamp);

        commit = MCUTypes.MCUCommit({
            parentJobId: inputs.parentJobId,
            underwriter: inputs.underwriter,
            merchantExecutionWallet: inputs.merchantExecutionWallet,
            decisionFeeUsdc: inputs.decisionFeeUsdc,
            requiredCollateralUsdc: inputs.requiredCollateralUsdc,
            fundedPrincipalUsdc: inputs.fundedPrincipalUsdc,
            coverageCapUsdc: inputs.coverageCapUsdc,
            validUntil: nowTs + inputs.validFor,
            executeUntil: nowTs + inputs.executeFor,
            unlockAt: nowTs + inputs.unlockIn,
            deliveryConfirmationTimeoutWindow: inputs.deliveryConfirmationTimeoutWindow,
            policyHash: inputs.policyHash,
            quoteIdHash: inputs.quoteIdHash,
            releasePrincipal: inputs.releasePrincipal
        });
    }

    /// @notice Encode an MCU commit for `setBudget(..., serviceFee, optParams)`.
    function encodeCommit(MCUTypes.MCUCommit memory commit) external pure returns (bytes memory) {
        return abi.encode(commit);
    }

    /// @notice Encode submit evidence for `submit(jobId, deliverable, optParams)`.
    function encodeSubmitEvidence(MCUTypes.SubmitEvidence memory evidence) external pure returns (bytes memory) {
        return abi.encode(evidence);
    }

    /// @notice Register an underwriter signer for future single-stage or
    ///         two-stage open commits.
    function registerUnderwriter(address underwriter) external onlyOwner {
        hook.registerUnderwriter(underwriter);
    }

    /// @notice Remove an underwriter signer from future admission checks.
    ///         Existing committed jobs remain valid because they already store
    ///         the underwriter address in their profile.
    function unregisterUnderwriter(address underwriter) external onlyOwner {
        hook.unregisterUnderwriter(underwriter);
    }

    /// @notice Build the CollateralManager permit that must match the committed MCU
    ///         profile for `MCUCoordinator.orchestrateFunding(...)`.
    /// @param jobId The ACP job id.
    /// @param client The ACP client identity for the job.
    /// @param adapter The `MCUJobAdapter` address that will hold collateral/principal.
    /// @param commit The committed MCU profile.
    /// @param nonce The underwriter permit nonce.
    function buildPermit(
        uint256 jobId,
        address client,
        address adapter,
        MCUTypes.MCUCommit memory commit,
        uint256 nonce
    ) external pure returns (ICollateralManager.UnderwritePermit memory permit) {
        uint256 settlementJobId = commit.parentJobId != 0 ? commit.parentJobId : jobId;

        permit = ICollateralManager.UnderwritePermit({
            jobId: jobId,
            settlementJobId: settlementJobId,
            safe: adapter,
            user: client,
            merchant: adapter,
            underwriter: commit.underwriter,
            decisionFeeUsdc: commit.decisionFeeUsdc,
            merchantExecutionWallet: commit.merchantExecutionWallet,
            requiredCollateralUsdc: commit.requiredCollateralUsdc,
            fundedPrincipalUsdc: commit.fundedPrincipalUsdc,
            coverageCapUsdc: commit.coverageCapUsdc,
            validUntil: commit.validUntil,
            executeUntil: commit.executeUntil,
            policyHash: commit.policyHash,
            nonce: nonce,
            unlockAt: commit.unlockAt
        });
    }
}
