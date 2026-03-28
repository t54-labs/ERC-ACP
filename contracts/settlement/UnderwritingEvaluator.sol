// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts-upgradeable/utils/cryptography/EIP712Upgradeable.sol";
import "../interfaces/IAgenticCommerceKernel.sol";
import "../hooks/underwriting/IUnderwritingHookView.sol";
import "../hooks/underwriting/UnderwritingTypes.sol";

/**
 * @title UnderwritingEvaluator
 * @notice Executes underwriter-signed complete and reject decisions.
 * @dev This is the canonical evaluator for the settlement migration. It validates
 *      the ACP job lifecycle, underwriting sidecar state, and EIP-712 signatures
 *      before calling back into ACP.
 */
contract UnderwritingEvaluator is Initializable, AccessControlUpgradeable, UUPSUpgradeable, EIP712Upgradeable {
    error ZeroAddress();
    error DecisionExpired(uint64 deadline, uint64 currentTimestamp);
    error NonceUsed(address underwriter, uint256 nonce);
    error InvalidSigner(address expected, address actual);
    error WrongDecisionStatus();
    error WrongDecisionState();
    error ClientConfirmationStillOpen();
    error ClientConfirmationWindowElapsed();
    error OnlyClient();

    bytes32 private constant COMPLETE_TYPEHASH =
        keccak256("CompleteDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 private constant REJECT_TYPEHASH =
        keccak256("RejectDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");

    IAgenticCommerceKernel public acp;
    IUnderwritingHookView public hook;
    uint64 public clientConfirmationWindowSeconds;
    address public admin;

    mapping(address underwriter => mapping(uint256 nonce => bool used)) public usedNonces;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Deploys the evaluator for a specific ACP kernel and hook.
    /// @param acp_ The ACP kernel used for job state reads and decisions.
    /// @param hook_ The underwriting hook view used for sidecar state reads.
    /// @param clientConfirmationWindowSeconds_ The duration after submission during which only the client may confirm.
    /// @param admin_ The address granted admin and upgrader roles.
    function initialize(
        address acp_,
        address hook_,
        uint64 clientConfirmationWindowSeconds_,
        address admin_
    ) external initializer {
        if (acp_ == address(0) || hook_ == address(0) || admin_ == address(0)) revert ZeroAddress();

        __AccessControl_init();
        __EIP712_init("Underwriting Settlement Evaluator", "1");

        acp = IAgenticCommerceKernel(acp_);
        hook = IUnderwritingHookView(hook_);
        clientConfirmationWindowSeconds = clientConfirmationWindowSeconds_;
        admin = admin_;

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        _grantRole(ADMIN_ROLE, admin_);
        _grantRole(UPGRADER_ROLE, admin_);
    }

    /// @notice Completes a submitted job using an underwriter-signed decision.
    /// @param decision The EIP-712 completion decision payload.
    /// @param underwriterDecisionSig The underwriter signature authorizing the completion.
    function completeBySig(UnderwritingTypes.CompleteDecision calldata decision, bytes calldata underwriterDecisionSig)
        external
    {
        if (block.timestamp > decision.deadline) revert DecisionExpired(decision.deadline, uint64(block.timestamp));

        IAgenticCommerceKernel.Job memory job = acp.getJob(decision.jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Submitted) revert WrongDecisionStatus();
        if (hook.jobSidecarState(decision.jobId) != UnderwritingTypes.SidecarState.EvidenceSubmitted) {
            revert WrongDecisionState();
        }

        _requireClientWindowElapsed(decision.jobId);

        _consumeNonceAndVerifySigner(
            hook.jobUnderwriter(decision.jobId),
            decision.nonce,
            _hashTypedDataV4(
                keccak256(abi.encode(COMPLETE_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce))
            ),
            underwriterDecisionSig
        );

        acp.complete(decision.jobId, decision.reason, bytes(""));
    }

    /// @notice Rejects a submitted job using an underwriter-signed decision.
    /// @param decision The EIP-712 rejection decision payload.
    /// @param underwriterDecisionSig The underwriter signature authorizing the rejection.
    function rejectBySig(UnderwritingTypes.RejectDecision calldata decision, bytes calldata underwriterDecisionSig)
        external
    {
        if (block.timestamp > decision.deadline) revert DecisionExpired(decision.deadline, uint64(block.timestamp));

        IAgenticCommerceKernel.Job memory job = acp.getJob(decision.jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Submitted) revert WrongDecisionStatus();
        if (hook.jobSidecarState(decision.jobId) != UnderwritingTypes.SidecarState.EvidenceSubmitted) {
            revert WrongDecisionState();
        }

        _requireClientWindowElapsed(decision.jobId);

        _consumeNonceAndVerifySigner(
            hook.jobUnderwriter(decision.jobId),
            decision.nonce,
            _hashTypedDataV4(
                keccak256(abi.encode(REJECT_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce))
            ),
            underwriterDecisionSig
        );

        acp.reject(decision.jobId, decision.reason, bytes(""));
    }

    /// @notice Allows the client to confirm a submitted job within the confirmation window.
    /// @param jobId The job to confirm.
    /// @param reason The client's confirmation reason code.
    function confirmByClient(uint256 jobId, bytes32 reason) external {
        IAgenticCommerceKernel.Job memory job = acp.getJob(jobId);
        if (msg.sender != job.client) revert OnlyClient();
        if (job.status != IAgenticCommerceKernel.JobStatus.Submitted) revert WrongDecisionStatus();
        if (hook.jobSidecarState(jobId) != UnderwritingTypes.SidecarState.EvidenceSubmitted) {
            revert WrongDecisionState();
        }

        uint64 submittedAt = hook.jobSubmittedAt(jobId);
        if (submittedAt == 0 || block.timestamp > submittedAt + clientConfirmationWindowSeconds) {
            revert ClientConfirmationWindowElapsed();
        }

        acp.complete(jobId, reason, bytes(""));
    }

    /// @dev Reverts when the client confirmation window has not yet elapsed.
    function _requireClientWindowElapsed(uint256 jobId) internal view {
        if (clientConfirmationWindowSeconds == 0) return;
        uint64 submittedAt = hook.jobSubmittedAt(jobId);
        if (submittedAt != 0 && block.timestamp <= submittedAt + clientConfirmationWindowSeconds) {
            revert ClientConfirmationStillOpen();
        }
    }

    /// @dev Reverts on reused nonces or invalid signatures before consuming the nonce.
    function _consumeNonceAndVerifySigner(
        address expectedUnderwriter,
        uint256 nonce,
        bytes32 digest,
        bytes calldata signature
    ) internal {
        if (usedNonces[expectedUnderwriter][nonce]) revert NonceUsed(expectedUnderwriter, nonce);

        address recovered = ECDSA.recover(digest, signature);
        if (recovered != expectedUnderwriter || expectedUnderwriter == address(0)) {
            revert InvalidSigner(expectedUnderwriter, recovered);
        }

        usedNonces[expectedUnderwriter][nonce] = true;
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    uint256[44] private __gap;
}
