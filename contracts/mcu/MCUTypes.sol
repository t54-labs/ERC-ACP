// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library MCUTypes {
    enum FlowKind {
        SingleStage,
        TwoStageOpen,
        TwoStageClose
    }

    enum SidecarState {
        None,
        Committed,
        FeeEscrowed,
        Protected,
        AwaitingClose,
        EvidenceSubmitted,
        SuccessPendingConfirmation,
        SuccessDisputeOpen,
        SuccessPendingCollateralRelease,
        SuccessSettled,
        SuccessSlashed,
        RejectPendingSlash,
        RejectSettled,
        ExpiryPendingTimeout,
        ExpirySettled
    }

    enum SuccessDisputeOutcome {
        ReleaseCollateral,
        SlashCollateral
    }

    struct MCUCommit {
        uint256 parentJobId;
        address underwriter;
        address merchantExecutionWallet;
        uint256 decisionFeeUsdc;
        uint256 requiredCollateralUsdc;
        uint256 fundedPrincipalUsdc;
        uint256 coverageCapUsdc;
        uint64 validUntil;
        uint64 executeUntil;
        uint64 unlockAt;
        uint64 deliveryConfirmationTimeoutWindow;
        bytes32 policyHash;
        bytes32 quoteIdHash;
        bool releasePrincipal;
    }

    struct SubmitEvidence {
        bytes32 bundleHash;
        bytes32 permitDigest;
        bytes32 execRequestHash;
        bytes32 execResultHash;
        bytes32 quoteIdHash;
        bytes32 policyHash;
    }

    struct RejectContext {
        bytes32 slashAttestationHash;
        bytes32 reasonCode;
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
