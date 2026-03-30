from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[3]
BACKEND_README = REPO_ROOT / "backend/underwriting_query_api/README.md"
ROOT_README = REPO_ROOT / "README.md"


def test_readme_mentions_postgres_alembic_and_no_webhooks():
    readme = BACKEND_README.read_text()

    assert "Postgres" in readme
    assert "Alembic" in readme
    assert "webhooks are not required in v1" in readme


def test_root_readme_links_backend_docs():
    readme = ROOT_README.read_text()

    assert "backend/underwriting_query_api/README.md" in readme


def test_backend_readme_documents_shared_settlement_gateway_behavior():
    readme = BACKEND_README.read_text()

    assert "shared-settlement close jobs" in readme
    assert "slash-resolution prepare flow intentionally returns a template" in readme
