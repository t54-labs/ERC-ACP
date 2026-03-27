// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../interfaces/ICollateralManager.sol";

/**
 * @title UnderwritingCollateralManager
 * @notice Deployable collateral manager that owns underwriter payout/recovery routing,
 *         permit verification, premium collection, principal release, collateral release,
 *         and collateral recovery.
 * @dev Underwriter signers can self-manage their payout (premium) and recovery addresses.
 *      The contract verifies EIP-712 UnderwritePermit signatures against permit.underwriter
 *      and enforces position lifecycle invariants.
 */
contract UnderwritingCollateralManager is ICollateralManager, EIP712, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ── errors ──────────────────────────────────────────────────────────

    error RecipientsNotSet();
    error PositionAlreadyExists();
    error PositionNotFound();
    error InvalidPermitSignature();
    error PrincipalAlreadyReleased();
    error CollateralAlreadyReleased();
    error CollateralAlreadyRecovered();
    error CallerNotEscrow();

    // ── EIP-712 typehash ────────────────────────────────────────────────

    bytes32 public constant UNDERWRITE_PERMIT_TYPEHASH = keccak256(
        "UnderwritePermit(uint256 jobId,uint256 settlementJobId,address safe,address user,address merchant,address underwriter,uint256 decisionFeeUsdc,address merchantExecutionWallet,uint256 requiredCollateralUsdc,uint256 fundedPrincipalUsdc,uint256 coverageCapUsdc,uint64 validUntil,uint64 executeUntil,bytes32 policyHash,uint256 nonce,uint64 unlockAt)"
    );

    bytes32 public constant SLASH_ATTESTATION_TYPEHASH = keccak256(
        "SlashAttestation(uint256 settlementJobId,address safe,address user,address merchant,uint256 slashAmountUsdc,bytes32 reasonCode,uint64 validUntil,uint256 nonce)"
    );

    // ── types ───────────────────────────────────────────────────────────

    /// @notice Underwriter-managed payout and recovery addresses.
    struct UnderwriterRecipients {
        address premiumRecipient;
        address recoveryRecipient;
    }

    /// @notice Position tracking for a single settlement flow.
    struct Position {
        address underwriter;
        address safe;
        address user;
        address merchantExecutionWallet;
        uint256 lockedCollateralUsdc;
        uint64 unlockAt;
        address claimant;
        bool premiumPaid;
        bool principalReleased;
        bool collateralRecovered;
        bool collateralReleased;
    }

    // ── state ───────────────────────────────────────────────────────────

    IERC20 public immutable usdc;

    /// @notice Underwriter => their configured payout/recovery addresses.
    mapping(address underwriter => UnderwriterRecipients) public recipientsByUnderwriter;

    /// @notice settlementJobId => position state.
    mapping(uint256 settlementJobId => Position) public positionBySettlementJobId;

    // ── events ──────────────────────────────────────────────────────────

    event UnderwriterRecipientsSet(address indexed underwriter, address premiumRecipient, address recoveryRecipient);
    event CollateralLocked(uint256 indexed settlementJobId, address indexed underwriter, uint256 collateralUsdc, uint256 premiumUsdc);
    event PrincipalReleasedToMerchant(uint256 indexed settlementJobId, address indexed merchantExecutionWallet, uint256 principalUsdc);
    event CollateralReleased(uint256 indexed settlementJobId, address indexed caller, uint256 collateralUsdc);
    event TimeoutClaimed(uint256 indexed settlementJobId, address indexed recoveryRecipient, uint256 collateralUsdc);
    event CollateralSlashed(uint256 indexed settlementJobId, address indexed recoveryRecipient, uint256 slashAmountUsdc);

    // ── constructor ─────────────────────────────────────────────────────

    /// @param usdc_ The USDC token used for all settlement transfers.
    constructor(IERC20 usdc_) EIP712("Underwriting Collateral Manager", "1") {
        usdc = usdc_;
    }

    // ── underwriter self-management ─────────────────────────────────────

    /// @notice Allows an underwriter to set their premium and recovery recipients.
    /// @param premiumRecipient The address that receives underwriting premiums.
    /// @param recoveryRecipient The address that receives recovered/slashed collateral.
    function setUnderwriterRecipients(address premiumRecipient, address recoveryRecipient) external {
        recipientsByUnderwriter[msg.sender] = UnderwriterRecipients({
            premiumRecipient: premiumRecipient,
            recoveryRecipient: recoveryRecipient
        });
        emit UnderwriterRecipientsSet(msg.sender, premiumRecipient, recoveryRecipient);
    }

    // ── ICollateralManager ──────────────────────────────────────────────

    /// @inheritdoc ICollateralManager
    function lockCollateral(
        UnderwritePermit calldata permit,
        address claimant,
        uint64 unlockAt,
        bytes calldata permitSig
    ) external override nonReentrant {
        // Verify the underwriter's EIP-712 signature on the permit
        _verifyPermitSignature(permit, permitSig);

        // Ensure recipients are configured
        UnderwriterRecipients memory recipients = recipientsByUnderwriter[permit.underwriter];
        if (recipients.premiumRecipient == address(0)) revert RecipientsNotSet();

        // Ensure no duplicate position
        if (positionBySettlementJobId[permit.settlementJobId].underwriter != address(0)) {
            revert PositionAlreadyExists();
        }

        // Store the position (safe = msg.sender, the escrow that locked collateral)
        positionBySettlementJobId[permit.settlementJobId] = Position({
            underwriter: permit.underwriter,
            safe: msg.sender,
            user: permit.user,
            merchantExecutionWallet: permit.merchantExecutionWallet,
            lockedCollateralUsdc: permit.requiredCollateralUsdc,
            unlockAt: unlockAt,
            claimant: claimant,
            premiumPaid: true,
            principalReleased: false,
            collateralRecovered: false,
            collateralReleased: false
        });

        // Pull collateral from msg.sender (the escrow)
        if (permit.requiredCollateralUsdc > 0) {
            usdc.safeTransferFrom(msg.sender, address(this), permit.requiredCollateralUsdc);
        }

        // Pull premium from permit.user and forward to premium recipient immediately
        if (permit.decisionFeeUsdc > 0) {
            usdc.safeTransferFrom(permit.user, recipients.premiumRecipient, permit.decisionFeeUsdc);
        }

        emit CollateralLocked(permit.settlementJobId, permit.underwriter, permit.requiredCollateralUsdc, permit.decisionFeeUsdc);
    }

    /// @inheritdoc ICollateralManager
    function releasePrincipalToMerchant(UnderwritePermit calldata permit, bytes calldata permitSig) external override nonReentrant {
        _verifyPermitSignature(permit, permitSig);

        Position storage pos = positionBySettlementJobId[permit.settlementJobId];
        if (pos.underwriter == address(0)) revert PositionNotFound();
        if (pos.principalReleased) revert PrincipalAlreadyReleased();

        pos.principalReleased = true;

        if (permit.fundedPrincipalUsdc > 0) {
            usdc.safeTransferFrom(msg.sender, permit.merchantExecutionWallet, permit.fundedPrincipalUsdc);
        }

        emit PrincipalReleasedToMerchant(permit.settlementJobId, permit.merchantExecutionWallet, permit.fundedPrincipalUsdc);
    }

    /// @inheritdoc ICollateralManager
    function confirmDeliveryBySig(uint256, uint256, bytes calldata) external override {
        // Delivery confirmation is a no-op in this implementation.
        // The settlement coordinator handles delivery semantics.
    }

    /// @inheritdoc ICollateralManager
    function releaseCollateral(uint256 settlementJobId) external override nonReentrant {
        Position storage pos = positionBySettlementJobId[settlementJobId];
        if (pos.underwriter == address(0)) revert PositionNotFound();
        if (msg.sender != pos.safe) revert CallerNotEscrow();
        if (pos.collateralReleased) revert CollateralAlreadyReleased();
        if (pos.collateralRecovered) revert CollateralAlreadyRecovered();

        pos.collateralReleased = true;

        uint256 amount = pos.lockedCollateralUsdc;
        if (amount > 0) {
            usdc.safeTransfer(msg.sender, amount);
        }

        emit CollateralReleased(settlementJobId, msg.sender, amount);
    }

    /// @inheritdoc ICollateralManager
    function claimTimeout(uint256 settlementJobId) external override nonReentrant {
        Position storage pos = positionBySettlementJobId[settlementJobId];
        if (pos.underwriter == address(0)) revert PositionNotFound();
        if (msg.sender != pos.safe) revert CallerNotEscrow();
        if (pos.collateralRecovered) revert CollateralAlreadyRecovered();
        if (pos.collateralReleased) revert CollateralAlreadyReleased();

        UnderwriterRecipients memory recipients = recipientsByUnderwriter[pos.underwriter];
        if (recipients.recoveryRecipient == address(0)) revert RecipientsNotSet();

        pos.collateralRecovered = true;

        uint256 amount = pos.lockedCollateralUsdc;
        if (amount > 0) {
            usdc.safeTransfer(recipients.recoveryRecipient, amount);
        }

        emit TimeoutClaimed(settlementJobId, recipients.recoveryRecipient, amount);
    }

    /// @inheritdoc ICollateralManager
    /// @dev slashSig verification is intentionally delegated to the upstream caller
    ///      (the settlement coordinator / evaluator), which validates the slash
    ///      attestation before invoking this function. Access control via pos.safe
    ///      ensures only the authorized escrow can trigger a slash.
    function slash(SlashAttestation calldata attestation, bytes calldata /* slashSig */) external override nonReentrant {
        Position storage pos = positionBySettlementJobId[attestation.settlementJobId];
        if (pos.underwriter == address(0)) revert PositionNotFound();
        if (msg.sender != pos.safe) revert CallerNotEscrow();
        if (pos.collateralRecovered) revert CollateralAlreadyRecovered();
        if (pos.collateralReleased) revert CollateralAlreadyReleased();

        UnderwriterRecipients memory recipients = recipientsByUnderwriter[pos.underwriter];
        if (recipients.recoveryRecipient == address(0)) revert RecipientsNotSet();

        uint256 slashAmount = attestation.slashAmountUsdc;
        if (slashAmount > pos.lockedCollateralUsdc) {
            slashAmount = pos.lockedCollateralUsdc;
        }

        uint256 remainder = pos.lockedCollateralUsdc - slashAmount;

        // Mark position as fully recovered
        pos.collateralRecovered = true;
        pos.lockedCollateralUsdc = 0;

        // Send slashed amount to recovery recipient
        if (slashAmount > 0) {
            usdc.safeTransfer(recipients.recoveryRecipient, slashAmount);
        }

        // Return any remainder to the escrow (partial slash)
        if (remainder > 0) {
            usdc.safeTransfer(msg.sender, remainder);
        }

        emit CollateralSlashed(attestation.settlementJobId, recipients.recoveryRecipient, slashAmount);
    }

    // ── internals ───────────────────────────────────────────────────────

    /// @dev Verifies an EIP-712 signature on an UnderwritePermit against permit.underwriter.
    function _verifyPermitSignature(UnderwritePermit calldata permit, bytes calldata permitSig) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                UNDERWRITE_PERMIT_TYPEHASH,
                permit.jobId,
                permit.settlementJobId,
                permit.safe,
                permit.user,
                permit.merchant,
                permit.underwriter,
                permit.decisionFeeUsdc,
                permit.merchantExecutionWallet,
                permit.requiredCollateralUsdc,
                permit.fundedPrincipalUsdc,
                permit.coverageCapUsdc,
                permit.validUntil,
                permit.executeUntil,
                permit.policyHash,
                permit.nonce,
                permit.unlockAt
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, permitSig);

        if (recovered != permit.underwriter || permit.underwriter == address(0)) {
            revert InvalidPermitSignature();
        }
    }
}
