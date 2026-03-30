from __future__ import annotations

from datetime import datetime

from sqlalchemy import BigInteger, Boolean, DateTime, Index, JSON, String, Text, func
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.orm import Mapped, mapped_column

from app.db.base import Base

JSON_VARIANT = JSON().with_variant(JSONB(astext_type=Text()), "postgresql")


class SyncStateRow(Base):
    __tablename__ = "sync_state"

    key: Mapped[str] = mapped_column(String(128), primary_key=True)
    value: Mapped[dict[str, object]] = mapped_column(JSON_VARIANT, nullable=False, default=dict)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class UnderwritingJobSnapshotRow(Base):
    __tablename__ = "underwriting_job_snapshots"
    __table_args__ = (
        Index("ix_underwriting_job_snapshots_job_status", "job_status"),
        Index("ix_underwriting_job_snapshots_sidecar_state", "sidecar_state"),
        Index("ix_underwriting_job_snapshots_settlement_state", "settlement_state"),
        Index("ix_underwriting_job_snapshots_underwriter", "underwriter"),
        Index("ix_underwriting_job_snapshots_client", "client"),
        Index("ix_underwriting_job_snapshots_provider", "provider"),
    )

    job_id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=False)
    settlement_job_id: Mapped[int | None] = mapped_column(BigInteger, index=True)
    parent_job_id: Mapped[int | None] = mapped_column(BigInteger, index=True)
    active_close_job_id: Mapped[int | None] = mapped_column(BigInteger)
    root_job_id: Mapped[int | None] = mapped_column(BigInteger, index=True)
    is_awaiting_close: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    allow_close_job: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    chain_id: Mapped[int] = mapped_column(BigInteger, nullable=False)
    job_status: Mapped[str] = mapped_column(String(64), nullable=False)
    sidecar_state: Mapped[str | None] = mapped_column(String(64))
    settlement_state: Mapped[str | None] = mapped_column(String(64))
    dispute_status: Mapped[str | None] = mapped_column(String(64))
    next_action_role: Mapped[str | None] = mapped_column(String(64))
    next_action_reason: Mapped[str | None] = mapped_column(Text)
    next_action_deadline: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    client_action_required: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    provider_action_required: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    underwriter_action_required: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    client: Mapped[str | None] = mapped_column(String(42))
    provider: Mapped[str | None] = mapped_column(String(42))
    underwriter: Mapped[str | None] = mapped_column(String(42))
    payment_token: Mapped[str | None] = mapped_column(String(42))
    expired_at: Mapped[int | None] = mapped_column(BigInteger)
    submitted_at: Mapped[int | None] = mapped_column(BigInteger)
    as_of_block: Mapped[int] = mapped_column(BigInteger, nullable=False)
    snapshot_json: Mapped[dict[str, object]] = mapped_column(JSON_VARIANT, nullable=False, default=dict)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class UnderwritingTimelineEventRow(Base):
    __tablename__ = "underwriting_timeline_events"
    __table_args__ = (
        Index("ix_underwriting_timeline_events_job_id", "job_id"),
        Index("ix_underwriting_timeline_events_settlement_job_id", "settlement_job_id"),
        Index("ix_underwriting_timeline_events_block_number_log_index", "block_number", "log_index"),
    )

    chain_id: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    transaction_hash: Mapped[str] = mapped_column(String(66), primary_key=True)
    log_index: Mapped[int] = mapped_column(BigInteger, primary_key=True)
    job_id: Mapped[int] = mapped_column(BigInteger, nullable=False)
    settlement_job_id: Mapped[int | None] = mapped_column(BigInteger)
    block_number: Mapped[int] = mapped_column(BigInteger, nullable=False)
    source: Mapped[str] = mapped_column(String(64), nullable=False)
    event_name: Mapped[str] = mapped_column(String(128), nullable=False)
    payload_json: Mapped[dict[str, object]] = mapped_column(JSON_VARIANT, nullable=False, default=dict)
    inserted_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )


class UnderwritingDisputeRow(Base):
    __tablename__ = "underwriting_disputes"
    __table_args__ = (
        Index("ix_underwriting_disputes_status", "status"),
        Index("ix_underwriting_disputes_settlement_job_id", "settlement_job_id"),
        Index("ix_underwriting_disputes_job_id", "job_id"),
    )

    settlement_job_id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=False)
    job_id: Mapped[int] = mapped_column(BigInteger, nullable=False)
    status: Mapped[str] = mapped_column(String(64), nullable=False)
    reason_code: Mapped[str | None] = mapped_column(String(66))
    opened_by: Mapped[str | None] = mapped_column(String(42))
    opened_at: Mapped[int | None] = mapped_column(BigInteger)
    resolved_at: Mapped[int | None] = mapped_column(BigInteger)
    slash_amount_usdc: Mapped[int | None] = mapped_column(BigInteger)
    tx_hash: Mapped[str | None] = mapped_column(String(66))
    dispute_json: Mapped[dict[str, object]] = mapped_column(JSON_VARIANT, nullable=False, default=dict)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class UnderwritingActionRequestRow(Base):
    __tablename__ = "underwriting_action_requests"
    __table_args__ = (
        Index("ix_underwriting_action_requests_job_id", "job_id"),
        Index("ix_underwriting_action_requests_status", "status"),
    )

    request_id: Mapped[str] = mapped_column(String(64), primary_key=True)
    job_id: Mapped[int] = mapped_column(BigInteger, nullable=False)
    settlement_job_id: Mapped[int | None] = mapped_column(BigInteger)
    actor_role: Mapped[str] = mapped_column(String(64), nullable=False)
    action_type: Mapped[str] = mapped_column(String(64), nullable=False)
    status: Mapped[str] = mapped_column(String(64), nullable=False)
    request_payload_json: Mapped[dict[str, object]] = mapped_column(JSON_VARIANT, nullable=False, default=dict)
    signed_payload_json: Mapped[dict[str, object] | None] = mapped_column(JSON_VARIANT)
    tx_hash: Mapped[str | None] = mapped_column(String(66))
    error_message: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )


class UnderwriterRow(Base):
    __tablename__ = "underwriters"

    address: Mapped[str] = mapped_column(String(42), primary_key=True)
    registered: Mapped[bool] = mapped_column(Boolean, nullable=False, default=False)
    premium_recipient: Mapped[str | None] = mapped_column(String(42))
    recovery_recipient: Mapped[str | None] = mapped_column(String(42))
    last_checked_block: Mapped[int | None] = mapped_column(BigInteger)
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        server_default=func.now(),
        onupdate=func.now(),
    )
