from __future__ import annotations

from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.db.models import UnderwritingDisputeRow, UnderwritingJobSnapshotRow
from app.services.query_jobs import serialize_dispute_row


def list_dispute_rows(
    db: Session,
    *,
    status: str | None = None,
    client: str | None = None,
    provider: str | None = None,
    underwriter: str | None = None,
    job_id: int | None = None,
    settlement_job_id: int | None = None,
) -> list[dict[str, Any]]:
    stmt = select(UnderwritingDisputeRow, UnderwritingJobSnapshotRow).join(
        UnderwritingJobSnapshotRow,
        UnderwritingJobSnapshotRow.settlement_job_id == UnderwritingDisputeRow.settlement_job_id,
    )
    if status is not None:
        stmt = stmt.where(UnderwritingDisputeRow.status == status)
    if client is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.client == client)
    if provider is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.provider == provider)
    if underwriter is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.underwriter == underwriter)
    if job_id is not None:
        stmt = stmt.where(UnderwritingDisputeRow.job_id == job_id)
    if settlement_job_id is not None:
        stmt = stmt.where(UnderwritingDisputeRow.settlement_job_id == settlement_job_id)
    rows = db.execute(stmt).all()
    seen: set[int] = set()
    items = []
    for dispute_row, _snapshot_row in rows:
        if dispute_row.settlement_job_id in seen:
            continue
        seen.add(dispute_row.settlement_job_id)
        items.append(serialize_dispute_row(dispute_row))
    return items
