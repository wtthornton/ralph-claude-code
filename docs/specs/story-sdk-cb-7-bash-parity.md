# Story RALPH-SDK-CB-7: Verify Behavior Matches lib/circuit_breaker.sh

**Epic:** [Active Circuit Breaker](epic-sdk-circuit-breaker.md)
**Priority:** High
**Status:** Pending
**Effort:** Small
**Component:** `sdk/tests/`

---

## Problem

The Python `CircuitBreaker` class must behave identically to the bash implementation in `lib/circuit_breaker.sh` for common scenarios. Behavioral drift between the two implementations would cause different outcomes depending on whether Ralph runs in bash mode or SDK mode.

Key bash behaviors to verify (from `lib/circuit_breaker.sh`):

1. **5 failures trip** (`CB_FAILURE_THRESHOLD=5`): `cb_evaluate_window()` trips at line 325 when `failures >= CB_FAILURE_THRESHOLD`
2. **Cooldown recovery** (`CB_COOLDOWN_MINUTES=30`): `_cb_check_cooldown()` at line 201-225 transitions OPEN -> HALF_OPEN when elapsed time >= cooldown
3. **Success after half-open**: `cb_record_success()` at line 278-283 records success, and the state file transitions HALF_OPEN -> CLOSED
4. **No-progress detection**: `consecutive_no_progress` field in state file, tracked by `on-stop.sh` hook
5. **Sliding window**: Only failures within `CB_FAILURE_DECAY_MINUTES` count (lines 262-311)

## Solution

Create a dedicated test module (`sdk/tests/test_circuit_breaker_parity.py`) that exercises the same scenarios against both the bash and Python implementations, verifying identical outcomes. These are integration-style tests that validate behavioral equivalence, not unit tests of individual methods.

## Implementation

### Step 1: Create parity test file

```python
# sdk/tests/test_circuit_breaker_parity.py
"""Parity tests: Python CircuitBreaker vs lib/circuit_breaker.sh.

These tests verify that the Python implementation produces the same
state transitions as the bash implementation for common scenarios.
"""
import time
import pytest
from ralph_sdk.circuit_breaker import CircuitBreaker, CBState

class MockStateBackend:
    """In-memory backend for parity tests."""
    def __init__(self):
        self._state = {}
        self._events = []

    def load_circuit_breaker(self):
        return self._state

    def save_circuit_breaker(self, state):
        self._state = state

    def record_circuit_event(self, event):
        self._events.append(event)
```

### Step 2: Parity scenario — 5 failures trip

```python
def test_parity_five_failures_trip():
    """Bash: CB_FAILURE_THRESHOLD=5 trips at 5 failures.
    Python: failure_threshold=5 trips at 5 failures.

    Reference: lib/circuit_breaker.sh line 325:
        if [[ "$failures" -ge "$CB_FAILURE_THRESHOLD" ]]; then
    """
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, failure_threshold=5, window_minutes=30)

    # 4 failures: still CLOSED
    for i in range(4):
        cb.record_failure(f"error_{i}")
    assert cb.state == CBState.CLOSED

    # 5th failure: trips to OPEN
    cb.record_failure("error_4")
    assert cb.state == CBState.OPEN
```

### Step 3: Parity scenario — cooldown recovery

```python
def test_parity_cooldown_recovery():
    """Bash: _cb_check_cooldown() transitions OPEN -> HALF_OPEN after cooldown.
    Python: can_proceed() transitions OPEN -> HALF_OPEN after cooldown.

    Reference: lib/circuit_breaker.sh lines 210-223:
        if [[ $elapsed_minutes -ge $CB_COOLDOWN_MINUTES ]]; then
            ... HALF_OPEN ...
    """
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, cooldown_minutes=30, failure_threshold=1)

    # Trip the breaker
    cb.record_failure("test")
    assert cb.state == CBState.OPEN

    # Before cooldown: stays OPEN
    assert cb.can_proceed() is False

    # Simulate cooldown elapsed (31 minutes ago)
    cb._opened_at = time.time() - (31 * 60)

    # After cooldown: transitions to HALF_OPEN
    assert cb.can_proceed() is True
    assert cb.state == CBState.HALF_OPEN
```

