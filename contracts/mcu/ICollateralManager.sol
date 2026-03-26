// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Neutral collateral interface consumed by the underwriting settlement layer.

interface ICollateralManager {
    struct UnderwritePermit {
        uint256 jobId;
        uint256 settlementJobId;
        address safe;
        address user;
        address merchant;
        address underwriter;
        uint256 decisionFeeUsdc;
        address merchantExecutionWallet;
        uint256 requiredCollateralUsdc;
        uint256 fundedPrincipalUsdc;
        uint256 coverageCapUsdc;
        uint64 validUntil;
        uint64 executeUntil;
        bytes32 policyHash;
        uint256 nonce;
        uint64 unlockAt;
    }

    struct SlashAttestation {
        uint256 settlementJobId;
        address safe;
        address user;
        address merchant;
        uint256 slashAmountUsdc;
        bytes32 reasonCode;
        uint64 validUntil;
        uint256 nonce;
    }

    function lockCollateral(
        UnderwritePermit calldata permit,
        address claimant,
        uint64 unlockAt,
        bytes calldata permitSig
    ) external;

    function releasePrincipalToMerchant(UnderwritePermit calldata permit, bytes calldata permitSig) external;
    function confirmDeliveryBySig(uint256 settlementJobId, uint256 deliveryNonce, bytes calldata sig) external;
    function releaseCollateral(uint256 settlementJobId) external;
    function claimTimeout(uint256 settlementJobId) external;
    function slash(SlashAttestation calldata attestation, bytes calldata slashSig) external;
}
