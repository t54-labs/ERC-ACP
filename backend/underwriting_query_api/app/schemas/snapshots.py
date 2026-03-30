from __future__ import annotations

from typing import Any

from pydantic import BaseModel


class UnderwritingJobSnapshot(BaseModel):
    chain_id: int
    as_of_block: int
    job_id: int
    settlement_job_id: int
    job: dict[str, Any]
    lineage: dict[str, Any]
    hook: dict[str, Any]
    settlement: dict[str, Any]
    dispute: dict[str, Any]
    underwriter: dict[str, Any]
    derived: dict[str, Any]
    orchestration: dict[str, Any]
