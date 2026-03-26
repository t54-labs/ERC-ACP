// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../interfaces/IAgenticCommerceKernel.sol";
import "../interfaces/ICollateralManager.sol";
import "../hooks/underwriting/UnderwritingHook.sol";
import "../hooks/underwriting/UnderwritingTypes.sol";
import "./SettlementTypes.sol";
import "./UnderwritingSettlementEscrow.sol";

/**
 * @title UnderwritingSettlementCoordinator
 * @notice Coordinates collateral, principal, expiry, and dispute settlement for protected underwriting jobs.
 * @dev The underwriting hook remains the workflow authority, while this contract
 *      owns settlement-specific state and deploys per-settlement escrows on demand.
 */
contract UnderwritingSettlementCoordinator {
    error WrongJobStatus();
    error WrongHook();
    error InvalidState();
    error MissingEscrow();
    error PermitMismatch();
    error OnlyClient();
    error OnlyProvider();
    error OnlyEvaluator();
    error DisputeHashRequired();
    error DisputeHashMismatch();
    error SlashAttestationHashMismatch();
    error TooEarly();
    error DisputeWindowExpired();

    IAgenticCommerceKernel public immutable acp;
    UnderwritingHook public immutable hook;
    ICollateralManager public immutable collateralManager;

    mapping(uint256 jobId => SettlementTypes.SettlementState) public jobSettlementState;
    mapping(uint256 jobId => SettlementTypes.SuccessDispute) public successDisputeByJobId;
    mapping(uint256 settlementJobId => address escrow) internal escrowBySettlementJobId;
    mapping(uint256 jobId => uint64 unlockAt) public unlockAtByJobId;
    uint64 public immutable disputeWindowSeconds;
    mapping(uint256 jobId => uint64 releaseRequestedAt) public releaseRequestedAtByJobId;

    event FundingOrchestrated(uint256 indexed jobId, address indexed escrow, uint256 indexed settlementJobId);
    event CollateralReleaseRequested(uint256 indexed jobId, uint256 indexed settlementJobId, address indexed provider);
    event CollateralReleased(uint256 indexed jobId, uint256 indexed settlementJobId);
    event SuccessDisputeOpened(
        uint256 indexed jobId, uint256 indexed settlementJobId, address indexed client, bytes32 disputeHash
    );
    event SuccessDisputeReleased(
        uint256 indexed jobId, uint256 indexed settlementJobId, bytes32 indexed disputeHash, bytes32 reason
    );
    event SuccessDisputeSlashed(
        uint256 indexed jobId,
        uint256 indexed settlementJobId,
        bytes32 indexed disputeHash,
        bytes32 reason,
        bytes32 slashAttestationHash
    );
    event ExpirySettled(uint256 indexed jobId, uint256 indexed settlementJobId, bool timeoutClaimed);
    event RejectedJobFinalized(uint256 indexed jobId, uint256 indexed settlementJobId);

    /// @notice Deploys the settlement coordinator for a specific ACP kernel, hook, and collateral manager.
    /// @param acp_ The ACP kernel used for job state reads.
    /// @param hook_ The underwriting hook that owns workflow legitimacy.
    /// @param collateralManager_ The collateral manager adapter used by settlement escrows.
    /// @param disputeWindowSeconds_ The duration of the client dispute window after release is requested.
    constructor(
        IAgenticCommerceKernel acp_,
        UnderwritingHook hook_,
        ICollateralManager collateralManager_,
        uint64 disputeWindowSeconds_
    ) {
        acp = acp_;
        hook = hook_;
        collateralManager = collateralManager_;
        disputeWindowSeconds = disputeWindowSeconds_;
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

        UnderwritingTypes.UnderwriteCommit memory commit = hook.getCommit(jobId);
        uint256 settlementJobId = hook.jobSettlementJobId(jobId);
        UnderwritingSettlementEscrow escrow =
            _getOrCreateEscrow(jobId, settlementJobId, job.client, job.provider, permit.merchantExecutionWallet);

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

    /// @notice Starts the provider collateral release flow after job completion.
    /// @param jobId The completed ACP job whose collateral should be released.
    function requestCollateralRelease(uint256 jobId) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != UnderwritingTypes.SidecarState.SuccessPendingConfirmation) {
            revert InvalidState();
        }
        if (msg.sender != job.provider) revert OnlyProvider();

        SettlementTypes.SettlementState currentState = jobSettlementState[jobId];
        if (
            currentState == SettlementTypes.SettlementState.DisputeOpen
                || currentState == SettlementTypes.SettlementState.SuccessSettled
                || currentState == SettlementTypes.SettlementState.SuccessSlashed
                || currentState == SettlementTypes.SettlementState.RejectSettled
                || currentState == SettlementTypes.SettlementState.ExpirySettled
        ) {
            revert InvalidState();
        }

        releaseRequestedAtByJobId[jobId] = uint64(block.timestamp);
        jobSettlementState[jobId] = SettlementTypes.SettlementState.SuccessPendingRelease;
        emit CollateralReleaseRequested(jobId, hook.jobSettlementJobId(jobId), job.provider);
    }

    /// @notice Opens a client dispute during the post-success release window.
    /// @param jobId The completed ACP job being disputed.
    /// @param disputeHash The opaque hash representing the client's dispute payload.
    function openSuccessDispute(uint256 jobId, bytes32 disputeHash) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (jobSettlementState[jobId] != SettlementTypes.SettlementState.SuccessPendingRelease) revert InvalidState();
        if (block.timestamp >= uint256(releaseRequestedAtByJobId[jobId]) + uint256(disputeWindowSeconds)) {
            revert DisputeWindowExpired();
        }
        if (msg.sender != job.client) revert OnlyClient();
        if (disputeHash == bytes32(0)) revert DisputeHashRequired();

        successDisputeByJobId[jobId] = SettlementTypes.SuccessDispute({
            disputeHash: disputeHash,
            openedAt: uint64(block.timestamp),
            deadline: uint64(block.timestamp + disputeWindowSeconds)
        });
        jobSettlementState[jobId] = SettlementTypes.SettlementState.DisputeOpen;

        emit SuccessDisputeOpened(jobId, hook.jobSettlementJobId(jobId), job.client, disputeHash);
    }

    /// @notice Applies an underwriter-signed success dispute decision.
    /// @param decision The dispute decision to execute.
    /// @param attestation The slash attestation to forward when slashing collateral.
    /// @param slashSig The signature authorizing `attestation`.
    function applySuccessDisputeDecision(
        SettlementTypes.SuccessDisputeDecision calldata decision,
        ICollateralManager.SlashAttestation calldata attestation,
        bytes calldata slashSig
    ) external {
        if (msg.sender != hook.evaluator()) revert OnlyEvaluator();

        IAgenticCommerceKernel.Job memory job = _getHookedJob(decision.jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (jobSettlementState[decision.jobId] != SettlementTypes.SettlementState.DisputeOpen) revert InvalidState();

        SettlementTypes.SuccessDispute storage dispute = successDisputeByJobId[decision.jobId];
        if (decision.disputeHash != dispute.disputeHash) revert DisputeHashMismatch();

        uint256 settlementJobId = hook.jobSettlementJobId(decision.jobId);
        if (decision.outcome == SettlementTypes.SuccessDisputeOutcome.ReleaseCollateral) {
            jobSettlementState[decision.jobId] = SettlementTypes.SettlementState.ReleaseApproved;
            emit SuccessDisputeReleased(decision.jobId, settlementJobId, decision.disputeHash, decision.reason);
            return;
        }

        if (decision.slashAttestationHash != keccak256(abi.encode(attestation))) {
            revert SlashAttestationHashMismatch();
        }

        UnderwritingSettlementEscrow escrow = _escrow(decision.jobId);
        escrow.slashCollateral(attestation, slashSig);
        jobSettlementState[decision.jobId] = SettlementTypes.SettlementState.SuccessSlashed;

        emit SuccessDisputeSlashed(
            decision.jobId, settlementJobId, decision.disputeHash, decision.reason, decision.slashAttestationHash
        );
    }

    /// @notice Finalizes collateral release once the dispute window has closed or been resolved.
    /// @param jobId The completed ACP job whose collateral should be released.
    function releaseCollateral(uint256 jobId) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();

        SettlementTypes.SettlementState currentState = jobSettlementState[jobId];
        if (
            currentState != SettlementTypes.SettlementState.SuccessPendingRelease
                && currentState != SettlementTypes.SettlementState.ReleaseApproved
        ) {
            revert InvalidState();
        }
        if (currentState == SettlementTypes.SettlementState.SuccessPendingRelease) {
            if (block.timestamp < uint256(releaseRequestedAtByJobId[jobId]) + uint256(disputeWindowSeconds)) {
                revert TooEarly();
            }
        }
        if (unlockAtByJobId[jobId] != 0 && block.timestamp < unlockAtByJobId[jobId]) revert InvalidState();

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

    /// @notice Finalizes rejected jobs and sweeps any residual escrow balance.
    /// @param jobId The rejected ACP job to finalize.
    function finalizeRejectedJob(uint256 jobId) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Rejected) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != UnderwritingTypes.SidecarState.RejectSettled) revert InvalidState();

        address escrowAddress = settlementEscrow(jobId);
        if (escrowAddress != address(0)) {
            UnderwritingSettlementEscrow(escrowAddress).sweepResidualToProvider();
        }
        jobSettlementState[jobId] = SettlementTypes.SettlementState.RejectSettled;

        emit RejectedJobFinalized(jobId, hook.jobSettlementJobId(jobId));
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
        address client,
        address provider,
        address merchantExecutionWallet
    ) internal returns (UnderwritingSettlementEscrow escrow) {
        address existing = escrowBySettlementJobId[settlementJobId];
        if (existing != address(0)) {
            return UnderwritingSettlementEscrow(existing);
        }

        escrow = new UnderwritingSettlementEscrow(acp.paymentToken(), collateralManager, address(this));
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
}
