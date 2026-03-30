from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import create_engine
from sqlalchemy.orm import Session, sessionmaker
from sqlalchemy.pool import StaticPool

from app.db.base import Base
from app.config import Settings
from app.db.models import UnderwriterRow, UnderwritingDisputeRow, UnderwritingJobSnapshotRow, UnderwritingTimelineEventRow
from app.main import create_app


@pytest.fixture
def db_session_factory() -> sessionmaker[Session]:
    engine = create_engine(
        "sqlite+pysqlite:///:memory:",
        future=True,
        connect_args={"check_same_thread": False},
        poolclass=StaticPool,
    )
    Base.metadata.create_all(engine)
    try:
        yield sessionmaker(bind=engine, future=True, expire_on_commit=False)
    finally:
        Base.metadata.drop_all(engine)


@pytest.fixture
def db_session(db_session_factory: sessionmaker[Session]) -> Session:
    session = db_session_factory()
    try:
        yield session
    finally:
        session.close()


@pytest.fixture
def client(db_session_factory: sessionmaker[Session]) -> TestClient:
    app = create_app(
        settings=Settings(
            DATABASE_URL="sqlite+pysqlite:///:memory:",
            UNDERWRITING_RPC_URL="mock://underwriting",
            ACP_ADDRESS="0x0000000000000000000000000000000000000000",
            UNDERWRITING_HOOK_ADDRESS="0x0000000000000000000000000000000000000000",
            UNDERWRITING_COORDINATOR_ADDRESS="0x0000000000000000000000000000000000000000",
            UNDERWRITING_EVALUATOR_ADDRESS="0x0000000000000000000000000000000000000000",
            UNDERWRITING_COLLATERAL_MANAGER_ADDRESS="0x0000000000000000000000000000000000000000",
        ),
        session_factory=db_session_factory,
    )
    return TestClient(app)


@pytest.fixture
def seeded_snapshot(db_session: Session) -> UnderwritingJobSnapshotRow:
    snapshot_json = {
        "job": {
            "id": 42,
            "status": "Submitted",
            "paymentToken": "0x0000000000000000000000000000000000000004",
            "client": "0x0000000000000000000000000000000000000001",
            "provider": "0x0000000000000000000000000000000000000002",
        },
        "lineage": {
            "parentJobId": 7,
            "activeCloseJobId": None,
            "rootJobId": 7,
            "isAwaitingClose": False,
            "allowCloseJob": True,
        },
        "hook": {
            "underwriter": "0x0000000000000000000000000000000000000042",
            "sidecarState": "EvidenceSubmitted",
            "submittedAt": 100,
        },
        "settlement": {
            "state": "DisputeOpen",
            "unlockAt": 180,
            "escrow": "0x00000000000000000000000000000000000000ee",
        },
        "dispute": {
            "status": "open",
            "reasonCode": "0x" + "44" * 32,
            "openedBy": "0x0000000000000000000000000000000000000001",
            "openedAt": 130,
            "resolvedAt": None,
            "slashAmountUsdc": None,
            "isOpen": True,
            "txHash": "0x" + "55" * 32,
        },
        "underwriter": {
            "registered": True,
            "premiumRecipient": "0x00000000000000000000000000000000000000f1",
            "recoveryRecipient": "0x00000000000000000000000000000000000000f2",
        },
        "derived": {
            "clientConfirmationOpen": False,
        },
        "orchestration": {
            "nextActionRole": "underwriter",
            "nextActionReason": "adjudicate with complete or reject",
            "nextActionDeadline": 160,
            "clientActionRequired": False,
            "providerActionRequired": False,
            "underwriterActionRequired": True,
        },
    }
    snapshot = UnderwritingJobSnapshotRow(
        job_id=42,
        settlement_job_id=42,
        parent_job_id=7,
        active_close_job_id=None,
        root_job_id=7,
        is_awaiting_close=False,
        allow_close_job=True,
        chain_id=8453,
        job_status="Submitted",
        sidecar_state="EvidenceSubmitted",
        settlement_state="DisputeOpen",
        dispute_status="open",
        next_action_role="underwriter",
        next_action_reason="adjudicate with complete or reject",
        next_action_deadline=None,
        client_action_required=False,
        provider_action_required=False,
        underwriter_action_required=True,
        client="0x0000000000000000000000000000000000000001",
        provider="0x0000000000000000000000000000000000000002",
        underwriter="0x0000000000000000000000000000000000000042",
        payment_token="0x0000000000000000000000000000000000000004",
        expired_at=999999,
        submitted_at=100,
        as_of_block=12_345,
        snapshot_json=snapshot_json,
    )
    db_session.add(snapshot)
    db_session.add(
        UnderwritingDisputeRow(
            settlement_job_id=42,
            job_id=42,
            status="open",
            reason_code="0x" + "44" * 32,
            opened_by="0x0000000000000000000000000000000000000001",
            opened_at=130,
            resolved_at=None,
            slash_amount_usdc=None,
            tx_hash="0x" + "55" * 32,
            dispute_json=snapshot_json["dispute"],
        )
    )
    db_session.add(
        UnderwritingTimelineEventRow(
            chain_id=8453,
            job_id=42,
            settlement_job_id=42,
            block_number=200,
            transaction_hash="0x" + "66" * 32,
            log_index=0,
            source="coordinator",
            event_name="SuccessDisputeOpened",
            payload_json={"reasonCode": "0x" + "44" * 32},
        )
    )
    db_session.add(
        UnderwritingTimelineEventRow(
            chain_id=8453,
            job_id=7,
            settlement_job_id=42,
            block_number=201,
            transaction_hash="0x" + "77" * 32,
            log_index=1,
            source="escrow",
            event_name="DeliveryConfirmationRequested",
            payload_json={"settlementJobId": 42},
        )
    )
    db_session.add(
        UnderwriterRow(
            address="0x0000000000000000000000000000000000000042",
            registered=True,
            premium_recipient="0x00000000000000000000000000000000000000f1",
            recovery_recipient="0x00000000000000000000000000000000000000f2",
            last_checked_block=12_345,
        )
    )
    db_session.commit()
    return snapshot


