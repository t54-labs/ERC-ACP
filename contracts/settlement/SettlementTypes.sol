// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library SettlementTypes {
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
        ExpirySettled
    }

    enum SuccessDisputeOutcome {
        ReleaseCollateral,
        SlashCollateral
    }

    struct SuccessDispute {
        bytes32 disputeHash;
        uint64 openedAt;
        uint64 deadline;
    }

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
