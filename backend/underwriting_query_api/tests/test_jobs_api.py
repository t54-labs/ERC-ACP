from __future__ import annotations

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


class StubChainReader:
    def __init__(self, *, hook_address: str, job_hook: str):
        self._hook_address = hook_address
        self._job_hook = job_hook

    def get_underwriting_hook_address(self) -> str:
        return self._hook_address

    def get_job_counter(self) -> int:
        return 1

    def get_chain_id(self) -> int:
        return 8453

    def get_latest_block(self) -> int:
        return 123_456

    def get_current_timestamp(self) -> int:
        return 150

    def get_job(self, job_id: int) -> dict[str, object]:
        return {
            "id": job_id,
            "client": "0x0000000000000000000000000000000000000001",
            "provider": "0x0000000000000000000000000000000000000002",
            "evaluator": "0x0000000000000000000000000000000000000003",
            "description": "stub",
            "budget": 1,
            "expiredAt": 999_999,
            "status": "Completed",
            "hook": self._job_hook,
            "paymentToken": "0x0000000000000000000000000000000000000004",
            "providerAgentId": "agent",
            "submittedAt": 100,
        }

    def get_job_kind(self, job_id: int) -> str:
        return "Standalone"

    def get_kernel_parent_job_id(self, job_id: int) -> int:
        return 0

    def get_kernel_close_job_id(self, job_id: int) -> int:
        return 0

    def get_commit(self, job_id: int) -> dict[str, object]:
        return {
            "parentJobId": 0,
            "underwriter": "0x0000000000000000000000000000000000000042",
            "validUntil": 200,
            "policyHash": "0x" + "11" * 32,
            "quoteIdHash": "0x" + "22" * 32,
            "termsHash": "0x" + "33" * 32,
            "allowCloseJob": False,
        }

    def get_job_underwriter(self, job_id: int) -> str:
        return "0x0000000000000000000000000000000000000042"

    def get_job_sidecar_state(self, job_id: int) -> str:
        return "SuccessPendingConfirmation"

    def get_job_settlement_job_id(self, job_id: int) -> int:
        return job_id

    def is_awaiting_close(self, job_id: int) -> bool:
        return False

    def get_parent_job_id(self, close_job_id: int) -> int:
        return 0

    def get_active_close_job_id(self, parent_job_id: int) -> int:
        return 0

    def get_job_submitted_at(self, job_id: int) -> int:
        return 100

    def get_registered_underwriter(self, underwriter: str) -> bool:
        return True

    def get_underwriter_recipients(self, underwriter: str) -> dict[str, object]:
        return {
            "premiumRecipient": "0x00000000000000000000000000000000000000f1",
            "recoveryRecipient": "0x00000000000000000000000000000000000000f2",
        }

    def get_settlement_state(self, job_id: int) -> str:
        return "SuccessPendingRelease"

    def get_unlock_at(self, job_id: int) -> int:
        return 180

    def get_settlement_escrow(self, job_id: int) -> str:
        return "0x00000000000000000000000000000000000000ee"

    def get_client_confirmation_window_seconds(self) -> int:
        return 60

    def get_dispute_events(self, job_id: int, settlement_job_id: int) -> list[dict[str, object]]:
        return []

    def get_timeline_events(
        self,
        job_id: int,
        settlement_job_id: int,
        *,
        to_block: int | None = None,
    ) -> list[dict[str, object]]:
        return []

    def get_incremental_log_batch(
        self,
        from_block: int,
        *,
        settlement_job_ids: list[int] | None = None,
    ) -> dict[str, object]:
        return {"latestBlock": from_block, "logs": []}

    def resolve_job_ids_for_log(self, log: dict[str, object]) -> list[int]:
        return []


def _build_refresh_client(db_session_factory, *, job_hook: str) -> TestClient:
    hook_address = "0x00000000000000000000000000000000000000aa"
    app = create_app(
        settings=Settings(
            DATABASE_URL="sqlite+pysqlite:///:memory:",
            UNDERWRITING_RPC_URL="mock://underwriting",
            ACP_ADDRESS="0x0000000000000000000000000000000000000000",
            UNDERWRITING_HOOK_ADDRESS=hook_address,
            UNDERWRITING_COORDINATOR_ADDRESS="0x0000000000000000000000000000000000000000",
            UNDERWRITING_EVALUATOR_ADDRESS="0x0000000000000000000000000000000000000000",
            UNDERWRITING_COLLATERAL_MANAGER_ADDRESS="0x0000000000000000000000000000000000000000",
        ),
        session_factory=db_session_factory,
        chain_reader_factory=lambda: StubChainReader(hook_address=hook_address, job_hook=job_hook),
    )
    return TestClient(app)


def test_get_job_returns_materialized_snapshot(client, seeded_snapshot):
    response = client.get(f"/underwriting/jobs/{seeded_snapshot.job_id}")

    assert response.status_code == 200
    assert response.json()["jobId"] == str(seeded_snapshot.job_id)


def test_list_jobs_filters_by_sidecar_state(client, seeded_snapshot):
    response = client.get("/underwriting/jobs?sidecarState=EvidenceSubmitted")

    assert response.status_code == 200
    assert len(response.json()["items"]) == 1


def test_list_jobs_filters_by_next_action_role(client, seeded_snapshot):
    response = client.get("/underwriting/jobs?nextActionRole=underwriter")

    assert response.status_code == 200
    assert len(response.json()["items"]) == 1


def test_get_related_jobs_returns_parent_and_close_linkage(client, seeded_snapshot):
    response = client.get(f"/underwriting/jobs/{seeded_snapshot.job_id}/related")

    assert response.status_code == 200
    assert "lineage" in response.json()


def test_get_job_timeline_returns_settlement_scoped_events(client, seeded_snapshot):
    response = client.get(f"/underwriting/jobs/{seeded_snapshot.job_id}/timeline")

    assert response.status_code == 200
    assert len(response.json()["items"]) == 2


def test_list_jobs_rejects_invalid_status_filter(client, seeded_snapshot):
    response = client.get("/underwriting/jobs?status=NotARealStatus")

    assert response.status_code == 422


def test_get_job_refreshes_missing_snapshot_from_chain(db_session_factory):
    client = _build_refresh_client(
        db_session_factory,
        job_hook="0x00000000000000000000000000000000000000aa",
    )

    response = client.get("/underwriting/jobs/314")

    assert response.status_code == 200
    assert response.json()["jobId"] == "314"
    assert response.json()["asOfBlock"] == 123_456


def test_get_job_returns_409_for_non_underwriting_runtime_job(db_session_factory):
    client = _build_refresh_client(
        db_session_factory,
        job_hook="0x00000000000000000000000000000000000000bb",
    )

    response = client.get("/underwriting/jobs/314")

    assert response.status_code == 409
