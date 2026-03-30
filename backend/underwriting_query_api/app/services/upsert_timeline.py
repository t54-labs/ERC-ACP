from __future__ import annotations

from typing import Any

from sqlalchemy.orm import Session

from app.db.models import UnderwritingTimelineEventRow


def upsert_timeline_events(db: Session, events: list[dict[str, Any]]) -> None:
    for event in events:
        db.merge(
            UnderwritingTimelineEventRow(
                chain_id=event["chain_id"],
                job_id=event["job_id"],
                settlement_job_id=event.get("settlement_job_id"),
                block_number=event["block_number"],
                transaction_hash=event["transaction_hash"],
                log_index=event["log_index"],
                source=event["source"],
                event_name=event["event_name"],
                payload_json=event["payload_json"],
            )
        )
