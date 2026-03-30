from __future__ import annotations

from dataclasses import dataclass
from typing import Any

import pytest
from fastapi.testclient import TestClient
from sqlalchemy.orm import Session, sessionmaker

from app.config import Settings
from app.main import create_app
from app.services.backfill import run_backfill


@dataclass
class RuntimeJob:
    job_id: int


class IntegrationFakeChain:
    underwriting_hook_address = "0x00000000000000000000000000000000000000aa"
    underwriter = "0x0000000000000000000000000000000000000042"
    client = "0x0000000000000000000000000000000000000001"
    provider = "0x0000000000000000000000000000000000000002"
    evaluator = "0x0000000000000000000000000000000000000003"
    payment_token = "0x0000000000000000000000000000000000000004"
    premium_recipient = "0x00000000000000000000000000000000000000f1"
    recovery_recipient = "0x00000000000000000000000000000000000000f2"

    def __init__(self) -> None:
        self.jobs: dict[int, dict[str, Any]] = {
            1: {
                "id": 1,
                "client": self.client,
                "provider": self.provider,
                "evaluator": self.evaluator,
                "description": "submitted underwriting job",
                "budget": 5_000_000,
                "expiredAt": 999999,
                "status": "Submitted",
                "hook": self.underwriting_hook_address,
                "paymentToken": self.payment_token,
                "providerAgentId": 0,
                "submittedAt": 100,
            },
            2: {
                "id": 2,
                "client": self.client,
                "provider": self.provider,
                "evaluator": self.evaluator,
                "description": "completed disputeable job",
                "budget": 5_000_000,
                "expiredAt": 999999,
                "status": "Completed",
                "hook": self.underwriting_hook_address,
                "paymentToken": self.payment_token,
                "providerAgentId": 0,
                "submittedAt": 100,
            },
            3: {
                "id": 3,
                "client": self.client,
                "provider": self.provider,
                "evaluator": self.evaluator,
                "description": "completed open dispute job",
                "budget": 5_000_000,
                "expiredAt": 999999,
                "status": "Completed",
                "hook": self.underwriting_hook_address,
                "paymentToken": self.payment_token,
                "providerAgentId": 0,
                "submittedAt": 100,
            },
            4: {
                "id": 4,
                "client": self.client,
                "provider": self.provider,
                "evaluator": self.evaluator,
                "description": "close job sharing success-pending-release settlement",
                "budget": 5_000_000,
                "expiredAt": 999999,
                "status": "Completed",
                "hook": self.underwriting_hook_address,
                "paymentToken": self.payment_token,
                "providerAgentId": 0,
                "submittedAt": 100,
            },
            5: {
                "id": 5,
                "client": self.client,
                "provider": self.provider,
                "evaluator": self.evaluator,
                "description": "close job sharing open dispute settlement",
                "budget": 5_000_000,
                "expiredAt": 999999,
                "status": "Completed",
                "hook": self.underwriting_hook_address,
                "paymentToken": self.payment_token,
                "providerAgentId": 0,
                "submittedAt": 100,
            },
        }
        self.timeline_events: dict[int, list[dict[str, Any]]] = {
            1: [
                {
                    "chain_id": 8453,
                    "job_id": 1,
                    "settlement_job_id": 1,
                    "block_number": 200,
                    "transaction_hash": "0x" + "11" * 32,
                    "log_index": 0,
                    "source": "acp",
                    "event_name": "JobSubmitted",
                    "payload_json": {"jobId": 1},
                },
            ],
            2: [
                {
                    "chain_id": 8453,
                    "job_id": 2,
                    "settlement_job_id": 2,
                    "block_number": 210,
                    "transaction_hash": "0x" + "22" * 32,
                    "log_index": 0,
                    "source": "acp",
                    "event_name": "JobCompleted",
                    "payload_json": {"jobId": 2},
                },
                {
                    "chain_id": 8453,
                    "job_id": 2,
                    "settlement_job_id": 2,
                    "block_number": 211,
                    "transaction_hash": "0x" + "23" * 32,
                    "log_index": 1,
                    "source": "coordinator",
                    "event_name": "CollateralReleaseRequested",
                    "payload_json": {"jobId": 2, "settlementJobId": 2},
                },
            ],
            3: [
                {
                    "chain_id": 8453,
                    "job_id": 3,
                    "settlement_job_id": 3,
                    "block_number": 220,
                    "transaction_hash": "0x" + "33" * 32,
                    "log_index": 0,
                    "source": "acp",
                    "event_name": "JobCompleted",
                    "payload_json": {"jobId": 3},
                },
                {
                    "chain_id": 8453,
                    "job_id": 3,
                    "settlement_job_id": 3,
                    "block_number": 221,
                    "transaction_hash": "0x" + "34" * 32,
                    "log_index": 1,
                    "source": "coordinator",
                    "event_name": "CollateralReleaseRequested",
                    "payload_json": {"jobId": 3, "settlementJobId": 3},
                },
                {
                    "chain_id": 8453,
                    "job_id": 3,
                    "settlement_job_id": 3,
                    "block_number": 222,
                    "transaction_hash": "0x" + "35" * 32,
                    "log_index": 2,
                    "source": "coordinator",
                    "event_name": "SuccessDisputeOpened",
                    "payload_json": {
                        "jobId": 3,
                        "settlementJobId": 3,
                        "reasonCode": "0x" + "44" * 32,
                        "timestamp": 130,
                    },
                },
            ],
            4: [
                {
                    "chain_id": 8453,
                    "job_id": 4,
                    "settlement_job_id": 2,
                    "block_number": 230,
                    "transaction_hash": "0x" + "44" * 32,
                    "log_index": 0,
                    "source": "acp",
                    "event_name": "JobCompleted",
                    "payload_json": {"jobId": 4},
                },
            ],
            5: [
                {
                    "chain_id": 8453,
                    "job_id": 5,
                    "settlement_job_id": 3,
                    "block_number": 240,
                    "transaction_hash": "0x" + "55" * 32,
                    "log_index": 0,
                    "source": "acp",
                    "event_name": "JobCompleted",
                    "payload_json": {"jobId": 5},
                },
                {
                    "chain_id": 8453,
                    "job_id": 3,
                    "settlement_job_id": 3,
                    "block_number": 241,
                    "transaction_hash": "0x" + "56" * 32,
                    "log_index": 1,
                    "source": "coordinator",
                    "event_name": "SuccessDisputeOpened",
                    "payload_json": {
                        "jobId": 3,
                        "settlementJobId": 3,
                        "reasonCode": "0x" + "44" * 32,
                        "timestamp": 130,
                    },
                },
            ],
        }

    def get_underwriting_hook_address(self) -> str:
        return self.underwriting_hook_address

    def get_job_counter(self) -> int:
        return 5

    def get_chain_id(self) -> int:
        return 8453

    def get_latest_block(self) -> int:
        return 500

    def get_current_timestamp(self) -> int:
        return 120

    def get_job(self, job_id: int) -> dict[str, Any]:
        return dict(self.jobs[job_id])

    def get_job_kind(self, job_id: int) -> str:
        return "Close" if job_id in {4, 5} else "Standalone"

    def get_kernel_parent_job_id(self, job_id: int) -> int:
        return 0

    def get_kernel_close_job_id(self, job_id: int) -> int:
        return 0

    def get_commit(self, job_id: int) -> dict[str, Any]:
        commit = {
            "parentJobId": 0,
            "underwriter": self.underwriter,
            "validUntil": 999999,
            "policyHash": "0x" + "11" * 32,
            "quoteIdHash": "0x" + "22" * 32,
            "termsHash": "0x" + "33" * 32,
            "allowCloseJob": False,
        }
        if job_id == 4:
            commit["parentJobId"] = 2
        if job_id == 5:
            commit["parentJobId"] = 3
        return commit

    def get_job_underwriter(self, job_id: int) -> str:
        return self.underwriter

    def get_job_sidecar_state(self, job_id: int) -> str:
        return "EvidenceSubmitted" if job_id == 1 else "SuccessPendingConfirmation"

    def get_job_settlement_job_id(self, job_id: int) -> int:
        if job_id == 4:
            return 2
        if job_id == 5:
            return 3
        return job_id

    def is_awaiting_close(self, job_id: int) -> bool:
        return False

    def get_parent_job_id(self, close_job_id: int) -> int:
        if close_job_id == 4:
            return 2
        if close_job_id == 5:
            return 3
        return 0

    def get_active_close_job_id(self, parent_job_id: int) -> int:
        if parent_job_id == 2:
            return 4
        if parent_job_id == 3:
            return 5
        return 0

    def get_job_submitted_at(self, job_id: int) -> int:
        return 100

    def get_registered_underwriter(self, underwriter: str) -> bool:
        return True

    def get_underwriter_recipients(self, underwriter: str) -> dict[str, Any]:
        return {
            "premiumRecipient": self.premium_recipient,
            "recoveryRecipient": self.recovery_recipient,
        }

    def get_settlement_state(self, settlement_owner_job_id: int) -> str:
        if settlement_owner_job_id == 1:
            return "PrincipalReleased"
        if settlement_owner_job_id == 2:
            return "SuccessPendingRelease"
        return "DisputeOpen"

    def get_unlock_at(self, settlement_owner_job_id: int) -> int:
        return 180

    def get_settlement_escrow(self, job_id: int) -> str:
        return "0x0000000000000000000000000000000000000e5c"

    def get_client_confirmation_window_seconds(self) -> int:
        return 60

    def get_dispute_events(self, job_id: int, settlement_job_id: int) -> list[dict[str, Any]]:
        items = []
        for event in self.timeline_events[job_id]:
            if event["event_name"] not in {"SuccessDisputeOpened", "DisputeSlashApplied"}:
                continue
            items.append(
                {
                    "eventName": event["event_name"],
                    "args": event["payload_json"],
                    "blockNumber": event["block_number"],
                    "transactionHash": event["transaction_hash"],
                    "logIndex": event["log_index"],
                    "timestamp": event["payload_json"].get("timestamp"),
                }
            )
        return items

    def get_timeline_events(self, job_id: int, settlement_job_id: int, *, to_block: int | None = None) -> list[dict[str, Any]]:
        assert to_block == 500
        return list(self.timeline_events[job_id])

    def get_incremental_log_batch(self, from_block: int, *, settlement_job_ids: list[int] | None = None) -> dict[str, Any]:
        return {"head_block": 500, "logs": []}

    def resolve_job_ids_for_log(self, log: dict[str, Any]) -> list[int]:
        return []


