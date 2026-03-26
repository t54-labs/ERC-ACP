// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Neutral collateral interface consumed by the underwriting settlement layer.
/**
 * @title ICollateralManager
 * @notice Minimal collateral engine surface used by the underwriting settlement layer.
 * @dev The settlement contracts treat this interface as an external adapter for
 *      collateral locks, principal releases, delivery confirmation, timeout claims,
 *      and collateral slashing.
 */
interface ICollateralManager {
    /// @notice Permit payload authorizing a protected underwriting settlement.
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

    /// @notice Slash payload describing a post-dispute collateral seizure.
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

    /// @notice Locks provider collateral for a settlement flow.
    /// @param permit The settlement permit being exercised.
    /// @param claimant The account authorized to claim timeout outcomes.
    /// @param unlockAt The earliest timestamp collateral may be released.
    /// @param permitSig The signature authorizing `permit`.
    function lockCollateral(
        UnderwritePermit calldata permit,
        address claimant,
        uint64 unlockAt,
        bytes calldata permitSig
    ) external;

    /// @notice Releases funded principal from escrow to the merchant execution wallet.
    /// @param permit The settlement permit governing the principal release.
    /// @param permitSig The signature authorizing `permit`.
    function releasePrincipalToMerchant(UnderwritePermit calldata permit, bytes calldata permitSig) external;

    /// @notice Confirms delivery using an off-chain signature.
    /// @param settlementJobId The settlement identifier being confirmed.
    /// @param deliveryNonce The monotonic delivery nonce used by the collateral manager.
    /// @param sig The signature authorizing delivery confirmation.
    function confirmDeliveryBySig(uint256 settlementJobId, uint256 deliveryNonce, bytes calldata sig) external;

    /// @notice Releases previously locked collateral back to the provider side.
    /// @param settlementJobId The settlement identifier whose collateral should be released.
    function releaseCollateral(uint256 settlementJobId) external;

    /// @notice Claims the timeout path for an expired settlement.
    /// @param settlementJobId The settlement identifier to settle through timeout.
    function claimTimeout(uint256 settlementJobId) external;

    /// @notice Slashes collateral according to a signed dispute attestation.
    /// @param attestation The slash attestation payload to execute.
    /// @param slashSig The signature authorizing the slash.
    function slash(SlashAttestation calldata attestation, bytes calldata slashSig) external;
}
