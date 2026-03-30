from __future__ import annotations

from fastapi import APIRouter, Request

router = APIRouter(tags=["health"])


@router.get("/underwriting/health")
def get_underwriting_health(request: Request) -> dict[str, object]:
    probe = request.app.state.health_probe
    return probe.read_status()
