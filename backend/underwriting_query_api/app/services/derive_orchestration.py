from __future__ import annotations

from typing import Any


def derive_orchestration(snapshot: dict[str, Any], now: int) -> dict[str, Any]:
    job = snapshot["job"]
    hook = snapshot["hook"]
    settlement = snapshot["settlement"]
    dispute = snapshot["dispute"]
    derived = snapshot["derived"]

    deadline = settlement.get("unlockAt") or job.get("expiredAt")

    orchestration = {
        "nextActionRole": None,
        "nextActionReason": None,
        "nextActionDeadline": deadline,
        "clientActionRequired": False,
        "providerActionRequired": False,
        "underwriterActionRequired": False,
    }

    if dispute.get("isOpen"):
        orchestration.update(
            {
                "nextActionRole": "underwriter",
                "nextActionReason": "resolve success dispute",
                "underwriterActionRequired": True,
                "nextActionDeadline": settlement.get("unlockAt"),
            }
        )
        return orchestration

    if (
        job.get("status") == "Funded"
        and derived.get("isProtected")
        and not int(hook.get("submittedAt") or 0)
        and int(job.get("expiredAt") or 0) > now
    ):
        orchestration.update(
            {
                "nextActionRole": "provider",
                "nextActionReason": "submit evidence before expiry",
                "providerActionRequired": True,
                "nextActionDeadline": job.get("expiredAt"),
            }
        )
        return orchestration

    if derived.get("clientConfirmationOpen"):
        orchestration.update(
            {
                "nextActionRole": "client",
                "nextActionReason": "confirm during confirmation window",
                "clientActionRequired": True,
                "nextActionDeadline": int(hook.get("submittedAt") or 0)
                + int(snapshot["evaluator"].get("clientConfirmationWindowSeconds") or 0),
            }
        )
        return orchestration

    if derived.get("awaitingUnderwriterDecision"):
        orchestration.update(
            {
                "nextActionRole": "underwriter",
                "nextActionReason": "adjudicate with complete or reject",
                "underwriterActionRequired": True,
                "nextActionDeadline": job.get("expiredAt"),
            }
        )
        return orchestration

    if job.get("status") == "Completed" and settlement.get("state") == "SuccessPendingRelease":
        if derived.get("canOpenSuccessDispute"):
            orchestration.update(
                {
                    "nextActionRole": "client",
                    "nextActionReason": "open dispute before unlock",
                    "clientActionRequired": True,
                    "nextActionDeadline": settlement.get("unlockAt"),
                }
            )
            return orchestration
        if derived.get("canReleaseCollateral"):
            orchestration.update(
                {
                    "nextActionRole": "provider",
                    "nextActionReason": "release collateral",
                    "providerActionRequired": True,
                    "nextActionDeadline": settlement.get("unlockAt"),
                }
            )
            return orchestration

    return orchestration
