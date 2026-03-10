// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "./IAgenticCommerceKernel.sol";
import "./IBondManager.sol";
import "./MCUTypes.sol";
import "./MCUHookLite.sol";
import "./MCUJobAdapter.sol";

contract MCUCoordinator {
    error WrongJobStatus();
    error WrongHook();
    error InvalidState();
    error MissingAdapter();
    error PermitMismatch();
    error UnlockNotReached();
    error OnlyMerchant();
    error OnlyUnderwriterEvaluator();
    error ConfirmationTimeoutNotReached(uint64 deadline, uint64 currentTimestamp);
    error DisputeHashRequired();
    error DisputeHashMismatch(bytes32 expected, bytes32 actual);
    error MemoMismatch(bytes32 expected, bytes32 actual);
    error UnexpectedSlashAttestationHash(bytes32 provided);
    error SlashAttestationHashRequired();
    error SlashAttestationHashMismatch(bytes32 expected, bytes32 actual);

    IAgenticCommerceKernel public immutable acp;
    MCUHookLite public immutable hook;
    IBondManager public immutable bondManager;

    event FundingOrchestrated(uint256 indexed jobId, address indexed adapter, bytes32 indexed memoId);
    event DeliveryConfirmed(uint256 indexed jobId, bytes32 indexed memoId, uint256 deliveryNonce);
    event BondReleased(uint256 indexed jobId, bytes32 indexed memoId);
    event SuccessDisputeOpened(
        uint256 indexed jobId, bytes32 indexed memoId, address indexed merchant, bytes32 disputeHash
    );
    event SuccessDisputeReleased(
        uint256 indexed jobId, bytes32 indexed memoId, bytes32 indexed disputeHash, bytes32 reason
    );
    event SuccessDisputeSlashed(
        uint256 indexed jobId,
        bytes32 indexed memoId,
        bytes32 indexed disputeHash,
        bytes32 reason,
        bytes32 slashAttestationHash
    );
    event ExpirySettled(uint256 indexed jobId, bytes32 indexed memoId, bool timeoutClaimed);
    event RejectedJobFinalized(uint256 indexed jobId, bytes32 indexed memoId);

    constructor(IAgenticCommerceKernel acp_, MCUHookLite hook_, IBondManager bondManager_) {
        acp = acp_;
        hook = hook_;
        bondManager = bondManager_;
    }

    function orchestrateFunding(
        uint256 jobId,
        IBondManager.UnderwritePermit calldata permit,
        bytes calldata permitSig
    ) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Funded) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != MCUTypes.SidecarState.FeeEscrowed) revert InvalidState();

        MCUTypes.MCUCommit memory commit = hook.getCommit(jobId);
        MCUJobAdapter adapter = _getOrCreateAdapter(jobId, job, commit);
        if (acp.getJobKind(jobId) == IAgenticCommerceKernel.JobKind.Close) {
            hook.markProtected(jobId, address(adapter));
            emit FundingOrchestrated(jobId, address(adapter), hook.jobMemoId(jobId));
            return;
        }

        _assertPermitMatches(jobId, job, commit, permit, address(adapter));

        // These adapter calls are intentionally lightweight in the scaffold. The
        // full token movement and BondManager side effects can be filled in later.
        adapter.pullBondFromProvider(commit.requiredBondUsdc);
        if (commit.releasePrincipal) {
            adapter.pullPrincipalFromClient(commit.fundedPrincipalUsdc);
        }

        adapter.lockBond(permit, permitSig);
        if (commit.releasePrincipal) {
            adapter.releasePrincipal(permit, permitSig);
        }

        hook.markProtected(jobId, address(adapter));
        emit FundingOrchestrated(jobId, address(adapter), commit.memoId);
    }

    function confirmDelivery(uint256 jobId, uint256 deliveryNonce, bytes calldata deliverySig) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != MCUTypes.SidecarState.SuccessPendingConfirmation) revert InvalidState();

        MCUJobAdapter adapter = _adapter(jobId);
        bytes32 memoId = hook.jobMemoId(jobId);

        adapter.confirmDeliveryBySig(deliveryNonce, deliverySig);
        hook.markSuccessPendingBondRelease(jobId);

        emit DeliveryConfirmed(jobId, memoId, deliveryNonce);
    }

    function openSuccessDispute(uint256 jobId, bytes32 disputeHash) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != MCUTypes.SidecarState.SuccessPendingConfirmation) revert InvalidState();
        if (msg.sender != job.provider) revert OnlyMerchant();
        if (disputeHash == bytes32(0)) revert DisputeHashRequired();

        uint64 deadline = hook.jobDeliveryConfirmationDeadline(jobId);
        if (block.timestamp < deadline) revert ConfirmationTimeoutNotReached(deadline, uint64(block.timestamp));

        bytes32 memoId = hook.jobMemoId(jobId);
        hook.markSuccessDisputeOpen(jobId, disputeHash);

        emit SuccessDisputeOpened(jobId, memoId, job.provider, disputeHash);
    }

    function applySuccessDisputeDecision(
        MCUTypes.SuccessDisputeDecision calldata decision,
        IBondManager.SlashAttestation calldata attestation,
        bytes calldata slashSig
    ) external {
        if (msg.sender != hook.underwriterEvaluator()) revert OnlyUnderwriterEvaluator();

        IAgenticCommerceKernel.Job memory job = _getHookedJob(decision.jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (hook.jobSidecarState(decision.jobId) != MCUTypes.SidecarState.SuccessDisputeOpen) revert InvalidState();

        bytes32 memoId = hook.jobMemoId(decision.jobId);
        if (decision.memoId != memoId) revert MemoMismatch(memoId, decision.memoId);

        bytes32 disputeHash = hook.jobLastSuccessDisputeHash(decision.jobId);
        if (decision.disputeHash != disputeHash) revert DisputeHashMismatch(disputeHash, decision.disputeHash);
        MCUTypes.MCUCommit memory commit = hook.getCommit(decision.jobId);

        if (decision.outcome == MCUTypes.SuccessDisputeOutcome.ReleaseBond) {
            if (decision.slashAttestationHash != bytes32(0)) {
                revert UnexpectedSlashAttestationHash(decision.slashAttestationHash);
            }

            hook.markSuccessPendingBondRelease(decision.jobId);
            emit SuccessDisputeReleased(decision.jobId, memoId, decision.disputeHash, decision.reason);
            return;
        }

        if (decision.slashAttestationHash == bytes32(0)) revert SlashAttestationHashRequired();

        bytes32 actualSlashAttestationHash = _hashSlashAttestation(attestation);
        if (actualSlashAttestationHash != decision.slashAttestationHash) {
            revert SlashAttestationHashMismatch(decision.slashAttestationHash, actualSlashAttestationHash);
        }
        if (attestation.memoId != decision.memoId) revert MemoMismatch(decision.memoId, attestation.memoId);
        if (attestation.jobId != _settlementJobId(decision.jobId, commit)) revert PermitMismatch();

        MCUJobAdapter adapter = _adapter(decision.jobId);
        adapter.slashBond(attestation, slashSig);
        hook.markSuccessSlashed(decision.jobId, decision.disputeHash, decision.slashAttestationHash);

        emit SuccessDisputeSlashed(
            decision.jobId, memoId, decision.disputeHash, decision.reason, decision.slashAttestationHash
        );
    }

    function releaseBond(uint256 jobId) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != MCUTypes.SidecarState.SuccessPendingBondRelease) revert InvalidState();

        MCUTypes.MCUCommit memory commit = hook.getCommit(jobId);
        if (block.timestamp < commit.unlockAt) revert UnlockNotReached();

        MCUJobAdapter adapter = _adapter(jobId);
        adapter.releaseBondAndForward();
        hook.markSuccessSettled(jobId);

        emit BondReleased(jobId, hook.jobMemoId(jobId));
    }

    function settleExpiry(uint256 jobId) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Expired) revert WrongJobStatus();

        MCUTypes.MCUCommit memory commit = hook.getCommit(jobId);
        MCUTypes.SidecarState state = hook.jobSidecarState(jobId);

        if (commit.parentJobId != 0) {
            if (
                state != MCUTypes.SidecarState.FeeEscrowed && state != MCUTypes.SidecarState.Protected
                    && state != MCUTypes.SidecarState.EvidenceSubmitted
            ) {
                revert InvalidState();
            }

            hook.markExpirySettled(jobId);
            emit ExpirySettled(jobId, hook.jobMemoId(jobId), false);
            return;
        }

        if (state == MCUTypes.SidecarState.FeeEscrowed) {
            hook.markExpirySettled(jobId);
            emit ExpirySettled(jobId, hook.jobMemoId(jobId), false);
            return;
        }

        if (state != MCUTypes.SidecarState.Protected && state != MCUTypes.SidecarState.EvidenceSubmitted) {
            revert InvalidState();
        }

        MCUJobAdapter adapter = _adapter(jobId);
        hook.markExpiryPendingTimeout(jobId);
        adapter.claimTimeout();
        hook.markExpirySettled(jobId);

        emit ExpirySettled(jobId, hook.jobMemoId(jobId), true);
    }

    function finalizeRejectedJob(uint256 jobId) external {
        IAgenticCommerceKernel.Job memory job = _getHookedJob(jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Rejected) revert WrongJobStatus();
        if (hook.jobSidecarState(jobId) != MCUTypes.SidecarState.RejectPendingSlash) revert InvalidState();

        MCUTypes.MCUCommit memory commit = hook.getCommit(jobId);
        if (commit.parentJobId != 0) {
            hook.markRejectSettled(jobId);
            emit RejectedJobFinalized(jobId, hook.jobMemoId(jobId));
            return;
        }

        MCUJobAdapter adapter = _adapter(jobId);

        // The actual slash call remains external to this skeleton because the
        // claimant restrictions depend on the eventual BondManager implementation.
        adapter.sweepResidualToProvider();
        hook.markRejectSettled(jobId);

        emit RejectedJobFinalized(jobId, hook.jobMemoId(jobId));
    }

    function _getHookedJob(uint256 jobId) internal view returns (IAgenticCommerceKernel.Job memory job) {
        job = acp.getJob(jobId);
        if (job.hook != address(hook)) revert WrongHook();
    }

    function _adapter(uint256 jobId) internal view returns (MCUJobAdapter) {
        address adapterAddress = hook.jobAdapter(jobId);
        if (adapterAddress == address(0)) revert MissingAdapter();
        return MCUJobAdapter(adapterAddress);
    }

    function _getOrCreateAdapter(
        uint256 jobId,
        IAgenticCommerceKernel.Job memory job,
        MCUTypes.MCUCommit memory commit
    ) internal returns (MCUJobAdapter adapter) {
        address adapterAddress = hook.jobAdapter(jobId);
        if (adapterAddress != address(0)) {
            return MCUJobAdapter(adapterAddress);
        }

        if (commit.parentJobId != 0) {
            address parentAdapterAddress = hook.jobAdapter(commit.parentJobId);
            if (parentAdapterAddress == address(0)) revert MissingAdapter();
            return MCUJobAdapter(parentAdapterAddress);
        }

        adapter = new MCUJobAdapter(acp.paymentToken(), bondManager, address(this));
        adapter.configure(jobId, job.client, job.provider, _settlementMemoId(commit), commit.merchantExecutionWallet);
    }

    function _settlementMemoId(MCUTypes.MCUCommit memory commit) internal pure returns (bytes32) {
        if (commit.parentJobId != 0 && commit.parentMemoId != bytes32(0)) {
            return commit.parentMemoId;
        }
        return commit.memoId;
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
        IBondManager.UnderwritePermit calldata permit,
        address adapter
    ) internal pure {
        if (
            permit.jobId != jobId || permit.memoId != commit.memoId || permit.safe != adapter
                || permit.merchant != adapter || permit.user != job.client
                || permit.underwriter != commit.underwriter
                || permit.merchantExecutionWallet != commit.merchantExecutionWallet
                || permit.decisionFeeUsdc != commit.decisionFeeUsdc
                || permit.requiredBondUsdc != commit.requiredBondUsdc
                || permit.fundedPrincipalUsdc != commit.fundedPrincipalUsdc
                || permit.coverageCapUsdc != commit.coverageCapUsdc
                || permit.validUntil != commit.validUntil || permit.executeUntil != commit.executeUntil
                || permit.unlockAt != commit.unlockAt || permit.policyHash != commit.policyHash
                || permit.parentMemoId != commit.parentMemoId
        ) {
            revert PermitMismatch();
        }
    }

    function _hashSlashAttestation(IBondManager.SlashAttestation calldata attestation) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                attestation.memoId,
                attestation.jobId,
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
