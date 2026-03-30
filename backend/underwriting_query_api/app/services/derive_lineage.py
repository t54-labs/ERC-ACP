from __future__ import annotations

from typing import Any


def derive_lineage(
    *,
    job_id: int,
    job_kind: str,
    commit: dict[str, Any],
    hook_parent_job_id: int,
    kernel_parent_job_id: int,
    hook_active_close_job_id: int,
    kernel_close_job_id: int,
    hook_is_awaiting_close: bool,
) -> dict[str, Any]:
    parent_job_id = int(commit.get("parentJobId") or hook_parent_job_id or kernel_parent_job_id or 0)
    root_job_id = parent_job_id or job_id
    active_close_job_id = int(hook_active_close_job_id or kernel_close_job_id or 0)
    is_awaiting_close = hook_is_awaiting_close if parent_job_id == 0 else False

    if job_kind == "Close" and parent_job_id:
        root_job_id = parent_job_id

    return {
        "parentJobId": parent_job_id or None,
        "activeCloseJobId": active_close_job_id or None,
        "rootJobId": root_job_id,
        "isAwaitingClose": is_awaiting_close,
        "allowCloseJob": bool(commit.get("allowCloseJob", False)),
    }
