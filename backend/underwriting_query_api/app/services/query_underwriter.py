from __future__ import annotations

from sqlalchemy.orm import Session

from app.db.models import UnderwriterRow


def get_underwriter_row(db: Session, address: str) -> UnderwriterRow | None:
    return db.get(UnderwriterRow, address)
