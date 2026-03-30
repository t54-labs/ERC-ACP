from app.db.models import UnderwritingJobSnapshotRow


def test_snapshot_model_exposes_search_columns():
    columns = UnderwritingJobSnapshotRow.__table__.columns.keys()

    assert "job_id" in columns
    assert "sidecar_state" in columns
    assert "snapshot_json" in columns
