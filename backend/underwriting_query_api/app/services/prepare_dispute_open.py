from __future__ import annotations

from uuid import uuid4

from sqlalchemy.orm import Session

from app.db.models import UnderwritingActionRequestRow, UnderwritingJobSnapshotRow

ACTION_TYPE = "open_dispute"
ACTOR_ROLE = "client"
ZERO_REASON_CODE = "0x" + "00" * 32


def prepare_dispute_open(
    db: Session,
    job_id: int,
    *,
    reason_code: str | None = None,
) -> UnderwritingActionRequestRow:
    row = db.get(UnderwritingJobSnapshotRow, job_id)
    if row is None:
        raise LookupError("job not found")
    if row.settlement_job_id is None:
        raise ValueError("job is missing settlement linkage")
    if row.job_status != "Completed" or row.settlement_state != "SuccessPendingRelease" or not row.client_action_required:
        raise ValueError("success dispute open is not currently allowed")

    action_job_id = row.settlement_job_id
    request_payload = {
        "contract": "UnderwritingSettlementCoordinator",
        "method": "openSuccessDispute",
        "signerRole": ACTOR_ROLE,
        "args": {
            "jobId": action_job_id,
            "reasonCode": reason_code or ZERO_REASON_CODE,
        },
    }
    request = UnderwritingActionRequestRow(
        request_id=uuid4().hex,
        job_id=row.job_id,
        settlement_job_id=row.settlement_job_id,
        actor_role=ACTOR_ROLE,
        action_type=ACTION_TYPE,
        status="prepared",
        request_payload_json=request_payload,
    )
    db.add(request)
    db.commit()
    db.refresh(request)
    return request
