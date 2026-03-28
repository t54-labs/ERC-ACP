// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "../interfaces/IAgenticCommerceKernel.sol";
import "../interfaces/ICollateralManager.sol";
import "../hooks/underwriting/UnderwritingHook.sol";
import "../hooks/underwriting/UnderwritingTypes.sol";
import "./SettlementTypes.sol";
import "./UnderwritingSettlementEscrow.sol";

/**
 * @title UnderwritingSettlementCoordinator
 * @notice Coordinates collateral, principal, expiry, and release settlement for protected underwriting jobs.
 * @dev The underwriting hook remains the workflow authority, while this contract
 *      owns settlement-specific state and deploys per-settlement escrows on demand.
 */
contract UnderwritingSettlementCoordinator is EIP712 {
    error WrongJobStatus();
    error WrongHook();
    error InvalidState();
    error MissingEscrow();
    error PermitMismatch();
    error UnsupportedSettlementToken();
    error TooEarly();
    error TooLate();
    error SlashExpired();
    error InvalidSlashSignature();
    error SlashAttestationMismatch();
    error OnlyClient();

    bytes32 internal constant SLASH_ATTESTATION_TYPEHASH = keccak256(
        "SlashAttestation(uint256 settlementJobId,address safe,address user,address merchant,uint256 slashAmountUsdc,bytes32 reasonCode,uint64 validUntil,uint256 nonce)"
    );

    IAgenticCommerceKernel public immutable acp;
    UnderwritingHook public immutable hook;
    ICollateralManager public immutable collateralManager;

    mapping(uint256 jobId => SettlementTypes.SettlementState) public jobSettlementState;
    mapping(uint256 settlementJobId => address escrow) internal escrowBySettlementJobId;
    mapping(uint256 jobId => uint64 unlockAt) public unlockAtByJobId;

    event FundingOrchestrated(uint256 indexed jobId, address indexed escrow, uint256 indexed settlementJobId);
    event CollateralReleased(uint256 indexed jobId, uint256 indexed settlementJobId);
    event ExpirySettled(uint256 indexed jobId, uint256 indexed settlementJobId, bool timeoutClaimed);
    event RejectedJobFinalized(uint256 indexed jobId, uint256 indexed settlementJobId);
    event CollateralReleaseRequested(uint256 indexed jobId, uint256 indexed settlementJobId);
    event SuccessDisputeOpened(uint256 indexed jobId, uint256 indexed settlementJobId, bytes32 reasonCode);
    event DisputeSlashApplied(uint256 indexed jobId, uint256 indexed settlementJobId, uint256 slashAmountUsdc);

    /// @notice Deploys the settlement coordinator for a specific ACP kernel, hook, and collateral manager.
    /// @param acp_ The ACP kernel used for job state reads.
    /// @param hook_ The underwriting hook that owns workflow legitimacy.
    /// @param collateralManager_ The collateral manager adapter used by settlement escrows.
    constructor(
        IAgenticCommerceKernel acp_,
        UnderwritingHook hook_,
        ICollateralManager collateralManager_
    ) EIP712("Underwriting Settlement Coordinator", "1") {
        acp = acp_;
        hook = hook_;
        collateralManager = collateralManager_;
    }

    /// @notice Returns the settlement escrow address associated with `jobId`.
    /// @param jobId The ACP job identifier to inspect.
    /// @return The deployed settlement escrow address, or zero when none exists.
    function settlementEscrow(uint256 jobId) public view returns (address) {
        return escrowBySettlementJobId[hook.jobSettlementJobId(jobId)];
    }

    /// @notice Orchestrates collateral locking and optional principal release for a funded job.
    /// @param jobId The funded ACP job to protect.
    /// @param permit The underwriting permit that must match the stored commit.
    /// @param permitSig The signature authorizing `permit`.
    function orchestrateFunding(
        uint256 jobId,
        ICollateralManager.UnderwritePermit calldata permit,
        bytes calldata permitSig
    ) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Funded) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != UnderwritingTypes.SidecarState.FeeEscrowed) revert InvalidState();
        if (job.paymentToken != hook.allowedSettlementToken()) revert UnsupportedSettlementToken();

        UnderwritingTypes.UnderwriteCommit memory commit = hook.getCommit(jobId);
        uint256 settlementJobId = hook.jobSettlementJobId(jobId);
        UnderwritingSettlementEscrow escrow =
            _getOrCreateEscrow(
                jobId, settlementJobId, job.paymentToken, job.client, job.provider, permit.merchantExecutionWallet
            );

        _assertPermitMatches(jobId, settlementJobId, job, commit, permit, address(escrow));
        unlockAtByJobId[jobId] = permit.unlockAt;

        if (commit.parentJobId == 0) {
            escrow.pullCollateralFromProvider(permit.requiredCollateralUsdc);
            escrow.lockCollateral(permit, permitSig);
            jobSettlementState[jobId] = SettlementTypes.SettlementState.CollateralLocked;

            if (permit.fundedPrincipalUsdc > 0) {
                escrow.pullPrincipalFromClient(permit.fundedPrincipalUsdc);
                escrow.releasePrincipalToMerchant(permit, permitSig);
                jobSettlementState[jobId] = SettlementTypes.SettlementState.PrincipalReleased;
            }
        }

        hook.markProtected(jobId);
        emit FundingOrchestrated(jobId, address(escrow), settlementJobId);
    }

    /// @notice Signals intent to reclaim provider collateral, opening a window for client disputes.
    /// @param jobId The completed ACP job whose collateral the provider wants released.
    function requestCollateralRelease(uint256 jobId) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != UnderwritingTypes.SidecarState.SuccessPendingConfirmation) {
            revert InvalidState();
        }
        _assertSettlementEntrypointAllowed(jobId);

        SettlementTypes.SettlementState currentState = jobSettlementState[jobId];
        UnderwritingTypes.UnderwriteCommit memory commit = hook.getCommit(jobId);
        bool isCloseJob = commit.parentJobId != 0;

        if (isCloseJob) {
            if (currentState != SettlementTypes.SettlementState.None) revert InvalidState();
        } else {
            if (
                currentState != SettlementTypes.SettlementState.PrincipalReleased
                    && currentState != SettlementTypes.SettlementState.CollateralLocked
            ) {
                revert InvalidState();
            }
        }

        jobSettlementState[jobId] = SettlementTypes.SettlementState.SuccessPendingRelease;

        emit CollateralReleaseRequested(jobId, hook.jobSettlementJobId(jobId));
    }

    /// @notice Opens a post-success dispute, blocking collateral release until the underwriter resolves it.
    /// @param jobId The completed ACP job being disputed.
    /// @param reasonCode The client-supplied reason for the dispute.
    function openSuccessDispute(uint256 jobId, bytes32 reasonCode) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (msg.sender != job.client) revert OnlyClient();
        if (jobSettlementState[jobId] != SettlementTypes.SettlementState.SuccessPendingRelease) revert InvalidState();

        uint64 unlock = unlockAtByJobId[jobId];
        if (unlock == 0 || block.timestamp >= unlock) revert TooLate();

        jobSettlementState[jobId] = SettlementTypes.SettlementState.DisputeOpen;

        emit SuccessDisputeOpened(jobId, hook.jobSettlementJobId(jobId), reasonCode);
    }

    /// @notice Releases provider collateral once the unlock time has passed and no dispute is open.
    /// @param jobId The completed ACP job whose collateral should be released.
    function releaseCollateral(uint256 jobId) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != UnderwritingTypes.SidecarState.SuccessPendingConfirmation) {
            revert InvalidState();
        }
        if (jobSettlementState[jobId] != SettlementTypes.SettlementState.SuccessPendingRelease) revert InvalidState();
        if (unlockAtByJobId[jobId] != 0 && block.timestamp < unlockAtByJobId[jobId]) revert TooEarly();

        UnderwritingSettlementEscrow escrow = _escrow(jobId);
        escrow.releaseCollateralAndForward();
        jobSettlementState[jobId] = SettlementTypes.SettlementState.SuccessSettled;

        emit CollateralReleased(jobId, hook.jobSettlementJobId(jobId));
    }

    /// @notice Settles an expired underwriting job through the correct timeout path.
    /// @param jobId The expired ACP job to settle.
    function settleExpiry(uint256 jobId) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Expired) revert WrongJobStatus();
        if (jobSettlementState[jobId] == SettlementTypes.SettlementState.ExpirySettled) revert InvalidState();

        UnderwritingTypes.UnderwriteCommit memory commit = hook.getCommit(jobId);
        UnderwritingTypes.SidecarState state = hook.jobSidecarState(jobId);

        if (commit.parentJobId != 0 || state == UnderwritingTypes.SidecarState.FeeEscrowed) {
            jobSettlementState[jobId] = SettlementTypes.SettlementState.ExpirySettled;
            emit ExpirySettled(jobId, hook.jobSettlementJobId(jobId), false);
            return;
        }

        if (state != UnderwritingTypes.SidecarState.Protected && state != UnderwritingTypes.SidecarState.EvidenceSubmitted) {
            revert InvalidState();
        }

        UnderwritingSettlementEscrow escrow = _escrow(jobId);
        escrow.claimTimeout();
        jobSettlementState[jobId] = SettlementTypes.SettlementState.ExpirySettled;

        emit ExpirySettled(jobId, hook.jobSettlementJobId(jobId), true);
    }

    /// @notice Finalizes rejected jobs by routing locked collateral to the underwriter's recovery recipient.
    /// @param jobId The rejected ACP job to finalize.
    function finalizeRejectedJob(uint256 jobId) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Rejected) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != UnderwritingTypes.SidecarState.RejectSettled) revert InvalidState();

        address escrowAddress = settlementEscrow(jobId);
        if (escrowAddress != address(0)) {
            UnderwritingSettlementEscrow(escrowAddress).claimTimeout();
        }
        jobSettlementState[jobId] = SettlementTypes.SettlementState.RejectSettled;

        emit RejectedJobFinalized(jobId, hook.jobSettlementJobId(jobId));
    }

    /// @notice Resolves an open post-success dispute by slashing provider collateral to the underwriter's recovery recipient.
    /// @param jobId The disputed ACP job whose collateral should be slashed.
    /// @param attestation The slash attestation describing the collateral seizure.
    /// @param slashSig The underwriter signature authorizing the slash.
    function applySuccessDisputeSlash(
        uint256 jobId,
        ICollateralManager.SlashAttestation calldata attestation,
        bytes calldata slashSig
    ) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (jobSettlementState[jobId] != SettlementTypes.SettlementState.DisputeOpen) revert InvalidState();
        if (block.timestamp > attestation.validUntil) revert SlashExpired();

        UnderwritingTypes.UnderwriteCommit memory commit = hook.getCommit(jobId);
        uint256 settlementJobId_ = hook.jobSettlementJobId(jobId);
        UnderwritingSettlementEscrow escrow = _escrow(jobId);

        if (
            attestation.settlementJobId != settlementJobId_ || attestation.safe != address(escrow)
                || attestation.user != job.client || attestation.merchant != address(escrow)
        ) {
            revert SlashAttestationMismatch();
        }

        _verifySlashSig(commit.underwriter, attestation, slashSig);

        escrow.slashCollateral(attestation, slashSig);
        jobSettlementState[jobId] = SettlementTypes.SettlementState.RecoverySettled;

        emit DisputeSlashApplied(jobId, settlementJobId_, attestation.slashAmountUsdc);
    }

    /// @dev Loads a job from ACP and ensures it is wired to this underwriting hook.
    function _getHookedJob(uint256 jobId) internal view returns (IAgenticCommerceKernel.Job memory job) {
        job = acp.getJob(jobId);
        if (job.hook != address(hook)) revert WrongHook();
    }

    /// @dev Returns the configured settlement escrow for `jobId`.
    function _escrow(uint256 jobId) internal view returns (UnderwritingSettlementEscrow) {
        address escrowAddress = settlementEscrow(jobId);
        if (escrowAddress == address(0)) revert MissingEscrow();
        return UnderwritingSettlementEscrow(escrowAddress);
    }

    /// @dev Returns an existing escrow or deploys and configures a new one for the settlement flow.
    function _getOrCreateEscrow(
        uint256 jobId,
        uint256 settlementJobId,
        address paymentToken,
        address client,
        address provider,
        address merchantExecutionWallet
    ) internal returns (UnderwritingSettlementEscrow escrow) {
        address existing = escrowBySettlementJobId[settlementJobId];
        if (existing != address(0)) {
            return UnderwritingSettlementEscrow(existing);
        }

        escrow = new UnderwritingSettlementEscrow(paymentToken, collateralManager, address(this));
        escrow.configure(jobId, client, provider, settlementJobId, merchantExecutionWallet);
        escrowBySettlementJobId[settlementJobId] = address(escrow);
        jobSettlementState[jobId] = SettlementTypes.SettlementState.EscrowConfigured;
    }

    /// @dev Verifies that a permit matches the recorded job, commit, and escrow configuration.
    function _assertPermitMatches(
        uint256 jobId,
        uint256 settlementJobId,
        IAgenticCommerceKernel.Job memory job,
        UnderwritingTypes.UnderwriteCommit memory commit,
        ICollateralManager.UnderwritePermit calldata permit,
        address escrowAddress
    ) internal pure {
        if (
            permit.jobId != jobId || permit.settlementJobId != settlementJobId || permit.safe != escrowAddress
                || permit.merchant != escrowAddress || permit.user != job.client || permit.underwriter != commit.underwriter
                || permit.validUntil != commit.validUntil || permit.policyHash != commit.policyHash
        ) {
            revert PermitMismatch();
        }
    }

    /// @dev Prevents a close-enabled root job from reopening settlement once a close leg has taken over.
    function _assertSettlementEntrypointAllowed(uint256 jobId) internal view {
        UnderwritingTypes.UnderwriteCommit memory commit = hook.getCommit(jobId);
        if (commit.parentJobId == 0 && commit.allowCloseJob && !hook.isAwaitingClose(jobId)) {
            revert InvalidState();
        }
    }

    /// @dev Verifies an EIP-712 slash attestation signature against the expected underwriter.
    function _verifySlashSig(
        address expectedUnderwriter,
        ICollateralManager.SlashAttestation calldata attestation,
        bytes calldata slashSig
    ) internal view {
        bytes32 structHash = keccak256(
            abi.encode(
                SLASH_ATTESTATION_TYPEHASH,
                attestation.settlementJobId,
                attestation.safe,
                attestation.user,
                attestation.merchant,
                attestation.slashAmountUsdc,
                attestation.reasonCode,
                attestation.validUntil,
                attestation.nonce
            )
        );

        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, slashSig);

        if (recovered != expectedUnderwriter || expectedUnderwriter == address(0)) {
            revert InvalidSlashSignature();
        }
    }
}
