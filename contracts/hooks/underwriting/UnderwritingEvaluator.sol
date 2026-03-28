// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "../../AgenticCommerceHooked.sol";
import "./IUnderwritingHookView.sol";
import "./UnderwritingTypes.sol";

/**
 * @title UnderwritingEvaluator
 * @notice Legacy lightweight evaluator retained only for parity coverage during the migration.
 * @dev This contract is not part of the canonical shared-environment or production runtime.
 *      New migration work should target `contracts/settlement/UnderwritingEvaluator.sol`.
 *      The contract validates the ACP job state, enforces EIP-712 signatures, and
 *      consumes one nonce per underwriter decision.
 */
contract UnderwritingEvaluator is EIP712 {
    error ZeroAddress();
    error WrongDecisionStatus();
    error WrongDecisionState();
    error DecisionExpired(uint64 deadline, uint64 currentTimestamp);
    error NonceUsed(address underwriter, uint256 nonce);
    error InvalidSigner(address expected, address actual);

    bytes32 private constant COMPLETE_TYPEHASH =
        keccak256("CompleteDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 private constant REJECT_TYPEHASH =
        keccak256("RejectDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");

    AgenticCommerceHooked public immutable acp;
    IUnderwritingHookView public immutable hook;

    mapping(address underwriter => mapping(uint256 nonce => bool used)) public usedNonces;

    /// @notice Deploys the evaluator for a specific ACP kernel and underwriting hook.
    /// @param acpContract_ The hooked ACP contract address.
    /// @param hook_ The underwriting hook view address.
    constructor(address acpContract_, address hook_) EIP712("Underwriting Evaluator", "1") {
        if (acpContract_ == address(0) || hook_ == address(0)) revert ZeroAddress();
        acp = AgenticCommerceHooked(acpContract_);
        hook = IUnderwritingHookView(hook_);
    }

    /// @notice Completes a submitted job using an underwriter-signed decision.
    /// @param decision The EIP-712 completion decision payload.
    /// @param signature The underwriter signature authorizing the completion.
    function completeBySig(UnderwritingTypes.CompleteDecision calldata decision, bytes calldata signature) external {
        if (block.timestamp > decision.deadline) revert DecisionExpired(decision.deadline, uint64(block.timestamp));

        AgenticCommerceHooked.Job memory job = acp.getJob(decision.jobId);
        if (job.status != AgenticCommerceHooked.JobStatus.Submitted) revert WrongDecisionStatus();
        if (hook.jobSidecarState(decision.jobId) != UnderwritingTypes.SidecarState.EvidenceSubmitted) {
            revert WrongDecisionState();
        }

        _consumeNonceAndVerifySigner(
            hook.jobUnderwriter(decision.jobId),
            decision.nonce,
            _hashTypedDataV4(
                keccak256(abi.encode(COMPLETE_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce))
            ),
            signature
        );

        acp.complete(decision.jobId, decision.reason, "");
    }

    /// @notice Rejects a submitted job using an underwriter-signed decision.
    /// @param decision The EIP-712 rejection decision payload.
    /// @param signature The underwriter signature authorizing the rejection.
    function rejectBySig(UnderwritingTypes.RejectDecision calldata decision, bytes calldata signature) external {
        if (block.timestamp > decision.deadline) revert DecisionExpired(decision.deadline, uint64(block.timestamp));

        AgenticCommerceHooked.Job memory job = acp.getJob(decision.jobId);
        if (job.status != AgenticCommerceHooked.JobStatus.Submitted) revert WrongDecisionStatus();
        if (hook.jobSidecarState(decision.jobId) != UnderwritingTypes.SidecarState.EvidenceSubmitted) {
            revert WrongDecisionState();
        }

        _consumeNonceAndVerifySigner(
            hook.jobUnderwriter(decision.jobId),
            decision.nonce,
            _hashTypedDataV4(
                keccak256(abi.encode(REJECT_TYPEHASH, decision.jobId, decision.reason, decision.deadline, decision.nonce))
            ),
            signature
        );

        acp.reject(decision.jobId, decision.reason, "");
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
}
