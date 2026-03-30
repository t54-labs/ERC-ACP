from __future__ import annotations

from typing import Any

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlalchemy.orm import Session

from app.db.models import UnderwritingActionRequestRow
from app.db.session import get_db_session
from app.services.prepare_dispute_open import prepare_dispute_open
from app.services.prepare_slash_resolution import prepare_slash_resolution
from app.services.submit_dispute_open import submit_dispute_open
from app.services.submit_slash_resolution import submit_slash_resolution

router = APIRouter(tags=["actions"])


class PrepareDisputeOpenBody(BaseModel):
    reasonCode: str | None = None


class ActionSubmitBody(BaseModel):
    requestId: str
    signedPayload: dict[str, Any] | None = None
    txHash: str | None = None


def _serialize_action_request(row: UnderwritingActionRequestRow) -> dict[str, object]:
    return {
        "requestId": row.request_id,
        "jobId": str(row.job_id),
        "settlementJobId": str(row.settlement_job_id) if row.settlement_job_id is not None else None,
        "actorRole": row.actor_role,
        "actionType": row.action_type,
        "status": row.status,
        "payload": row.request_payload_json,
        "signedPayload": row.signed_payload_json,
        "txHash": row.tx_hash,
        "errorMessage": row.error_message,
    }


@router.post("/underwriting/jobs/{job_id}/disputes/open/prepare")
def prepare_job_dispute_open(
    job_id: int,
    body: PrepareDisputeOpenBody | None = None,
    db: Session = Depends(get_db_session),
) -> dict[str, object]:
    try:
        row = prepare_dispute_open(db, job_id, reason_code=body.reasonCode if body else None)
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return _serialize_action_request(row)


@router.post("/underwriting/jobs/{job_id}/disputes/open/submit")
def submit_job_dispute_open(
    job_id: int,
    body: ActionSubmitBody,
    db: Session = Depends(get_db_session),
) -> dict[str, object]:
    try:
        row = submit_dispute_open(
            db,
            job_id,
            request_id=body.requestId,
            signed_payload=body.signedPayload,
            tx_hash=body.txHash,
        )
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return _serialize_action_request(row)


@router.post("/underwriting/jobs/{job_id}/disputes/resolve-slash/prepare")
def prepare_job_slash_resolution(
    job_id: int,
    db: Session = Depends(get_db_session),
) -> dict[str, object]:
    try:
        row = prepare_slash_resolution(db, job_id)
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return _serialize_action_request(row)


@router.post("/underwriting/jobs/{job_id}/disputes/resolve-slash/submit")
def submit_job_slash_resolution(
    job_id: int,
    body: ActionSubmitBody,
    db: Session = Depends(get_db_session),
) -> dict[str, object]:
    try:
        row = submit_slash_resolution(
            db,
            job_id,
            request_id=body.requestId,
            signed_payload=body.signedPayload,
            tx_hash=body.txHash,
        )
    except LookupError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc
    except ValueError as exc:
        raise HTTPException(status_code=409, detail=str(exc)) from exc
    return _serialize_action_request(row)
