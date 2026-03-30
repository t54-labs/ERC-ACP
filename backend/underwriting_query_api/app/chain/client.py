from __future__ import annotations

from typing import Any, Protocol

from web3 import HTTPProvider, Web3

from app.chain.abi import load_abi
from app.config import Settings

ZERO_ADDRESS = "0x0000000000000000000000000000000000000000"
JOB_STATUS = ["Open", "Funded", "Submitted", "Completed", "Rejected", "Expired"]
JOB_KIND = ["Standalone", "Open", "Close"]
SIDECAR_STATE = [
    "None",
    "Committed",
    "FeeEscrowed",
    "Protected",
    "EvidenceSubmitted",
    "AwaitingClose",
    "SuccessPendingConfirmation",
    "RejectSettled",
]
SETTLEMENT_STATE = [
    "None",
    "EscrowConfigured",
    "CollateralLocked",
    "PrincipalReleased",
    "SuccessPendingRelease",
    "DisputeOpen",
    "SuccessSettled",
    "RejectSettled",
    "ExpirySettled",
    "RecoverySettled",
]

JOB_KEYS = [
    "id",
    "client",
    "provider",
    "evaluator",
    "description",
    "budget",
    "expiredAt",
    "status",
    "hook",
    "paymentToken",
    "providerAgentId",
    "submittedAt",
]
COMMIT_KEYS = [
    "parentJobId",
    "underwriter",
    "validUntil",
    "policyHash",
    "quoteIdHash",
    "termsHash",
    "allowCloseJob",
]
RECIPIENT_KEYS = ["premiumRecipient", "recoveryRecipient"]


class UnderwritingChainReader(Protocol):
    def get_underwriting_hook_address(self) -> str: ...
    def get_chain_id(self) -> int: ...
    def get_latest_block(self) -> int: ...
    def get_current_timestamp(self) -> int: ...
    def get_job(self, job_id: int) -> dict[str, Any]: ...
    def get_job_kind(self, job_id: int) -> str: ...
    def get_kernel_parent_job_id(self, job_id: int) -> int: ...
    def get_kernel_close_job_id(self, job_id: int) -> int: ...
    def get_commit(self, job_id: int) -> dict[str, Any]: ...
    def get_job_underwriter(self, job_id: int) -> str: ...
    def get_job_sidecar_state(self, job_id: int) -> str: ...
    def get_job_settlement_job_id(self, job_id: int) -> int: ...
    def is_awaiting_close(self, job_id: int) -> bool: ...
    def get_parent_job_id(self, close_job_id: int) -> int: ...
    def get_active_close_job_id(self, parent_job_id: int) -> int: ...
    def get_job_submitted_at(self, job_id: int) -> int: ...
    def get_registered_underwriter(self, underwriter: str) -> bool: ...
    def get_underwriter_recipients(self, underwriter: str) -> dict[str, Any]: ...
    def get_settlement_state(self, job_id: int) -> str: ...
    def get_unlock_at(self, job_id: int) -> int: ...
    def get_settlement_escrow(self, job_id: int) -> str: ...
    def get_client_confirmation_window_seconds(self) -> int: ...
    def get_dispute_events(self, job_id: int, settlement_job_id: int) -> list[dict[str, Any]]: ...


def _coerce_enum(value: Any, choices: list[str]) -> str:
    if isinstance(value, str):
        return value
    return choices[int(value)]


def _coerce_struct(value: Any, keys: list[str]) -> dict[str, Any]:
    if isinstance(value, dict):
        return dict(value)
    if hasattr(value, "_asdict"):
        return dict(value._asdict())
    return {key: value[index] for index, key in enumerate(keys)}


