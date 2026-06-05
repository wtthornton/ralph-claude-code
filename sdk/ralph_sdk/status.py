"""Ralph status management — reads/writes status.json compatible with bash loop."""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from ralph_sdk.circuit_state import CircuitBreakerState
from ralph_sdk.status_classify import (
    CircuitBreakerStateEnum,
    ErrorCategory,
    RalphLoopStatus,
    WorkType,
    classify_error,
)

__all__ = [
    "CircuitBreakerState",
    "CircuitBreakerStateEnum",
    "ErrorCategory",
    "RalphLoopStatus",
    "RalphStatus",
    "WorkType",
    "classify_error",
]


class RalphStatus(BaseModel):
    """Structured status compatible with on-stop.sh -> status.json format."""

    model_config = ConfigDict(validate_assignment=True)

    work_type: WorkType = WorkType.UNKNOWN
    completed_task: str = ""
    next_task: str = ""
    progress_summary: str = ""
    exit_signal: bool = False
    status: RalphLoopStatus = RalphLoopStatus.IN_PROGRESS
    timestamp: str = ""
    loop_count: int = 0
    session_id: str = ""
    circuit_breaker_state: str = "CLOSED"
    correlation_id: str = ""
    error: str = ""
    error_category: ErrorCategory | None = None

    # SDK-LIFECYCLE-3: Permission denial events detected during iteration.
    # Typed as list[Any] at runtime to avoid circular import with parsing.py;
    # at type-check time the annotation resolves to list[PermissionDenialEvent].
    permission_denials: list[Any] = Field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        """Export as dictionary matching status.json schema."""
        d = {
            "WORK_TYPE": self.work_type.value,
            "COMPLETED_TASK": self.completed_task,
            "NEXT_TASK": self.next_task,
            "PROGRESS_SUMMARY": self.progress_summary,
            "EXIT_SIGNAL": self.exit_signal,
            "status": self.status.value,
            "timestamp": self.timestamp or time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "loop_count": self.loop_count,
            "session_id": self.session_id,
            "circuit_breaker_state": self.circuit_breaker_state,
            "correlation_id": self.correlation_id,
            "error": self.error,
        }
        if self.error_category is not None:
            d["error_category"] = self.error_category.value
        if self.permission_denials:
            d["permission_denials"] = [
                pd.model_dump() if hasattr(pd, "model_dump") else pd
                for pd in self.permission_denials
            ]
        return d

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> RalphStatus:
        """Create from status.json dictionary."""
        error_cat_raw = data.get("error_category")
        error_cat: ErrorCategory | None = None
        if error_cat_raw is not None:
            try:
                error_cat = ErrorCategory(error_cat_raw)
            except ValueError:
                error_cat = ErrorCategory.UNKNOWN
        return cls(
            work_type=data.get("WORK_TYPE", "UNKNOWN"),
            completed_task=data.get("COMPLETED_TASK", ""),
            next_task=data.get("NEXT_TASK", ""),
            progress_summary=data.get("PROGRESS_SUMMARY", ""),
            exit_signal=data.get("EXIT_SIGNAL", False),
            status=data.get("status", "IN_PROGRESS"),
            timestamp=data.get("timestamp", ""),
            loop_count=data.get("loop_count", 0),
            session_id=data.get("session_id", ""),
            circuit_breaker_state=data.get("circuit_breaker_state", "CLOSED"),
            correlation_id=data.get("correlation_id", ""),
            error=data.get("error", ""),
            error_category=error_cat,
        )

    @classmethod
    def load(cls, ralph_dir: str | Path = ".ralph", *, backend: Any | None = None) -> RalphStatus:
        """Load status from .ralph/status.json or via state backend.

        Note: When using an async backend, use load_async() instead.
        This method only supports sync file reads (no backend).
        """
        if backend is not None:
            import asyncio
            try:
                loop = asyncio.get_running_loop()
            except RuntimeError:
                loop = None
            if loop and loop.is_running():
                # Already in async context — caller must use load_async()
                raise RuntimeError(
                    "Cannot call sync load() with async backend from async context. "
                    "Use load_async() instead."
                )
            data = asyncio.run(backend.read_status())
            return cls.from_dict(data) if data else cls()

        status_file = Path(ralph_dir) / "status.json"
        if not status_file.exists():
            return cls()
        try:
            data = json.loads(status_file.read_text(encoding="utf-8"))
            return cls.from_dict(data)
        except (json.JSONDecodeError, OSError):
            return cls()

    def save(self, ralph_dir: str | Path = ".ralph", *, backend: Any | None = None) -> None:
        """Write status atomically to .ralph/status.json or via state backend.

        Note: When using an async backend, use save_async() instead.
        """
        if backend is not None:
            import asyncio
            try:
                loop = asyncio.get_running_loop()
            except RuntimeError:
                loop = None
            if loop and loop.is_running():
                raise RuntimeError(
                    "Cannot call sync save() with async backend from async context. "
                    "Use save_async() instead."
                )
            asyncio.run(backend.write_status(self.to_dict()))
            return

        ralph_dir = Path(ralph_dir)
        ralph_dir.mkdir(parents=True, exist_ok=True)
        status_file = ralph_dir / "status.json"
        tmp_file = status_file.with_suffix(f".{os.getpid()}.tmp")
        try:
            tmp_file.write_text(
                json.dumps(self.to_dict(), indent=2) + "\n",
                encoding="utf-8",
            )
            tmp_file.replace(status_file)
        finally:
            # Clean up temp file if replace failed (WSL/NTFS compat)
            tmp_file.unlink(missing_ok=True)
