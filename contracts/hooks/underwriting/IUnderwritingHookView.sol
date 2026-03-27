// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./UnderwritingTypes.sol";

/**
 * @title IUnderwritingHookView
 * @notice Read-only view surface exposed by the underwriting hook.
 */
interface IUnderwritingHookView {
    /// @notice Returns the underwriting commitment recorded for `jobId`.
    /// @param jobId The job identifier to inspect.
    /// @return The stored underwriting commit.
    function getCommit(uint256 jobId) external view returns (UnderwritingTypes.UnderwriteCommit memory);

    /// @notice Returns the underwriter responsible for `jobId`.
    /// @param jobId The job identifier to inspect.
    /// @return The bound underwriter address.
    function jobUnderwriter(uint256 jobId) external view returns (address);

    /// @notice Returns the underwriting sidecar state for `jobId`.
    /// @param jobId The job identifier to inspect.
    /// @return The current underwriting sidecar state.
    function jobSidecarState(uint256 jobId) external view returns (UnderwritingTypes.SidecarState);

    /// @notice Returns the settlement job id associated with `jobId`.
    /// @param jobId The job identifier to inspect.
    /// @return The canonical settlement job id, or zero if the job is not committed.
    function jobSettlementJobId(uint256 jobId) external view returns (uint256);

    /// @notice Indicates whether a successful parent job is waiting for a close job.
    /// @param jobId The parent job identifier to inspect.
    /// @return True when the job is awaiting a close leg.
    function isAwaitingClose(uint256 jobId) external view returns (bool);

    /// @notice Returns the parent job id for a committed close job.
    /// @param closeJobId The close job identifier to inspect.
    /// @return The linked parent job id, or zero when unset.
    function getParentJobId(uint256 closeJobId) external view returns (uint256);

    /// @notice Returns the active close job id associated with a parent job.
    /// @param parentJobId The parent job identifier to inspect.
    /// @return The linked close job id, or zero when unset.
    function getActiveCloseJobId(uint256 parentJobId) external view returns (uint256);

    /// @notice Returns the timestamp at which the provider submitted evidence for `jobId`.
    /// @param jobId The job identifier to inspect.
    /// @return The submission timestamp, or zero when no submission has been recorded.
    function jobSubmittedAt(uint256 jobId) external view returns (uint64);
}