@pytest.fixture
def seeded_underwriter(seeded_snapshot: UnderwritingJobSnapshotRow, db_session: Session) -> UnderwriterRow:
    return db_session.get(UnderwriterRow, seeded_snapshot.underwriter)


@pytest.fixture
def seeded_close_snapshot(
    db_session: Session,
    seeded_snapshot: UnderwritingJobSnapshotRow,
) -> UnderwritingJobSnapshotRow:
    snapshot_json = {
        "job": {
            "id": 77,
            "status": "Completed",
            "paymentToken": "0x0000000000000000000000000000000000000004",
            "client": "0x0000000000000000000000000000000000000001",
            "provider": "0x0000000000000000000000000000000000000002",
        },
        "lineage": {
            "parentJobId": 42,
            "activeCloseJobId": 77,
            "rootJobId": 42,
            "isAwaitingClose": False,
            "allowCloseJob": False,
        },
        "hook": {
            "underwriter": "0x0000000000000000000000000000000000000042",
            "sidecarState": "SuccessPendingConfirmation",
            "submittedAt": 100,
        },
        "settlement": {
            "state": "DisputeOpen",
            "unlockAt": 180,
            "escrow": "0x00000000000000000000000000000000000000ee",
        },
        "dispute": {
            "status": "open",
            "reasonCode": "0x" + "44" * 32,
            "openedBy": "0x0000000000000000000000000000000000000001",
            "openedAt": 130,
            "resolvedAt": None,
            "slashAmountUsdc": None,
            "isOpen": True,
            "txHash": "0x" + "55" * 32,
        },
        "underwriter": {
            "registered": True,
            "premiumRecipient": "0x00000000000000000000000000000000000000f1",
            "recoveryRecipient": "0x00000000000000000000000000000000000000f2",
        },
        "derived": {},
        "orchestration": {
            "nextActionRole": "underwriter",
            "nextActionReason": "resolve success dispute",
            "nextActionDeadline": 180,
            "clientActionRequired": False,
            "providerActionRequired": False,
            "underwriterActionRequired": True,
        },
    }
    snapshot = UnderwritingJobSnapshotRow(
        job_id=77,
        settlement_job_id=42,
        parent_job_id=42,
        active_close_job_id=77,
        root_job_id=42,
        is_awaiting_close=False,
        allow_close_job=False,
        chain_id=8453,
        job_status="Completed",
        sidecar_state="SuccessPendingConfirmation",
        settlement_state="DisputeOpen",
        dispute_status="open",
        next_action_role="underwriter",
        next_action_reason="resolve success dispute",
        next_action_deadline=None,
        client_action_required=False,
        provider_action_required=False,
        underwriter_action_required=True,
        client="0x0000000000000000000000000000000000000001",
        provider="0x0000000000000000000000000000000000000002",
        underwriter="0x0000000000000000000000000000000000000042",
        payment_token="0x0000000000000000000000000000000000000004",
        expired_at=999999,
        submitted_at=100,
        as_of_block=12_345,
        snapshot_json=snapshot_json,
    )
    db_session.add(snapshot)
    db_session.commit()
    return snapshot


