def test_get_job_dispute_returns_projection(client, seeded_snapshot):
    response = client.get(f"/underwriting/jobs/{seeded_snapshot.job_id}/dispute")

    assert response.status_code == 200
    assert response.json()["status"] == "open"


def test_list_disputes_filters_by_status(client, seeded_snapshot):
    response = client.get("/underwriting/disputes?status=open")

    assert response.status_code == 200
    assert len(response.json()["items"]) == 1


def test_get_job_dispute_uses_requested_close_job_identity(client, seeded_close_snapshot):
    response = client.get(f"/underwriting/jobs/{seeded_close_snapshot.job_id}/dispute")

    assert response.status_code == 200
    assert response.json()["jobId"] == str(seeded_close_snapshot.job_id)


def test_list_disputes_can_filter_by_close_job_id(client, seeded_close_snapshot):
    response = client.get(f"/underwriting/disputes?jobId={seeded_close_snapshot.job_id}")

    assert response.status_code == 200
    assert len(response.json()["items"]) == 1


def test_list_disputes_preserves_canonical_job_id_without_job_filter(client, seeded_close_snapshot):
    response = client.get("/underwriting/disputes")

    assert response.status_code == 200
    assert len(response.json()["items"]) == 1
    assert response.json()["items"][0]["jobId"] == "42"


def test_list_disputes_rejects_invalid_status_filter(client, seeded_snapshot):
    response = client.get("/underwriting/disputes?status=bogus")

    assert response.status_code == 422
