"""In-memory NullStateBackend.

Split out of ralph_sdk.state: the file-free backend used for testing and
for TheStudio embedded mode where state is managed by the orchestrator.
"""

from __future__ import annotations

from typing import Any

from ralph_sdk.state_protocol import RalphStateBackend


class NullStateBackend(RalphStateBackend):
    """In-memory state backend — creates no files on disk.

    Used for testing and for TheStudio embedded mode where state
    is managed by the orchestrator.
    """

    def __init__(self) -> None:
        self._status: dict[str, Any] = {}
        self._circuit_breaker: dict[str, Any] = {}
        self._call_count: int = 0
        self._last_reset: int = 0
        self._session_id: str = ""
        self._fix_plan: str = ""
        self._session_metadata: dict[str, Any] = {}
        self._session_history: list[dict[str, Any]] = []
        self._continue_as_new_state: dict[str, Any] = {}

    # --- Status ---

    async def read_status(self) -> dict[str, Any]:
        return dict(self._status)

    async def write_status(self, data: dict[str, Any]) -> None:
        self._status = dict(data)

    # --- Circuit Breaker ---

    async def read_circuit_breaker(self) -> dict[str, Any]:
        return dict(self._circuit_breaker)

    async def write_circuit_breaker(self, data: dict[str, Any]) -> None:
        self._circuit_breaker = dict(data)

    # --- Rate Limiting ---

    async def read_call_count(self) -> int:
        return self._call_count

    async def write_call_count(self, count: int) -> None:
        self._call_count = count

    async def read_last_reset(self) -> int:
        return self._last_reset

    async def write_last_reset(self, timestamp: int) -> None:
        self._last_reset = timestamp

    # --- Session ---

    async def read_session_id(self) -> str:
        return self._session_id

    async def write_session_id(self, session_id: str) -> None:
        self._session_id = session_id

    # --- Task Plan ---

    async def read_fix_plan(self) -> str:
        return self._fix_plan

    async def write_fix_plan(self, content: str) -> None:
        self._fix_plan = content

    # --- Session Lifecycle (SDK-CONTEXT-3) ---

    async def read_session_metadata(self) -> dict[str, Any]:
        return dict(self._session_metadata)

    async def write_session_metadata(self, data: dict[str, Any]) -> None:
        self._session_metadata = dict(data)

    async def read_session_history(self) -> list[dict[str, Any]]:
        return list(self._session_history)

    async def append_session_history(self, entry: dict[str, Any]) -> None:
        self._session_history.append(dict(entry))

    async def read_continue_as_new_state(self) -> dict[str, Any]:
        return dict(self._continue_as_new_state)

    async def write_continue_as_new_state(self, data: dict[str, Any]) -> None:
        self._continue_as_new_state = dict(data)
