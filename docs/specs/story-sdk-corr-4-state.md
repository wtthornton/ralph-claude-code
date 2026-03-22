# Story RALPH-SDK-CORR-4: Include correlation_id in status.json and Circuit Breaker Events

**Epic:** [Correlation ID Threading](epic-sdk-correlation-id.md)
**Priority:** Medium
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/status.py`, `sdk/ralph_sdk/circuit_breaker.py`

---

## Problem

The status.json file (written by `RalphStatus.save()` in status.py, lines 74-88) and circuit breaker event records (written by `CircuitBreaker._log_transition()` from CB-1) contain no correlation context. When reviewing state files after a multi-run session, there is no way to determine which run produced which status update or circuit breaker event.

## Solution

1. Include `correlation_id` in the status.json output (handled by CORR-2's `RalphStatus.to_dict()` changes — this story ensures the agent loop actually sets it before saving).
2. Include `correlation_id` in circuit breaker event records passed to `RalphStateBackend.record_circuit_event()`.

## Implementation

### Step 1: Ensure status.json includes correlation_id

In `RalphAgent.run_iteration()`, the `RalphStatus` object already gets `correlation_id` set via CORR-2. Verify that `status.save()` writes it:

```python
# In run_iteration():
status = self._parse_response(result.stdout, result.returncode)
status.loop_count = self.loop_count
status.session_id = self.session_id
status.correlation_id = str(self.correlation_id)  # Set before save
status.save(str(self.ralph_dir))
```

The resulting `status.json` will include:

```json
{
    "WORK_TYPE": "IMPLEMENTATION",
    "COMPLETED_TASK": "Fixed the bug",
    "correlation_id": "550e8400-e29b-41d4-a716-446655440000",
    ...
}
```

### Step 2: Add correlation_id to circuit breaker events

Update `CircuitBreaker._log_transition()` (from CB-1) to accept and include `correlation_id`:

```python
class CircuitBreaker:
    def __init__(
        self,
        backend: RalphStateBackend,
        *,
        correlation_id: str = "",
        # ... other params ...
    ) -> None:
        self._correlation_id = correlation_id
        # ... existing init ...

    def _log_transition(self, from_state: CBState, to_state: CBState, reason: str) -> None:
        """Log state transition and record event."""
        logger.info(
            "Circuit breaker: %s -> %s (%s)",
            from_state.value, to_state.value, reason,
        )
        event = {
            "timestamp": time.time(),
            "from_state": from_state.value,
            "to_state": to_state.value,
            "reason": reason,
        }
        if self._correlation_id:
            event["correlation_id"] = self._correlation_id
        self._backend.record_circuit_event(event)
```

### Step 3: Pass correlation_id from agent to circuit breaker

In `RalphAgent.__init__()` (updated by CB-6):

```python
self._circuit_breaker = CircuitBreaker(
    backend=backend,
    correlation_id=str(self.correlation_id),
    failure_threshold=self.config.cb_same_error_threshold,
    # ... other params ...
)
```

### Step 4: Include correlation_id in circuit breaker state file

Update `CircuitBreaker._save_state()` to include correlation_id:

```python
def _save_state(self) -> None:
    """Persist current state via backend."""
    state = {
        "state": self._state.value,
        "consecutive_no_progress": self._consecutive_no_progress,
        "total_opens": self._total_opens,
        "opened_at": self._opened_at,
        "reason": self._reason,
        "last_change": time.time(),
    }
    if self._correlation_id:
        state["correlation_id"] = self._correlation_id
    self._backend.save_circuit_breaker(state)
```

## Design Notes

- **Backward compatible**: The `correlation_id` field is only included when non-empty. Existing bash consumers (`jq -r '.state'`) are unaffected by the extra field.
- **Circuit breaker gets a string, not UUID**: The circuit breaker module should not depend on the `uuid` module. It receives a plain string from the agent.
- **Event audit trail**: Circuit breaker events with correlation_id enable TheStudio to attribute breaker trips to specific task executions.

## Acceptance Criteria

- [ ] `status.json` includes `correlation_id` field when set by the agent
- [ ] `CircuitBreaker` constructor accepts optional `correlation_id: str` parameter
- [ ] Circuit breaker event records include `correlation_id` when set
- [ ] Circuit breaker state file (`.circuit_breaker_state`) includes `correlation_id` when set
- [ ] `correlation_id` is omitted from all outputs when empty (backward compatible)
- [ ] Bash loop is unaffected by the extra field in status.json
- [ ] Agent passes `str(self.correlation_id)` to the circuit breaker

## Test Plan

```python
import json
from pathlib import Path

def test_status_json_includes_correlation_id(tmp_path):
    """status.json includes correlation_id when set."""
    status = RalphStatus(correlation_id="test-corr-id")
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    status.save(str(ralph_dir))

    data = json.loads((ralph_dir / "status.json").read_text())
    assert data["correlation_id"] == "test-corr-id"

def test_status_json_omits_empty_correlation(tmp_path):
    """status.json omits correlation_id when empty."""
    status = RalphStatus()
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    status.save(str(ralph_dir))

    data = json.loads((ralph_dir / "status.json").read_text())
    assert "correlation_id" not in data

def test_circuit_breaker_event_includes_correlation():
    """Circuit breaker events include correlation_id."""
    backend = MockStateBackend()
    cb = CircuitBreaker(
        backend,
        correlation_id="cb-corr-id",
        failure_threshold=1,
    )
    cb.record_failure("test")

    assert len(backend.recorded_events) == 1
    assert backend.recorded_events[0]["correlation_id"] == "cb-corr-id"

def test_circuit_breaker_event_omits_empty_correlation():
    """Circuit breaker events omit correlation_id when empty."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, failure_threshold=1)
    cb.record_failure("test")

    assert "correlation_id" not in backend.recorded_events[0]

def test_circuit_breaker_state_includes_correlation():
    """Circuit breaker state file includes correlation_id."""
    backend = MockStateBackend()
    cb = CircuitBreaker(
        backend,
        correlation_id="state-corr-id",
        failure_threshold=1,
    )
    cb.record_failure("test")

    assert backend.saved_state.get("correlation_id") == "state-corr-id"
```
