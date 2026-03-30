from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from app.db.models import SyncStateRow, UnderwritingJobSnapshotRow
from app.services.backfill import run_backfill


@dataclass
class BackfillFakeChain:
    underwriting_hook_address: str = "0x00000000000000000000000000000000000000aa"
    latest_blocks: list[int] = field(default_factory=lambda: [300, 301, 301])
    jobs: dict[int, dict[str, Any]] = field(
        default_factory=lambda: {
            1: {
                "id": 1,
                "client": "0x0000000000000000000000000000000000000001",
                "provider": "0x0000000000000000000000000000000000000002",
                "evaluator": "0x0000000000000000000000000000000000000003",
                "description": "job one",
                "budget": 5_000_000,
                "expiredAt": 999999,
                "status": "Submitted",
                "hook": "0x00000000000000000000000000000000000000aa",
                "paymentToken": "0x0000000000000000000000000000000000000004",
                "providerAgentId": 0,
                "submittedAt": 100,
            },
            2: {
                "id": 2,
                "client": "0x0000000000000000000000000000000000000011",
                "provider": "0x0000000000000000000000000000000000000012",
                "evaluator": "0x0000000000000000000000000000000000000013",
                "description": "job two",
                "budget": 6_000_000,
                "expiredAt": 999999,
                "status": "Funded",
                "hook": "0x00000000000000000000000000000000000000aa",
                "paymentToken": "0x0000000000000000000000000000000000000004",
                "providerAgentId": 0,
                "submittedAt": 0,
            },
            3: {
                "id": 3,
                "client": "0x0000000000000000000000000000000000000021",
                "provider": "0x0000000000000000000000000000000000000022",
                "evaluator": "0x0000000000000000000000000000000000000023",
                "description": "non underwriting",
                "budget": 7_000_000,
                "expiredAt": 999999,
                "status": "Open",
                "hook": "0x00000000000000000000000000000000000000bb",
                "paymentToken": "0x0000000000000000000000000000000000000004",
                "providerAgentId": 0,
                "submittedAt": 0,
            },
        }
    )

    def get_underwriting_hook_address(self) -> str:
        return self.underwriting_hook_address

    def get_job_counter(self) -> int:
        return 3

    def get_chain_id(self) -> int:
        return 8453

    def get_latest_block(self) -> int:
        if len(self.latest_blocks) > 1:
            return self.latest_blocks.pop(0)
        return self.latest_blocks[0]

    def get_current_timestamp(self) -> int:
        return 120

    def get_job(self, job_id: int) -> dict[str, Any]:
        return dict(self.jobs[job_id])

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
        return "EvidenceSubmitted" if job_id == 1 else "Protected"

    def get_job_settlement_job_id(self, job_id: int) -> int:
        return job_id

    def is_awaiting_close(self, job_id: int) -> bool:
        return False

    def get_parent_job_id(self, close_job_id: int) -> int:
        return 0

    def get_active_close_job_id(self, parent_job_id: int) -> int:
        return 0

    def get_job_submitted_at(self, job_id: int) -> int:
        return self.jobs[job_id]["submittedAt"]

    def get_registered_underwriter(self, underwriter: str) -> bool:
        return True

    def get_underwriter_recipients(self, underwriter: str) -> dict[str, Any]:
        return {
            "premiumRecipient": "0x00000000000000000000000000000000000000f1",
            "recoveryRecipient": "0x00000000000000000000000000000000000000f2",
        }

    def get_settlement_state(self, settlement_owner_job_id: int) -> str:
        return "PrincipalReleased" if settlement_owner_job_id == 1 else "CollateralLocked"

    def get_unlock_at(self, settlement_owner_job_id: int) -> int:
        return 180

    def get_settlement_escrow(self, job_id: int) -> str:
        return "0x0000000000000000000000000000000000000e5c"

    def get_client_confirmation_window_seconds(self) -> int:
        return 60

    def get_dispute_events(self, job_id: int, settlement_job_id: int) -> list[dict[str, Any]]:
        return []

    def get_timeline_events(self, job_id: int, settlement_job_id: int, *, to_block: int | None = None) -> list[dict[str, Any]]:
        assert to_block == 300
        return [
            {
                "chain_id": 8453,
                "job_id": job_id,
                "settlement_job_id": settlement_job_id,
                "block_number": 200 + job_id,
                "transaction_hash": "0x" + f"{job_id:064x}",
                "log_index": 0,
                "source": "acp",
                "event_name": "JobSubmitted",
                "payload_json": {"jobId": job_id},
            },
            {
                "chain_id": 8453,
                "job_id": 0,
                "settlement_job_id": 0,
                "block_number": 150 + job_id,
                "transaction_hash": "0x" + f"{job_id + 100:064x}",
                "log_index": 1,
                "source": "collateral_manager",
                "event_name": "UnderwriterRecipientsSet",
                "payload_json": {
                    "underwriter": "0x0000000000000000000000000000000000000042",
                    "premiumRecipient": "0x00000000000000000000000000000000000000f1",
                },
            },
        ]

    def get_incremental_log_batch(self, from_block: int, *, settlement_job_ids: list[int] | None = None) -> dict[str, Any]:
        return {"head_block": 300, "logs": []}

    def resolve_job_ids_for_log(self, log: dict[str, Any]) -> list[int]:
        return []


def test_backfill_scans_job_counter_and_persists_underwriting_snapshots(db_session):
    run_backfill(chain=BackfillFakeChain(), db=db_session)

    assert db_session.query(UnderwritingJobSnapshotRow).count() == 2
    assert db_session.get(SyncStateRow, "lastIndexedBlock").value["block"] == 300
