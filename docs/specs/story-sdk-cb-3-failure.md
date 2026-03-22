# Story RALPH-SDK-CB-3: Implement record_failure(reason) with Sliding Window Detection

**Epic:** [Active Circuit Breaker](epic-sdk-circuit-breaker.md)
**Priority:** Critical
**Status:** Done
**Effort:** Medium
**Component:** `sdk/ralph_sdk/circuit_breaker.py`

---

## Problem

The circuit breaker needs to detect repeated failures and trip the breaker when the failure count exceeds a threshold within a time window. The bash implementation (`lib/circuit_breaker.sh`, lines 268-351) uses a file-based sliding window (`CB_FAILURE_DECAY_MINUTES=30`, `CB_FAILURE_THRESHOLD=5`) that records timestamped events and only counts recent failures.

The SDK's passive `CircuitBreakerState` tracks `same_error_count` as a simple counter with no time windowing. Failures from hours ago count the same as recent ones, leading to false trips (the exact problem that `CBDECAY-1` solved for the bash loop).

## Solution

Implement `record_failure(reason)` on the `CircuitBreaker` class with time-based sliding window detection:

1. Record the failure timestamp
2. Count only failures within `window_minutes`
3. When count >= `failure_threshold`, transition CLOSED -> OPEN
4. When in HALF_OPEN, any single failure immediately transitions to OPEN

This mirrors the bash `cb_record_failure()` + `cb_evaluate_window()` logic.

## Implementation

### Step 1: Add record_failure() method

```python
def record_failure(self, reason: str = "") -> None:
    """Record a failed iteration and evaluate sliding window.

    CLOSED: append timestamp, check if failures in window >= threshold.
    HALF_OPEN: any failure -> OPEN immediately.
    OPEN: record but no transition (already open).

    Args:
        reason: Description of the failure (e.g., "timeout", "error", "is_error:true").
    """
    now = time.time()
    self._failure_timestamps.append(now)
    self._prune_expired_failures()

    if self._state == CBState.HALF_OPEN:
        # Any failure in HALF_OPEN -> OPEN
        self._trip(f"Failure during half-open: {reason}")
    elif self._state == CBState.CLOSED:
        # Evaluate sliding window
        self._evaluate_window(reason)
    # OPEN: already open, just record
```

### Step 2: Implement sliding window evaluation

```python
def _evaluate_window(self, reason: str) -> None:
    """Evaluate the sliding window and trip if threshold reached.

    Matches bash cb_evaluate_window() logic:
    - Only count failures within window_minutes
    - Trip when count >= failure_threshold
    """
    window_failures = len(self._failure_timestamps)  # Already pruned

    if window_failures >= self.failure_threshold:
        logger.warning(
            "Circuit breaker threshold reached: %d failures in last %dm",
            window_failures, self.window_minutes,
        )
        self._trip(
            f"failure_threshold: {window_failures} failures "
            f"in {self.window_minutes}m window"
        )
```

### Step 3: Implement the trip helper

```python
def _trip(self, reason: str) -> None:
    """Transition to OPEN state."""
    old_state = self._state
    self._state = CBState.OPEN
    self._opened_at = time.time()
    self._total_opens += 1
    self._reason = reason
    self._log_transition(old_state, CBState.OPEN, reason)
    self._save_state()
```

### Step 4: Ensure _prune_expired_failures is available

This method is defined in CB-2. It removes timestamps older than `window_minutes`:

```python
def _prune_expired_failures(self) -> None:
    """Remove failure timestamps outside the sliding window."""
    cutoff = time.time() - (self.window_minutes * 60)
    self._failure_timestamps = [
        ts for ts in self._failure_timestamps if ts >= cutoff
    ]
```

## Design Notes

- **Sliding window vs cumulative**: Matches the bash `CBDECAY-1` fix. Only recent failures count, preventing false trips from old bursts.
- **No minimum calls check**: The bash implementation has `CB_MIN_CALLS=3`. This can be added if needed, but the Python implementation starts simpler. If the agent hasn't made 3 calls yet, it's unlikely to have 5 failures.
- **HALF_OPEN single-failure trip**: Matches bash behavior where any failure during monitoring mode immediately reopens the breaker. This is stricter than CLOSED mode (which requires threshold failures).

## Acceptance Criteria

- [ ] `record_failure(reason)` method exists on `CircuitBreaker`
- [ ] Failure timestamps are recorded and used for sliding window
- [ ] Only failures within `window_minutes` count toward threshold
- [ ] When failure count >= `failure_threshold` in window, transitions CLOSED -> OPEN
- [ ] When in HALF_OPEN, any single failure transitions to OPEN
- [ ] When in OPEN, failure is recorded but no state change
- [ ] `_trip()` sets `_opened_at`, increments `_total_opens`, logs transition
- [ ] State is persisted after every trip
- [ ] Expired failure timestamps are pruned on each `record_failure()` call

## Test Plan

```python
def test_record_failure_below_threshold():
    """Failures below threshold do not trip the breaker."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, failure_threshold=5)

    for _ in range(4):
        cb.record_failure("test error")

    assert cb.state == CBState.CLOSED

def test_record_failure_at_threshold_trips():
    """5 failures within window trip the breaker."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, failure_threshold=5)

    for _ in range(5):
        cb.record_failure("test error")

    assert cb.state == CBState.OPEN
    assert cb._total_opens == 1
    assert cb._opened_at is not None

def test_record_failure_sliding_window_excludes_old():
    """Old failures outside window do not count."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, failure_threshold=5, window_minutes=5)

    # 4 old failures (10 min ago, outside 5-min window)
    old_time = time.time() - 600
    cb._failure_timestamps = [old_time] * 4

    # 1 new failure (inside window)
    cb.record_failure("new error")

    assert cb.state == CBState.CLOSED  # Only 1 recent failure, not 5

def test_record_failure_half_open_single_failure_trips():
    """Any failure in HALF_OPEN immediately reopens."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend)
    cb._state = CBState.HALF_OPEN

    cb.record_failure("test error")

    assert cb.state == CBState.OPEN

def test_record_failure_open_state_records_only():
    """Failure in OPEN state is recorded but doesn't change state."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend)
    cb._state = CBState.OPEN
    cb._opened_at = time.time()
    cb._total_opens = 1

    cb.record_failure("another error")

    assert cb.state == CBState.OPEN
    assert cb._total_opens == 1  # Not incremented again

def test_record_failure_tracks_reason():
    """Trip reason is stored."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, failure_threshold=1)

    cb.record_failure("API timeout")

    assert cb.state == CBState.OPEN
    assert "failure_threshold" in cb._reason

def test_record_failure_logs_transition_event():
    """Trip logs a transition event via backend."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, failure_threshold=1)

    cb.record_failure("test")

    assert len(backend.recorded_events) == 1
    event = backend.recorded_events[0]
    assert event["from_state"] == "CLOSED"
    assert event["to_state"] == "OPEN"
```
