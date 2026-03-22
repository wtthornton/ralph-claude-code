# Story RALPH-SDK-CB-4: Implement record_no_progress() Detection

**Epic:** [Active Circuit Breaker](epic-sdk-circuit-breaker.md)
**Priority:** High
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/circuit_breaker.py`

---

## Problem

Ralph can enter a state where Claude responds successfully (no errors, no timeouts) but makes no actual progress — no files are changed, no tasks are completed. The bash implementation tracks this via `consecutive_no_progress` in `.circuit_breaker_state` and trips the breaker when the count exceeds a threshold.

The SDK's passive `CircuitBreakerState` has a `no_progress_count` field but never increments it. The agent loop has no mechanism to detect zero-work iterations and signal the circuit breaker.

## Solution

Implement `record_no_progress()` on the `CircuitBreaker` class:

1. Increment `_consecutive_no_progress` counter
2. When count >= `no_progress_threshold` (default 3), trip the breaker
3. The counter is reset to 0 on any `record_success()` call (already handled in CB-2)

A "no progress" iteration is defined as: no files changed AND no tasks completed. The caller (agent loop) determines this from the `RalphStatus` fields — the circuit breaker itself just tracks the count.

## Implementation

### Step 1: Add record_no_progress() method

```python
def record_no_progress(self) -> None:
    """Record a zero-work iteration (no files changed, no tasks completed).

    Increments the consecutive no-progress counter. When the count
    reaches no_progress_threshold, trips the breaker.

    The counter is reset on record_success() (a successful iteration
    with actual progress).
    """
    self._consecutive_no_progress += 1
    logger.debug(
        "No progress detected: %d/%d consecutive",
        self._consecutive_no_progress,
        self.no_progress_threshold,
    )

    if self._consecutive_no_progress >= self.no_progress_threshold:
        self._trip(
            f"no_progress: {self._consecutive_no_progress} consecutive "
            f"zero-work iterations"
        )
    else:
        self._save_state()
```

## Design Notes

- **Caller determines "no progress"**: The `CircuitBreaker` does not inspect `RalphStatus` directly. The agent loop checks `status.work_type`, `status.completed_task`, and file change detection, then calls `record_no_progress()` or `record_success()` accordingly. This keeps the circuit breaker focused on state management.
- **Interaction with record_failure()**: A failing iteration (error, timeout) should call `record_failure()`, not `record_no_progress()`. No-progress detection is for iterations that *succeed* technically but accomplish nothing. However, `record_no_progress()` does NOT reset the no-progress counter — only `record_success()` does.
- **Default threshold of 3**: Matches bash behavior. Three consecutive zero-work loops strongly indicate Claude is stuck.

## Acceptance Criteria

- [ ] `record_no_progress()` method exists on `CircuitBreaker`
- [ ] Increments `_consecutive_no_progress` on each call
- [ ] When count >= `no_progress_threshold`, trips the breaker (CLOSED -> OPEN)
- [ ] Trip reason includes the count and "no_progress" label
- [ ] Counter is NOT reset by `record_no_progress()` itself
- [ ] Counter IS reset by `record_success()` (verified by CB-2)
- [ ] State is persisted after each call (even non-tripping ones, for visibility)
- [ ] Debug log message shows current count vs threshold

## Test Plan

```python
def test_record_no_progress_increments_counter():
    """Each call increments the no-progress counter."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, no_progress_threshold=5)

    cb.record_no_progress()
    assert cb._consecutive_no_progress == 1

    cb.record_no_progress()
    assert cb._consecutive_no_progress == 2

def test_record_no_progress_trips_at_threshold():
    """Trips breaker when count reaches threshold."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, no_progress_threshold=3)

    cb.record_no_progress()
    cb.record_no_progress()
    assert cb.state == CBState.CLOSED  # Not yet

    cb.record_no_progress()
    assert cb.state == CBState.OPEN  # 3 >= 3, tripped
    assert "no_progress" in cb._reason

def test_record_no_progress_reset_by_success():
    """Counter is reset when record_success() is called."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, no_progress_threshold=3)

    cb.record_no_progress()
    cb.record_no_progress()
    assert cb._consecutive_no_progress == 2

    cb.record_success()
    assert cb._consecutive_no_progress == 0

    # Needs 3 more no-progress calls to trip
    cb.record_no_progress()
    cb.record_no_progress()
    assert cb.state == CBState.CLOSED

def test_record_no_progress_persists_state():
    """State is saved after each no-progress call."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, no_progress_threshold=5)

    cb.record_no_progress()
    assert backend.save_count >= 1

def test_record_no_progress_default_threshold():
    """Default no_progress_threshold is 3 (matching bash)."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend)
    assert cb.no_progress_threshold == 3
```
