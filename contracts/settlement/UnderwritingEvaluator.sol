// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "../mcu/IAgenticCommerceKernel.sol";
import "../mcu/ICollateralManager.sol";
import "../hooks/underwriting/IUnderwritingHookView.sol";
import "../hooks/underwriting/UnderwritingTypes.sol";
import "./SettlementTypes.sol";

interface ISettlementDisputeCoordinator {
    function applySuccessDisputeDecision(
        SettlementTypes.SuccessDisputeDecision calldata decision,
        ICollateralManager.SlashAttestation calldata attestation,
        bytes calldata slashSig
    ) external;
}

contract UnderwritingEvaluator is EIP712 {
    error InvalidCoordinator();
    error DecisionExpired(uint64 deadline, uint64 currentTimestamp);
    error NonceUsed(address underwriter, uint256 nonce);
    error InvalidSigner(address expected, address actual);
    error WrongDecisionStatus();
    error WrongDecisionState();

    bytes32 private constant COMPLETE_TYPEHASH =
        keccak256("CompleteDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 private constant REJECT_TYPEHASH =
        keccak256("RejectDecision(uint256 jobId,bytes32 reason,uint64 deadline,uint256 nonce)");
    bytes32 private constant SUCCESS_DISPUTE_TYPEHASH = keccak256(
        "SuccessDisputeDecision(uint256 jobId,bytes32 disputeHash,uint8 outcome,bytes32 reason,bytes32 slashAttestationHash,uint64 deadline,uint256 nonce)"
    );

    IAgenticCommerceKernel public immutable acp;
    IUnderwritingHookView public immutable hook;
    ISettlementDisputeCoordinator public immutable coordinator;

    mapping(address underwriter => mapping(uint256 nonce => bool used)) public usedNonces;

    constructor(IAgenticCommerceKernel acp_, IUnderwritingHookView hook_, address coordinator_)
        EIP712("Underwriting Settlement Evaluator", "1")
    {
        if (coordinator_ == address(0)) revert InvalidCoordinator();
        acp = acp_;
        hook = hook_;
        coordinator = ISettlementDisputeCoordinator(coordinator_);
    }

    function completeBySig(UnderwritingTypes.CompleteDecision calldata decision, bytes calldata underwriterDecisionSig)
        external
    {
        if (block.timestamp > decision.deadline) revert DecisionExpired(decision.deadline, uint64(block.timestamp));

        IAgenticCommerceKernel.Job memory job = acp.getJob(decision.jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Submitted) revert WrongDecisionStatus();
        if (hook.jobSidecarState(decision.jobId) != UnderwritingTypes.SidecarState.EvidenceSubmitted) {
            revert WrongDecisionState();
        }

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

    function rejectBySig(UnderwritingTypes.RejectDecision calldata decision, bytes calldata underwriterDecisionSig)
        external
    {
        if (block.timestamp > decision.deadline) revert DecisionExpired(decision.deadline, uint64(block.timestamp));

        IAgenticCommerceKernel.Job memory job = acp.getJob(decision.jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Submitted) revert WrongDecisionStatus();
        if (hook.jobSidecarState(decision.jobId) != UnderwritingTypes.SidecarState.EvidenceSubmitted) {
            revert WrongDecisionState();
        }

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

    function resolveSuccessDisputeBySig(
        SettlementTypes.SuccessDisputeDecision calldata decision,
        ICollateralManager.SlashAttestation calldata attestation,
        bytes calldata slashSig,
        bytes calldata underwriterDecisionSig
    ) external {
        if (block.timestamp > decision.deadline) revert DecisionExpired(decision.deadline, uint64(block.timestamp));

        IAgenticCommerceKernel.Job memory job = acp.getJob(decision.jobId);
        if (job.status != IAgenticCommerceKernel.JobStatus.Completed) revert WrongDecisionStatus();

        _consumeNonceAndVerifySigner(
            hook.jobUnderwriter(decision.jobId),
            decision.nonce,
            _hashTypedDataV4(
                keccak256(
                    abi.encode(
                        SUCCESS_DISPUTE_TYPEHASH,
                        decision.jobId,
                        decision.disputeHash,
                        uint8(decision.outcome),
                        decision.reason,
                        decision.slashAttestationHash,
                        decision.deadline,
                        decision.nonce
                    )
                )
            ),
            underwriterDecisionSig
        );

        coordinator.applySuccessDisputeDecision(decision, attestation, slashSig);
    }

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
