from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.db.session import get_db_session
from app.services.query_disputes import list_dispute_rows

router = APIRouter(tags=["disputes"])
DISPUTE_STATUSES = {"open", "resolved", "none"}


@router.get("/underwriting/disputes")
def list_disputes(
    status: str | None = None,
    client: str | None = None,
    provider: str | None = None,
    underwriter: str | None = None,
    jobId: int | None = None,
    settlementJobId: int | None = None,
    db: Session = Depends(get_db_session),
) -> dict[str, object]:
    if status is not None and status not in DISPUTE_STATUSES:
        raise HTTPException(status_code=422, detail="invalid dispute status filter")
    return {
        "items": list_dispute_rows(
            db,
            status=status,
            client=client,
            provider=provider,
            underwriter=underwriter,
            job_id=jobId,
            settlement_job_id=settlementJobId,
        )
    }