@pytest.fixture
def integration_runtime() -> IntegrationFakeChain:
    return IntegrationFakeChain()


@pytest.fixture
def integration_client(
    db_session_factory: sessionmaker[Session],
    integration_runtime: IntegrationFakeChain,
) -> TestClient:
    with db_session_factory() as db:
        run_backfill(chain=integration_runtime, db=db)

    app = create_app(
        settings=Settings(
            DATABASE_URL="sqlite+pysqlite:///:memory:",
            UNDERWRITING_RPC_URL="mock://underwriting",
            ACP_ADDRESS="0x0000000000000000000000000000000000000000",
            UNDERWRITING_HOOK_ADDRESS=integration_runtime.underwriting_hook_address,
            UNDERWRITING_COORDINATOR_ADDRESS="0x0000000000000000000000000000000000000000",
            UNDERWRITING_EVALUATOR_ADDRESS="0x0000000000000000000000000000000000000000",
            UNDERWRITING_COLLATERAL_MANAGER_ADDRESS="0x0000000000000000000000000000000000000000",
        ),
        session_factory=db_session_factory,
        chain_reader_factory=lambda: integration_runtime,
    )
    return TestClient(app)


@pytest.fixture
def seeded_chain_runtime() -> RuntimeJob:
    return RuntimeJob(job_id=1)


