from __future__ import annotations

from dataclasses import dataclass

from fastapi import FastAPI
from sqlalchemy import create_engine, text
from web3 import HTTPProvider, Web3

from app.api.health import router as health_router
from app.config import Settings, get_settings


@dataclass(slots=True)
class HealthProbe:
    settings: Settings

    def read_status(self) -> dict[str, object]:
        if self.settings.underwriting_rpc_url.startswith("mock://"):
            chain_id = 0
            latest_rpc_block = 0
        else:
            web3 = Web3(HTTPProvider(self.settings.underwriting_rpc_url))
            chain_id = web3.eth.chain_id
            latest_rpc_block = web3.eth.block_number

        if self.settings.database_url.startswith("sqlite"):
            db_status = "ok"
        else:
            engine = create_engine(self.settings.database_url, future=True)
            with engine.connect() as connection:
                connection.execute(text("SELECT 1"))
            db_status = "ok"

        return {
            "ok": True,
            "chainId": chain_id,
            "latestRpcBlock": latest_rpc_block,
            "lastIndexedBlock": 0,
            "dbStatus": db_status,
        }


def create_app(
    *,
    settings: Settings | None = None,
    health_probe: HealthProbe | None = None,
) -> FastAPI:
    resolved_settings = settings or get_settings()

    app = FastAPI(title="Underwriting Query API")
    app.state.settings = resolved_settings
    app.state.health_probe = health_probe or HealthProbe(resolved_settings)
    app.include_router(health_router)
    return app


app = create_app()
