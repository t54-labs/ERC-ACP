// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title SettlementTypes
 * @notice Shared settlement orchestration types for protected underwriting jobs.
 */
library SettlementTypes {
    /// @notice Settlement lifecycle tracked by `UnderwritingSettlementCoordinator`.
    enum SettlementState {
        None,
        EscrowConfigured,
        CollateralLocked,
        PrincipalReleased,
        SuccessPendingRelease,
        DisputeOpen,
        ReleaseApproved,
        SuccessSettled,
        SuccessSlashed,
        RejectSettled,
        ExpirySettled,
        RecoverySettled
    }

    /// @notice Resolution options available for a post-success dispute.
    enum SuccessDisputeOutcome {
        ReleaseCollateral,
        SlashCollateral
    }

    /// @notice Metadata recorded when the client opens a post-success dispute.
    struct SuccessDispute {
        bytes32 disputeHash;
        uint64 openedAt;
        uint64 deadline;
    }

    /// @notice EIP-712 dispute resolution payload signed by the underwriter.
    struct SuccessDisputeDecision {
        uint256 jobId;
        bytes32 disputeHash;
        SuccessDisputeOutcome outcome;
        bytes32 reason;
        bytes32 slashAttestationHash;
        uint64 deadline;
        uint256 nonce;
    }
}
