// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../contracts/mcu/ICollateralManager.sol";

contract MockCollateralManager is ICollateralManager {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    uint256 public lastLockJobId;
    uint256 public lastLockSettlementJobId;
    address public lastLockClaimant;
    uint64 public lastLockUnlockAt;
    bytes32 public lastLockPermitSigHash;
    bool public lockCollateralCalled;

    uint256 public lastReleasePrincipalJobId;
    uint256 public lastReleasePrincipalSettlementJobId;
    bytes32 public lastReleasePrincipalPermitSigHash;
    bool public releasePrincipalCalled;

    uint256 public lastConfirmSettlementJobId;
    uint256 public lastConfirmDeliveryNonce;
    bytes32 public lastConfirmSigHash;
    bool public confirmDeliveryCalled;

    uint256 public lastReleasedSettlementJobId;
    bool public releaseCollateralCalled;

    uint256 public lastTimeoutSettlementJobId;
    bool public claimTimeoutCalled;

    SlashAttestation public lastSlashAttestation;
    bytes32 public lastSlashSigHash;
    bool public slashCalled;

    mapping(uint256 settlementJobId => uint256 amount) public lockedCollateralBySettlementJobId;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function lockCollateral(
        UnderwritePermit calldata permit,
        address claimant,
        uint64 unlockAt,
        bytes calldata permitSig
    ) external override {
        lockCollateralCalled = true;
        lastLockJobId = permit.jobId;
        lastLockSettlementJobId = permit.settlementJobId;
        lastLockClaimant = claimant;
        lastLockUnlockAt = unlockAt;
        lastLockPermitSigHash = keccak256(permitSig);

        if (permit.requiredCollateralUsdc > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), permit.requiredCollateralUsdc);
            lockedCollateralBySettlementJobId[permit.settlementJobId] += permit.requiredCollateralUsdc;
        }

        if (permit.decisionFeeUsdc > 0) {
            usdc.safeTransferFrom(permit.user, address(this), permit.decisionFeeUsdc);
        }
    }

    function releasePrincipalToMerchant(UnderwritePermit calldata permit, bytes calldata permitSig) external override {
        releasePrincipalCalled = true;
        lastReleasePrincipalJobId = permit.jobId;
        lastReleasePrincipalSettlementJobId = permit.settlementJobId;
        lastReleasePrincipalPermitSigHash = keccak256(permitSig);

        if (permit.fundedPrincipalUsdc > 0) {
            usdc.safeTransferFrom(msg.sender, permit.merchantExecutionWallet, permit.fundedPrincipalUsdc);
        }
    }

    function confirmDeliveryBySig(uint256 settlementJobId, uint256 deliveryNonce, bytes calldata sig) external override {
        confirmDeliveryCalled = true;
        lastConfirmSettlementJobId = settlementJobId;
        lastConfirmDeliveryNonce = deliveryNonce;
        lastConfirmSigHash = keccak256(sig);
    }

    function releaseCollateral(uint256 settlementJobId) external override {
        releaseCollateralCalled = true;
        lastReleasedSettlementJobId = settlementJobId;

        uint256 amount = lockedCollateralBySettlementJobId[settlementJobId];
        lockedCollateralBySettlementJobId[settlementJobId] = 0;

        if (amount > 0) {
            usdc.safeTransfer(msg.sender, amount);
        }
    }

    function claimTimeout(uint256 settlementJobId) external override {
        claimTimeoutCalled = true;
        lastTimeoutSettlementJobId = settlementJobId;
    }

    function slash(SlashAttestation calldata attestation, bytes calldata slashSig) external override {
        slashCalled = true;
        lastSlashAttestation = attestation;
        lastSlashSigHash = keccak256(slashSig);
    }
}
