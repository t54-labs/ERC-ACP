"""add snapshot lookup indexes

Revision ID: 0002_snapshot_indexes
Revises: 0001_underwriting_query
Create Date: 2026-03-30 00:00:01.000000
"""

from __future__ import annotations

from alembic import op

revision = "0002_snapshot_indexes"
down_revision = "0001_underwriting_query"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.create_index("ix_underwriting_job_snapshots_dispute_status", "underwriting_job_snapshots", ["dispute_status"])
    op.create_index("ix_underwriting_job_snapshots_next_action_role", "underwriting_job_snapshots", ["next_action_role"])


def downgrade() -> None:
    op.drop_index("ix_underwriting_job_snapshots_next_action_role", table_name="underwriting_job_snapshots")
    op.drop_index("ix_underwriting_job_snapshots_dispute_status", table_name="underwriting_job_snapshots")
