// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title UnderwritingTypes
 * @notice Shared underwriting workflow types used by the hook and evaluator.
 */
library UnderwritingTypes {
    /// @notice Sidecar lifecycle tracked alongside the ACP job lifecycle.
    enum SidecarState {
        None,
        Committed,
        FeeEscrowed,
        Protected,
        EvidenceSubmitted,
        AwaitingClose,
        SuccessPendingConfirmation,
        RejectSettled
    }

    /// @notice Underwriter commitment bound to a job during budget configuration.
    struct UnderwriteCommit {
        /// @notice Parent open job id when this is a close job; zero for standalone/open jobs.
        uint256 parentJobId;
        /// @notice Underwriter responsible for completion and rejection signatures.
        address underwriter;
        /// @notice Last timestamp at which the commit can be accepted.
        uint64 validUntil;
        /// @notice Hash of the policy terms this workflow is enforcing.
        bytes32 policyHash;
        /// @notice Hash of the quoted pricing or underwriting offer.
        bytes32 quoteIdHash;
        /// @notice Hash of any supplemental commercial terms.
        bytes32 termsHash;
        /// @notice Whether a successful parent job may open a linked close job.
        bool allowCloseJob;
    }

    /// @notice Evidence payload that must match the previously committed underwriting terms.
    struct SubmitEvidence {
        /// @notice Bundle hash that is also emitted as the ACP deliverable.
        bytes32 bundleHash;
        /// @notice Policy hash that must match the stored commit.
        bytes32 policyHash;
        /// @notice Quote hash that must match the stored commit.
        bytes32 quoteIdHash;
        /// @notice Terms hash that must match the stored commit.
        bytes32 termsHash;
    }

    /// @notice EIP-712 completion instruction signed by the responsible underwriter.
    struct CompleteDecision {
        uint256 jobId;
        bytes32 reason;
        uint64 deadline;
        uint256 nonce;
    }

    /// @notice EIP-712 rejection instruction signed by the responsible underwriter.
    struct RejectDecision {
        uint256 jobId;
        bytes32 reason;
        uint64 deadline;
        uint256 nonce;
    }
}
