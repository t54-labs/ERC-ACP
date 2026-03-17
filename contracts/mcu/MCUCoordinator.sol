// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IAgenticCommerceKernel.sol";
import "./ICollateralManager.sol";
import "./MCUTypes.sol";
import "./MCUHookLite.sol";
import "./MCUSettlementEscrow.sol";

contract MCUCoordinator {
    error WrongJobStatus();
    error WrongHook();
    error InvalidState();
    error MissingAdapter();
    error PermitMismatch();
    error UnlockNotReached();
    error OnlyClient();
    error OnlyProvider();
    error OnlyUnderwriterEvaluator();
    error DisputeWindowClosed(uint64 deadline, uint64 currentTimestamp);
    error DisputeWindowOpen(uint64 deadline, uint64 currentTimestamp);
    error DisputeHashRequired();
    error DisputeHashMismatch(bytes32 expected, bytes32 actual);
    error SettlementJobMismatch(uint256 expected, uint256 actual);
    error UnexpectedSlashAttestationHash(bytes32 provided);
    error SlashAttestationHashRequired();
    error SlashAttestationHashMismatch(bytes32 expected, bytes32 actual);

    IAgenticCommerceKernel public immutable acp;
    MCUHookLite public immutable hook;
    ICollateralManager public immutable collateralManager;

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

    constructor(IAgenticCommerceKernel acp_, MCUHookLite hook_, ICollateralManager collateralManager_) {
        acp = acp_;
        hook = hook_;
        collateralManager = collateralManager_;
    }

    function orchestrateFunding(
        uint256 jobId,
        ICollateralManager.UnderwritePermit calldata permit,
        bytes calldata permitSig
    ) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Funded) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != MCUTypes.SidecarState.FeeEscrowed) revert InvalidState();

        MCUTypes.MCUCommit memory commit = hook.getCommit(jobId);
        MCUTypes.FlowKind flowKind = hook.jobFlowKind(jobId);
        MCUSettlementEscrow escrow = _getOrCreateEscrow(jobId, job, commit);
        if (flowKind == MCUTypes.FlowKind.TwoStageClose) {
            hook.markProtected(jobId, address(escrow));
            emit FundingOrchestrated(jobId, address(escrow), hook.jobSettlementJobId(jobId));
            return;
        }

        _assertPermitMatches(jobId, job, commit, permit, address(escrow));

        // These escrow calls are intentionally lightweight in the scaffold. The
        // full token movement and CollateralManager side effects can be filled in later.
        escrow.pullCollateralFromProvider(commit.requiredCollateralUsdc);
        if (commit.releasePrincipal) {
            escrow.pullPrincipalFromClient(commit.fundedPrincipalUsdc);
        }

        escrow.lockCollateral(permit, permitSig);
        if (commit.releasePrincipal) {
            escrow.releasePrincipal(permit, permitSig);
        }

        hook.markProtected(jobId, address(escrow));
        emit FundingOrchestrated(jobId, address(escrow), _settlementJobId(jobId, commit));
    }

    function requestCollateralRelease(uint256 jobId) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != MCUTypes.SidecarState.SuccessPendingConfirmation) revert InvalidState();
        if (msg.sender != job.provider) revert OnlyProvider();

        uint256 settlementJobId = hook.jobSettlementJobId(jobId);
        hook.markSuccessPendingCollateralRelease(jobId);

        emit CollateralReleaseRequested(jobId, settlementJobId, job.provider);
    }

    function openSuccessDispute(uint256 jobId, bytes32 disputeHash) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != MCUTypes.SidecarState.SuccessPendingCollateralRelease) revert InvalidState();
        if (msg.sender != job.client) revert OnlyClient();
        if (disputeHash == bytes32(0)) revert DisputeHashRequired();

        uint64 deadline = hook.jobDeliveryConfirmationDeadline(jobId);
        if (deadline == 0 || block.timestamp > deadline) revert DisputeWindowClosed(deadline, uint64(block.timestamp));

        uint256 settlementJobId = hook.jobSettlementJobId(jobId);
        hook.markSuccessDisputeOpen(jobId, disputeHash);

        emit SuccessDisputeOpened(jobId, settlementJobId, job.client, disputeHash);
    }

    function applySuccessDisputeDecision(
        MCUTypes.SuccessDisputeDecision calldata decision,
        ICollateralManager.SlashAttestation calldata attestation,
        bytes calldata slashSig
    ) external {
        if (msg.sender != hook.underwriterEvaluator()) revert OnlyUnderwriterEvaluator();

        IAgenticCommerceKernel.Job memory job = _getHookedJob(decision.jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (hook.jobSidecarState(decision.jobId) != MCUTypes.SidecarState.SuccessDisputeOpen) revert InvalidState();

        uint256 settlementJobId = hook.jobSettlementJobId(decision.jobId);

        bytes32 disputeHash = hook.jobLastSuccessDisputeHash(decision.jobId);
        if (decision.disputeHash != disputeHash) revert DisputeHashMismatch(disputeHash, decision.disputeHash);

        if (decision.outcome == MCUTypes.SuccessDisputeOutcome.ReleaseCollateral) {
            if (decision.slashAttestationHash != bytes32(0)) {
                revert UnexpectedSlashAttestationHash(decision.slashAttestationHash);
            }

            hook.markSuccessPendingCollateralRelease(decision.jobId);
            emit SuccessDisputeReleased(decision.jobId, settlementJobId, decision.disputeHash, decision.reason);
            return;
        }

        if (decision.slashAttestationHash == bytes32(0)) revert SlashAttestationHashRequired();

        bytes32 actualSlashAttestationHash = _hashSlashAttestation(attestation);
        if (actualSlashAttestationHash != decision.slashAttestationHash) {
            revert SlashAttestationHashMismatch(decision.slashAttestationHash, actualSlashAttestationHash);
        }
        if (attestation.settlementJobId != settlementJobId) {
            revert SettlementJobMismatch(settlementJobId, attestation.settlementJobId);
        }

        MCUSettlementEscrow escrow = _escrow(decision.jobId);
        escrow.slashCollateral(attestation, slashSig);
        hook.markSuccessSlashed(decision.jobId, decision.disputeHash, decision.slashAttestationHash);

        emit SuccessDisputeSlashed(
            decision.jobId, settlementJobId, decision.disputeHash, decision.reason, decision.slashAttestationHash
        );
    }

    function releaseCollateral(uint256 jobId) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != MCUTypes.SidecarState.SuccessPendingCollateralRelease) revert InvalidState();

        MCUTypes.MCUCommit memory commit = hook.getCommit(jobId);
        if (block.timestamp < commit.unlockAt) revert UnlockNotReached();
        uint64 deadline = hook.jobDeliveryConfirmationDeadline(jobId);
        if (deadline == 0 || block.timestamp <= deadline) {
            revert DisputeWindowOpen(deadline, uint64(block.timestamp));
        }

        MCUSettlementEscrow escrow = _escrow(jobId);
        escrow.releaseCollateralAndForward();
        hook.markSuccessSettled(jobId);

        emit CollateralReleased(jobId, hook.jobSettlementJobId(jobId));
    }

    function settleExpiry(uint256 jobId) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Expired) revert WrongJobStatus();

        MCUTypes.FlowKind flowKind = hook.jobFlowKind(jobId);
        MCUTypes.SidecarState state = hook.jobSidecarState(jobId);

        if (flowKind == MCUTypes.FlowKind.TwoStageClose) {
            if (
                state != MCUTypes.SidecarState.FeeEscrowed && state != MCUTypes.SidecarState.Protected
                    && state != MCUTypes.SidecarState.EvidenceSubmitted
            ) {
                revert InvalidState();
            }

            hook.markExpirySettled(jobId);
            emit ExpirySettled(jobId, hook.jobSettlementJobId(jobId), false);
            return;
        }

        if (state == MCUTypes.SidecarState.FeeEscrowed) {
            hook.markExpirySettled(jobId);
            emit ExpirySettled(jobId, hook.jobSettlementJobId(jobId), false);
            return;
        }

        if (state != MCUTypes.SidecarState.Protected && state != MCUTypes.SidecarState.EvidenceSubmitted) {
            revert InvalidState();
        }

        MCUSettlementEscrow escrow = _escrow(jobId);
        hook.markExpiryPendingTimeout(jobId);
        escrow.claimTimeout();
        hook.markExpirySettled(jobId);

        emit ExpirySettled(jobId, hook.jobSettlementJobId(jobId), true);
    }

    function finalizeRejectedJob(uint256 jobId) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Rejected) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != MCUTypes.SidecarState.RejectPendingSlash) revert InvalidState();

        if (hook.jobFlowKind(jobId) == MCUTypes.FlowKind.TwoStageClose) {
            hook.markRejectSettled(jobId);
            emit RejectedJobFinalized(jobId, hook.jobSettlementJobId(jobId));
            return;
        }

        MCUSettlementEscrow escrow = _escrow(jobId);

        // The actual slash call remains external to this skeleton because the
        // claimant restrictions depend on the eventual CollateralManager implementation.
        escrow.sweepResidualToProvider();
        hook.markRejectSettled(jobId);

        emit RejectedJobFinalized(jobId, hook.jobSettlementJobId(jobId));
    }

    function _getHookedJob(uint256 jobId) internal view returns (IAgenticCommerceKernel.Job memory job) {
        job = acp.getJob(jobId);
        if (job.hook != address(hook)) revert WrongHook();
    }

    function _escrow(uint256 jobId) internal view returns (MCUSettlementEscrow) {
        address adapterAddress = hook.jobAdapter(jobId);
        if (adapterAddress == address(0)) revert MissingAdapter();
        return MCUSettlementEscrow(adapterAddress);
    }

    function _getOrCreateEscrow(
        uint256 jobId,
        IAgenticCommerceKernel.Job memory job,
        MCUTypes.MCUCommit memory commit
    ) internal returns (MCUSettlementEscrow escrow) {
        address adapterAddress = hook.jobAdapter(jobId);
        if (adapterAddress != address(0)) {
            return MCUSettlementEscrow(adapterAddress);
        }

        if (commit.parentJobId != 0) {
            address parentAdapterAddress = hook.jobAdapter(commit.parentJobId);
            if (parentAdapterAddress == address(0)) revert MissingAdapter();
            return MCUSettlementEscrow(parentAdapterAddress);
        }

        escrow = new MCUSettlementEscrow(acp.paymentToken(), collateralManager, address(this));
        escrow.configure(jobId, job.client, job.provider, _settlementJobId(jobId, commit), commit.merchantExecutionWallet);
    }

    function _settlementJobId(uint256 jobId, MCUTypes.MCUCommit memory commit) internal pure returns (uint256) {
        if (commit.parentJobId != 0) {
            return commit.parentJobId;
        }
        return jobId;
    }

    function _assertPermitMatches(
        uint256 jobId,
        IAgenticCommerceKernel.Job memory job,
        MCUTypes.MCUCommit memory commit,
        ICollateralManager.UnderwritePermit calldata permit,
        address adapter
    ) internal pure {
        if (
            permit.jobId != jobId || permit.settlementJobId != _settlementJobId(jobId, commit) || permit.safe != adapter
                || permit.merchant != adapter || permit.user != job.client
                || permit.underwriter != commit.underwriter
                || permit.merchantExecutionWallet != commit.merchantExecutionWallet
                || permit.decisionFeeUsdc != commit.decisionFeeUsdc
                || permit.requiredCollateralUsdc != commit.requiredCollateralUsdc
                || permit.fundedPrincipalUsdc != commit.fundedPrincipalUsdc
                || permit.coverageCapUsdc != commit.coverageCapUsdc
                || permit.validUntil != commit.validUntil || permit.executeUntil != commit.executeUntil
                || permit.unlockAt != commit.unlockAt || permit.policyHash != commit.policyHash
        ) {
            revert PermitMismatch();
        }
    }

    function _hashSlashAttestation(ICollateralManager.SlashAttestation calldata attestation) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
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
    }
}
