// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

library MCUTypes {
    enum SidecarState {
        None,
        Committed,
        FeeEscrowed,
        Protected,
        AwaitingClose,
        EvidenceSubmitted,
        SuccessPendingConfirmation,
        SuccessDisputeOpen,
        SuccessPendingBondRelease,
        SuccessSettled,
        SuccessSlashed,
        RejectPendingSlash,
        RejectSettled,
        ExpiryPendingTimeout,
        ExpirySettled
    }

    enum SuccessDisputeOutcome {
        ReleaseBond,
        SlashBond
    }

    struct MCUCommit {
        bytes32 memoId;
        uint256 parentJobId;
        address underwriter;
        address merchantExecutionWallet;
        uint256 decisionFeeUsdc;
        uint256 requiredBondUsdc;
        uint256 fundedPrincipalUsdc;
        uint256 coverageCapUsdc;
        uint64 validUntil;
        uint64 executeUntil;
        uint64 unlockAt;
        uint64 deliveryConfirmationTimeoutWindow;
        bytes32 policyHash;
        bytes32 parentMemoId;
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

    struct CompleteContext {
        bytes32 memoId;
    }

    struct RejectContext {
        bytes32 memoId;
        bytes32 slashAttestationHash;
        bytes32 reasonCode;
    }

    struct SuccessDisputeDecision {
        uint256 jobId;
        bytes32 memoId;
        bytes32 disputeHash;
        SuccessDisputeOutcome outcome;
        bytes32 reason;
        bytes32 slashAttestationHash;
        uint64 deadline;
        uint256 nonce;
    }
}
