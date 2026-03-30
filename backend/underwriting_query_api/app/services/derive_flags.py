from __future__ import annotations

from typing import Any


def derive_flags(
    *,
    job: dict[str, Any],
    hook: dict[str, Any],
    settlement: dict[str, Any],
    dispute: dict[str, Any],
    evaluator: dict[str, Any],
    now: int,
) -> dict[str, Any]:
    sidecar_state = hook.get("sidecarState")
    settlement_state = settlement.get("state")
    submitted_at = int(hook.get("submittedAt") or 0)
    confirmation_window = int(evaluator.get("clientConfirmationWindowSeconds") or 0)
    unlock_at = int(settlement.get("unlockAt") or 0)

    client_confirmation_open = (
        job.get("status") == "Submitted"
        and sidecar_state == "EvidenceSubmitted"
        and submitted_at > 0
        and confirmation_window > 0
        and now <= submitted_at + confirmation_window
    )
    awaiting_underwriter_decision = (
        job.get("status") == "Submitted"
        and sidecar_state == "EvidenceSubmitted"
        and not client_confirmation_open
    )

    return {
        "isProtected": sidecar_state
        in {
            "Protected",
            "EvidenceSubmitted",
            "AwaitingClose",
            "SuccessPendingConfirmation",
            "RejectSettled",
        }
        or settlement_state not in {None, "None"},
        "clientConfirmationOpen": client_confirmation_open,
        "awaitingUnderwriterDecision": awaiting_underwriter_decision,
        "canSettleExpiry": job.get("status") == "Expired" and settlement_state != "ExpirySettled",
        "canReleaseCollateral": settlement_state == "SuccessPendingRelease" and (unlock_at == 0 or now >= unlock_at),
        "canOpenSuccessDispute": (
            settlement_state == "SuccessPendingRelease"
            and unlock_at > 0
            and now < unlock_at
            and dispute.get("status") != "resolved"
        ),
    }
