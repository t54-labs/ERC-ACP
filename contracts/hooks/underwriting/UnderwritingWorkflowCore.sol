// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@acp/AgenticCommerce.sol";
import "./UnderwritingTypes.sol";

/**
 * @title UnderwritingWorkflowCore
 * @notice Internal workflow state machine shared by underwriting hook variants.
 * @dev Stores commit metadata, sidecar lifecycle, and parent/close job linkage while
 *      exposing reusable helpers for each ACP hook callback.
 */
abstract contract UnderwritingWorkflowCore {
    error UnderwriterNotRegistered();
    error ProviderRequired();
    error EvaluatorMismatch();
    error ZeroAddress();
    error CommitExpired();
    error CommitLocked();
    error CommitNotFound();
    error ParentNotCommitted();
    error ParentNotAwaitingClose();
    error ActiveCloseExists();
    error ParentMismatch();
    error EvidenceMismatch();
    error InvalidState();
    error UnsupportedSettlementToken();

    mapping(address => bool) internal registeredUnderwriterByAddress;
    mapping(uint256 => UnderwritingTypes.UnderwriteCommit) internal commits;
    mapping(uint256 => bytes32) internal commitHashByJobId;
    mapping(uint256 => address) internal committedPaymentTokenByJobId;
    mapping(uint256 => uint256) internal committedBudgetByJobId;
    mapping(uint256 => bool) internal awaitingCloseByJobId;
    mapping(uint256 => uint256) internal parentJobIdByCloseJobId;
    mapping(uint256 => uint256) internal activeCloseJobIdByParentJobId;
    mapping(uint256 => UnderwritingTypes.SidecarState) internal sidecarStateByJobId;
    mapping(uint256 => uint64) internal submittedAtByJobId;

    /// @dev Registers an underwriter for future standalone commitments.
    function _registerUnderwriter(address underwriter) internal {
        if (underwriter == address(0)) revert ZeroAddress();
        registeredUnderwriterByAddress[underwriter] = true;
    }

    /// @dev Removes an underwriter from future standalone commitments.
    function _unregisterUnderwriter(address underwriter) internal {
        if (underwriter == address(0)) revert ZeroAddress();
        delete registeredUnderwriterByAddress[underwriter];
    }

    /// @dev Returns whether an address is currently registered as an underwriter.
    function _isRegisteredUnderwriter(address underwriter) internal view returns (bool) {
        return registeredUnderwriterByAddress[underwriter];
    }

    /// @dev Returns the stored underwriting commit for `jobId`.
    function _getCommit(uint256 jobId) internal view returns (UnderwritingTypes.UnderwriteCommit memory) {
        return commits[jobId];
    }

    /// @dev Returns whether `jobId` is waiting for a linked close job.
    function _isAwaitingClose(uint256 jobId) internal view returns (bool) {
        return awaitingCloseByJobId[jobId];
    }

    /// @dev Returns the parent job id for a close job.
    function _getParentJobId(uint256 closeJobId) internal view returns (uint256) {
        return parentJobIdByCloseJobId[closeJobId];
    }

    /// @dev Returns the currently active close job id for a parent job.
    function _getActiveCloseJobId(uint256 parentJobId) internal view returns (uint256) {
        return activeCloseJobIdByParentJobId[parentJobId];
    }

    /// @dev Returns the underwriting sidecar state for `jobId`.
    function _getSidecarState(uint256 jobId) internal view returns (UnderwritingTypes.SidecarState) {
        return sidecarStateByJobId[jobId];
    }

    /// @dev Returns the submission timestamp for `jobId`.
    function _getSubmittedAt(uint256 jobId) internal view returns (uint64) {
        return submittedAtByJobId[jobId];
    }

    /// @dev Returns the canonical settlement job id for `jobId`.
    function _getSettlementJobId(uint256 jobId) internal view returns (uint256) {
        if (commitHashByJobId[jobId] == bytes32(0)) return 0;

        UnderwritingTypes.UnderwriteCommit memory commit = commits[jobId];
        if (commit.parentJobId != 0) {
            return commit.parentJobId;
        }

        return jobId;
    }

    /// @dev Returns the underwriter responsible for `jobId`.
    function _getUnderwriter(uint256 jobId) internal view returns (address) {
        return _requireCommit(jobId).underwriter;
    }

    /// @dev Validates and stores the underwriting commit during `setBudget`.
    function _preSetBudgetWorkflow(
        AgenticCommerce acp,
        address expectedEvaluator,
        address allowedSettlementToken,
        uint256 jobId,
        address paymentToken,
        uint256 amount,
        bytes memory optParams
    ) internal {
        AgenticCommerce.Job memory job = acp.getJob(jobId);
        UnderwritingTypes.UnderwriteCommit memory commit = abi.decode(optParams, (UnderwritingTypes.UnderwriteCommit));
        bytes32 newCommitHash = keccak256(abi.encode(commit));

        if (job.provider == address(0)) revert ProviderRequired();
        if (job.evaluator != expectedEvaluator) revert EvaluatorMismatch();
        if (allowedSettlementToken != address(0) && paymentToken != allowedSettlementToken) revert UnsupportedSettlementToken();

        if (commitHashByJobId[jobId] != bytes32(0)) {
            if (commitHashByJobId[jobId] != newCommitHash) revert CommitLocked();
            if (committedPaymentTokenByJobId[jobId] != paymentToken) revert CommitLocked();
            if (committedBudgetByJobId[jobId] != amount) revert CommitLocked();
            return;
        }

        if (commit.validUntil <= block.timestamp) revert CommitExpired();

        if (commit.parentJobId == 0) {
            if (!registeredUnderwriterByAddress[commit.underwriter]) revert UnderwriterNotRegistered();
        } else {
            _clearStaleCloseIfTerminal(acp, commit.parentJobId);
            _validateCloseCommit(acp, jobId, job, commit);
            parentJobIdByCloseJobId[jobId] = commit.parentJobId;
            activeCloseJobIdByParentJobId[commit.parentJobId] = jobId;
        }

        commitHashByJobId[jobId] = newCommitHash;
        committedPaymentTokenByJobId[jobId] = paymentToken;
        committedBudgetByJobId[jobId] = amount;
        commits[jobId] = commit;
        sidecarStateByJobId[jobId] = UnderwritingTypes.SidecarState.Committed;
    }

    /// @dev Ensures a committed underwriting job is ready for ACP funding.
    function _preFundWorkflow(AgenticCommerce acp, uint256 jobId) internal view {
        UnderwritingTypes.UnderwriteCommit memory commit = _requireCommit(jobId);
        if (sidecarStateByJobId[jobId] != UnderwritingTypes.SidecarState.Committed) revert InvalidState();
        if (commit.parentJobId != 0) _assertParentReadyForClose(acp, commit.parentJobId);
    }

    /// @dev Marks the job as fee-escrowed after ACP funding succeeds.
    function _postFundWorkflow(uint256 jobId) internal {
        if (sidecarStateByJobId[jobId] != UnderwritingTypes.SidecarState.Committed) revert InvalidState();
        sidecarStateByJobId[jobId] = UnderwritingTypes.SidecarState.FeeEscrowed;
    }

    /// @dev Marks the job as protected after settlement-side funding orchestration finishes.
    function _markProtectedWorkflow(uint256 jobId) internal {
        _requireCommit(jobId);
        if (sidecarStateByJobId[jobId] != UnderwritingTypes.SidecarState.FeeEscrowed) revert InvalidState();
        sidecarStateByJobId[jobId] = UnderwritingTypes.SidecarState.Protected;
    }

    /// @dev Ensures a protected underwriting job is ready for submission.
    function _preSubmitWorkflow(AgenticCommerce acp, uint256 jobId) internal view {
        UnderwritingTypes.UnderwriteCommit memory commit = _requireCommit(jobId);
        if (sidecarStateByJobId[jobId] != UnderwritingTypes.SidecarState.Protected) revert InvalidState();
        if (commit.parentJobId != 0) _assertParentReadyForClose(acp, commit.parentJobId);
    }

    /// @dev Validates submission evidence against the stored commit and advances the sidecar state.
    function _postSubmitWorkflow(uint256 jobId, bytes32 deliverable, bytes memory optParams) internal {
        if (sidecarStateByJobId[jobId] != UnderwritingTypes.SidecarState.Protected) revert InvalidState();

        UnderwritingTypes.SubmitEvidence memory evidence = abi.decode(optParams, (UnderwritingTypes.SubmitEvidence));
        UnderwritingTypes.UnderwriteCommit memory commit = _requireCommit(jobId);

        if (deliverable != evidence.bundleHash) revert EvidenceMismatch();
        if (evidence.policyHash != commit.policyHash) revert EvidenceMismatch();
        if (evidence.quoteIdHash != commit.quoteIdHash) revert EvidenceMismatch();
        if (evidence.termsHash != commit.termsHash) revert EvidenceMismatch();

        sidecarStateByJobId[jobId] = UnderwritingTypes.SidecarState.EvidenceSubmitted;
        submittedAtByJobId[jobId] = uint64(block.timestamp);
    }

    /// @dev Ensures signed completion or rejection decisions execute from the correct sidecar state.
    function _preDecisionWorkflow(AgenticCommerce acp, uint256 jobId) internal view {
        UnderwritingTypes.UnderwriteCommit memory commit = _requireCommit(jobId);
        if (sidecarStateByJobId[jobId] != UnderwritingTypes.SidecarState.EvidenceSubmitted) revert InvalidState();
        if (commit.parentJobId != 0) _assertParentReadyForClose(acp, commit.parentJobId);
    }

    /// @dev Allows client-side open-job rejects while routing funded/submitted jobs through decision validation.
    function _preRejectWorkflow(AgenticCommerce acp, uint256 jobId) internal view {
        AgenticCommerce.Job memory job = acp.getJob(jobId);
        if (job.status == AgenticCommerce.JobStatus.Open) return;
        _preDecisionWorkflow(acp, jobId);
    }

    /// @dev Finalizes hook-side success state and clears parent/close linkage where needed.
    function _postCompleteWorkflow(uint256 jobId) internal {
        UnderwritingTypes.UnderwriteCommit memory commit = _requireCommit(jobId);
        if (commit.parentJobId == 0 && commit.allowCloseJob) {
            awaitingCloseByJobId[jobId] = true;
            sidecarStateByJobId[jobId] = UnderwritingTypes.SidecarState.AwaitingClose;
            return;
        }

        sidecarStateByJobId[jobId] = UnderwritingTypes.SidecarState.SuccessPendingConfirmation;

        if (commit.parentJobId != 0) {
            uint256 parentJobId = commit.parentJobId;
            if (activeCloseJobIdByParentJobId[parentJobId] == jobId) {
                delete activeCloseJobIdByParentJobId[parentJobId];
            }
            delete awaitingCloseByJobId[parentJobId];
            sidecarStateByJobId[parentJobId] = UnderwritingTypes.SidecarState.SuccessPendingConfirmation;
        }
    }

    /// @dev Finalizes hook-side reject state and clears active close-job linkage.
    function _postRejectWorkflow(uint256 jobId) internal {
        if (commitHashByJobId[jobId] == bytes32(0)) return;

        UnderwritingTypes.UnderwriteCommit memory commit = commits[jobId];
        sidecarStateByJobId[jobId] = UnderwritingTypes.SidecarState.RejectSettled;

        if (commit.parentJobId != 0 && activeCloseJobIdByParentJobId[commit.parentJobId] == jobId) {
            delete activeCloseJobIdByParentJobId[commit.parentJobId];
        }
    }

    /// @dev Verifies that a close-job commit is consistent with its parent job and commit.
    function _validateCloseCommit(
        AgenticCommerce acp,
        uint256 jobId,
        AgenticCommerce.Job memory job,
        UnderwritingTypes.UnderwriteCommit memory commit
    ) internal view {
        UnderwritingTypes.UnderwriteCommit memory parentCommit = commits[commit.parentJobId];
        AgenticCommerce.Job memory parentJob = acp.getJob(commit.parentJobId);
        uint256 activeCloseJobId = activeCloseJobIdByParentJobId[commit.parentJobId];

        if (commitHashByJobId[commit.parentJobId] == bytes32(0)) revert ParentNotCommitted();
        if (parentJob.id == 0) revert ParentMismatch();
        if (commit.parentJobId == jobId) revert ParentMismatch();
        if (parentCommit.parentJobId != 0 || !parentCommit.allowCloseJob || commit.allowCloseJob) {
            revert ParentMismatch();
        }
        if (
            parentJob.client != job.client || parentJob.provider != job.provider || parentJob.evaluator != job.evaluator
                || parentJob.hook != job.hook
        ) revert ParentMismatch();
        if (parentCommit.underwriter != commit.underwriter) revert ParentMismatch();
        _assertParentReadyForClose(acp, commit.parentJobId);
        if (activeCloseJobId != 0 && activeCloseJobId != jobId) revert ActiveCloseExists();
    }

    /// @dev Ensures a parent job is completed and explicitly awaiting a close leg.
    function _assertParentReadyForClose(AgenticCommerce acp, uint256 parentJobId) internal view {
        AgenticCommerce.Job memory parentJob = acp.getJob(parentJobId);
        if (
            parentJob.status != AgenticCommerce.JobStatus.Completed
                || !awaitingCloseByJobId[parentJobId]
                || sidecarStateByJobId[parentJobId] != UnderwritingTypes.SidecarState.AwaitingClose
        ) {
            revert ParentNotAwaitingClose();
        }
    }

    /// @dev Clears active close linkage once the tracked close job has reached a terminal state.
    function _clearStaleCloseIfTerminal(AgenticCommerce acp, uint256 parentJobId) internal {
        uint256 activeCloseJobId = activeCloseJobIdByParentJobId[parentJobId];
        if (activeCloseJobId == 0) return;

        AgenticCommerce.Job memory activeCloseJob = acp.getJob(activeCloseJobId);
        if (
            activeCloseJob.status == AgenticCommerce.JobStatus.Rejected
                || activeCloseJob.status == AgenticCommerce.JobStatus.Expired
        ) {
            delete activeCloseJobIdByParentJobId[parentJobId];
        }
    }

    /// @dev Returns the stored commit for `jobId` or reverts when none exists.
    function _requireCommit(uint256 jobId) internal view returns (UnderwritingTypes.UnderwriteCommit memory) {
        if (commitHashByJobId[jobId] == bytes32(0)) revert CommitNotFound();
        return commits[jobId];
    }
}
