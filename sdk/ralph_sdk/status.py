"""Ralph status management — reads/writes status.json compatible with bash loop."""

from __future__ import annotations

import json
import os
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class RalphStatus:
    """Structured status compatible with on-stop.sh → status.json format."""

    work_type: str = "UNKNOWN"
    completed_task: str = ""
    next_task: str = ""
    progress_summary: str = ""
    exit_signal: bool = False
    status: str = "IN_PROGRESS"
    timestamp: str = ""
    loop_count: int = 0
    session_id: str = ""
    circuit_breaker_state: str = "CLOSED"
    error: str = ""

    def to_dict(self) -> dict[str, Any]:
        """Export as dictionary matching status.json schema."""
        return {
            "WORK_TYPE": self.work_type,
            "COMPLETED_TASK": self.completed_task,
            "NEXT_TASK": self.next_task,
            "PROGRESS_SUMMARY": self.progress_summary,
            "EXIT_SIGNAL": self.exit_signal,
            "status": self.status,
            "timestamp": self.timestamp or time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "loop_count": self.loop_count,
            "session_id": self.session_id,
            "circuit_breaker_state": self.circuit_breaker_state,
            "error": self.error,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> RalphStatus:
        """Create from status.json dictionary."""
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
            error=data.get("error", ""),
        )

    @classmethod
    def load(cls, ralph_dir: str | Path = ".ralph") -> RalphStatus:
        """Load status from .ralph/status.json."""
        status_file = Path(ralph_dir) / "status.json"
        if not status_file.exists():
            return cls()
        try:
            data = json.loads(status_file.read_text(encoding="utf-8"))
            return cls.from_dict(data)
        except (json.JSONDecodeError, OSError):
            return cls()

    def save(self, ralph_dir: str | Path = ".ralph") -> None:
        """Write status atomically to .ralph/status.json (matching bash atomic write pattern)."""
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


@dataclass
class CircuitBreakerState:
    """Circuit breaker state compatible with .circuit_breaker_state JSON."""

    state: str = "CLOSED"  # CLOSED, HALF_OPEN, OPEN
    no_progress_count: int = 0
    same_error_count: int = 0
    last_error: str = ""
    opened_at: str = ""
    last_transition: str = ""

    @classmethod
    def load(cls, ralph_dir: str | Path = ".ralph") -> CircuitBreakerState:
        """Load from .ralph/.circuit_breaker_state."""
        cb_file = Path(ralph_dir) / ".circuit_breaker_state"
        if not cb_file.exists():
            return cls()
        try:
            data = json.loads(cb_file.read_text(encoding="utf-8"))
            return cls(
                state=data.get("state", "CLOSED"),
                no_progress_count=data.get("no_progress_count", 0),
                same_error_count=data.get("same_error_count", 0),
                last_error=data.get("last_error", ""),
                opened_at=data.get("opened_at", ""),
                last_transition=data.get("last_transition", ""),
            )
        except (json.JSONDecodeError, OSError):
            return cls()

    def save(self, ralph_dir: str | Path = ".ralph") -> None:
        """Write circuit breaker state atomically."""
        ralph_dir = Path(ralph_dir)
        ralph_dir.mkdir(parents=True, exist_ok=True)
        cb_file = ralph_dir / ".circuit_breaker_state"
        tmp_file = cb_file.with_suffix(f".{os.getpid()}.tmp")
        try:
            tmp_file.write_text(
                json.dumps({
                    "state": self.state,
                    "no_progress_count": self.no_progress_count,
                    "same_error_count": self.same_error_count,
                    "last_error": self.last_error,
                    "opened_at": self.opened_at,
                    "last_transition": self.last_transition,
                }, indent=2) + "\n",
                encoding="utf-8",
            )
            tmp_file.replace(cb_file)
        finally:
            tmp_file.unlink(missing_ok=True)

    def trip(self, reason: str = "") -> None:
        """Transition to OPEN state."""
        self.state = "OPEN"
        self.opened_at = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        self.last_error = reason
        self.last_transition = f"OPEN: {reason}"

    def half_open(self) -> None:
        """Transition to HALF_OPEN (cooldown expired)."""
        self.state = "HALF_OPEN"
        self.last_transition = "HALF_OPEN: cooldown expired"

    def close(self) -> None:
        """Transition to CLOSED (recovery successful)."""
        self.state = "CLOSED"
        self.no_progress_count = 0
        self.same_error_count = 0
        self.last_error = ""
        self.opened_at = ""
        self.last_transition = "CLOSED: recovery successful"

    def reset(self, reason: str = "manual") -> None:
        """Reset to initial state."""
        self.state = "CLOSED"
        self.no_progress_count = 0
        self.same_error_count = 0
        self.last_error = ""
        self.opened_at = ""
        self.last_transition = f"RESET: {reason}"
