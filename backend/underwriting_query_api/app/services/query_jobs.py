from __future__ import annotations

from collections.abc import Callable
from typing import Any

from sqlalchemy import select
from sqlalchemy.orm import Session

from app.chain.client import UnderwritingChainReader
from app.db.models import UnderwritingDisputeRow, UnderwritingJobSnapshotRow, UnderwritingTimelineEventRow
from app.services.hydrate_snapshot import NonUnderwritingJobError, hydrate_underwriting_snapshot
from app.services.upsert_snapshot import upsert_snapshot


def serialize_snapshot_row(row: UnderwritingJobSnapshotRow) -> dict[str, Any]:
    snapshot = row.snapshot_json
    return {
        "chainId": row.chain_id,
        "asOfBlock": row.as_of_block,
        "jobId": str(row.job_id),
        "settlementJobId": str(row.settlement_job_id),
        "job": snapshot.get("job", {}),
        "lineage": snapshot.get("lineage", {}),
        "hook": snapshot.get("hook", {}),
        "settlement": snapshot.get("settlement", {}),
        "dispute": snapshot.get("dispute", {}),
        "underwriter": snapshot.get("underwriter", {}),
        "derived": snapshot.get("derived", {}),
        "orchestration": snapshot.get("orchestration", {}),
    }


def serialize_timeline_row(row: UnderwritingTimelineEventRow) -> dict[str, Any]:
    return {
        "blockNumber": row.block_number,
        "transactionHash": row.transaction_hash,
        "logIndex": row.log_index,
        "source": row.source,
        "eventName": row.event_name,
        "payload": row.payload_json,
    }


def serialize_dispute_row(row: UnderwritingDisputeRow, *, requested_job_id: int | None = None) -> dict[str, Any]:
    return {
        "jobId": str(requested_job_id or row.job_id),
        "settlementJobId": str(row.settlement_job_id),
        **row.dispute_json,
    }


def get_job_snapshot(
    db: Session,
    job_id: int,
    *,
    refresh_chain_factory: Callable[[], UnderwritingChainReader] | None = None,
) -> UnderwritingJobSnapshotRow | None:
    row = db.get(UnderwritingJobSnapshotRow, job_id)
    if row is not None or refresh_chain_factory is None:
        return row

    chain = refresh_chain_factory()
    snapshot = hydrate_underwriting_snapshot(job_id=job_id, chain=chain)
    upsert_snapshot(db, snapshot)
    db.commit()
    return db.get(UnderwritingJobSnapshotRow, job_id)


def list_job_snapshots(
    db: Session,
    *,
    status: str | None = None,
    sidecar_state: str | None = None,
    settlement_state: str | None = None,
    parent_job_id: int | None = None,
    root_job_id: int | None = None,
    is_awaiting_close: bool | None = None,
    next_action_role: str | None = None,
    client_action_required: bool | None = None,
    provider_action_required: bool | None = None,
    underwriter_action_required: bool | None = None,
    underwriter: str | None = None,
    client: str | None = None,
    provider: str | None = None,
    payment_token: str | None = None,
) -> list[UnderwritingJobSnapshotRow]:
    stmt = select(UnderwritingJobSnapshotRow)
    if status is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.job_status == status)
    if sidecar_state is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.sidecar_state == sidecar_state)
    if settlement_state is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.settlement_state == settlement_state)
    if parent_job_id is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.parent_job_id == parent_job_id)
    if root_job_id is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.root_job_id == root_job_id)
    if is_awaiting_close is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.is_awaiting_close == is_awaiting_close)
    if next_action_role is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.next_action_role == next_action_role)
    if client_action_required is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.client_action_required == client_action_required)
    if provider_action_required is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.provider_action_required == provider_action_required)
    if underwriter_action_required is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.underwriter_action_required == underwriter_action_required)
    if underwriter is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.underwriter == underwriter)
    if client is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.client == client)
    if provider is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.provider == provider)
    if payment_token is not None:
        stmt = stmt.where(UnderwritingJobSnapshotRow.payment_token == payment_token)
    return list(db.scalars(stmt.order_by(UnderwritingJobSnapshotRow.job_id)))


def get_related_job_view(db: Session, job_id: int) -> dict[str, Any] | None:
    row = db.get(UnderwritingJobSnapshotRow, job_id)
    if row is None:
        return None
    return {
        "jobId": str(row.job_id),
        "settlementJobId": str(row.settlement_job_id),
        "lineage": row.snapshot_json.get("lineage", {}),
    }


def get_timeline_rows(db: Session, job_id: int) -> list[UnderwritingTimelineEventRow]:
    row = db.get(UnderwritingJobSnapshotRow, job_id)
    if row is None:
        return []
    stmt = (
        select(UnderwritingTimelineEventRow)
        .where(
            (UnderwritingTimelineEventRow.job_id == job_id)
            | (UnderwritingTimelineEventRow.settlement_job_id == row.settlement_job_id)
        )
        .order_by(UnderwritingTimelineEventRow.block_number, UnderwritingTimelineEventRow.log_index)
    )
    return list(db.scalars(stmt))


def get_dispute_row_for_job(
    db: Session,
    job_id: int,
) -> tuple[UnderwritingDisputeRow, int] | None:
    row = db.get(UnderwritingJobSnapshotRow, job_id)
    if row is None:
        return None
    dispute_row = db.get(UnderwritingDisputeRow, row.settlement_job_id)
    if dispute_row is None:
        return None
    return dispute_row, job_id