class UnderwritingChainClient:
    def __init__(self, settings: Settings):
        self.settings = settings
        self.web3 = Web3(HTTPProvider(settings.underwriting_rpc_url))
        self.hook_address = Web3.to_checksum_address(settings.underwriting_hook_address)
        self.acp = self.web3.eth.contract(
            address=Web3.to_checksum_address(settings.acp_address),
            abi=load_abi("acp"),
        )
        self.hook = self.web3.eth.contract(address=self.hook_address, abi=load_abi("hook"))
        self.coordinator = self.web3.eth.contract(
            address=Web3.to_checksum_address(settings.underwriting_coordinator_address),
            abi=load_abi("coordinator"),
        )
        self.evaluator = self.web3.eth.contract(
            address=Web3.to_checksum_address(settings.underwriting_evaluator_address),
            abi=load_abi("evaluator"),
        )
        self.collateral_manager = self.web3.eth.contract(
            address=Web3.to_checksum_address(settings.underwriting_collateral_manager_address),
            abi=load_abi("collateral_manager"),
        )

    def get_underwriting_hook_address(self) -> str:
        return self.hook_address

    def get_chain_id(self) -> int:
        return int(self.web3.eth.chain_id)

    def get_latest_block(self) -> int:
        return int(self.web3.eth.get_block("latest")["number"])

    def get_current_timestamp(self) -> int:
        return int(self.web3.eth.get_block("latest")["timestamp"])

    def get_job(self, job_id: int) -> dict[str, Any]:
        job = _coerce_struct(self.acp.functions.getJob(job_id).call(), JOB_KEYS)
        job["status"] = _coerce_enum(job["status"], JOB_STATUS)
        return job

    def get_job_kind(self, job_id: int) -> str:
        return _coerce_enum(self.acp.functions.getJobKind(job_id).call(), JOB_KIND)

    def get_kernel_parent_job_id(self, job_id: int) -> int:
        return int(self.acp.functions.getParentJobId(job_id).call())

    def get_kernel_close_job_id(self, job_id: int) -> int:
        return int(self.acp.functions.getCloseJobId(job_id).call())

    def get_commit(self, job_id: int) -> dict[str, Any]:
        return _coerce_struct(self.hook.functions.getCommit(job_id).call(), COMMIT_KEYS)

    def get_job_underwriter(self, job_id: int) -> str:
        return self.hook.functions.jobUnderwriter(job_id).call()

    def get_job_sidecar_state(self, job_id: int) -> str:
        return _coerce_enum(self.hook.functions.jobSidecarState(job_id).call(), SIDECAR_STATE)

    def get_job_settlement_job_id(self, job_id: int) -> int:
        return int(self.hook.functions.jobSettlementJobId(job_id).call())

    def is_awaiting_close(self, job_id: int) -> bool:
        return bool(self.hook.functions.isAwaitingClose(job_id).call())

    def get_parent_job_id(self, close_job_id: int) -> int:
        return int(self.hook.functions.getParentJobId(close_job_id).call())

    def get_active_close_job_id(self, parent_job_id: int) -> int:
        return int(self.hook.functions.getActiveCloseJobId(parent_job_id).call())

    def get_job_submitted_at(self, job_id: int) -> int:
        return int(self.hook.functions.jobSubmittedAt(job_id).call())

    def get_registered_underwriter(self, underwriter: str) -> bool:
        if not underwriter or underwriter == ZERO_ADDRESS:
            return False
        return bool(self.hook.functions.registeredUnderwriters(underwriter).call())

    def get_underwriter_recipients(self, underwriter: str) -> dict[str, Any]:
        if not underwriter or underwriter == ZERO_ADDRESS:
            return {"premiumRecipient": ZERO_ADDRESS, "recoveryRecipient": ZERO_ADDRESS}
        return _coerce_struct(
            self.collateral_manager.functions.recipientsByUnderwriter(underwriter).call(),
            RECIPIENT_KEYS,
        )

    def get_settlement_state(self, job_id: int) -> str:
        return _coerce_enum(self.coordinator.functions.jobSettlementState(job_id).call(), SETTLEMENT_STATE)

    def get_unlock_at(self, job_id: int) -> int:
        return int(self.coordinator.functions.unlockAtByJobId(job_id).call())

    def get_settlement_escrow(self, job_id: int) -> str:
        return self.coordinator.functions.settlementEscrow(job_id).call()

    def get_client_confirmation_window_seconds(self) -> int:
        return int(self.evaluator.functions.clientConfirmationWindowSeconds().call())

    def get_dispute_events(self, job_id: int, settlement_job_id: int) -> list[dict[str, Any]]:
        latest_block = self.get_latest_block()
        events: list[dict[str, Any]] = []
        for event_cls in (
            self.coordinator.events.SuccessDisputeOpened,
            self.coordinator.events.DisputeSlashApplied,
        ):
            for event in event_cls().get_logs(
                from_block=0,
                to_block=latest_block,
                argument_filters={"jobId": job_id},
            ):
                args = dict(event["args"])
                if settlement_job_id and int(args.get("settlementJobId", settlement_job_id)) != settlement_job_id:
                    continue
                block = self.web3.eth.get_block(event["blockNumber"])
                events.append(
                    {
                        "eventName": event.event,
                        "args": args,
                        "blockNumber": int(event["blockNumber"]),
                        "transactionHash": event["transactionHash"].hex(),
                        "logIndex": int(event["logIndex"]),
                        "timestamp": int(block["timestamp"]),
                    }
                )
        return sorted(events, key=lambda item: (item["blockNumber"], item["logIndex"]))
