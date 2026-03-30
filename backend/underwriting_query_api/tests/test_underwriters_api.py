def test_get_underwriter_is_point_lookup_only(client, seeded_underwriter):
    response = client.get(f"/underwriters/{seeded_underwriter.address}")

    assert response.status_code == 200
    assert response.json()["registered"] is True
