from __future__ import annotations

from sqlalchemy.orm import Session

from app.chain.client import UnderwritingChainReader
from app.services.hydrate_snapshot import hydrate_underwriting_snapshot
from app.services.upsert_snapshot import set_sync_state, upsert_snapshot
from app.services.upsert_timeline import upsert_timeline_events


def run_backfill(*, chain: UnderwritingChainReader, db: Session) -> None:
    for job_id in range(1, chain.get_job_counter() + 1):
        job = chain.get_job(job_id)
        if job.get("hook", "").lower() != chain.get_underwriting_hook_address().lower():
            continue

        snapshot = hydrate_underwriting_snapshot(job_id=job_id, chain=chain)
        upsert_snapshot(db, snapshot)
        upsert_timeline_events(db, chain.get_timeline_events(job_id, snapshot.settlement_job_id))

    set_sync_state(db, key="lastIndexedBlock", value={"block": chain.get_latest_block()})
    db.commit()
