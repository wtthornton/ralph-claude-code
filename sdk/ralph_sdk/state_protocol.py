"""RalphStateBackend Protocol.

Split out of ralph_sdk.state: the Protocol defining the 18 async state
operations, shared by FileStateBackend and NullStateBackend.
"""

from __future__ import annotations

from typing import Any, Protocol, runtime_checkable


@runtime_checkable
class RalphStateBackend(Protocol):
    """Protocol defining the 18 async state operations."""

    # --- Status ---

    async def read_status(self) -> dict[str, Any]:
        """Read current status (status.json equivalent)."""
        ...

    async def write_status(self, data: dict[str, Any]) -> None:
        """Write status atomically."""
        ...

    # --- Circuit Breaker ---

    async def read_circuit_breaker(self) -> dict[str, Any]:
        """Read circuit breaker state."""
        ...

    async def write_circuit_breaker(self, data: dict[str, Any]) -> None:
        """Write circuit breaker state atomically."""
        ...

    # --- Rate Limiting ---

    async def read_call_count(self) -> int:
        """Read current API call count."""
        ...

    async def write_call_count(self, count: int) -> None:
        """Write API call count."""
        ...

    async def read_last_reset(self) -> int:
        """Read last rate limit reset timestamp."""
        ...

    async def write_last_reset(self, timestamp: int) -> None:
        """Write rate limit reset timestamp."""
        ...

    # --- Session ---

    async def read_session_id(self) -> str:
        """Read Claude session ID."""
        ...

    async def write_session_id(self, session_id: str) -> None:
        """Write Claude session ID."""
        ...

    # --- Task Plan ---

    async def read_fix_plan(self) -> str:
        """Read fix_plan.md content."""
        ...

    async def write_fix_plan(self, content: str) -> None:
        """Write fix_plan.md content."""
        ...

    # --- Session Lifecycle (SDK-CONTEXT-3) ---

    async def read_session_metadata(self) -> dict[str, Any]:
        """Read session metadata (created_at, iteration_count, etc.)."""
        ...

    async def write_session_metadata(self, data: dict[str, Any]) -> None:
        """Write session metadata atomically."""
        ...

    async def read_session_history(self) -> list[dict[str, Any]]:
        """Read list of previous session records."""
        ...

    async def append_session_history(self, entry: dict[str, Any]) -> None:
        """Append a session record to history."""
        ...

    async def read_continue_as_new_state(self) -> dict[str, Any]:
        """Read continue-as-new state for session rotation."""
        ...

    async def write_continue_as_new_state(self, data: dict[str, Any]) -> None:
        """Write continue-as-new state for session rotation."""
        ...
