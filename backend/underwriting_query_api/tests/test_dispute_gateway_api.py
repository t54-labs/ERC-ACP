from app.db.models import UnderwritingActionRequestRow


def test_prepare_dispute_open_creates_action_request(client, db_session, seeded_disputeable_job):
    response = client.post(f"/underwriting/jobs/{seeded_disputeable_job.job_id}/disputes/open/prepare")

    assert response.status_code == 200
    assert response.json()["actionType"] == "open_dispute"

    row = db_session.get(UnderwritingActionRequestRow, response.json()["requestId"])
    assert row is not None
    assert row.job_id == seeded_disputeable_job.job_id
    assert row.actor_role == "client"
    assert row.status == "prepared"


def test_submit_dispute_open_persists_submission(client, db_session, seeded_disputeable_job):
    prepare = client.post(f"/underwriting/jobs/{seeded_disputeable_job.job_id}/disputes/open/prepare")

    response = client.post(
        f"/underwriting/jobs/{seeded_disputeable_job.job_id}/disputes/open/submit",
        json={
            "requestId": prepare.json()["requestId"],
            "signedPayload": {"signature": "0x" + "99" * 65},
            "txHash": "0x" + "88" * 32,
        },
    )

    assert response.status_code == 200
    assert response.json()["status"] == "submitted"

    row = db_session.get(UnderwritingActionRequestRow, prepare.json()["requestId"])
    assert row is not None
    assert row.status == "submitted"
    assert row.tx_hash == "0x" + "88" * 32


def test_prepare_slash_resolution_creates_action_request(client, db_session, seeded_open_dispute):
    response = client.post(f"/underwriting/jobs/{seeded_open_dispute.job_id}/disputes/resolve-slash/prepare")

    assert response.status_code == 200
    assert response.json()["actionType"] == "resolve_dispute_slash"

    row = db_session.get(UnderwritingActionRequestRow, response.json()["requestId"])
    assert row is not None
    assert row.job_id == seeded_open_dispute.job_id
    assert row.actor_role == "underwriter"
    assert row.status == "prepared"


def test_submit_slash_resolution_persists_submission(client, db_session, seeded_open_dispute):
    prepare = client.post(f"/underwriting/jobs/{seeded_open_dispute.job_id}/disputes/resolve-slash/prepare")

    response = client.post(
        f"/underwriting/jobs/{seeded_open_dispute.job_id}/disputes/resolve-slash/submit",
        json={
            "requestId": prepare.json()["requestId"],
            "signedPayload": {
                "attestation": {
                    "settlementJobId": seeded_open_dispute.settlement_job_id,
                    "slashAmountUsdc": 500_000,
                },
                "signature": "0x" + "77" * 65,
            },
            "txHash": "0x" + "66" * 32,
        },
    )

    assert response.status_code == 200
    assert response.json()["status"] == "submitted"

    row = db_session.get(UnderwritingActionRequestRow, prepare.json()["requestId"])
    assert row is not None
    assert row.status == "submitted"
    assert row.tx_hash == "0x" + "66" * 32
