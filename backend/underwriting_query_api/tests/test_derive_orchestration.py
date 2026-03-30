from app.schemas.snapshots import UnderwritingJobSnapshot
from app.services.derive_orchestration import derive_orchestration
from app.services.project_snapshot import build_dispute_row_payload, build_snapshot_row_payload


def test_submitted_job_with_open_confirmation_window_requires_client_action():
    orchestration = derive_orchestration(
        {
            "job": {"status": "Submitted"},
            "hook": {"sidecarState": "EvidenceSubmitted", "submittedAt": 100},
            "settlement": {"state": "PrincipalReleased", "unlockAt": 0},
            "dispute": {"isOpen": False},
            "derived": {"clientConfirmationOpen": True},
        },
        now=120,
    )

    assert orchestration["nextActionRole"] == "client"
    assert orchestration["clientActionRequired"] is True


def test_snapshot_projection_persists_lineage_dispute_and_orchestration_scalars():
    snapshot = UnderwritingJobSnapshot(
        chain_id=8453,
        as_of_block=12_345,
        job_id=42,
        settlement_job_id=4200,
        job={"status": "Submitted"},
        lineage={
            "parentJobId": 7,
            "activeCloseJobId": None,
            "rootJobId": 7,
            "isAwaitingClose": False,
            "allowCloseJob": True,
        },
        hook={"sidecarState": "EvidenceSubmitted", "submittedAt": 100},
        settlement={"state": "DisputeOpen", "unlockAt": 180, "escrow": "0x00000000000000000000000000000000000000ee"},
        dispute={
            "status": "open",
            "reasonCode": "0x" + "44" * 32,
            "openedBy": "0x0000000000000000000000000000000000000001",
            "openedAt": 130,
            "resolvedAt": None,
            "slashAmountUsdc": None,
            "isOpen": True,
            "txHash": "0x" + "55" * 32,
        },
        underwriter={
            "registered": True,
            "premiumRecipient": "0x00000000000000000000000000000000000000f1",
            "recoveryRecipient": "0x00000000000000000000000000000000000000f2",
        },
        derived={"clientConfirmationOpen": True},
        orchestration={
            "nextActionRole": "client",
            "nextActionReason": "confirm during confirmation window",
            "nextActionDeadline": 160,
            "clientActionRequired": True,
            "providerActionRequired": False,
            "underwriterActionRequired": False,
        },
    )

    snapshot_row = build_snapshot_row_payload(snapshot)
    dispute_row = build_dispute_row_payload(snapshot)

    assert snapshot_row["parent_job_id"] == 7
    assert snapshot_row["dispute_status"] == "open"
    assert snapshot_row["next_action_role"] == "client"
    assert snapshot_row["snapshot_json"]["orchestration"]["nextActionRole"] == "client"
    assert dispute_row["settlement_job_id"] == 4200
    assert dispute_row["status"] == "open"
