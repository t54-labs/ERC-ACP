from __future__ import annotations

from sqlalchemy.orm import Session

from app.db.models import SyncStateRow, UnderwriterRow, UnderwritingDisputeRow, UnderwritingJobSnapshotRow
from app.schemas.snapshots import UnderwritingJobSnapshot
from app.services.project_snapshot import build_dispute_row_payload, build_snapshot_row_payload


def upsert_snapshot(db: Session, snapshot: UnderwritingJobSnapshot) -> None:
    db.merge(UnderwritingJobSnapshotRow(**build_snapshot_row_payload(snapshot)))
    db.merge(UnderwritingDisputeRow(**build_dispute_row_payload(snapshot)))

    underwriter_address = snapshot.hook.get("underwriter")
    if underwriter_address:
        db.merge(
            UnderwriterRow(
                address=underwriter_address,
                registered=bool(snapshot.underwriter.get("registered", False)),
                premium_recipient=snapshot.underwriter.get("premiumRecipient"),
                recovery_recipient=snapshot.underwriter.get("recoveryRecipient"),
                last_checked_block=snapshot.as_of_block,
            )
        )


def set_sync_state(db: Session, *, key: str, value: dict[str, int]) -> None:
    db.merge(SyncStateRow(key=key, value=value))
