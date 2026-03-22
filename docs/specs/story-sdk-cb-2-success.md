# Story RALPH-SDK-CB-2: Implement record_success() — HALF_OPEN to CLOSED Transition

**Epic:** [Active Circuit Breaker](epic-sdk-circuit-breaker.md)
**Priority:** High
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/circuit_breaker.py`

---

## Problem

After the `CircuitBreaker` class is created (CB-1), it needs a `record_success()` method to handle successful loop iterations. In the bash implementation (`cb_record_success()` in `lib/circuit_breaker.sh`, line 278-283), a success event is recorded, old events are pruned, and — critically — when in HALF_OPEN state, a success transitions the breaker back to CLOSED.

Without this method, the circuit breaker can never recover from HALF_OPEN to CLOSED after a cooldown period.

## Solution

Implement `record_success()` on the `CircuitBreaker` class:

- **HALF_OPEN state**: Transition to CLOSED, reset all counters (consecutive_no_progress, failure timestamps). Log the transition. Persist via backend.
- **CLOSED state**: No-op for state transitions. Reset `consecutive_no_progress` counter to 0 (a success means progress was made). Prune expired failures from the sliding window.
- **OPEN state**: No-op (should not happen — `can_proceed()` blocks execution when OPEN).

## Implementation

### Step 1: Add record_success() method

```python
def record_success(self) -> None:
    """Record a successful iteration.

    HALF_OPEN -> CLOSED: recovery confirmed, reset counters.
    CLOSED: reset no-progress counter, prune old failures.
    OPEN: no-op (should not be called in OPEN state).
    """
    if self._state == CBState.HALF_OPEN:
        old_state = self._state
        self._state = CBState.CLOSED
        self._consecutive_no_progress = 0
        self._failure_timestamps.clear()
        self._opened_at = None
        self._reason = "Recovery successful"
        self._log_transition(old_state, CBState.CLOSED, "Success after half-open")
        self._save_state()
    elif self._state == CBState.CLOSED:
        self._consecutive_no_progress = 0
        self._prune_expired_failures()
        self._save_state()
    # OPEN state: no-op
```

### Step 2: Add failure timestamp pruning helper

```python
def _prune_expired_failures(self) -> None:
    """Remove failure timestamps outside the sliding window."""
    cutoff = time.time() - (self.window_minutes * 60)
    self._failure_timestamps = [
        ts for ts in self._failure_timestamps if ts >= cutoff
    ]
```

## Acceptance Criteria

- [ ] `record_success()` method exists on `CircuitBreaker`
- [ ] When in HALF_OPEN, transitions to CLOSED and resets all counters
- [ ] When in CLOSED, resets `consecutive_no_progress` to 0
- [ ] When in CLOSED, prunes expired failure timestamps from sliding window
- [ ] When in OPEN, is a no-op (does not change state)
- [ ] State transition is logged via `_log_transition()`
- [ ] State is persisted via `_save_state()` after HALF_OPEN -> CLOSED
- [ ] State is persisted via `_save_state()` after CLOSED success (counter reset)

## Test Plan

```python
def test_record_success_half_open_to_closed():
    """HALF_OPEN -> CLOSED on success."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend)
    cb._state = CBState.HALF_OPEN
    cb._consecutive_no_progress = 2
    cb._failure_timestamps = [time.time()]

    cb.record_success()

    assert cb.state == CBState.CLOSED
    assert cb._consecutive_no_progress == 0
    assert cb._failure_timestamps == []
    assert cb._opened_at is None
    assert backend.saved_state["state"] == "CLOSED"

def test_record_success_closed_resets_no_progress():
    """CLOSED success resets no-progress counter."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend)
    cb._state = CBState.CLOSED
    cb._consecutive_no_progress = 2

    cb.record_success()

    assert cb.state == CBState.CLOSED
    assert cb._consecutive_no_progress == 0

def test_record_success_closed_prunes_old_failures():
    """CLOSED success prunes expired failure timestamps."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, window_minutes=5)
    cb._state = CBState.CLOSED
    old_ts = time.time() - 600  # 10 minutes ago, outside 5-min window
    recent_ts = time.time() - 60  # 1 minute ago, inside window
    cb._failure_timestamps = [old_ts, recent_ts]

    cb.record_success()

    assert len(cb._failure_timestamps) == 1
    assert cb._failure_timestamps[0] == recent_ts

def test_record_success_open_is_noop():
    """OPEN state: record_success is a no-op."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend)
    cb._state = CBState.OPEN
    cb._opened_at = time.time()

    cb.record_success()

    assert cb.state == CBState.OPEN  # Unchanged

def test_record_success_logs_transition():
    """HALF_OPEN -> CLOSED logs a transition event."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend)
    cb._state = CBState.HALF_OPEN

    cb.record_success()

    assert len(backend.recorded_events) == 1
    event = backend.recorded_events[0]
    assert event["from_state"] == "HALF_OPEN"
    assert event["to_state"] == "CLOSED"
```
