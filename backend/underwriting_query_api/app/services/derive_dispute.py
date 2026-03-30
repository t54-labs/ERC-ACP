from __future__ import annotations

from typing import Any


def derive_dispute(
    *,
    job: dict[str, Any],
    settlement_state: str,
    dispute_events: list[dict[str, Any]],
) -> dict[str, Any]:
    dispute = {
        "isOpen": False,
        "reasonCode": None,
        "openedBy": None,
        "openedAt": None,
        "resolvedAt": None,
        "slashAmountUsdc": None,
        "status": "none",
        "txHash": None,
    }

    for event in sorted(dispute_events, key=lambda item: (item["blockNumber"], item["logIndex"])):
        event_name = event["eventName"]
        args = event["args"]
        if event_name == "SuccessDisputeOpened":
            dispute.update(
                {
                    "isOpen": True,
                    "reasonCode": args.get("reasonCode"),
                    "openedBy": job.get("client"),
                    "openedAt": event.get("timestamp"),
                    "status": "open",
                    "txHash": event["transactionHash"],
                }
            )
        elif event_name == "DisputeSlashApplied":
            dispute.update(
                {
                    "isOpen": False,
                    "resolvedAt": event.get("timestamp"),
                    "slashAmountUsdc": int(args.get("slashAmountUsdc", 0)),
                    "status": "resolved",
                    "txHash": event["transactionHash"],
                }
            )

    if settlement_state == "DisputeOpen":
        dispute["isOpen"] = True
        dispute["status"] = "open"
    elif settlement_state == "RecoverySettled" and dispute["status"] == "none":
        dispute["status"] = "resolved"

    return dispute
