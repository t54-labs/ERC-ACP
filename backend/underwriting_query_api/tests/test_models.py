from app.db.base import Base
from app.db.models import (
    SyncStateRow,
    UnderwriterRow,
    UnderwritingActionRequestRow,
    UnderwritingDisputeRow,
    UnderwritingJobSnapshotRow,
    UnderwritingTimelineEventRow,
)


def test_snapshot_model_exposes_search_columns():
    columns = UnderwritingJobSnapshotRow.__table__.columns.keys()

    assert "job_id" in columns
    assert "sidecar_state" in columns
    assert "snapshot_json" in columns


def test_metadata_exposes_required_tables_and_indexes():
    tables = Base.metadata.tables

    assert SyncStateRow.__tablename__ in tables
    assert UnderwritingJobSnapshotRow.__tablename__ in tables
    assert UnderwritingTimelineEventRow.__tablename__ in tables
    assert UnderwritingDisputeRow.__tablename__ in tables
    assert UnderwritingActionRequestRow.__tablename__ in tables
    assert UnderwriterRow.__tablename__ in tables

    timeline_indexes = {index.name for index in UnderwritingTimelineEventRow.__table__.indexes}
    dispute_primary_keys = list(UnderwritingDisputeRow.__table__.primary_key.columns.keys())

    assert "ix_underwriting_timeline_events_block_number_log_index" in timeline_indexes
    assert dispute_primary_keys == ["settlement_job_id"]
    assert UnderwritingJobSnapshotRow.__table__.c.job_id.autoincrement is False
    assert UnderwritingDisputeRow.__table__.c.settlement_job_id.autoincrement is False
