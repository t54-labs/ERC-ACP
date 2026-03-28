// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../../AgenticCommerceHooked.sol";
import "./UnderwritingHook.sol";
import "./UnderwritingTypes.sol";

/**
 * @title UnderwritingCoordinator
 * @notice Legacy lightweight coordinator retained only for parity tests during the migration.
 * @dev This contract is not part of the canonical shared-environment or production runtime.
 *      New migration work should target `contracts/settlement/UnderwritingSettlementCoordinator.sol`.
 *      This lightweight path predates the settlement stack and only marks jobs as protected
 *      once ACP funding has succeeded.
 */
contract UnderwritingCoordinator {
    error ZeroAddress();
    error WrongHook();
    error WrongJobStatus();
    error InvalidState();

    AgenticCommerceHooked public immutable acp;
    UnderwritingHook public immutable hook;

    event FundingOrchestrated(uint256 indexed jobId, uint256 indexed settlementJobId);

    /// @notice Deploys the coordinator for a specific ACP kernel and underwriting hook.
    /// @param acpContract_ The hooked ACP contract address.
    /// @param hook_ The underwriting hook address.
    constructor(address acpContract_, address hook_) {
        if (acpContract_ == address(0) || hook_ == address(0)) revert ZeroAddress();
        acp = AgenticCommerceHooked(acpContract_);
        hook = UnderwritingHook(hook_);
    }

    /// @notice Marks a funded underwriting job as protected.
    /// @param jobId The funded ACP job to transition.
    function orchestrateFunding(uint256 jobId) external {
        AgenticCommerceHooked.Job memory job = acp.getJob(jobId);
        if (job.hook != address(hook)) revert WrongHook();
        if (job.status != AgenticCommerceHooked.JobStatus.Funded) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != UnderwritingTypes.SidecarState.FeeEscrowed) revert InvalidState();

        hook.markProtected(jobId);
        emit FundingOrchestrated(jobId, hook.jobSettlementJobId(jobId));
    }
}
