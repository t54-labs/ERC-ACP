from __future__ import annotations

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.db.session import get_db_session
from app.services.query_disputes import list_dispute_rows

router = APIRouter(tags=["disputes"])


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
