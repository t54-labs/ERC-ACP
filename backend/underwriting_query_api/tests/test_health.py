from fastapi.testclient import TestClient

from app.main import create_app


def test_health_returns_chain_and_index_status():
    client = TestClient(create_app())

    response = client.get("/underwriting/health")

    assert response.status_code == 200
    body = response.json()
    assert body["ok"] is True
    assert "chainId" in body
    assert "lastIndexedBlock" in body
