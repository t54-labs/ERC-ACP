"""create underwriting query tables

Revision ID: 0001_underwriting_query
Revises:
Create Date: 2026-03-30 00:00:00.000000
"""

from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "0001_underwriting_query"
down_revision = None
branch_labels = None
depends_on = None

JSONB = postgresql.JSONB(astext_type=sa.Text())


def upgrade() -> None:
    op.create_table(
        "sync_state",
        sa.Column("key", sa.String(length=128), nullable=False),
        sa.Column("value", JSONB, nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("key", name="pk_sync_state"),
    )

    op.create_table(
        "underwriting_job_snapshots",
        sa.Column("job_id", sa.BigInteger(), nullable=False),
        sa.Column("settlement_job_id", sa.BigInteger(), nullable=True),
        sa.Column("parent_job_id", sa.BigInteger(), nullable=True),
        sa.Column("active_close_job_id", sa.BigInteger(), nullable=True),
        sa.Column("root_job_id", sa.BigInteger(), nullable=True),
        sa.Column("is_awaiting_close", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("allow_close_job", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("chain_id", sa.BigInteger(), nullable=False),
        sa.Column("job_status", sa.String(length=64), nullable=False),
        sa.Column("sidecar_state", sa.String(length=64), nullable=True),
        sa.Column("settlement_state", sa.String(length=64), nullable=True),
        sa.Column("dispute_status", sa.String(length=64), nullable=True),
        sa.Column("next_action_role", sa.String(length=64), nullable=True),
        sa.Column("next_action_reason", sa.Text(), nullable=True),
        sa.Column("next_action_deadline", sa.DateTime(timezone=True), nullable=True),
        sa.Column("client_action_required", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("provider_action_required", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("underwriter_action_required", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("client", sa.String(length=42), nullable=True),
        sa.Column("provider", sa.String(length=42), nullable=True),
        sa.Column("underwriter", sa.String(length=42), nullable=True),
        sa.Column("payment_token", sa.String(length=42), nullable=True),
        sa.Column("expired_at", sa.BigInteger(), nullable=True),
        sa.Column("submitted_at", sa.BigInteger(), nullable=True),
        sa.Column("as_of_block", sa.BigInteger(), nullable=False),
        sa.Column("snapshot_json", JSONB, nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("job_id", name="pk_underwriting_job_snapshots"),
    )
    op.create_index("ix_underwriting_job_snapshots_job_status", "underwriting_job_snapshots", ["job_status"])
    op.create_index("ix_underwriting_job_snapshots_sidecar_state", "underwriting_job_snapshots", ["sidecar_state"])
    op.create_index("ix_underwriting_job_snapshots_settlement_state", "underwriting_job_snapshots", ["settlement_state"])
    op.create_index("ix_underwriting_job_snapshots_underwriter", "underwriting_job_snapshots", ["underwriter"])
    op.create_index("ix_underwriting_job_snapshots_client", "underwriting_job_snapshots", ["client"])
    op.create_index("ix_underwriting_job_snapshots_provider", "underwriting_job_snapshots", ["provider"])
    op.create_index("ix_underwriting_job_snapshots_settlement_job_id", "underwriting_job_snapshots", ["settlement_job_id"])
    op.create_index("ix_underwriting_job_snapshots_parent_job_id", "underwriting_job_snapshots", ["parent_job_id"])
    op.create_index("ix_underwriting_job_snapshots_root_job_id", "underwriting_job_snapshots", ["root_job_id"])

    op.create_table(
        "underwriting_timeline_events",
        sa.Column("chain_id", sa.BigInteger(), nullable=False),
        sa.Column("transaction_hash", sa.String(length=66), nullable=False),
        sa.Column("log_index", sa.BigInteger(), nullable=False),
        sa.Column("job_id", sa.BigInteger(), nullable=False),
        sa.Column("settlement_job_id", sa.BigInteger(), nullable=True),
        sa.Column("block_number", sa.BigInteger(), nullable=False),
        sa.Column("source", sa.String(length=64), nullable=False),
        sa.Column("event_name", sa.String(length=128), nullable=False),
        sa.Column("payload_json", JSONB, nullable=False),
        sa.Column("inserted_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("chain_id", "transaction_hash", "log_index", name="pk_underwriting_timeline_events"),
    )
    op.create_index("ix_underwriting_timeline_events_job_id", "underwriting_timeline_events", ["job_id"])
    op.create_index(
        "ix_underwriting_timeline_events_settlement_job_id",
        "underwriting_timeline_events",
        ["settlement_job_id"],
    )
    op.create_index(
        "ix_underwriting_timeline_events_block_number_log_index",
        "underwriting_timeline_events",
        ["block_number", "log_index"],
    )

    op.create_table(
        "underwriting_disputes",
        sa.Column("job_id", sa.BigInteger(), nullable=False),
        sa.Column("settlement_job_id", sa.BigInteger(), nullable=True),
        sa.Column("status", sa.String(length=64), nullable=False),
        sa.Column("reason_code", sa.String(length=66), nullable=True),
        sa.Column("opened_by", sa.String(length=42), nullable=True),
        sa.Column("opened_at", sa.BigInteger(), nullable=True),
        sa.Column("resolved_at", sa.BigInteger(), nullable=True),
        sa.Column("slash_amount_usdc", sa.BigInteger(), nullable=True),
        sa.Column("tx_hash", sa.String(length=66), nullable=True),
        sa.Column("dispute_json", JSONB, nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("job_id", name="pk_underwriting_disputes"),
    )
    op.create_index("ix_underwriting_disputes_status", "underwriting_disputes", ["status"])
    op.create_index("ix_underwriting_disputes_settlement_job_id", "underwriting_disputes", ["settlement_job_id"])

    op.create_table(
        "underwriting_action_requests",
        sa.Column("request_id", sa.String(length=64), nullable=False),
        sa.Column("job_id", sa.BigInteger(), nullable=False),
        sa.Column("settlement_job_id", sa.BigInteger(), nullable=True),
        sa.Column("actor_role", sa.String(length=64), nullable=False),
        sa.Column("action_type", sa.String(length=64), nullable=False),
        sa.Column("status", sa.String(length=64), nullable=False),
        sa.Column("request_payload_json", JSONB, nullable=False),
        sa.Column("signed_payload_json", JSONB, nullable=True),
        sa.Column("tx_hash", sa.String(length=66), nullable=True),
        sa.Column("error_message", sa.Text(), nullable=True),
        sa.Column("created_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("request_id", name="pk_underwriting_action_requests"),
    )
    op.create_index("ix_underwriting_action_requests_job_id", "underwriting_action_requests", ["job_id"])
    op.create_index("ix_underwriting_action_requests_status", "underwriting_action_requests", ["status"])

    op.create_table(
        "underwriters",
        sa.Column("address", sa.String(length=42), nullable=False),
        sa.Column("registered", sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column("premium_recipient", sa.String(length=42), nullable=True),
        sa.Column("recovery_recipient", sa.String(length=42), nullable=True),
        sa.Column("last_checked_block", sa.BigInteger(), nullable=True),
        sa.Column("updated_at", sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.PrimaryKeyConstraint("address", name="pk_underwriters"),
    )


def downgrade() -> None:
    op.drop_table("underwriters")
    op.drop_index("ix_underwriting_action_requests_status", table_name="underwriting_action_requests")
    op.drop_index("ix_underwriting_action_requests_job_id", table_name="underwriting_action_requests")
    op.drop_table("underwriting_action_requests")
    op.drop_index("ix_underwriting_disputes_settlement_job_id", table_name="underwriting_disputes")
    op.drop_index("ix_underwriting_disputes_status", table_name="underwriting_disputes")
    op.drop_table("underwriting_disputes")
    op.drop_index("ix_underwriting_timeline_events_block_number_log_index", table_name="underwriting_timeline_events")
    op.drop_index("ix_underwriting_timeline_events_settlement_job_id", table_name="underwriting_timeline_events")
    op.drop_index("ix_underwriting_timeline_events_job_id", table_name="underwriting_timeline_events")
    op.drop_table("underwriting_timeline_events")
    op.drop_index("ix_underwriting_job_snapshots_root_job_id", table_name="underwriting_job_snapshots")
    op.drop_index("ix_underwriting_job_snapshots_parent_job_id", table_name="underwriting_job_snapshots")
    op.drop_index("ix_underwriting_job_snapshots_settlement_job_id", table_name="underwriting_job_snapshots")
    op.drop_index("ix_underwriting_job_snapshots_provider", table_name="underwriting_job_snapshots")
    op.drop_index("ix_underwriting_job_snapshots_client", table_name="underwriting_job_snapshots")
    op.drop_index("ix_underwriting_job_snapshots_underwriter", table_name="underwriting_job_snapshots")
    op.drop_index("ix_underwriting_job_snapshots_settlement_state", table_name="underwriting_job_snapshots")
    op.drop_index("ix_underwriting_job_snapshots_sidecar_state", table_name="underwriting_job_snapshots")
    op.drop_index("ix_underwriting_job_snapshots_job_status", table_name="underwriting_job_snapshots")
    op.drop_table("underwriting_job_snapshots")
    op.drop_table("sync_state")
