from __future__ import annotations

from datetime import UTC, datetime
from typing import Any

from app.schemas.snapshots import UnderwritingJobSnapshot


def _timestamp_to_datetime(value: Any) -> datetime | None:
    if not value:
        return None
    if isinstance(value, datetime):
        return value
    return datetime.fromtimestamp(int(value), tz=UTC)


def build_snapshot_row_payload(snapshot: UnderwritingJobSnapshot) -> dict[str, Any]:
    payload = snapshot.model_dump(mode="json")
    return {
        "job_id": snapshot.job_id,
        "settlement_job_id": snapshot.settlement_job_id,
        "parent_job_id": snapshot.lineage.get("parentJobId"),
        "active_close_job_id": snapshot.lineage.get("activeCloseJobId"),
        "root_job_id": snapshot.lineage.get("rootJobId"),
        "is_awaiting_close": bool(snapshot.lineage.get("isAwaitingClose", False)),
        "allow_close_job": bool(snapshot.lineage.get("allowCloseJob", False)),
        "chain_id": snapshot.chain_id,
        "job_status": snapshot.job.get("status"),
        "sidecar_state": snapshot.hook.get("sidecarState"),
        "settlement_state": snapshot.settlement.get("state"),
        "dispute_status": snapshot.dispute.get("status"),
        "next_action_role": snapshot.orchestration.get("nextActionRole"),
        "next_action_reason": snapshot.orchestration.get("nextActionReason"),
        "next_action_deadline": _timestamp_to_datetime(snapshot.orchestration.get("nextActionDeadline")),
        "client_action_required": bool(snapshot.orchestration.get("clientActionRequired", False)),
        "provider_action_required": bool(snapshot.orchestration.get("providerActionRequired", False)),
        "underwriter_action_required": bool(snapshot.orchestration.get("underwriterActionRequired", False)),
        "client": snapshot.job.get("client"),
        "provider": snapshot.job.get("provider"),
        "underwriter": snapshot.hook.get("underwriter"),
        "payment_token": snapshot.job.get("paymentToken"),
        "expired_at": snapshot.job.get("expiredAt"),
        "submitted_at": snapshot.hook.get("submittedAt"),
        "as_of_block": snapshot.as_of_block,
        "snapshot_json": payload,
    }


def build_dispute_row_payload(snapshot: UnderwritingJobSnapshot) -> dict[str, Any]:
    stable_job_id = snapshot.lineage.get("rootJobId") or snapshot.settlement_job_id or snapshot.job_id
    return {
        "settlement_job_id": snapshot.settlement_job_id,
        "job_id": stable_job_id,
        "status": snapshot.dispute.get("status"),
        "reason_code": snapshot.dispute.get("reasonCode"),
        "opened_by": snapshot.dispute.get("openedBy"),
        "opened_at": snapshot.dispute.get("openedAt"),
        "resolved_at": snapshot.dispute.get("resolvedAt"),
        "slash_amount_usdc": snapshot.dispute.get("slashAmountUsdc"),
        "tx_hash": snapshot.dispute.get("txHash"),
        "dispute_json": snapshot.dispute,
    }
