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
    def get_job_counter(self) -> int: ...
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
    def get_timeline_events(self, job_id: int, settlement_job_id: int) -> list[dict[str, Any]]: ...
    def get_incremental_logs(self, from_block: int) -> list[dict[str, Any]]: ...
    def resolve_job_ids_for_log(self, log: dict[str, Any]) -> list[int]: ...


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

    def get_job_counter(self) -> int:
        return int(self.acp.functions.jobCounter().call())

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

    def get_settlement_state(self, settlement_owner_job_id: int) -> str:
        return _coerce_enum(
            self.coordinator.functions.jobSettlementState(settlement_owner_job_id).call(),
            SETTLEMENT_STATE,
        )

    def get_unlock_at(self, settlement_owner_job_id: int) -> int:
        return int(self.coordinator.functions.unlockAtByJobId(settlement_owner_job_id).call())

    def get_settlement_escrow(self, job_id: int) -> str:
        return self.coordinator.functions.settlementEscrow(job_id).call()

    def get_client_confirmation_window_seconds(self) -> int:
        return int(self.evaluator.functions.clientConfirmationWindowSeconds().call())

    def get_dispute_events(self, job_id: int, settlement_job_id: int) -> list[dict[str, Any]]:
        return [
            {
                "eventName": event["event_name"],
                "args": event["payload_json"],
                "blockNumber": event["block_number"],
                "transactionHash": event["transaction_hash"],
                "logIndex": event["log_index"],
                "timestamp": event["payload_json"].get("timestamp"),
            }
            for event in self.get_timeline_events(job_id, settlement_job_id)
            if event["event_name"] in {"SuccessDisputeOpened", "DisputeSlashApplied"}
        ]

    def _normalize_event(self, source: str, event: Any) -> dict[str, Any]:
        block = self.web3.eth.get_block(event["blockNumber"])
        args = dict(event["args"])
        return {
            "chain_id": self.get_chain_id(),
            "job_id": int(args.get("jobId") or args.get("job_id") or args.get("settlementJobId") or 0),
            "settlement_job_id": int(args.get("settlementJobId") or args.get("settlement_job_id") or 0),
            "block_number": int(event["blockNumber"]),
            "transaction_hash": event["transactionHash"].hex(),
            "log_index": int(event["logIndex"]),
            "source": source,
            "event_name": event.event,
            "payload_json": {
                **args,
                "timestamp": int(block["timestamp"]),
            },
        }

    def _event_logs(self, contract: Any, source: str, event_names: list[str], from_block: int, to_block: int) -> list[dict[str, Any]]:
        logs: list[dict[str, Any]] = []
        for event_name in event_names:
            event_cls = getattr(contract.events, event_name)
            for event in event_cls().get_logs(from_block=from_block, to_block=to_block):
                logs.append(self._normalize_event(source, event))
        return logs

    def get_timeline_events(self, job_id: int, settlement_job_id: int) -> list[dict[str, Any]]:
        latest_block = self.get_latest_block()
        events = []
        events.extend(
            self._event_logs(
                self.acp,
                "acp",
                [
                    "JobCreated",
                    "ProviderSet",
                    "BudgetSet",
                    "JobFunded",
                    "JobSubmitted",
                    "JobCompleted",
                    "JobRejected",
                    "JobExpired",
                    "PaymentReleased",
                    "Refunded",
                ],
                0,
                latest_block,
            )
        )
        events.extend(
            self._event_logs(
                self.coordinator,
                "coordinator",
                [
                    "FundingOrchestrated",
                    "CollateralReleaseRequested",
                    "CollateralReleased",
                    "ExpirySettled",
                    "RejectedJobFinalized",
                    "SuccessDisputeOpened",
                    "DisputeSlashApplied",
                ],
                0,
                latest_block,
            )
        )
        events.extend(
            self._event_logs(
                self.collateral_manager,
                "collateral_manager",
                [
                    "CollateralLocked",
                    "PrincipalReleasedToMerchant",
                    "CollateralReleased",
                    "TimeoutClaimed",
                    "CollateralSlashed",
                ],
                0,
                latest_block,
            )
        )

        escrow_address = self.get_settlement_escrow(job_id)
        if escrow_address and escrow_address != ZERO_ADDRESS:
            escrow = self.web3.eth.contract(
                address=Web3.to_checksum_address(escrow_address),
                abi=load_abi("escrow"),
            )
            events.extend(
                self._event_logs(
                    escrow,
                    "escrow",
                    [
                        "EscrowConfigured",
                        "CollateralPullRequested",
                        "PrincipalPullRequested",
                        "CollateralLockRequested",
                        "PrincipalReleaseRequested",
                        "DeliveryConfirmationRequested",
                        "CollateralReleaseRequested",
                        "TimeoutClaimRequested",
                        "SlashExecuted",
                    ],
                    0,
                    latest_block,
                )
            )

        relevant = [
            event
            for event in events
            if event["job_id"] == job_id
            or (settlement_job_id and event["settlement_job_id"] == settlement_job_id)
        ]
        return sorted(relevant, key=lambda item: (item["block_number"], item["log_index"]))

    def get_incremental_logs(self, from_block: int) -> list[dict[str, Any]]:
        latest_block = self.get_latest_block()
        start_block = max(from_block + 1, 0)
        events = []
        events.extend(
            self._event_logs(
                self.acp,
                "acp",
                [
                    "JobCreated",
                    "ProviderSet",
                    "BudgetSet",
                    "JobFunded",
                    "JobSubmitted",
                    "JobCompleted",
                    "JobRejected",
                    "JobExpired",
                    "PaymentReleased",
                    "Refunded",
                ],
                start_block,
                latest_block,
            )
        )
        events.extend(
            self._event_logs(
                self.coordinator,
                "coordinator",
                [
                    "FundingOrchestrated",
                    "CollateralReleaseRequested",
                    "CollateralReleased",
                    "ExpirySettled",
                    "RejectedJobFinalized",
                    "SuccessDisputeOpened",
                    "DisputeSlashApplied",
                ],
                start_block,
                latest_block,
            )
        )
        events.extend(
            self._event_logs(
                self.collateral_manager,
                "collateral_manager",
                [
                    "CollateralLocked",
                    "PrincipalReleasedToMerchant",
                    "CollateralReleased",
                    "TimeoutClaimed",
                    "CollateralSlashed",
                ],
                start_block,
                latest_block,
            )
        )
        return sorted(events, key=lambda item: (item["block_number"], item["log_index"]))

    def resolve_job_ids_for_log(self, log: dict[str, Any]) -> list[int]:
        touched = set()
        job_id = int(log.get("job_id") or 0)
        settlement_job_id = int(log.get("settlement_job_id") or 0)
        if job_id:
            touched.add(job_id)
        if settlement_job_id:
            touched.add(settlement_job_id)
            active_close_job_id = self.get_active_close_job_id(settlement_job_id)
            if active_close_job_id:
                touched.add(active_close_job_id)
        return sorted(touched)
