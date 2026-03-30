from __future__ import annotations

from sqlalchemy.orm import Session

from app.chain.client import UnderwritingChainReader
from app.db.models import SyncStateRow, UnderwritingJobSnapshotRow
from app.services.hydrate_snapshot import hydrate_underwriting_snapshot
from app.services.upsert_snapshot import set_sync_state, upsert_snapshot
from app.services.upsert_timeline import upsert_timeline_events


def _last_indexed_block(db: Session) -> int:
    state = db.get(SyncStateRow, "lastIndexedBlock")
    if state is None:
        return 0
    return int(state.value.get("block", 0))


def run_incremental_sync(*, chain: UnderwritingChainReader, db: Session) -> None:
    from_block = _last_indexed_block(db)
    settlement_job_ids = [
        value
        for (value,) in db.query(UnderwritingJobSnapshotRow.settlement_job_id)
        .distinct()
        .filter(UnderwritingJobSnapshotRow.settlement_job_id.is_not(None))
        .all()
    ]
    batch = chain.get_incremental_log_batch(from_block, settlement_job_ids=settlement_job_ids)
    touched_job_ids: set[int] = set()

    for log in batch["logs"]:
        touched_job_ids.update(chain.resolve_job_ids_for_log(log))
        if log["event_name"] == "UnderwriterRecipientsSet":
            underwriter = log["payload_json"].get("underwriter")
            if underwriter:
                touched_job_ids.update(
                    job_id
                    for (job_id,) in db.query(UnderwritingJobSnapshotRow.job_id)
                    .filter(UnderwritingJobSnapshotRow.underwriter == underwriter)
                    .all()
                )

    for job_id in sorted(touched_job_ids):
        job = chain.get_job(job_id)
        if job.get("hook", "").lower() != chain.get_underwriting_hook_address().lower():
            continue

        snapshot = hydrate_underwriting_snapshot(job_id=job_id, chain=chain)
        upsert_snapshot(db, snapshot)
        upsert_timeline_events(
            db,
            chain.get_timeline_events(job_id, snapshot.settlement_job_id, to_block=batch["head_block"]),
        )

    set_sync_state(db, key="lastIndexedBlock", value={"block": batch["head_block"]})
    db.commit()
