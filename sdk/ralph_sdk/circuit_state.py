"""CircuitBreakerState model split out of status.py.

The persisted circuit-breaker state model and its transition helpers.
Re-exported from ``ralph_sdk.status`` so the public import surface is
unchanged.
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

from pydantic import BaseModel, ConfigDict

from ralph_sdk.status_classify import CircuitBreakerStateEnum


class CircuitBreakerState(BaseModel):
    """Circuit breaker state compatible with .circuit_breaker_state JSON."""

    model_config = ConfigDict(validate_assignment=True)

    state: CircuitBreakerStateEnum = CircuitBreakerStateEnum.CLOSED
    no_progress_count: int = 0
    same_error_count: int = 0
    last_error: str = ""
    opened_at: str = ""
    last_transition: str = ""

    def _to_state_dict(self) -> dict[str, Any]:
        """Export as dictionary for state backend."""
        return {
            "state": self.state.value,
            "no_progress_count": self.no_progress_count,
            "same_error_count": self.same_error_count,
            "last_error": self.last_error,
            "opened_at": self.opened_at,
            "last_transition": self.last_transition,
        }

    @classmethod
    def _from_state_dict(cls, data: dict[str, Any]) -> CircuitBreakerState:
        """Create from state dict."""
        return cls(
            state=data.get("state", "CLOSED"),
            no_progress_count=data.get("no_progress_count", 0),
            same_error_count=data.get("same_error_count", 0),
            last_error=data.get("last_error", ""),
            opened_at=data.get("opened_at", ""),
            last_transition=data.get("last_transition", ""),
        )

    @classmethod
    def load(cls, ralph_dir: str | Path = ".ralph", *, backend: Any | None = None) -> CircuitBreakerState:
        """Load from .ralph/.circuit_breaker_state or via state backend.

        Note: When using an async backend, use asyncio.run() or call backend directly.
        """
        if backend is not None:
            import asyncio
            try:
                loop = asyncio.get_running_loop()
            except RuntimeError:
                loop = None
            if loop and loop.is_running():
                raise RuntimeError(
                    "Cannot call sync load() with async backend from async context."
                )
            data = asyncio.run(backend.read_circuit_breaker())
            return cls._from_state_dict(data) if data else cls()

        cb_file = Path(ralph_dir) / ".circuit_breaker_state"
        if not cb_file.exists():
            return cls()
        try:
            data = json.loads(cb_file.read_text(encoding="utf-8"))
            return cls._from_state_dict(data)
        except (json.JSONDecodeError, OSError):
            return cls()

    def save(self, ralph_dir: str | Path = ".ralph", *, backend: Any | None = None) -> None:
        """Write circuit breaker state atomically or via state backend."""
        if backend is not None:
            import asyncio
            try:
                loop = asyncio.get_running_loop()
            except RuntimeError:
                loop = None
            if loop and loop.is_running():
                raise RuntimeError(
                    "Cannot call sync save() with async backend from async context."
                )
            asyncio.run(backend.write_circuit_breaker(self._to_state_dict()))
            return

        ralph_dir = Path(ralph_dir)
        ralph_dir.mkdir(parents=True, exist_ok=True)
        cb_file = ralph_dir / ".circuit_breaker_state"
        tmp_file = cb_file.with_suffix(f".{os.getpid()}.tmp")
        try:
            tmp_file.write_text(
                json.dumps(self._to_state_dict(), indent=2) + "\n",
                encoding="utf-8",
            )
            tmp_file.replace(cb_file)
        finally:
            tmp_file.unlink(missing_ok=True)

    def trip(self, reason: str = "") -> None:
        """Transition to OPEN state."""
        self.state = CircuitBreakerStateEnum.OPEN
        self.opened_at = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        self.last_error = reason
        self.last_transition = f"OPEN: {reason}"

    def half_open(self) -> None:
        """Transition to HALF_OPEN (cooldown expired)."""
        self.state = CircuitBreakerStateEnum.HALF_OPEN
        self.last_transition = "HALF_OPEN: cooldown expired"

    def close(self) -> None:
        """Transition to CLOSED (recovery successful)."""
        self.state = CircuitBreakerStateEnum.CLOSED
        self.no_progress_count = 0
        self.same_error_count = 0
        self.last_error = ""
        self.opened_at = ""
        self.last_transition = "CLOSED: recovery successful"

    def reset(self, reason: str = "manual") -> None:
        """Reset to initial state."""
        self.state = CircuitBreakerStateEnum.CLOSED
        self.no_progress_count = 0
        self.same_error_count = 0
        self.last_error = ""
        self.opened_at = ""
        self.last_transition = f"RESET: {reason}"
