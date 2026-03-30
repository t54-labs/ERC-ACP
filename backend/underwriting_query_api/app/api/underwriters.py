from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlalchemy.orm import Session

from app.db.session import get_db_session
from app.services.query_underwriter import get_underwriter_row

router = APIRouter(tags=["underwriters"])


@router.get("/underwriters/{address}")
def get_underwriter(address: str, db: Session = Depends(get_db_session)) -> dict[str, object]:
    row = get_underwriter_row(db, address)
    if row is None:
        raise HTTPException(status_code=404, detail="underwriter not found")
    return {
        "address": row.address,
        "registered": row.registered,
        "premiumRecipient": row.premium_recipient,
        "recoveryRecipient": row.recovery_recipient,
    }
