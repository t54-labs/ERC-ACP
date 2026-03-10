// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../IACPHook.sol";
import "./IAgenticCommerceKernel.sol";
import "./MCUTypes.sol";

contract MCUHookLite is IACPHook {
    error OnlyACP();
    error OnlyAdmin();
    error OnlyCoordinator();
    error WiringAlreadySet();
    error WiringIncomplete();
    error UnsupportedSelector();
    error ProfileAlreadyCommitted();
    error ProfileNotCommitted();
    error ProviderMustBeSet();
    error EvaluatorMismatch();
    error InvalidProfile();
    error InvalidState();
    error EvidenceMismatch();
    error AdapterMismatch();
    error DuplicateMemoId();
    error InvalidParentJob();
    error ParentProfileNotCommitted();
    error ParentHookMismatch();
    error ParentMemoMismatch();
    error ParentAlreadyHasCloseJob();
    error NestedCloseUnsupported();

    struct Profile {
        bool initialized;
        address adapter;
        MCUTypes.SidecarState sidecarState;
        bytes32 configHash;
        uint64 completionObservedAt;
        bytes32 lastBundleHash;
        bytes32 lastReason;
        bytes32 lastSuccessDisputeHash;
        bytes32 lastSlashAttestationHash;
        MCUTypes.MCUCommit commit;
    }

    bytes4 private constant SEL_SET_PROVIDER = bytes4(keccak256("setProvider(uint256,address,bytes)"));
    bytes4 private constant SEL_SET_BUDGET = bytes4(keccak256("setBudget(uint256,uint256,bytes)"));
    bytes4 private constant SEL_FUND = bytes4(keccak256("fund(uint256,uint256,bytes)"));
    bytes4 private constant SEL_SUBMIT = bytes4(keccak256("submit(uint256,bytes32,bytes)"));
    bytes4 private constant SEL_COMPLETE = bytes4(keccak256("complete(uint256,bytes32,bytes)"));
    bytes4 private constant SEL_REJECT = bytes4(keccak256("reject(uint256,bytes32,bytes)"));

    IAgenticCommerceKernel public immutable acp;
    address public immutable admin;

    address public coordinator;
    address public underwriterEvaluator;

    mapping(uint256 jobId => Profile) internal profiles;
    mapping(bytes32 memoId => uint256 jobId) internal jobIdByMemoId;

    event WiringSet(address indexed coordinator, address indexed underwriterEvaluator);
    event ProfileCommitted(
        uint256 indexed jobId,
        bytes32 indexed memoId,
        address indexed underwriter,
        bytes32 configHash
    );
    event EvidenceRecorded(uint256 indexed jobId, bytes32 indexed memoId, bytes32 indexed bundleHash);
    event CompletionObserved(uint256 indexed jobId, bytes32 indexed memoId, bytes32 indexed reason);
    event RejectionObserved(
        uint256 indexed jobId,
        bytes32 indexed memoId,
        bytes32 indexed reason,
        bytes32 slashAttestationHash
    );
    event SidecarStateUpdated(
        uint256 indexed jobId,
        MCUTypes.SidecarState previousState,
        MCUTypes.SidecarState nextState
    );
    event ParentJobLinked(uint256 indexed closeJobId, uint256 indexed parentJobId, bytes32 indexed parentMemoId);

    modifier onlyACP() {
        if (msg.sender != address(acp)) revert OnlyACP();
        _;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert OnlyAdmin();
        _;
    }

    modifier onlyCoordinator() {
        if (msg.sender != coordinator) revert OnlyCoordinator();
        _;
    }

    constructor(IAgenticCommerceKernel acp_, address admin_) {
        if (address(acp_) == address(0) || admin_ == address(0)) revert InvalidProfile();
        acp = acp_;
        admin = admin_;
    }

    function setWiring(address coordinator_, address underwriterEvaluator_) external onlyAdmin {
        if (coordinator != address(0) || underwriterEvaluator != address(0)) revert WiringAlreadySet();
        if (coordinator_ == address(0) || underwriterEvaluator_ == address(0)) revert InvalidProfile();

        coordinator = coordinator_;
        underwriterEvaluator = underwriterEvaluator_;

        emit WiringSet(coordinator_, underwriterEvaluator_);
    }

    function beforeAction(uint256 jobId, bytes4 selector, bytes calldata data) external override onlyACP {
        if (selector == SEL_SET_PROVIDER) {
            return;
        }
        if (selector == SEL_SET_BUDGET) {
            _beforeSetBudget(jobId, data);
            return;
        }
        if (selector == SEL_FUND) {
            _beforeFund(jobId);
            return;
        }
        if (selector == SEL_SUBMIT) {
            _beforeSubmit(jobId);
            return;
        }
        if (selector == SEL_COMPLETE) {
            _beforeComplete(jobId);
            return;
        }
        if (selector == SEL_REJECT) {
            return;
        }

        revert UnsupportedSelector();
    }

    function afterAction(uint256 jobId, bytes4 selector, bytes calldata data) external override onlyACP {
        if (selector == SEL_SET_PROVIDER || selector == SEL_SET_BUDGET) {
            return;
        }
        if (selector == SEL_FUND) {
            _afterFund(jobId);
            return;
        }
        if (selector == SEL_SUBMIT) {
            _afterSubmit(jobId, data);
            return;
        }
        if (selector == SEL_COMPLETE) {
            _afterComplete(jobId, data);
            return;
        }
        if (selector == SEL_REJECT) {
            _afterReject(jobId, data);
            return;
        }

        revert UnsupportedSelector();
    }

    function jobUnderwriter(uint256 jobId) external view returns (address) {
        return profiles[jobId].commit.underwriter;
    }

    function jobMemoId(uint256 jobId) external view returns (bytes32) {
        return _settlementMemoId(profiles[jobId].commit);
    }

    function jobAdapter(uint256 jobId) external view returns (address) {
        return profiles[jobId].adapter;
    }

    function jobSidecarState(uint256 jobId) external view returns (MCUTypes.SidecarState) {
        return profiles[jobId].sidecarState;
    }

    function getCommit(uint256 jobId) external view returns (MCUTypes.MCUCommit memory) {
        return profiles[jobId].commit;
    }

    function jobCompletionObservedAt(uint256 jobId) external view returns (uint64) {
        return profiles[jobId].completionObservedAt;
    }

    function jobDeliveryConfirmationDeadline(uint256 jobId) external view returns (uint64) {
        Profile storage profile = _profile(jobId);
        return profile.completionObservedAt + profile.commit.deliveryConfirmationTimeoutWindow;
    }

    function jobLastSuccessDisputeHash(uint256 jobId) external view returns (bytes32) {
        return profiles[jobId].lastSuccessDisputeHash;
    }

    function getJobIdByMemoId(bytes32 memoId) external view returns (uint256) {
        return jobIdByMemoId[memoId];
    }

    function getParentJobId(uint256 jobId) external view returns (uint256) {
        try acp.getParentJobId(jobId) returns (uint256 parentJobId) {
            return parentJobId;
        } catch {
            return 0;
        }
    }

    function getCloseJobId(uint256 jobId) external view returns (uint256) {
        try acp.getCloseJobId(jobId) returns (uint256 closeJobId) {
            return closeJobId;
        } catch {
            return 0;
        }
    }

    function markProtected(uint256 jobId, address adapter) external onlyCoordinator {
        Profile storage profile = _profile(jobId);
        if (profile.sidecarState != MCUTypes.SidecarState.FeeEscrowed) revert InvalidState();
        if (adapter == address(0)) revert InvalidProfile();
        if (profile.adapter != address(0) && profile.adapter != adapter) revert AdapterMismatch();

        profile.adapter = adapter;
        _setState(profile, jobId, MCUTypes.SidecarState.Protected);
    }

    function markSuccessPendingBondRelease(uint256 jobId) external onlyCoordinator {
        Profile storage profile = _profile(jobId);
        if (
            profile.sidecarState != MCUTypes.SidecarState.SuccessPendingConfirmation
                && profile.sidecarState != MCUTypes.SidecarState.SuccessDisputeOpen
        ) {
            revert InvalidState();
        }
        _setState(profile, jobId, MCUTypes.SidecarState.SuccessPendingBondRelease);
    }

    function markSuccessDisputeOpen(uint256 jobId, bytes32 disputeHash) external onlyCoordinator {
        Profile storage profile = _profile(jobId);
        if (profile.sidecarState != MCUTypes.SidecarState.SuccessPendingConfirmation) revert InvalidState();
        if (disputeHash == bytes32(0)) revert InvalidProfile();

        profile.lastSuccessDisputeHash = disputeHash;
        _setState(profile, jobId, MCUTypes.SidecarState.SuccessDisputeOpen);
    }

    function markSuccessSlashed(uint256 jobId, bytes32 disputeHash, bytes32 slashAttestationHash) external onlyCoordinator {
        Profile storage profile = _profile(jobId);
        if (profile.sidecarState != MCUTypes.SidecarState.SuccessDisputeOpen) revert InvalidState();
        if (disputeHash == bytes32(0) || disputeHash != profile.lastSuccessDisputeHash) revert EvidenceMismatch();
        if (slashAttestationHash == bytes32(0)) revert InvalidProfile();

        profile.lastSlashAttestationHash = slashAttestationHash;
        _setState(profile, jobId, MCUTypes.SidecarState.SuccessSlashed);
    }

    function markSuccessSettled(uint256 jobId) external onlyCoordinator {
        Profile storage profile = _profile(jobId);
        if (profile.sidecarState != MCUTypes.SidecarState.SuccessPendingBondRelease) revert InvalidState();
        _setState(profile, jobId, MCUTypes.SidecarState.SuccessSettled);
    }

    function markRejectSettled(uint256 jobId) external onlyCoordinator {
        Profile storage profile = _profile(jobId);
        if (profile.sidecarState != MCUTypes.SidecarState.RejectPendingSlash) revert InvalidState();
        _setState(profile, jobId, MCUTypes.SidecarState.RejectSettled);
    }

    function markExpiryPendingTimeout(uint256 jobId) external onlyCoordinator {
        Profile storage profile = _profile(jobId);
        if (
            profile.sidecarState != MCUTypes.SidecarState.Protected
                && profile.sidecarState != MCUTypes.SidecarState.EvidenceSubmitted
        ) {
            revert InvalidState();
        }
        _setState(profile, jobId, MCUTypes.SidecarState.ExpiryPendingTimeout);
    }

    function markExpirySettled(uint256 jobId) external onlyCoordinator {
        Profile storage profile = _profile(jobId);
        if (profile.commit.parentJobId != 0) {
            if (
                profile.sidecarState != MCUTypes.SidecarState.FeeEscrowed
                    && profile.sidecarState != MCUTypes.SidecarState.Protected
                    && profile.sidecarState != MCUTypes.SidecarState.EvidenceSubmitted
            ) {
                revert InvalidState();
            }
            _setState(profile, jobId, MCUTypes.SidecarState.ExpirySettled);
            return;
        }
        if (
            profile.sidecarState != MCUTypes.SidecarState.FeeEscrowed
                && profile.sidecarState != MCUTypes.SidecarState.ExpiryPendingTimeout
        ) {
            revert InvalidState();
        }
        _setState(profile, jobId, MCUTypes.SidecarState.ExpirySettled);
    }

    function _beforeSetBudget(uint256 jobId, bytes calldata data) internal {
        if (coordinator == address(0) || underwriterEvaluator == address(0)) revert WiringIncomplete();
        if (profiles[jobId].initialized) revert ProfileAlreadyCommitted();

        (, bytes memory optParams) = abi.decode(data, (uint256, bytes));
        MCUTypes.MCUCommit memory commit = abi.decode(optParams, (MCUTypes.MCUCommit));
        IAgenticCommerceKernel.Job memory job = acp.getJob(jobId);

        if (job.provider == address(0)) revert ProviderMustBeSet();
        if (job.evaluator != underwriterEvaluator) revert EvaluatorMismatch();
        _validateCommit(commit);
        if (jobIdByMemoId[commit.memoId] != 0) revert DuplicateMemoId();

        if (commit.parentJobId != 0) {
            commit = _resolveParentCommit(jobId, job, commit);
        }

        profiles[jobId] = Profile({
            initialized: true,
            adapter: address(0),
            sidecarState: MCUTypes.SidecarState.Committed,
            configHash: _hashCommit(commit),
            completionObservedAt: 0,
            lastBundleHash: bytes32(0),
            lastReason: bytes32(0),
            lastSuccessDisputeHash: bytes32(0),
            lastSlashAttestationHash: bytes32(0),
            commit: commit
        });

        jobIdByMemoId[commit.memoId] = jobId;
        if (commit.parentJobId != 0) {
            emit ParentJobLinked(jobId, commit.parentJobId, commit.parentMemoId);
        }

        emit ProfileCommitted(jobId, commit.memoId, commit.underwriter, profiles[jobId].configHash);
    }

    function _beforeFund(uint256 jobId) internal view {
        Profile storage profile = _profile(jobId);
        if (profile.sidecarState != MCUTypes.SidecarState.Committed) revert InvalidState();
        if (profile.commit.parentJobId != 0) {
            _assertParentReadyForClose(profile.commit.parentJobId);
        }
    }

    function _afterFund(uint256 jobId) internal {
        Profile storage profile = _profile(jobId);
        if (profile.sidecarState != MCUTypes.SidecarState.Committed) revert InvalidState();
        _setState(profile, jobId, MCUTypes.SidecarState.FeeEscrowed);
    }

    function _beforeSubmit(uint256 jobId) internal view {
        Profile storage profile = _profile(jobId);
        if (profile.sidecarState != MCUTypes.SidecarState.Protected) revert InvalidState();
        if (profile.commit.parentJobId != 0) {
            _assertParentReadyForClose(profile.commit.parentJobId);
        }
    }

    function _beforeComplete(uint256 jobId) internal view {
        Profile storage profile = _profile(jobId);
        if (acp.getJobKind(jobId) == IAgenticCommerceKernel.JobKind.Open) {
            if (profile.sidecarState != MCUTypes.SidecarState.Protected) revert InvalidState();
            return;
        }
        if (profile.sidecarState != MCUTypes.SidecarState.EvidenceSubmitted) revert InvalidState();
    }

    function _afterSubmit(uint256 jobId, bytes calldata data) internal {
        Profile storage profile = _profile(jobId);
        (bytes32 deliverable, bytes memory optParams) = abi.decode(data, (bytes32, bytes));
        MCUTypes.SubmitEvidence memory evidence = abi.decode(optParams, (MCUTypes.SubmitEvidence));

        if (deliverable != evidence.bundleHash) revert EvidenceMismatch();
        if (
            evidence.policyHash != profile.commit.policyHash || evidence.quoteIdHash != profile.commit.quoteIdHash
        ) {
            revert EvidenceMismatch();
        }

        profile.lastBundleHash = evidence.bundleHash;
        _setState(profile, jobId, MCUTypes.SidecarState.EvidenceSubmitted);

        emit EvidenceRecorded(jobId, profile.commit.memoId, evidence.bundleHash);
    }

    function _afterComplete(uint256 jobId, bytes calldata data) internal {
        Profile storage profile = profiles[jobId];
        if (!profile.initialized) return;

        (bytes32 reason,) = abi.decode(data, (bytes32, bytes));
        profile.lastReason = reason;
        profile.lastSuccessDisputeHash = bytes32(0);

        if (acp.getJobKind(jobId) == IAgenticCommerceKernel.JobKind.Open) {
            profile.completionObservedAt = 0;
            _setState(profile, jobId, MCUTypes.SidecarState.AwaitingClose);
        } else {
            profile.completionObservedAt = uint64(block.timestamp);
            _setState(profile, jobId, MCUTypes.SidecarState.SuccessPendingConfirmation);
        }

        emit CompletionObserved(jobId, profile.commit.memoId, reason);
    }

    function _afterReject(uint256 jobId, bytes calldata data) internal {
        Profile storage profile = profiles[jobId];
        if (!profile.initialized) return;

        (bytes32 reason, bytes memory optParams) = abi.decode(data, (bytes32, bytes));
        profile.lastReason = reason;

        bytes32 slashAttestationHash;
        if (optParams.length > 0) {
            MCUTypes.RejectContext memory context = abi.decode(optParams, (MCUTypes.RejectContext));
            if (context.memoId != _settlementMemoId(profile.commit)) revert EvidenceMismatch();
            slashAttestationHash = context.slashAttestationHash;
            profile.lastSlashAttestationHash = context.slashAttestationHash;
        }

        if (
            profile.sidecarState == MCUTypes.SidecarState.Protected
                || profile.sidecarState == MCUTypes.SidecarState.EvidenceSubmitted
        ) {
            _setState(profile, jobId, MCUTypes.SidecarState.RejectPendingSlash);
        } else {
            _setState(profile, jobId, MCUTypes.SidecarState.RejectSettled);
        }

        emit RejectionObserved(jobId, _settlementMemoId(profile.commit), reason, slashAttestationHash);
    }

    function _profile(uint256 jobId) internal view returns (Profile storage profile) {
        profile = profiles[jobId];
        if (!profile.initialized) revert ProfileNotCommitted();
    }

    function _setState(Profile storage profile, uint256 jobId, MCUTypes.SidecarState nextState) internal {
        MCUTypes.SidecarState previousState = profile.sidecarState;
        profile.sidecarState = nextState;
        emit SidecarStateUpdated(jobId, previousState, nextState);
    }

    function _assertParentReadyForClose(uint256 parentJobId) internal view {
        IAgenticCommerceKernel.Job memory parentJob = acp.getJob(parentJobId);
        Profile storage parentProfile = _profile(parentJobId);

        if (
            parentJob.status != IAgenticCommerceKernel.JobStatus.Completed
                || parentProfile.sidecarState != MCUTypes.SidecarState.AwaitingClose
        ) {
            revert InvalidState();
        }
    }

    function _resolveParentCommit(
        uint256 jobId,
        IAgenticCommerceKernel.Job memory job,
        MCUTypes.MCUCommit memory commit
    ) internal view returns (MCUTypes.MCUCommit memory) {
        if (commit.parentJobId == jobId) revert InvalidParentJob();
        if (acp.getJobKind(jobId) != IAgenticCommerceKernel.JobKind.Close) revert InvalidParentJob();
        if (acp.getParentJobId(jobId) != commit.parentJobId) revert InvalidParentJob();

        IAgenticCommerceKernel.Job memory parentJob = acp.getJob(commit.parentJobId);
        if (parentJob.id == 0) revert InvalidParentJob();
        if (acp.getJobKind(commit.parentJobId) != IAgenticCommerceKernel.JobKind.Open) revert InvalidParentJob();
        uint256 linkedCloseJobId = acp.getCloseJobId(commit.parentJobId);
        if (linkedCloseJobId == 0) revert InvalidParentJob();
        if (linkedCloseJobId != jobId) revert ParentAlreadyHasCloseJob();
        if (parentJob.hook != address(this)) revert ParentHookMismatch();

        Profile storage parentProfile = profiles[commit.parentJobId];
        if (!parentProfile.initialized) revert ParentProfileNotCommitted();
        if (parentProfile.commit.parentJobId != 0) revert NestedCloseUnsupported();
        if (job.hook != address(this)) revert InvalidParentJob();
        if (
            parentJob.client != job.client || parentJob.provider != job.provider
                || parentJob.evaluator != job.evaluator
        ) {
            revert InvalidParentJob();
        }
        if (parentProfile.commit.underwriter != commit.underwriter) revert InvalidParentJob();

        if (commit.parentMemoId == bytes32(0)) {
            commit.parentMemoId = parentProfile.commit.memoId;
        } else if (commit.parentMemoId != parentProfile.commit.memoId) {
            revert ParentMemoMismatch();
        }
        commit.unlockAt = parentProfile.commit.unlockAt;

        _assertParentReadyForClose(commit.parentJobId);

        return commit;
    }

    function _validateCommit(MCUTypes.MCUCommit memory commit) internal view {
        if (
            commit.memoId == bytes32(0) || commit.underwriter == address(0)
                || commit.merchantExecutionWallet == address(0)
        ) {
            revert InvalidProfile();
        }
        if (commit.parentJobId == 0 && commit.parentMemoId != bytes32(0)) revert InvalidProfile();
        if (commit.decisionFeeUsdc == 0 || commit.requiredBondUsdc == 0) revert InvalidProfile();
        if (commit.coverageCapUsdc > commit.requiredBondUsdc) revert InvalidProfile();
        if (commit.fundedPrincipalUsdc > commit.coverageCapUsdc) revert InvalidProfile();
        if (commit.deliveryConfirmationTimeoutWindow == 0) revert InvalidProfile();
        if (
            commit.validUntil <= block.timestamp || commit.executeUntil <= block.timestamp
                || commit.unlockAt <= block.timestamp
        ) {
            revert InvalidProfile();
        }
    }

    function _hashCommit(MCUTypes.MCUCommit memory commit) internal pure returns (bytes32) {
        return keccak256(
            abi.encode(
                commit.memoId,
                commit.parentJobId,
                commit.underwriter,
                commit.merchantExecutionWallet,
                commit.decisionFeeUsdc,
                commit.requiredBondUsdc,
                commit.fundedPrincipalUsdc,
                commit.coverageCapUsdc,
                commit.validUntil,
                commit.executeUntil,
                commit.unlockAt,
                commit.deliveryConfirmationTimeoutWindow,
                commit.policyHash,
                commit.parentMemoId,
                commit.quoteIdHash,
                commit.releasePrincipal
            )
        );
    }

    function _settlementMemoId(MCUTypes.MCUCommit memory commit) internal pure returns (bytes32) {
        if (commit.parentJobId != 0 && commit.parentMemoId != bytes32(0)) {
            return commit.parentMemoId;
        }
        return commit.memoId;
    }
}
