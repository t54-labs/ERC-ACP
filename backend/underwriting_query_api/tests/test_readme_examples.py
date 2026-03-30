from pathlib import Path


def test_readme_mentions_postgres_alembic_and_no_webhooks():
    readme = Path("backend/underwriting_query_api/README.md").read_text()

    assert "Postgres" in readme
    assert "Alembic" in readme
    assert "webhooks are not required in v1" in readme


def test_root_readme_links_backend_docs():
    readme = Path("README.md").read_text()

    assert "backend/underwriting_query_api/README.md" in readme
