from __future__ import annotations

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        case_sensitive=False,
    )

    database_url: str = Field(
        default="sqlite+pysqlite:///:memory:",
        alias="DATABASE_URL",
    )
    underwriting_rpc_url: str = Field(
        default="mock://underwriting",
        alias="UNDERWRITING_RPC_URL",
    )
    acp_address: str = Field(
        default="0x0000000000000000000000000000000000000000",
        alias="ACP_ADDRESS",
    )
    underwriting_hook_address: str = Field(
        default="0x0000000000000000000000000000000000000000",
        alias="UNDERWRITING_HOOK_ADDRESS",
    )
    underwriting_coordinator_address: str = Field(
        default="0x0000000000000000000000000000000000000000",
        alias="UNDERWRITING_COORDINATOR_ADDRESS",
    )
    underwriting_evaluator_address: str = Field(
        default="0x0000000000000000000000000000000000000000",
        alias="UNDERWRITING_EVALUATOR_ADDRESS",
    )
    underwriting_collateral_manager_address: str = Field(
        default="0x0000000000000000000000000000000000000000",
        alias="UNDERWRITING_COLLATERAL_MANAGER_ADDRESS",
    )

    @property
    def has_runtime_configuration(self) -> bool:
        addresses = (
            self.acp_address,
            self.underwriting_hook_address,
            self.underwriting_coordinator_address,
            self.underwriting_evaluator_address,
            self.underwriting_collateral_manager_address,
        )
        return (
            not self.underwriting_rpc_url.startswith("mock://")
            and all(address.lower() != ZERO_ADDRESS for address in addresses)
        )


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    return Settings()
