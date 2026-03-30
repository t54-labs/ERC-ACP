from __future__ import annotations

from collections.abc import Callable

from fastapi import APIRouter, Depends, HTTPException, Request
from sqlalchemy.orm import Session

from app.chain.client import JOB_STATUS, SETTLEMENT_STATE, SIDECAR_STATE, UnderwritingChainReader
from app.db.session import get_db_session
from app.services.hydrate_snapshot import NonUnderwritingJobError
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
NEXT_ACTION_ROLES = {"client", "provider", "underwriter"}


def _validate_job_filters(
    *,
    status: str | None,
    sidecar_state: str | None,
    settlement_state: str | None,
    next_action_role: str | None,
) -> None:
    if status is not None and status not in JOB_STATUS:
        raise HTTPException(status_code=422, detail="invalid status filter")
    if sidecar_state is not None and sidecar_state not in SIDECAR_STATE:
        raise HTTPException(status_code=422, detail="invalid sidecarState filter")
    if settlement_state is not None and settlement_state not in SETTLEMENT_STATE:
        raise HTTPException(status_code=422, detail="invalid settlementState filter")
    if next_action_role is not None and next_action_role not in NEXT_ACTION_ROLES:
        raise HTTPException(status_code=422, detail="invalid nextActionRole filter")


@router.get("/underwriting/jobs/{job_id}")
def get_job(job_id: int, request: Request, db: Session = Depends(get_db_session)) -> dict[str, object]:
    chain_reader_factory: Callable[[], UnderwritingChainReader] | None = request.app.state.chain_reader_factory
    try:
        row = get_job_snapshot(db, job_id, refresh_chain_factory=chain_reader_factory)
    except NonUnderwritingJobError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    except Exception as exc:
        raise HTTPException(status_code=404, detail="job not found") from exc
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
    _validate_job_filters(
        status=status,
        sidecar_state=sidecarState,
        settlement_state=settlementState,
        next_action_role=nextActionRole,
    )
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
    result = get_dispute_row_for_job(db, job_id)
    if result is None:
        raise HTTPException(status_code=404, detail="dispute not found")
    row, requested_job_id = result
    return serialize_dispute_row(row, requested_job_id=requested_job_id)
