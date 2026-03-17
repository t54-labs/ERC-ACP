// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "../IACPHook.sol";
import "./IAgenticCommerceKernel.sol";
import "./MCUTypes.sol";

contract MCUHookLite is IACPHook {
    error OnlyACP();
    error OnlyAdmin();
    error OnlyCoordinator();
    error UnderwriterNotRegistered();
    error WiringAlreadySet();
    error WiringIncomplete();
    error UnsupportedSelector();
    error UnsupportedJobKind();
    error ProfileAlreadyCommitted();
    error ProfileNotCommitted();
    error ProviderMustBeSet();
    error EvaluatorMismatch();
    error InvalidProfile();
    error InvalidState();
    error EvidenceMismatch();
    error AdapterMismatch();
    error InvalidParentJob();
    error ParentProfileNotCommitted();
    error ParentHookMismatch();
    error ParentAlreadyHasCloseJob();
    error NestedCloseUnsupported();

    struct Profile {
        bool initialized;
        address adapter;
        MCUTypes.FlowKind flowKind;
        MCUTypes.SidecarState sidecarState;
        bytes32 configHash;
        uint64 completionObservedAt;
        uint64 settlementRequestedAt;
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
    mapping(address underwriter => bool registered) internal registeredUnderwriters;
    mapping(uint256 closeJobId => uint256 parentJobId) internal parentJobIdByCloseJobId;
    mapping(uint256 parentJobId => uint256 closeJobId) internal activeCloseJobIdByParentJobId;

    event WiringSet(address indexed coordinator, address indexed underwriterEvaluator);
    event UnderwriterRegistered(address indexed underwriter);
    event UnderwriterUnregistered(address indexed underwriter);
    event ProfileCommitted(
        uint256 indexed jobId,
        uint256 indexed settlementJobId,
        address indexed underwriter,
        bytes32 configHash
    );
    event EvidenceRecorded(uint256 indexed jobId, uint256 indexed settlementJobId, bytes32 indexed bundleHash);
    event CompletionObserved(uint256 indexed jobId, uint256 indexed settlementJobId, bytes32 indexed reason);
    event RejectionObserved(
        uint256 indexed jobId,
        uint256 indexed settlementJobId,
        bytes32 indexed reason,
        bytes32 slashAttestationHash
    );
    event SidecarStateUpdated(
        uint256 indexed jobId,
        MCUTypes.SidecarState previousState,
        MCUTypes.SidecarState nextState
    );
    event ParentJobLinked(uint256 indexed closeJobId, uint256 indexed parentJobId);

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

    function registerUnderwriter(address underwriter) external onlyAdmin {
        if (underwriter == address(0)) revert InvalidProfile();
        registeredUnderwriters[underwriter] = true;
        emit UnderwriterRegistered(underwriter);
    }

    function unregisterUnderwriter(address underwriter) external onlyAdmin {
        if (underwriter == address(0)) revert InvalidProfile();
        delete registeredUnderwriters[underwriter];
        emit UnderwriterUnregistered(underwriter);
    }

    function isRegisteredUnderwriter(address underwriter) external view returns (bool) {
        return registeredUnderwriters[underwriter];
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
        return _profile(jobId).commit.underwriter;
    }

    function jobSettlementJobId(uint256 jobId) external view returns (uint256) {
        return _settlementJobId(jobId, _profile(jobId).commit);
    }

    function jobAdapter(uint256 jobId) external view returns (address) {
        return _profile(jobId).adapter;
    }

    function jobSidecarState(uint256 jobId) external view returns (MCUTypes.SidecarState) {
        return _profile(jobId).sidecarState;
    }

    function jobFlowKind(uint256 jobId) external view returns (MCUTypes.FlowKind) {
        return _profile(jobId).flowKind;
    }

    function getCommit(uint256 jobId) external view returns (MCUTypes.MCUCommit memory) {
        return _profile(jobId).commit;
    }

    function jobCompletionObservedAt(uint256 jobId) external view returns (uint64) {
        return _profile(jobId).completionObservedAt;
    }

    function jobDeliveryConfirmationDeadline(uint256 jobId) external view returns (uint64) {
        Profile storage profile = _profile(jobId);
        if (profile.settlementRequestedAt == 0) {
            return 0;
        }
        return profile.settlementRequestedAt + profile.commit.deliveryConfirmationTimeoutWindow;
    }

    function jobLastSuccessDisputeHash(uint256 jobId) external view returns (bytes32) {
        return _profile(jobId).lastSuccessDisputeHash;
    }

    function getParentJobId(uint256 jobId) external view returns (uint256) {
        return parentJobIdByCloseJobId[jobId];
    }

    function getCloseJobId(uint256 jobId) external view returns (uint256) {
        return activeCloseJobIdByParentJobId[jobId];
    }

    function markProtected(uint256 jobId, address adapter) external onlyCoordinator {
        Profile storage profile = _profile(jobId);
        if (profile.sidecarState != MCUTypes.SidecarState.FeeEscrowed) revert InvalidState();
        if (adapter == address(0)) revert InvalidProfile();
        if (profile.adapter != address(0) && profile.adapter != adapter) revert AdapterMismatch();

        profile.adapter = adapter;
        _setState(profile, jobId, MCUTypes.SidecarState.Protected);
    }

    function markSuccessPendingCollateralRelease(uint256 jobId) external onlyCoordinator {
        Profile storage profile = _profile(jobId);
        if (profile.sidecarState == MCUTypes.SidecarState.SuccessPendingConfirmation) {
            profile.settlementRequestedAt = uint64(block.timestamp);
        }
        if (
            profile.sidecarState != MCUTypes.SidecarState.SuccessPendingConfirmation
                && profile.sidecarState != MCUTypes.SidecarState.SuccessDisputeOpen
        ) {
            revert InvalidState();
        }
        _setState(profile, jobId, MCUTypes.SidecarState.SuccessPendingCollateralRelease);
    }

    function markSuccessDisputeOpen(uint256 jobId, bytes32 disputeHash) external onlyCoordinator {
        Profile storage profile = _profile(jobId);
        if (profile.sidecarState != MCUTypes.SidecarState.SuccessPendingCollateralRelease) revert InvalidState();
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
        if (profile.sidecarState != MCUTypes.SidecarState.SuccessPendingCollateralRelease) revert InvalidState();
        _setState(profile, jobId, MCUTypes.SidecarState.SuccessSettled);
    }

    function markRejectSettled(uint256 jobId) external onlyCoordinator {
        Profile storage profile = _profile(jobId);
        if (profile.sidecarState != MCUTypes.SidecarState.RejectPendingSlash) revert InvalidState();
        _setState(profile, jobId, MCUTypes.SidecarState.RejectSettled);
        _clearActiveCloseLinkage(profile, jobId);
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
        if (profile.flowKind == MCUTypes.FlowKind.TwoStageClose) {
            if (
                profile.sidecarState != MCUTypes.SidecarState.FeeEscrowed
                    && profile.sidecarState != MCUTypes.SidecarState.Protected
                    && profile.sidecarState != MCUTypes.SidecarState.EvidenceSubmitted
            ) {
                revert InvalidState();
            }
            _setState(profile, jobId, MCUTypes.SidecarState.ExpirySettled);
            _clearActiveCloseLinkage(profile, jobId);
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
        IAgenticCommerceKernel.JobKind jobKind = acp.getJobKind(jobId);
        MCUTypes.FlowKind flowKind = _resolveFlowKind(jobKind, commit);

        if (job.provider == address(0)) revert ProviderMustBeSet();
        if (job.evaluator != underwriterEvaluator) revert EvaluatorMismatch();
        _validateCommit(commit);

        if (flowKind == MCUTypes.FlowKind.TwoStageClose) {
            commit = _resolveParentCommit(jobId, job, commit);
            parentJobIdByCloseJobId[jobId] = commit.parentJobId;
            activeCloseJobIdByParentJobId[commit.parentJobId] = jobId;
        } else if (!registeredUnderwriters[commit.underwriter]) {
            revert UnderwriterNotRegistered();
        }

        profiles[jobId] = Profile({
            initialized: true,
            adapter: address(0),
            flowKind: flowKind,
            sidecarState: MCUTypes.SidecarState.Committed,
            configHash: _hashCommit(commit),
            completionObservedAt: 0,
            settlementRequestedAt: 0,
            lastBundleHash: bytes32(0),
            lastReason: bytes32(0),
            lastSuccessDisputeHash: bytes32(0),
            lastSlashAttestationHash: bytes32(0),
            commit: commit
        });

        if (flowKind == MCUTypes.FlowKind.TwoStageClose) {
            emit ParentJobLinked(jobId, commit.parentJobId);
        }

        emit ProfileCommitted(jobId, _settlementJobId(jobId, commit), commit.underwriter, profiles[jobId].configHash);
    }

    function _beforeFund(uint256 jobId) internal view {
        Profile storage profile = _profile(jobId);
        if (profile.sidecarState != MCUTypes.SidecarState.Committed) revert InvalidState();
        if (profile.flowKind == MCUTypes.FlowKind.TwoStageClose) {
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
        if (profile.flowKind == MCUTypes.FlowKind.TwoStageClose) {
            _assertParentReadyForClose(profile.commit.parentJobId);
        }
    }

    function _beforeComplete(uint256 jobId) internal view {
        Profile storage profile = _profile(jobId);
        if (profile.flowKind == MCUTypes.FlowKind.TwoStageOpen) {
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

        emit EvidenceRecorded(jobId, _settlementJobId(jobId, profile.commit), evidence.bundleHash);
    }

    function _afterComplete(uint256 jobId, bytes calldata data) internal {
        Profile storage profile = profiles[jobId];
        if (!profile.initialized) return;

        (bytes32 reason,) = abi.decode(data, (bytes32, bytes));
        profile.lastReason = reason;
        profile.lastSuccessDisputeHash = bytes32(0);

        if (profile.flowKind == MCUTypes.FlowKind.TwoStageOpen) {
            profile.completionObservedAt = 0;
            profile.settlementRequestedAt = 0;
            _setState(profile, jobId, MCUTypes.SidecarState.AwaitingClose);
        } else {
            profile.completionObservedAt = uint64(block.timestamp);
            profile.settlementRequestedAt = 0;
            _setState(profile, jobId, MCUTypes.SidecarState.SuccessPendingConfirmation);
        }

        emit CompletionObserved(jobId, _settlementJobId(jobId, profile.commit), reason);
    }

    function _afterReject(uint256 jobId, bytes calldata data) internal {
        Profile storage profile = profiles[jobId];
        if (!profile.initialized) return;

        (bytes32 reason, bytes memory optParams) = abi.decode(data, (bytes32, bytes));
        profile.lastReason = reason;

        bytes32 slashAttestationHash;
        if (optParams.length > 0) {
            MCUTypes.RejectContext memory context = abi.decode(optParams, (MCUTypes.RejectContext));
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
            _clearActiveCloseLinkage(profile, jobId);
        }

        emit RejectionObserved(jobId, _settlementJobId(jobId, profile.commit), reason, slashAttestationHash);
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

    function _clearActiveCloseLinkage(Profile storage profile, uint256 jobId) internal {
        if (profile.flowKind != MCUTypes.FlowKind.TwoStageClose) return;

        uint256 parentJobId = parentJobIdByCloseJobId[jobId];
        if (parentJobId == 0) return;
        if (activeCloseJobIdByParentJobId[parentJobId] == jobId) {
            delete activeCloseJobIdByParentJobId[parentJobId];
        }
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

        IAgenticCommerceKernel.Job memory parentJob = acp.getJob(commit.parentJobId);
        if (parentJob.id == 0) revert InvalidParentJob();
        if (acp.getJobKind(commit.parentJobId) != IAgenticCommerceKernel.JobKind.Open) revert InvalidParentJob();
        uint256 linkedCloseJobId = activeCloseJobIdByParentJobId[commit.parentJobId];
        if (linkedCloseJobId != 0 && linkedCloseJobId != jobId) revert ParentAlreadyHasCloseJob();
        if (parentJob.hook != address(this)) revert ParentHookMismatch();

        Profile storage parentProfile = profiles[commit.parentJobId];
        if (!parentProfile.initialized) revert ParentProfileNotCommitted();
        if (parentProfile.flowKind != MCUTypes.FlowKind.TwoStageOpen) revert NestedCloseUnsupported();
        if (job.hook != address(this)) revert InvalidParentJob();
        if (
            parentJob.client != job.client || parentJob.provider != job.provider
                || parentJob.evaluator != job.evaluator
        ) {
            revert InvalidParentJob();
        }
        if (parentProfile.commit.underwriter != commit.underwriter) revert InvalidParentJob();

        commit.unlockAt = parentProfile.commit.unlockAt;

        _assertParentReadyForClose(commit.parentJobId);

        return commit;
    }

    function _resolveFlowKind(IAgenticCommerceKernel.JobKind jobKind, MCUTypes.MCUCommit memory commit)
        internal
        pure
        returns (MCUTypes.FlowKind)
    {
        if (jobKind == IAgenticCommerceKernel.JobKind.Open) {
            if (commit.parentJobId != 0) revert InvalidProfile();
            return MCUTypes.FlowKind.TwoStageOpen;
        }
        if (jobKind == IAgenticCommerceKernel.JobKind.Standalone) {
            if (commit.parentJobId == 0) return MCUTypes.FlowKind.SingleStage;
            return MCUTypes.FlowKind.TwoStageClose;
        }
        revert UnsupportedJobKind();
    }

    function _validateCommit(MCUTypes.MCUCommit memory commit) internal view {
        if (commit.underwriter == address(0) || commit.merchantExecutionWallet == address(0)) {
            revert InvalidProfile();
        }
        if (commit.decisionFeeUsdc == 0 || commit.requiredCollateralUsdc == 0) revert InvalidProfile();
        if (commit.coverageCapUsdc > commit.requiredCollateralUsdc) revert InvalidProfile();
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
                commit.parentJobId,
                commit.underwriter,
                commit.merchantExecutionWallet,
                commit.decisionFeeUsdc,
                commit.requiredCollateralUsdc,
                commit.fundedPrincipalUsdc,
                commit.coverageCapUsdc,
                commit.validUntil,
                commit.executeUntil,
                commit.unlockAt,
                commit.deliveryConfirmationTimeoutWindow,
                commit.policyHash,
                commit.quoteIdHash,
                commit.releasePrincipal
            )
        );
    }

    function _settlementJobId(uint256 jobId, MCUTypes.MCUCommit memory commit) internal pure returns (uint256) {
        if (commit.parentJobId != 0) {
            return commit.parentJobId;
        }
        return jobId;
    }
}
