from __future__ import annotations

from typing import Any

from app.chain.client import UnderwritingChainReader
from app.schemas.snapshots import UnderwritingJobSnapshot
from app.services.derive_dispute import derive_dispute
from app.services.derive_flags import derive_flags
from app.services.derive_lineage import derive_lineage
from app.services.derive_orchestration import derive_orchestration

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"


class NonUnderwritingJobError(ValueError):
    """Raised when a job exists but is not wired to the configured underwriting hook."""


def _has_commit(commit: dict[str, Any]) -> bool:
    return any(
        [
            int(commit.get("parentJobId") or 0) != 0,
            (commit.get("underwriter") or ZERO_ADDRESS) != ZERO_ADDRESS,
            int(commit.get("validUntil") or 0) != 0,
            commit.get("policyHash") not in {None, "0x" + "0" * 64},
            commit.get("quoteIdHash") not in {None, "0x" + "0" * 64},
            commit.get("termsHash") not in {None, "0x" + "0" * 64},
            bool(commit.get("allowCloseJob")),
        ]
    )


def hydrate_underwriting_snapshot(job_id: int, chain: UnderwritingChainReader) -> UnderwritingJobSnapshot:
    latest_block = chain.get_latest_block()
    now = chain.get_current_timestamp()
    job = chain.get_job(job_id)

    if job.get("hook", "").lower() != chain.get_underwriting_hook_address().lower():
        raise NonUnderwritingJobError(f"job {job_id} is not hooked to the configured underwriting runtime")

    job_kind = chain.get_job_kind(job_id)
    commit = chain.get_commit(job_id)
    settlement_job_id = int(chain.get_job_settlement_job_id(job_id))
    settlement_owner_job_id = settlement_job_id or job_id
    hook_parent_job_id = chain.get_parent_job_id(job_id)
    kernel_parent_job_id = chain.get_kernel_parent_job_id(job_id)
    lineage_parent_job_id = int(commit.get("parentJobId") or hook_parent_job_id or kernel_parent_job_id or 0)
    lineage_root_job_id = lineage_parent_job_id or job_id

    lineage = derive_lineage(
        job_id=job_id,
        job_kind=job_kind,
        commit=commit,
        hook_parent_job_id=hook_parent_job_id,
        kernel_parent_job_id=kernel_parent_job_id,
        hook_active_close_job_id=chain.get_active_close_job_id(lineage_root_job_id),
        kernel_close_job_id=chain.get_kernel_close_job_id(lineage_root_job_id),
        hook_is_awaiting_close=chain.is_awaiting_close(lineage_root_job_id),
    )

    sidecar_state = chain.get_job_sidecar_state(job_id)
    submitted_at = int(chain.get_job_submitted_at(job_id))
    underwriter_address = chain.get_job_underwriter(job_id)
    hook = {
        "hasCommit": _has_commit(commit),
        "underwriter": underwriter_address,
        "sidecarState": sidecar_state,
        "isAwaitingClose": lineage["isAwaitingClose"],
        "submittedAt": submitted_at,
        "commit": {
            "parentJobId": int(commit.get("parentJobId") or 0) or None,
            "underwriter": commit.get("underwriter"),
            "validUntil": int(commit.get("validUntil") or 0) or None,
            "policyHash": commit.get("policyHash"),
            "quoteIdHash": commit.get("quoteIdHash"),
            "termsHash": commit.get("termsHash"),
            "allowCloseJob": bool(commit.get("allowCloseJob")),
        },
    }

    settlement = {
        "state": chain.get_settlement_state(settlement_owner_job_id),
        "unlockAt": chain.get_unlock_at(settlement_owner_job_id),
        "escrow": chain.get_settlement_escrow(job_id),
    }
    evaluator = {
        "clientConfirmationWindowSeconds": chain.get_client_confirmation_window_seconds(),
    }
    dispute = derive_dispute(
        job=job,
        settlement_state=settlement["state"],
        dispute_events=chain.get_dispute_events(job_id, settlement_owner_job_id),
    )
    recipients = chain.get_underwriter_recipients(underwriter_address)
    underwriter = {
        "registered": chain.get_registered_underwriter(underwriter_address),
        "premiumRecipient": recipients.get("premiumRecipient"),
        "recoveryRecipient": recipients.get("recoveryRecipient"),
    }
    derived = derive_flags(
        job=job,
        hook=hook,
        settlement=settlement,
        dispute=dispute,
        evaluator=evaluator,
        now=now,
    )

    snapshot_payload: dict[str, Any] = {
        "job": {
            **job,
            "kind": job_kind,
        },
        "lineage": lineage,
        "hook": hook,
        "settlement": settlement,
        "dispute": dispute,
        "underwriter": underwriter,
        "evaluator": evaluator,
        "derived": derived,
    }
    orchestration = derive_orchestration(snapshot_payload, now=now)

    return UnderwritingJobSnapshot(
        chain_id=chain.get_chain_id(),
        as_of_block=latest_block,
        job_id=job_id,
        settlement_job_id=settlement_job_id,
        job=snapshot_payload["job"],
        lineage=lineage,
        hook=hook,
        settlement=settlement,
        dispute=dispute,
        underwriter=underwriter,
        derived=derived,
        orchestration=orchestration,
    )
