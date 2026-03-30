from __future__ import annotations

from uuid import uuid4

from sqlalchemy.orm import Session

from app.db.models import UnderwritingActionRequestRow, UnderwritingJobSnapshotRow

ACTION_TYPE = "resolve_dispute_slash"
ACTOR_ROLE = "underwriter"


def prepare_slash_resolution(db: Session, job_id: int) -> UnderwritingActionRequestRow:
    row = db.get(UnderwritingJobSnapshotRow, job_id)
    if row is None:
        raise LookupError("job not found")
    if row.settlement_job_id is None:
        raise ValueError("job is missing settlement linkage")
    if row.job_status != "Completed" or row.settlement_state != "DisputeOpen" or not row.underwriter_action_required:
        raise ValueError("dispute slash resolution is not currently allowed")

    snapshot = row.snapshot_json
    settlement = snapshot.get("settlement", {})
    dispute = snapshot.get("dispute", {})
    job = snapshot.get("job", {})
    escrow = settlement.get("escrow")
    action_job_id = row.settlement_job_id
    request_payload = {
        "contract": "UnderwritingSettlementCoordinator",
        "method": "applySuccessDisputeSlash",
        "signerRole": ACTOR_ROLE,
        "requiredUserInput": ["slashAmountUsdc", "validUntil", "nonce"],
        "args": {
            "jobId": action_job_id,
            "attestation": {
                "settlementJobId": row.settlement_job_id,
                "safe": escrow,
                "user": job.get("client"),
                "merchant": escrow,
                "slashAmountUsdc": None,
                "reasonCode": dispute.get("reasonCode"),
                "validUntil": None,
                "nonce": None,
            },
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
