from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any

from app.db.models import SyncStateRow, UnderwritingJobSnapshotRow, UnderwritingTimelineEventRow
from app.services.sync_logs import run_incremental_sync


@dataclass
class SyncFakeChain:
    underwriting_hook_address: str = "0x00000000000000000000000000000000000000aa"
    job: dict[str, Any] = field(
        default_factory=lambda: {
            "id": 1,
            "client": "0x0000000000000000000000000000000000000001",
            "provider": "0x0000000000000000000000000000000000000002",
            "evaluator": "0x0000000000000000000000000000000000000003",
            "description": "job one",
            "budget": 5_000_000,
            "expiredAt": 999999,
            "status": "Completed",
            "hook": "0x00000000000000000000000000000000000000aa",
            "paymentToken": "0x0000000000000000000000000000000000000004",
            "providerAgentId": 0,
            "submittedAt": 100,
        }
    )

    def get_underwriting_hook_address(self) -> str:
        return self.underwriting_hook_address

    def get_job_counter(self) -> int:
        return 1

    def get_chain_id(self) -> int:
        return 8453

    def get_latest_block(self) -> int:
        return 250

    def get_current_timestamp(self) -> int:
        return 200

    def get_job(self, job_id: int) -> dict[str, Any]:
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
        return "SuccessPendingConfirmation"

    def get_job_settlement_job_id(self, job_id: int) -> int:
        return 1

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

    def get_settlement_state(self, settlement_owner_job_id: int) -> str:
        return "SuccessPendingRelease"

    def get_unlock_at(self, settlement_owner_job_id: int) -> int:
        return 220

    def get_settlement_escrow(self, job_id: int) -> str:
        return "0x0000000000000000000000000000000000000e5c"

    def get_client_confirmation_window_seconds(self) -> int:
        return 60

    def get_dispute_events(self, job_id: int, settlement_job_id: int) -> list[dict[str, Any]]:
        return []

    def get_timeline_events(self, job_id: int, settlement_job_id: int, *, to_block: int | None = None) -> list[dict[str, Any]]:
        assert to_block == 210
        return [
            {
                "chain_id": 8453,
                "job_id": job_id,
                "settlement_job_id": settlement_job_id,
                "block_number": 210,
                "transaction_hash": "0x" + "11" * 32,
                "log_index": 0,
                "source": "coordinator",
                "event_name": "DeliveryConfirmationRequested",
                "payload_json": {"jobId": job_id, "settlementJobId": settlement_job_id},
            }
        ]

    def get_incremental_log_batch(self, from_block: int, *, settlement_job_ids: list[int] | None = None) -> dict[str, Any]:
        assert settlement_job_ids == [1]
        return {
            "head_block": 210,
            "logs": [
                {
                    "block_number": 210,
                    "job_id": 0,
                    "settlement_job_id": 1,
                    "event_name": "DeliveryConfirmationRequested",
                    "payload_json": {"settlementJobId": 1},
                }
            ],
        }

    def resolve_job_ids_for_log(self, log: dict[str, Any]) -> list[int]:
        return [log["job_id"]]


def test_incremental_sync_refreshes_jobs_touched_by_logs(db_session):
    db_session.add(SyncStateRow(key="lastIndexedBlock", value={"block": 100}))
    db_session.add(
        UnderwritingJobSnapshotRow(
            job_id=1,
            settlement_job_id=1,
            parent_job_id=None,
            active_close_job_id=None,
            root_job_id=1,
            is_awaiting_close=False,
            allow_close_job=False,
            chain_id=8453,
            job_status="Completed",
            sidecar_state="SuccessPendingConfirmation",
            settlement_state="SuccessPendingRelease",
            dispute_status="none",
            next_action_role="provider",
            next_action_reason="release collateral",
            next_action_deadline=None,
            client_action_required=False,
            provider_action_required=True,
            underwriter_action_required=False,
            client="0x0000000000000000000000000000000000000001",
            provider="0x0000000000000000000000000000000000000002",
            underwriter="0x0000000000000000000000000000000000000042",
            payment_token="0x0000000000000000000000000000000000000004",
            expired_at=999999,
            submitted_at=100,
            as_of_block=100,
            snapshot_json={},
        )
    )
    db_session.commit()

    run_incremental_sync(chain=SyncFakeChain(), db=db_session)

    assert db_session.query(UnderwritingTimelineEventRow).count() > 0
    assert db_session.get(SyncStateRow, "lastIndexedBlock").value["block"] == 210
