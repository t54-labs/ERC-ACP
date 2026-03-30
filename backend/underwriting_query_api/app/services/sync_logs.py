from __future__ import annotations

from sqlalchemy.orm import Session

from app.chain.client import UnderwritingChainReader
from app.db.models import SyncStateRow
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
    touched_job_ids: set[int] = set()

    for log in chain.get_incremental_logs(from_block):
        touched_job_ids.update(chain.resolve_job_ids_for_log(log))

    for job_id in sorted(touched_job_ids):
        job = chain.get_job(job_id)
        if job.get("hook", "").lower() != chain.get_underwriting_hook_address().lower():
            continue

        snapshot = hydrate_underwriting_snapshot(job_id=job_id, chain=chain)
        upsert_snapshot(db, snapshot)
        upsert_timeline_events(db, chain.get_timeline_events(job_id, snapshot.settlement_job_id))

    set_sync_state(db, key="lastIndexedBlock", value={"block": chain.get_latest_block()})
    db.commit()
