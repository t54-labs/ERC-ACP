from __future__ import annotations

from typing import Any

from sqlalchemy.orm import Session

from app.db.models import UnderwritingActionRequestRow, UnderwritingJobSnapshotRow

ACTION_TYPE = "open_dispute"


def submit_dispute_open(
    db: Session,
    job_id: int,
    *,
    request_id: str,
    signed_payload: dict[str, Any] | None,
    tx_hash: str | None,
) -> UnderwritingActionRequestRow:
    snapshot = db.get(UnderwritingJobSnapshotRow, job_id)
    if snapshot is None:
        raise LookupError("job not found")
    if (
        snapshot.settlement_job_id is None
        or snapshot.job_status != "Completed"
        or snapshot.settlement_state != "SuccessPendingRelease"
        or not snapshot.client_action_required
    ):
        raise ValueError("success dispute open is not currently allowed")

    row = db.get(UnderwritingActionRequestRow, request_id)
    if row is None or row.job_id != job_id or row.action_type != ACTION_TYPE:
        raise LookupError("action request not found")
    if row.status != "prepared":
        raise ValueError("action request is not ready for submission")

    row.signed_payload_json = signed_payload or {}
    row.tx_hash = tx_hash
    row.status = "submitted"
    row.error_message = None
    db.commit()
    db.refresh(row)
    return row
