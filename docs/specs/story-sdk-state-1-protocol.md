# Story RALPH-SDK-STATE-1: Define RalphStateBackend Protocol

**Epic:** [Pluggable State Backend](epic-sdk-state-backend.md)
**Priority:** Critical
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/state.py` (new file)

---

## Problem

All state persistence in the Ralph SDK is hardcoded to filesystem operations scattered
across `agent.py`, `status.py`, and `tools.py`. There is no abstraction boundary between
the agent logic and the storage mechanism. TheStudio needs to swap in PostgreSQL or Redis
backends, and tests need a no-op backend that creates no files.

Without a formal protocol, every new backend would require ad-hoc monkey-patching of
internal methods.

## Solution

Define a `RalphStateBackend` Protocol class in a new `sdk/ralph_sdk/state.py` module
with 12 async methods covering every state operation the agent performs. The protocol
uses `typing.Protocol` so that backends satisfy it structurally (no inheritance required).

All methods are `async def` from day one to match the RFC contract, even though the
initial `FileStateBackend` (Story 2) will use synchronous I/O under the hood.

## Implementation

Create `sdk/ralph_sdk/state.py` with:

```python
from __future__ import annotations

from typing import Any, Protocol

from ralph_sdk.status import CircuitBreakerState, RalphStatus


class RalphStateBackend(Protocol):
    """Abstract state persistence contract for Ralph agents.

    Implementations:
      - FileStateBackend  (default, Story 2)
      - NullStateBackend  (testing, Story 3)
      - PostgresStateBackend  (TheStudio, out of scope)
    """

    # -- Status -----------------------------------------------------------
    async def load_status(self) -> RalphStatus: ...
    async def save_status(self, status: RalphStatus) -> None: ...

    # -- Circuit breaker --------------------------------------------------
    async def load_circuit_breaker(self) -> CircuitBreakerState: ...
    async def save_circuit_breaker(self, cb: CircuitBreakerState) -> None: ...
    async def record_circuit_event(self, event: dict[str, Any]) -> None: ...

    # -- Rate limiting ----------------------------------------------------
    async def get_call_count(self) -> int: ...
    async def increment_call_count(self) -> int: ...
    async def reset_call_count(self) -> None: ...

    # -- Session ----------------------------------------------------------
    async def load_session_id(self) -> str: ...
    async def save_session_id(self, session_id: str) -> None: ...
    async def clear_session_id(self) -> None: ...

    # -- Metrics ----------------------------------------------------------
    async def record_metric(self, metric: dict[str, Any]) -> None: ...
```

No implementations in this story -- only the protocol definition and its imports.

## Acceptance Criteria

- [ ] `sdk/ralph_sdk/state.py` exists with `RalphStateBackend` Protocol class
- [ ] Protocol has exactly 12 `async def` methods as listed above
- [ ] All methods use proper type hints referencing `RalphStatus` and `CircuitBreakerState`
- [ ] `from ralph_sdk.state import RalphStateBackend` imports cleanly
- [ ] Protocol uses `typing.Protocol` (structural subtyping, not ABC)
- [ ] No concrete implementations in this file (those are Stories 2 and 3)
- [ ] Module docstring documents the three intended implementations

## Test Plan

- **Import test**: `from ralph_sdk.state import RalphStateBackend` succeeds without error.
- **Protocol verification**: Create a minimal class implementing all 12 methods with `pass` bodies. Confirm `isinstance(instance, RalphStateBackend)` is `True` at runtime (requires `runtime_checkable` decorator -- add if needed, or verify structurally via mypy).
- **Incomplete implementation**: A class missing one method should fail a mypy `Protocol` check (static verification, not runtime test).
- **Type check**: `mypy sdk/ralph_sdk/state.py` passes cleanly.
