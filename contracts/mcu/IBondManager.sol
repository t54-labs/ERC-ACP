// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IBondManager {
    struct UnderwritePermit {
        bytes32 memoId;
        uint256 jobId;
        address safe;
        address user;
        address merchant;
        address underwriter;
        uint256 decisionFeeUsdc;
        address merchantExecutionWallet;
        uint256 requiredBondUsdc;
        uint256 fundedPrincipalUsdc;
        uint256 coverageCapUsdc;
        uint64 validUntil;
        uint64 executeUntil;
        bytes32 policyHash;
        uint256 nonce;
        uint64 unlockAt;
        bytes32 parentMemoId;
    }

    struct SlashAttestation {
        bytes32 memoId;
        uint256 jobId;
        address safe;
        address user;
        address merchant;
        uint256 slashAmountUsdc;
        bytes32 reasonCode;
        uint64 validUntil;
        uint256 nonce;
    }

    function lockBond(
        UnderwritePermit calldata permit,
        address claimant,
        uint64 unlockAt,
        bytes calldata permitSig
    ) external;

    function releasePrincipalToMerchant(UnderwritePermit calldata permit, bytes calldata permitSig) external;
    function confirmDeliveryBySig(bytes32 memoId, uint256 deliveryNonce, bytes calldata sig) external;
    function releaseBond(bytes32 memoId) external;
    function claimTimeout(bytes32 memoId) external;
    function slash(SlashAttestation calldata attestation, bytes calldata slashSig) external;
}
