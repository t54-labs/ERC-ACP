from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.db.session import get_db_session
from app.services.query_jobs import (
    get_dispute_row_for_job,
    get_job_snapshot,
    get_related_job_view,
    list_job_snapshots,
    serialize_dispute_row,
    serialize_snapshot_row,
)
from app.services.query_timeline import list_timeline_events

router = APIRouter(tags=["jobs"])


@router.get("/underwriting/jobs/{job_id}")
def get_job(job_id: int, db: Session = Depends(get_db_session)) -> dict[str, object]:
    row = get_job_snapshot(db, job_id)
    if row is None:
        raise HTTPException(status_code=404, detail="job not found")
    return serialize_snapshot_row(row)


@router.get("/underwriting/jobs")
def list_jobs(
    status: str | None = None,
    sidecarState: str | None = None,
    settlementState: str | None = None,
    parentJobId: int | None = None,
    rootJobId: int | None = None,
    isAwaitingClose: bool | None = None,
    nextActionRole: str | None = None,
    clientActionRequired: bool | None = None,
    providerActionRequired: bool | None = None,
    underwriterActionRequired: bool | None = None,
    underwriter: str | None = None,
    client: str | None = None,
    provider: str | None = None,
    paymentToken: str | None = None,
    db: Session = Depends(get_db_session),
) -> dict[str, object]:
    rows = list_job_snapshots(
        db,
        status=status,
        sidecar_state=sidecarState,
        settlement_state=settlementState,
        parent_job_id=parentJobId,
        root_job_id=rootJobId,
        is_awaiting_close=isAwaitingClose,
        next_action_role=nextActionRole,
        client_action_required=clientActionRequired,
        provider_action_required=providerActionRequired,
        underwriter_action_required=underwriterActionRequired,
        underwriter=underwriter,
        client=client,
        provider=provider,
        payment_token=paymentToken,
    )
    return {
        "items": [serialize_snapshot_row(row) for row in rows],
        "asOfBlock": max((row.as_of_block for row in rows), default=0),
    }


@router.get("/underwriting/jobs/{job_id}/related")
def get_related(job_id: int, db: Session = Depends(get_db_session)) -> dict[str, object]:
    view = get_related_job_view(db, job_id)
    if view is None:
        raise HTTPException(status_code=404, detail="job not found")
    return view


@router.get("/underwriting/jobs/{job_id}/timeline")
def get_timeline(job_id: int, db: Session = Depends(get_db_session)) -> dict[str, object]:
    row = get_job_snapshot(db, job_id)
    if row is None:
        raise HTTPException(status_code=404, detail="job not found")
    return {"items": list_timeline_events(db, job_id)}


@router.get("/underwriting/jobs/{job_id}/dispute")
def get_job_dispute(job_id: int, db: Session = Depends(get_db_session)) -> dict[str, object]:
    row = get_dispute_row_for_job(db, job_id)
    if row is None:
        raise HTTPException(status_code=404, detail="dispute not found")
    return serialize_dispute_row(row)