### Step 4: Parity scenario — success after half-open

```python
def test_parity_success_after_half_open():
    """Bash: success in HALF_OPEN -> CLOSED (via on-stop.sh hook).
    Python: record_success() in HALF_OPEN -> CLOSED.

    Full cycle: CLOSED -> OPEN -> HALF_OPEN -> CLOSED
    """
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, failure_threshold=1, cooldown_minutes=0)

    # CLOSED -> OPEN
    cb.record_failure("test")
    assert cb.state == CBState.OPEN

    # OPEN -> HALF_OPEN (cooldown=0, immediate)
    assert cb.can_proceed() is True
    assert cb.state == CBState.HALF_OPEN

    # HALF_OPEN -> CLOSED (success)
    cb.record_success()
    assert cb.state == CBState.CLOSED
```

### Step 5: Parity scenario — no-progress detection

```python
def test_parity_no_progress_detection():
    """Bash: consecutive_no_progress >= threshold trips.
    Python: record_no_progress() count >= no_progress_threshold trips.

    Reference: on-stop.sh increments consecutive_no_progress when
    no files changed and no tasks completed.
    """
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, no_progress_threshold=3)

    cb.record_no_progress()
    cb.record_no_progress()
    assert cb.state == CBState.CLOSED

    cb.record_no_progress()
    assert cb.state == CBState.OPEN
    assert "no_progress" in cb._reason
```

### Step 6: Parity scenario — sliding window expiry

```python
def test_parity_sliding_window_expiry():
    """Bash: old failures outside CB_FAILURE_DECAY_MINUTES are excluded.
    Python: old failures outside window_minutes are excluded.

    Reference: lib/circuit_breaker.sh line 308:
        total=$(awk -v cutoff="$cutoff" '$1 >= cutoff' ...)

    This verifies the CBDECAY-1 fix is replicated in Python.
    """
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, failure_threshold=5, window_minutes=5)

    # 4 old failures (outside 5-min window)
    old_time = time.time() - 600  # 10 minutes ago
    cb._failure_timestamps = [old_time] * 4

    # 2 new failures (inside window)
    cb.record_failure("recent_1")
    cb.record_failure("recent_2")

    # Should NOT trip: only 2 recent failures, not 5
    assert cb.state == CBState.CLOSED
```

### Step 7: Parity scenario — failure during half-open

```python
def test_parity_failure_during_half_open():
    """Bash: failure during HALF_OPEN -> OPEN.
    Python: record_failure() in HALF_OPEN -> OPEN immediately.

    Any failure during monitoring mode reopens the breaker.
    """
    backend = MockStateBackend()
    cb = CircuitBreaker(backend)
    cb._state = CBState.HALF_OPEN

    cb.record_failure("still broken")

    assert cb.state == CBState.OPEN
```

## Acceptance Criteria

- [ ] Test file `sdk/tests/test_circuit_breaker_parity.py` exists
- [ ] Scenario: 5 failures trip the breaker (matches `CB_FAILURE_THRESHOLD=5`)
- [ ] Scenario: Cooldown recovery OPEN -> HALF_OPEN (matches `CB_COOLDOWN_MINUTES=30`)
- [ ] Scenario: Success after HALF_OPEN -> CLOSED (full recovery cycle)
- [ ] Scenario: No-progress detection at threshold (matches `consecutive_no_progress`)
- [ ] Scenario: Sliding window excludes old failures (matches `CB_FAILURE_DECAY_MINUTES`)
- [ ] Scenario: Failure during HALF_OPEN immediately reopens
- [ ] All tests pass with `pytest sdk/tests/test_circuit_breaker_parity.py`

## Test Plan

The story IS the test plan. Run:

```bash
cd sdk && pytest tests/test_circuit_breaker_parity.py -v
```

All 7 scenarios must pass. These tests serve as the behavioral contract between the bash and Python implementations.
