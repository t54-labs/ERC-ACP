from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from app.services.hydrate_snapshot import hydrate_underwriting_snapshot


@dataclass
class FakeChain:
    underwriting_hook_address: str = "0x00000000000000000000000000000000000000aa"
    job: dict[str, Any] = field(
        default_factory=lambda: {
            "id": 42,
            "client": "0x0000000000000000000000000000000000000001",
            "provider": "0x0000000000000000000000000000000000000002",
            "evaluator": "0x0000000000000000000000000000000000000003",
            "description": "underwriting job",
            "budget": 5_000_000,
            "expiredAt": 999999,
            "status": "Submitted",
            "hook": "0x00000000000000000000000000000000000000aa",
            "paymentToken": "0x0000000000000000000000000000000000000004",
            "providerAgentId": 0,
            "submittedAt": 100,
        }
    )

    def get_underwriting_hook_address(self) -> str:
        return self.underwriting_hook_address

    def get_chain_id(self) -> int:
        return 8453

    def get_latest_block(self) -> int:
        return 12_345

    def get_current_timestamp(self) -> int:
        return 120

    def get_job(self, job_id: int) -> dict[str, Any]:
        assert job_id == self.job["id"]
        return dict(self.job)

    def get_job_kind(self, job_id: int) -> str:
        return "Standalone"

    def get_kernel_parent_job_id(self, job_id: int) -> int:
        return 0

    def get_kernel_close_job_id(self, job_id: int) -> int:
        return 0

    def get_commit(self, job_id: int) -> dict[str, Any]:
        return {
            "parentJobId": 0,
            "underwriter": "0x0000000000000000000000000000000000000042",
            "validUntil": 999999,
            "policyHash": "0x" + "11" * 32,
            "quoteIdHash": "0x" + "22" * 32,
            "termsHash": "0x" + "33" * 32,
            "allowCloseJob": False,
        }

    def get_job_underwriter(self, job_id: int) -> str:
        return "0x0000000000000000000000000000000000000042"

    def get_job_sidecar_state(self, job_id: int) -> str:
        return "EvidenceSubmitted"

    def get_job_settlement_job_id(self, job_id: int) -> int:
        return 4200

    def is_awaiting_close(self, job_id: int) -> bool:
        return False

    def get_parent_job_id(self, close_job_id: int) -> int:
        return 0

    def get_active_close_job_id(self, parent_job_id: int) -> int:
        return 0

    def get_job_submitted_at(self, job_id: int) -> int:
        return 100

    def get_registered_underwriter(self, underwriter: str) -> bool:
        return True

    def get_underwriter_recipients(self, underwriter: str) -> dict[str, Any]:
        return {
            "premiumRecipient": "0x00000000000000000000000000000000000000f1",
            "recoveryRecipient": "0x00000000000000000000000000000000000000f2",
        }

    def get_settlement_state(self, job_id: int) -> str:
        return "PrincipalReleased"

    def get_unlock_at(self, job_id: int) -> int:
        return 180

    def get_settlement_escrow(self, job_id: int) -> str:
        return "0x0000000000000000000000000000000000000e5c"

    def get_client_confirmation_window_seconds(self) -> int:
        return 60

    def get_dispute_events(self, job_id: int, settlement_job_id: int) -> list[dict[str, Any]]:
        return []


def test_hydrate_snapshot_joins_acp_hook_and_settlement_reads():
    snapshot = hydrate_underwriting_snapshot(job_id=42, chain=FakeChain())

    assert snapshot.job_id == 42
    assert snapshot.settlement_job_id == 4200
    assert snapshot.hook["underwriter"] == "0x0000000000000000000000000000000000000042"
    assert snapshot.settlement["state"] == "PrincipalReleased"
    assert snapshot.derived["clientConfirmationOpen"] is True
    assert snapshot.orchestration["nextActionRole"] == "client"


@dataclass
class SharedSettlementFakeChain(FakeChain):
    job: dict[str, Any] = field(
        default_factory=lambda: {
            "id": 77,
            "client": "0x0000000000000000000000000000000000000001",
            "provider": "0x0000000000000000000000000000000000000002",
            "evaluator": "0x0000000000000000000000000000000000000003",
            "description": "close job",
            "budget": 5_000_000,
            "expiredAt": 999999,
            "status": "Completed",
            "hook": "0x00000000000000000000000000000000000000aa",
            "paymentToken": "0x0000000000000000000000000000000000000004",
            "providerAgentId": 0,
            "submittedAt": 100,
        }
    )

    def get_job_kind(self, job_id: int) -> str:
        return "Close"

    def get_commit(self, job_id: int) -> dict[str, Any]:
        commit = super().get_commit(job_id)
        commit["parentJobId"] = 42
        return commit

    def get_job_settlement_job_id(self, job_id: int) -> int:
        return 42

    def get_parent_job_id(self, close_job_id: int) -> int:
        return 42

    def get_active_close_job_id(self, parent_job_id: int) -> int:
        return 77

    def get_settlement_state(self, settlement_owner_job_id: int) -> str:
        assert settlement_owner_job_id == 42
        return "DisputeOpen"

    def get_unlock_at(self, settlement_owner_job_id: int) -> int:
        assert settlement_owner_job_id == 42
        return 180

    def get_dispute_events(self, job_id: int, settlement_job_id: int) -> list[dict[str, Any]]:
        assert job_id == 77
        assert settlement_job_id == 42
        return [
            {
                "eventName": "SuccessDisputeOpened",
                "args": {
                    "jobId": 42,
                    "settlementJobId": 42,
                    "reasonCode": "0x" + "44" * 32,
                },
                "blockNumber": 12_000,
                "transactionHash": "0x" + "55" * 32,
                "logIndex": 1,
                "timestamp": 130,
            }
        ]


def test_hydrate_snapshot_reuses_shared_settlement_state_for_close_jobs():
    snapshot = hydrate_underwriting_snapshot(job_id=77, chain=SharedSettlementFakeChain())

    assert snapshot.settlement_job_id == 42
    assert snapshot.lineage["parentJobId"] == 42
    assert snapshot.settlement["state"] == "DisputeOpen"
    assert snapshot.dispute["status"] == "open"
    assert snapshot.orchestration["nextActionRole"] == "underwriter"
