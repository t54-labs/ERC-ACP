def test_get_job_dispute_returns_projection(client, seeded_snapshot):
    response = client.get(f"/underwriting/jobs/{seeded_snapshot.job_id}/dispute")

    assert response.status_code == 200
    assert response.json()["status"] == "open"


def test_list_disputes_filters_by_status(client, seeded_snapshot):
    response = client.get("/underwriting/disputes?status=open")

    assert response.status_code == 200
    assert len(response.json()["items"]) == 1
