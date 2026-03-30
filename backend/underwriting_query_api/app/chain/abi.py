from __future__ import annotations

import json
from functools import lru_cache
from pathlib import Path
from typing import Any

PROJECT_ROOT = Path(__file__).resolve().parents[4]
OUT_DIR = PROJECT_ROOT / "out"

ARTIFACT_PATHS = {
    "acp": OUT_DIR / "AgenticCommerce.sol" / "AgenticCommerce.json",
    "hook": OUT_DIR / "UnderwritingHook.sol" / "UnderwritingHook.json",
    "coordinator": OUT_DIR / "UnderwritingSettlementCoordinator.sol" / "UnderwritingSettlementCoordinator.json",
    "evaluator": OUT_DIR / "UnderwritingEvaluator.sol" / "UnderwritingEvaluator.json",
    "collateral_manager": OUT_DIR / "UnderwritingCollateralManager.sol" / "UnderwritingCollateralManager.json",
}


@lru_cache(maxsize=None)
def load_abi(name: str) -> list[dict[str, Any]]:
    artifact_path = ARTIFACT_PATHS[name]
    artifact = json.loads(artifact_path.read_text())
    return artifact["abi"]
