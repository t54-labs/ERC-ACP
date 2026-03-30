from dataclasses import dataclass

from fastapi.testclient import TestClient

from app.config import Settings
from app.main import create_app


@dataclass(slots=True)
class StubHealthProbe:
    payload: dict[str, object]

    def read_status(self) -> dict[str, object]:
        return self.payload


def test_health_returns_chain_and_index_status():
    probe = StubHealthProbe(
        {
            "ok": True,
            "configurationStatus": "configured",
            "chainId": 8453,
            "latestRpcBlock": 123456,
            "lastIndexedBlock": 123000,
            "dbStatus": "ok",
            "rpcStatus": "ok",
        }
    )
    client = TestClient(
        create_app(
            settings=Settings(
                DATABASE_URL="sqlite+pysqlite:///:memory:",
                UNDERWRITING_RPC_URL="https://rpc.example",
                ACP_ADDRESS="0x0000000000000000000000000000000000000001",
                UNDERWRITING_HOOK_ADDRESS="0x0000000000000000000000000000000000000002",
                UNDERWRITING_COORDINATOR_ADDRESS="0x0000000000000000000000000000000000000003",
                UNDERWRITING_EVALUATOR_ADDRESS="0x0000000000000000000000000000000000000004",
                UNDERWRITING_COLLATERAL_MANAGER_ADDRESS="0x0000000000000000000000000000000000000005",
            ),
            health_probe=probe,
        )
    )

    response = client.get("/underwriting/health")

    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True
    assert body["chainId"] == 8453
    assert body["latestRpcBlock"] == 123456
    assert body["lastIndexedBlock"] == 123000
    assert body["dbStatus"] == "ok"


def test_health_reports_unconfigured_defaults_as_unhealthy():
    client = TestClient(create_app())

    response = client.get("/underwriting/health")

    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is False
    assert body["configurationStatus"] == "unconfigured"
    assert body["chainId"] is None
    assert body["latestRpcBlock"] is None
    assert body["rpcStatus"] == "unconfigured"
