# Story RALPH-SDK-STATE-3: Implement NullStateBackend

**Epic:** [Pluggable State Backend](epic-sdk-state-backend.md)
**Priority:** High
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/state.py`

---

## Problem

Testing the Ralph SDK currently requires a real `.ralph/` directory with real files.
This creates several problems:

1. Tests create filesystem side effects that must be cleaned up.
2. Tests running in parallel can interfere via shared file paths.
3. CI environments (containers, sandboxes) may have restricted filesystem access.
4. Stateless environments (Lambda, Temporal activities) cannot use file-based state.

A lightweight in-memory backend is needed for testing and stateless deployments.

## Solution

Implement `NullStateBackend` in `sdk/ralph_sdk/state.py` that satisfies the
`RalphStateBackend` protocol using only in-memory data structures. No files are created,
no directories are touched. All state lives in dicts and instance variables within the
backend object.

The name "Null" follows the Null Object pattern -- it is a fully functional backend that
simply does not persist anywhere.

## Implementation

Add `NullStateBackend` class to `sdk/ralph_sdk/state.py`:

```python
class NullStateBackend:
    """In-memory state backend — no persistence, no files.

    All state lives in instance variables. Used for:
      - Unit/integration testing (no filesystem side effects)
      - Stateless environments (Lambda, containers)
      - TheStudio when state is managed externally
    """

    def __init__(self) -> None:
        self._status: RalphStatus = RalphStatus()
        self._circuit_breaker: CircuitBreakerState = CircuitBreakerState()
        self._circuit_events: list[dict[str, Any]] = []
        self._call_count: int = 0
        self._last_reset: int = 0
        self._session_id: str = ""
        self._metrics: list[dict[str, Any]] = []

    # -- Status -----------------------------------------------------------
    async def load_status(self) -> RalphStatus:
        return self._status

    async def save_status(self, status: RalphStatus) -> None:
        self._status = status

    # -- Circuit breaker --------------------------------------------------
    async def load_circuit_breaker(self) -> CircuitBreakerState:
        return self._circuit_breaker

    async def save_circuit_breaker(self, cb: CircuitBreakerState) -> None:
        self._circuit_breaker = cb

    async def record_circuit_event(self, event: dict[str, Any]) -> None:
        self._circuit_events.append(event)

    # -- Rate limiting ----------------------------------------------------
    async def get_call_count(self) -> int:
        return self._call_count

    async def increment_call_count(self) -> int:
        now = int(time.time())
        if now - self._last_reset >= 3600:
            self._call_count = 1
            self._last_reset = now
        else:
            self._call_count += 1
        return self._call_count

    async def reset_call_count(self) -> None:
        self._call_count = 0
        self._last_reset = int(time.time())

    # -- Session ----------------------------------------------------------
    async def load_session_id(self) -> str:
        return self._session_id

    async def save_session_id(self, session_id: str) -> None:
        self._session_id = session_id

    async def clear_session_id(self) -> None:
        self._session_id = ""

    # -- Metrics ----------------------------------------------------------
    async def record_metric(self, metric: dict[str, Any]) -> None:
        self._metrics.append(metric)
```

Key design decisions:
- `increment_call_count` still implements the hourly-reset logic using `time.time()` so
  that rate limiting behavior is consistent between backends.
- `_circuit_events` and `_metrics` are plain lists for easy test assertions (e.g.,
  `assert len(backend._metrics) == 3`).
- State is instance-scoped, not class-scoped -- each `NullStateBackend()` is independent.

## Acceptance Criteria

- [ ] `NullStateBackend` class added to `sdk/ralph_sdk/state.py`
- [ ] Constructor takes no arguments
- [ ] All 12 protocol methods implemented as `async def`
- [ ] No filesystem operations -- no `Path`, no `open()`, no `mkdir()`
- [ ] Status round-trips: save then load returns same object
- [ ] Circuit breaker round-trips: save then load returns same object
- [ ] Call count increments correctly in memory
- [ ] Hourly reset logic works the same as `FileStateBackend`
- [ ] Session ID save/load/clear works in memory
- [ ] `record_circuit_event` and `record_metric` append to internal lists
- [ ] Each instance is independent (no shared class-level state)

## Test Plan

- **No files created**: Initialize `NullStateBackend()` in a temp directory. Call every method. Verify temp directory is empty afterward (no files, no subdirectories created).
- **Status round-trip**: `save_status(status)`, then `load_status()`. Verify the returned `RalphStatus` is the same object (or has same field values).
- **Circuit breaker round-trip**: Same pattern as status.
- **Call count**: Call `increment_call_count()` five times. Verify `get_call_count()` returns 5. Call `reset_call_count()`. Verify `get_call_count()` returns 0.
- **Session lifecycle**: `save_session_id("sess-1")`, verify `load_session_id()` returns `"sess-1"`. `clear_session_id()`, verify `load_session_id()` returns `""`.
- **Event accumulation**: Record three circuit events. Verify `backend._circuit_events` has length 3 with correct payloads.
- **Metric accumulation**: Record two metrics. Verify `backend._metrics` has length 2.
- **Instance isolation**: Create two `NullStateBackend` instances. Mutate one. Verify the other is unaffected.
