from __future__ import annotations

from sqlalchemy.orm import Session

from app.services.query_jobs import get_timeline_rows, serialize_timeline_row


def list_timeline_events(db: Session, job_id: int) -> list[dict[str, object]]:
    return [serialize_timeline_row(row) for row in get_timeline_rows(db, job_id)]
