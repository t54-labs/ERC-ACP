// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../contracts/mcu/IBondManager.sol";

contract MockBondManager is IBondManager {
    using SafeERC20 for IERC20;

    IERC20 public immutable usdc;

    uint256 public lastLockJobId;
    bytes32 public lastLockMemoId;
    address public lastLockClaimant;
    uint64 public lastLockUnlockAt;
    bytes32 public lastLockPermitSigHash;
    bool public lockBondCalled;

    uint256 public lastReleasePrincipalJobId;
    bytes32 public lastReleasePrincipalMemoId;
    bytes32 public lastReleasePrincipalPermitSigHash;
    bool public releasePrincipalCalled;

    bytes32 public lastConfirmMemoId;
    uint256 public lastConfirmDeliveryNonce;
    bytes32 public lastConfirmSigHash;
    bool public confirmDeliveryCalled;

    bytes32 public lastReleasedMemoId;
    bool public releaseBondCalled;

    bytes32 public lastTimeoutMemoId;
    bool public claimTimeoutCalled;

    SlashAttestation public lastSlashAttestation;
    bytes32 public lastSlashSigHash;
    bool public slashCalled;

    mapping(bytes32 memoId => uint256 amount) public lockedBondByMemo;

    constructor(IERC20 usdc_) {
        usdc = usdc_;
    }

    function lockBond(
        UnderwritePermit calldata permit,
        address claimant,
        uint64 unlockAt,
        bytes calldata permitSig
    ) external override {
        lockBondCalled = true;
        lastLockJobId = permit.jobId;
        lastLockMemoId = permit.memoId;
        lastLockClaimant = claimant;
        lastLockUnlockAt = unlockAt;
        lastLockPermitSigHash = keccak256(permitSig);

        if (permit.requiredBondUsdc > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), permit.requiredBondUsdc);
            lockedBondByMemo[permit.memoId] += permit.requiredBondUsdc;
        }

        if (permit.decisionFeeUsdc > 0) {
            usdc.safeTransferFrom(permit.user, address(this), permit.decisionFeeUsdc);
        }
    }

    function releasePrincipalToMerchant(UnderwritePermit calldata permit, bytes calldata permitSig) external override {
        releasePrincipalCalled = true;
        lastReleasePrincipalJobId = permit.jobId;
        lastReleasePrincipalMemoId = permit.memoId;
        lastReleasePrincipalPermitSigHash = keccak256(permitSig);

        if (permit.fundedPrincipalUsdc > 0) {
            usdc.safeTransferFrom(msg.sender, permit.merchantExecutionWallet, permit.fundedPrincipalUsdc);
        }
    }

    function confirmDeliveryBySig(bytes32 memoId, uint256 deliveryNonce, bytes calldata sig) external override {
        confirmDeliveryCalled = true;
        lastConfirmMemoId = memoId;
        lastConfirmDeliveryNonce = deliveryNonce;
        lastConfirmSigHash = keccak256(sig);
    }

    function releaseBond(bytes32 memoId) external override {
        releaseBondCalled = true;
        lastReleasedMemoId = memoId;

        uint256 amount = lockedBondByMemo[memoId];
        lockedBondByMemo[memoId] = 0;

        if (amount > 0) {
            usdc.safeTransfer(msg.sender, amount);
        }
    }

    function claimTimeout(bytes32 memoId) external override {
        claimTimeoutCalled = true;
        lastTimeoutMemoId = memoId;
    }

    function slash(SlashAttestation calldata attestation, bytes calldata slashSig) external override {
        slashCalled = true;
        lastSlashAttestation = attestation;
        lastSlashSigHash = keccak256(slashSig);
    }
}
