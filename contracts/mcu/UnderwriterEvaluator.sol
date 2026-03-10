// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "./IAgenticCommerceKernel.sol";
import "./IBondManager.sol";
import "./MCUTypes.sol";

interface IMCUHookView {
    function jobUnderwriter(uint256 jobId) external view returns (address);
    function jobMemoId(uint256 jobId) external view returns (bytes32);
    function jobSidecarState(uint256 jobId) external view returns (MCUTypes.SidecarState);
}

interface IMCUSuccessDisputeCoordinator {
    function applySuccessDisputeDecision(
        MCUTypes.SuccessDisputeDecision calldata decision,
        IBondManager.SlashAttestation calldata attestation,
        bytes calldata slashSig
    ) external;
}

contract UnderwriterEvaluator is EIP712 {
    error InvalidCoordinator();
    error DecisionExpired(uint64 deadline, uint64 currentTimestamp);
    error NonceUsed(address underwriter, uint256 nonce);
    error InvalidSigner(address expected, address actual);
    error MemoMismatch(bytes32 expected, bytes32 actual);
    error WrongJobStatus();
    error WrongSidecarState();
    error DisputeHashRequired();
    error UnexpectedSlashAttestationHash(bytes32 provided);
    error SlashAttestationHashRequired();
    error SlashAttestationHashMismatch(bytes32 expected, bytes32 actual);

    bytes32 private constant COMPLETE_TYPEHASH = keccak256(
        "CompleteDecision(uint256 jobId,bytes32 memoId,bytes32 reason,uint64 deadline,uint256 nonce)"
    );
    bytes32 private constant REJECT_TYPEHASH = keccak256(
        "RejectDecision(uint256 jobId,bytes32 memoId,bytes32 reason,bytes32 slashAttestationHash,uint64 deadline,uint256 nonce)"
    );
    bytes32 private constant SUCCESS_DISPUTE_TYPEHASH = keccak256(
        "SuccessDisputeDecision(uint256 jobId,bytes32 memoId,bytes32 disputeHash,uint8 outcome,bytes32 reason,bytes32 slashAttestationHash,uint64 deadline,uint256 nonce)"
    );

    struct CompleteDecision {
        uint256 jobId;
        bytes32 memoId;
        bytes32 reason;
        uint64 deadline;
        uint256 nonce;
    }

    struct RejectDecision {
        uint256 jobId;
        bytes32 memoId;
        bytes32 reason;
        bytes32 slashAttestationHash;
        uint64 deadline;
        uint256 nonce;
    }

    IAgenticCommerceKernel public immutable acp;
    IMCUHookView public immutable hook;
    IMCUSuccessDisputeCoordinator public immutable coordinator;

    mapping(address underwriter => mapping(uint256 nonce => bool used)) public usedNonces;

    event CompletedByUnderwriter(
        uint256 indexed jobId,
        bytes32 indexed memoId,
        address indexed underwriter,
        bytes32 reason
    );
    event RejectedByUnderwriter(
        uint256 indexed jobId,
        bytes32 indexed memoId,
        address indexed underwriter,
        bytes32 reason,
        bytes32 slashAttestationHash
    );
    event SuccessDisputeResolvedByUnderwriter(
        uint256 indexed jobId,
        bytes32 indexed memoId,
        address indexed underwriter,
        bytes32 disputeHash,
        MCUTypes.SuccessDisputeOutcome outcome,
        bytes32 reason,
        bytes32 slashAttestationHash
    );

    constructor(IAgenticCommerceKernel acp_, IMCUHookView hook_, address coordinator_)
        EIP712("MCU Underwriter Evaluator", "1")
    {
        if (coordinator_ == address(0)) revert InvalidCoordinator();
        acp = acp_;
        hook = hook_;
        coordinator = IMCUSuccessDisputeCoordinator(coordinator_);
    }

    function completeBySig(CompleteDecision calldata decision, bytes calldata underwriterDecisionSig) external {
        if (block.timestamp > decision.deadline) revert DecisionExpired(decision.deadline, uint64(block.timestamp));

        IAgenticCommerceKernel.Job memory job = acp.getJob(decision.jobId);
        IAgenticCommerceKernel.JobKind jobKind = acp.getJobKind(decision.jobId);
        if (jobKind == IAgenticCommerceKernel.JobKind.Open) {
            if (job.status != IAgenticCommerceKernel.JobStatus.Funded) revert WrongJobStatus();
            if (hook.jobSidecarState(decision.jobId) != MCUTypes.SidecarState.Protected) revert WrongSidecarState();
        } else {
            if (job.status != IAgenticCommerceKernel.JobStatus.Submitted) revert WrongJobStatus();
            if (hook.jobSidecarState(decision.jobId) != MCUTypes.SidecarState.EvidenceSubmitted) {
                revert WrongSidecarState();
            }
        }

        address underwriter = hook.jobUnderwriter(decision.jobId);
        bytes32 memoId = hook.jobMemoId(decision.jobId);
        if (memoId != decision.memoId) revert MemoMismatch(memoId, decision.memoId);
        if (usedNonces[underwriter][decision.nonce]) revert NonceUsed(underwriter, decision.nonce);

        bytes32 structHash = keccak256(
            abi.encode(
                COMPLETE_TYPEHASH,
                decision.jobId,
                decision.memoId,
                decision.reason,
                decision.deadline,
                decision.nonce
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, underwriterDecisionSig);
        if (recovered != underwriter || underwriter == address(0)) revert InvalidSigner(underwriter, recovered);

        usedNonces[underwriter][decision.nonce] = true;

        acp.complete(
            decision.jobId,
            decision.reason,
            abi.encode(MCUTypes.CompleteContext({memoId: decision.memoId}))
        );

        emit CompletedByUnderwriter(decision.jobId, decision.memoId, underwriter, decision.reason);
    }

    function rejectBySig(RejectDecision calldata decision, bytes calldata underwriterDecisionSig) external {
        if (block.timestamp > decision.deadline) revert DecisionExpired(decision.deadline, uint64(block.timestamp));

        IAgenticCommerceKernel.Job memory job = acp.getJob(decision.jobId);
        IAgenticCommerceKernel.JobKind jobKind = acp.getJobKind(decision.jobId);
        if (jobKind == IAgenticCommerceKernel.JobKind.Open) {
            if (job.status != IAgenticCommerceKernel.JobStatus.Funded) revert WrongJobStatus();
            if (hook.jobSidecarState(decision.jobId) != MCUTypes.SidecarState.Protected) revert WrongSidecarState();
        } else {
            if (job.status != IAgenticCommerceKernel.JobStatus.Submitted) revert WrongJobStatus();
            if (hook.jobSidecarState(decision.jobId) != MCUTypes.SidecarState.EvidenceSubmitted) {
                revert WrongSidecarState();
            }
        }

        address underwriter = hook.jobUnderwriter(decision.jobId);
        bytes32 memoId = hook.jobMemoId(decision.jobId);
        if (memoId != decision.memoId) revert MemoMismatch(memoId, decision.memoId);
        if (usedNonces[underwriter][decision.nonce]) revert NonceUsed(underwriter, decision.nonce);

        bytes32 structHash = keccak256(
            abi.encode(
                REJECT_TYPEHASH,
                decision.jobId,
                decision.memoId,
                decision.reason,
                decision.slashAttestationHash,
                decision.deadline,
                decision.nonce
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, underwriterDecisionSig);
        if (recovered != underwriter || underwriter == address(0)) revert InvalidSigner(underwriter, recovered);

        usedNonces[underwriter][decision.nonce] = true;

        acp.reject(
            decision.jobId,
            decision.reason,
            abi.encode(
                MCUTypes.RejectContext({
                    memoId: decision.memoId,
                    slashAttestationHash: decision.slashAttestationHash,
                    reasonCode: decision.reason
                })
            )
        );

        emit RejectedByUnderwriter(
            decision.jobId, decision.memoId, underwriter, decision.reason, decision.slashAttestationHash
        );
    }

    function resolveSuccessDisputeBySig(
        MCUTypes.SuccessDisputeDecision calldata decision,
        IBondManager.SlashAttestation calldata attestation,
        bytes calldata slashSig,
        bytes calldata underwriterDecisionSig
    ) external {
        if (block.timestamp > decision.deadline) revert DecisionExpired(decision.deadline, uint64(block.timestamp));

        IAgenticCommerceKernel.Job memory job = acp.getJob(decision.jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongJobStatus();
        if (hook.jobSidecarState(decision.jobId) != MCUTypes.SidecarState.SuccessDisputeOpen) {
            revert WrongSidecarState();
        }
        if (decision.disputeHash == bytes32(0)) revert DisputeHashRequired();

        if (decision.outcome == MCUTypes.SuccessDisputeOutcome.ReleaseBond) {
            if (decision.slashAttestationHash != bytes32(0)) {
                revert UnexpectedSlashAttestationHash(decision.slashAttestationHash);
            }
        } else {
            if (decision.slashAttestationHash == bytes32(0)) revert SlashAttestationHashRequired();
            bytes32 actualSlashAttestationHash = _hashSlashAttestation(attestation);
            if (actualSlashAttestationHash != decision.slashAttestationHash) {
                revert SlashAttestationHashMismatch(decision.slashAttestationHash, actualSlashAttestationHash);
            }
        }

        address underwriter = hook.jobUnderwriter(decision.jobId);
        bytes32 memoId = hook.jobMemoId(decision.jobId);
        if (memoId != decision.memoId) revert MemoMismatch(memoId, decision.memoId);
        if (usedNonces[underwriter][decision.nonce]) revert NonceUsed(underwriter, decision.nonce);

        bytes32 structHash = keccak256(
            abi.encode(
                SUCCESS_DISPUTE_TYPEHASH,
                decision.jobId,
                decision.memoId,
                decision.disputeHash,
                uint8(decision.outcome),
                decision.reason,
                decision.slashAttestationHash,
                decision.deadline,
                decision.nonce
            )
        );
        bytes32 digest = _hashTypedDataV4(structHash);
        address recovered = ECDSA.recover(digest, underwriterDecisionSig);
        if (recovered != underwriter || underwriter == address(0)) revert InvalidSigner(underwriter, recovered);

        usedNonces[underwriter][decision.nonce] = true;

        coordinator.applySuccessDisputeDecision(decision, attestation, slashSig);

        emit SuccessDisputeResolvedByUnderwriter(
            decision.jobId,
            decision.memoId,
            underwriter,
            decision.disputeHash,
            decision.outcome,
            decision.reason,
            decision.slashAttestationHash
        );
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
