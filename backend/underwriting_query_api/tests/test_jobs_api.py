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
