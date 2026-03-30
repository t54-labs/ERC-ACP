from __future__ import annotations

from dataclasses import dataclass
from typing import Callable

from fastapi import FastAPI
from sqlalchemy import Engine, text
from sqlalchemy.orm import Session, sessionmaker
from web3 import HTTPProvider, Web3

from app.chain.client import UnderwritingChainClient, UnderwritingChainReader
from app.api.disputes import router as disputes_router
from app.api.health import router as health_router
from app.api.jobs import router as jobs_router
from app.api.underwriters import router as underwriters_router
from app.config import Settings, get_settings
from app.db.session import build_session_factory


@dataclass(slots=True)
class HealthProbe:
    settings: Settings
    engine: Engine
    web3: Web3 | None = None

    def read_status(self) -> dict[str, object]:
        with self.engine.connect() as connection:
            connection.execute(text("SELECT 1"))
        db_status = "ok"

        chain_id: int | None = None
        latest_rpc_block: int | None = None
        rpc_status = "unconfigured"

        if self.web3 is not None:
            chain_id = self.web3.eth.chain_id
            latest_rpc_block = self.web3.eth.block_number
            rpc_status = "ok"

        return {
            "ok": db_status == "ok" and rpc_status == "ok" and self.settings.has_runtime_configuration,
            "configurationStatus": "configured" if self.settings.has_runtime_configuration else "unconfigured",
            "chainId": chain_id,
            "latestRpcBlock": latest_rpc_block,
            "lastIndexedBlock": 0,
            "dbStatus": db_status,
            "rpcStatus": rpc_status,
        }


def create_app(
    *,
    settings: Settings | None = None,
    health_probe: HealthProbe | None = None,
    session_factory: sessionmaker[Session] | None = None,
    chain_reader_factory: Callable[[], UnderwritingChainReader] | None = None,
) -> FastAPI:
    resolved_settings = settings or get_settings()
    resolved_session_factory = session_factory or build_session_factory(resolved_settings.database_url)
    engine = resolved_session_factory.kw["bind"]
    web3 = (
        Web3(HTTPProvider(resolved_settings.underwriting_rpc_url))
        if resolved_settings.has_runtime_configuration
        else None
    )
    resolved_chain_reader_factory = chain_reader_factory
    if resolved_chain_reader_factory is None and resolved_settings.has_runtime_configuration:
        resolved_chain_reader_factory = lambda: UnderwritingChainClient(resolved_settings)

    app = FastAPI(title="Underwriting Query API")
    app.state.settings = resolved_settings
    app.state.engine = engine
    app.state.session_factory = resolved_session_factory
    app.state.chain_reader_factory = resolved_chain_reader_factory
    app.state.health_probe = health_probe or HealthProbe(resolved_settings, engine=engine, web3=web3)
    app.include_router(health_router)
    app.include_router(jobs_router)
    app.include_router(disputes_router)
    app.include_router(underwriters_router)
    return app


app = create_app()
