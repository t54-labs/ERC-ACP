// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IAgenticCommerceKernel
 * @notice Minimal ACP kernel interface consumed by underwriting modules.
 * @dev Exposes the job record shape plus the read/write entrypoints the
 *      underwriting hook, evaluator, and settlement layer depend on.
 */
interface IAgenticCommerceKernel {
    /// @notice Lifecycle states a job can move through in the ACP kernel.
    enum JobStatus {
        Open,
        Funded,
        Submitted,
        Completed,
        Rejected,
        Expired
    }

    /// @notice High-level job categories used to link open and close jobs.
    enum JobKind {
        Standalone,
        Open,
        Close
    }

    /// @notice Canonical ACP job record returned by the kernel.
    struct Job {
        uint256 id;
        address client;
        address provider;
        address evaluator;
        address hook;
        string description;
        uint256 budget;
        uint256 expiredAt;
        JobStatus status;
    }

    /// @notice Returns the ERC20 token address used for ACP settlement.
    function paymentToken() external view returns (address);

    /// @notice Returns the stored job record for `jobId`.
    /// @param jobId The job identifier to fetch.
    /// @return The full ACP job struct.
    function getJob(uint256 jobId) external view returns (Job memory);

    /// @notice Returns the job category for `jobId`.
    /// @param jobId The job identifier to inspect.
    /// @return The kernel's recorded job kind.
    function getJobKind(uint256 jobId) external view returns (JobKind);

    /// @notice Returns the parent job id for a close job.
    /// @param jobId The close job identifier to inspect.
    /// @return The linked parent job id, or zero when unset.
    function getParentJobId(uint256 jobId) external view returns (uint256);

    /// @notice Returns the active close job id for an open parent job.
    /// @param jobId The parent job identifier to inspect.
    /// @return The linked close job id, or zero when unset.
    function getCloseJobId(uint256 jobId) external view returns (uint256);

    /// @notice Assigns a provider to a job created without one.
    /// @param jobId The job to update.
    /// @param provider The provider address to set.
    /// @param optParams Hook-specific auxiliary parameters forwarded by ACP.
    function setProvider(uint256 jobId, address provider, bytes calldata optParams) external;

    /// @notice Records the job budget that must be escrowed before execution.
    /// @param jobId The job to update.
    /// @param amount The proposed budget amount.
    /// @param optParams Hook-specific auxiliary parameters forwarded by ACP.
    function setBudget(uint256 jobId, uint256 amount, bytes calldata optParams) external;

    /// @notice Escrows the job budget for a previously configured job.
    /// @param jobId The job to fund.
    /// @param expectedBudget The caller's expected budget guard.
    /// @param optParams Hook-specific auxiliary parameters forwarded by ACP.
    function fund(uint256 jobId, uint256 expectedBudget, bytes calldata optParams) external;

    /// @notice Submits the provider's deliverable for evaluator review.
    /// @param jobId The job being submitted.
    /// @param deliverable The deliverable hash or identifier.
    /// @param optParams Hook-specific auxiliary parameters forwarded by ACP.
    function submit(uint256 jobId, bytes32 deliverable, bytes calldata optParams) external;

    /// @notice Completes a submitted job and releases funds.
    /// @param jobId The job to complete.
    /// @param reason The evaluator's completion reason code.
    /// @param optParams Hook-specific auxiliary parameters forwarded by ACP.
    function complete(uint256 jobId, bytes32 reason, bytes calldata optParams) external;

    /// @notice Rejects a job and triggers the kernel refund flow.
    /// @param jobId The job to reject.
    /// @param reason The rejection reason code.
    /// @param optParams Hook-specific auxiliary parameters forwarded by ACP.
    function reject(uint256 jobId, bytes32 reason, bytes calldata optParams) external;
}