@pytest.fixture
def seeded_disputeable_runtime() -> RuntimeJob:
    return RuntimeJob(job_id=2)


@pytest.fixture
def seeded_open_dispute_runtime() -> RuntimeJob:
    return RuntimeJob(job_id=3)


@pytest.fixture
def seeded_close_disputeable_runtime() -> RuntimeJob:
    return RuntimeJob(job_id=4)


@pytest.fixture
def seeded_close_open_dispute_runtime() -> RuntimeJob:
    return RuntimeJob(job_id=5)


def test_materialized_snapshot_matches_live_contract_state(integration_client, seeded_chain_runtime):
    response = integration_client.get(f"/underwriting/jobs/{seeded_chain_runtime.job_id}")

    assert response.status_code == 200
    body = response.json()
    assert body["job"]["status"] == "Submitted"
    assert body["hook"]["sidecarState"] == "EvidenceSubmitted"
    assert body["orchestration"]["nextActionRole"] in {"client", "underwriter", "provider", None}


def test_timeline_rows_contain_expected_runtime_events(integration_client, seeded_open_dispute_runtime):
    response = integration_client.get(f"/underwriting/jobs/{seeded_open_dispute_runtime.job_id}/timeline")

    assert response.status_code == 200
    event_names = [item["eventName"] for item in response.json()["items"]]

    assert "JobCompleted" in event_names
    assert "CollateralReleaseRequested" in event_names
    assert "SuccessDisputeOpened" in event_names