@pytest.fixture
def seeded_disputeable_job(db_session: Session) -> UnderwritingJobSnapshotRow:
    snapshot_json = {
        "job": {
            "id": 88,
            "status": "Completed",
            "paymentToken": "0x0000000000000000000000000000000000000004",
            "client": "0x0000000000000000000000000000000000000001",
            "provider": "0x0000000000000000000000000000000000000002",
        },
        "lineage": {
            "parentJobId": None,
            "activeCloseJobId": None,
            "rootJobId": 88,
            "isAwaitingClose": False,
            "allowCloseJob": False,
        },
        "hook": {
            "underwriter": "0x0000000000000000000000000000000000000042",
            "sidecarState": "SuccessPendingConfirmation",
            "submittedAt": 100,
        },
        "settlement": {
            "state": "SuccessPendingRelease",
            "unlockAt": 180,
            "escrow": "0x00000000000000000000000000000000000000ee",
        },
        "dispute": {
            "status": "none",
            "reasonCode": None,
            "openedBy": None,
            "openedAt": None,
            "resolvedAt": None,
            "slashAmountUsdc": None,
            "isOpen": False,
            "txHash": None,
        },
        "underwriter": {
            "registered": True,
            "premiumRecipient": "0x00000000000000000000000000000000000000f1",
            "recoveryRecipient": "0x00000000000000000000000000000000000000f2",
        },
        "derived": {
            "canOpenSuccessDispute": True,
            "canReleaseCollateral": False,
            "clientConfirmationOpen": False,
        },
        "orchestration": {
            "nextActionRole": "client",
            "nextActionReason": "open dispute before unlock",
            "nextActionDeadline": 180,
            "clientActionRequired": True,
            "providerActionRequired": False,
            "underwriterActionRequired": False,
        },
    }
    snapshot = UnderwritingJobSnapshotRow(
        job_id=88,
        settlement_job_id=88,
        parent_job_id=None,
        active_close_job_id=None,
        root_job_id=88,
        is_awaiting_close=False,
        allow_close_job=False,
        chain_id=8453,
        job_status="Completed",
        sidecar_state="SuccessPendingConfirmation",
        settlement_state="SuccessPendingRelease",
        dispute_status="none",
        next_action_role="client",
        next_action_reason="open dispute before unlock",
        next_action_deadline=None,
        client_action_required=True,
        provider_action_required=False,
        underwriter_action_required=False,
        client="0x0000000000000000000000000000000000000001",
        provider="0x0000000000000000000000000000000000000002",
        underwriter="0x0000000000000000000000000000000000000042",
        payment_token="0x0000000000000000000000000000000000000004",
        expired_at=999999,
        submitted_at=100,
        as_of_block=12_345,
        snapshot_json=snapshot_json,
    )
    db_session.add(snapshot)
    db_session.commit()
    return snapshot


@pytest.fixture
def seeded_open_dispute(db_session: Session) -> UnderwritingJobSnapshotRow:
    snapshot_json = {
        "job": {
            "id": 99,
            "status": "Completed",
            "paymentToken": "0x0000000000000000000000000000000000000004",
            "client": "0x0000000000000000000000000000000000000001",
            "provider": "0x0000000000000000000000000000000000000002",
        },
        "lineage": {
            "parentJobId": None,
            "activeCloseJobId": None,
            "rootJobId": 99,
            "isAwaitingClose": False,
            "allowCloseJob": False,
        },
        "hook": {
            "underwriter": "0x0000000000000000000000000000000000000042",
            "sidecarState": "SuccessPendingConfirmation",
            "submittedAt": 100,
        },
        "settlement": {
            "state": "DisputeOpen",
            "unlockAt": 180,
            "escrow": "0x00000000000000000000000000000000000000ee",
        },
        "dispute": {
            "status": "open",
            "reasonCode": "0x" + "44" * 32,
            "openedBy": "0x0000000000000000000000000000000000000001",
            "openedAt": 130,
            "resolvedAt": None,
            "slashAmountUsdc": None,
            "isOpen": True,
            "txHash": "0x" + "55" * 32,
        },
        "underwriter": {
            "registered": True,
            "premiumRecipient": "0x00000000000000000000000000000000000000f1",
            "recoveryRecipient": "0x00000000000000000000000000000000000000f2",
        },
        "derived": {},
        "orchestration": {
            "nextActionRole": "underwriter",
            "nextActionReason": "resolve success dispute",
            "nextActionDeadline": 180,
            "clientActionRequired": False,
            "providerActionRequired": False,
            "underwriterActionRequired": True,
        },
    }
    snapshot = UnderwritingJobSnapshotRow(
        job_id=99,
        settlement_job_id=99,
        parent_job_id=None,
        active_close_job_id=None,
        root_job_id=99,
        is_awaiting_close=False,
        allow_close_job=False,
        chain_id=8453,
        job_status="Completed",
        sidecar_state="SuccessPendingConfirmation",
        settlement_state="DisputeOpen",
        dispute_status="open",
        next_action_role="underwriter",
        next_action_reason="resolve success dispute",
        next_action_deadline=None,
        client_action_required=False,
        provider_action_required=False,
        underwriter_action_required=True,
        client="0x0000000000000000000000000000000000000001",
        provider="0x0000000000000000000000000000000000000002",
        underwriter="0x0000000000000000000000000000000000000042",
        payment_token="0x0000000000000000000000000000000000000004",
        expired_at=999999,
        submitted_at=100,
        as_of_block=12_345,
        snapshot_json=snapshot_json,
    )
    db_session.add(snapshot)
    db_session.commit()
    return snapshot