def test_dispute_gateway_flows_match_runtime(
    integration_client,
    seeded_disputeable_runtime,
    seeded_open_dispute_runtime,
    seeded_close_disputeable_runtime,
    seeded_close_open_dispute_runtime,
):
    dispute = integration_client.get(f"/underwriting/jobs/{seeded_open_dispute_runtime.job_id}/dispute")
    dispute_open_prepare = integration_client.post(
        f"/underwriting/jobs/{seeded_disputeable_runtime.job_id}/disputes/open/prepare"
    )
    close_dispute_open_prepare = integration_client.post(
        f"/underwriting/jobs/{seeded_close_disputeable_runtime.job_id}/disputes/open/prepare"
    )
    slash_prepare = integration_client.post(
        f"/underwriting/jobs/{seeded_open_dispute_runtime.job_id}/disputes/resolve-slash/prepare"
    )
    close_slash_prepare = integration_client.post(
        f"/underwriting/jobs/{seeded_close_open_dispute_runtime.job_id}/disputes/resolve-slash/prepare"
    )

    assert dispute.status_code == 200
    assert dispute.json()["status"] in {"open", "resolved", "none"}
    assert dispute_open_prepare.status_code == 200
    assert dispute_open_prepare.json()["payload"]["method"] == "openSuccessDispute"
    assert close_dispute_open_prepare.status_code == 200
    assert close_dispute_open_prepare.json()["jobId"] == str(seeded_close_disputeable_runtime.job_id)
    assert close_dispute_open_prepare.json()["payload"]["args"]["jobId"] == seeded_disputeable_runtime.job_id
    assert slash_prepare.status_code == 200
    assert slash_prepare.json()["payload"]["method"] == "applySuccessDisputeSlash"
    assert close_slash_prepare.status_code == 200
    assert close_slash_prepare.json()["jobId"] == str(seeded_close_open_dispute_runtime.job_id)
    assert close_slash_prepare.json()["payload"]["args"]["jobId"] == seeded_open_dispute_runtime.job_id
    assert close_slash_prepare.json()["payload"]["requiredUserInput"] == ["slashAmountUsdc", "validUntil", "nonce"]
    assert close_slash_prepare.json()["payload"]["args"]["attestation"]["slashAmountUsdc"] is None
    assert close_slash_prepare.json()["payload"]["args"]["attestation"]["validUntil"] is None
    assert close_slash_prepare.json()["payload"]["args"]["attestation"]["nonce"] is None
