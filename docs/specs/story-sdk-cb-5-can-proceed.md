# Story RALPH-SDK-CB-5: Implement can_proceed() with Cooldown Check

**Epic:** [Active Circuit Breaker](epic-sdk-circuit-breaker.md)
**Priority:** Critical
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/circuit_breaker.py`

---

## Problem

The agent loop needs a single method to check whether it should proceed with the next iteration. In the bash implementation, `can_execute()` (`lib/circuit_breaker.sh`, line 97-101) checks if state is not OPEN, and `_cb_check_cooldown()` (line 201-225) handles the OPEN -> HALF_OPEN transition when the cooldown period has elapsed.

The SDK's `check_circuit_breaker()` in `agent.py` (line 354-357) reads state from a file and returns a bool, but never handles cooldown-based recovery. If the breaker trips, it stays OPEN until manually reset.

## Solution

Implement `can_proceed()` on the `CircuitBreaker` class:

- **CLOSED**: Return `True` (normal operation)
- **HALF_OPEN**: Return `True` (monitoring mode, allow one iteration to test recovery)
- **OPEN**: Check if `cooldown_minutes` have elapsed since `_opened_at`. If elapsed, transition to HALF_OPEN and return `True`. Otherwise return `False`.

This is the primary method called by the agent loop before each iteration.

## Implementation

### Step 1: Add can_proceed() method

```python
def can_proceed(self) -> bool:
    """Check if the agent loop should proceed with the next iteration.

    Returns True if CLOSED or HALF_OPEN.
    When OPEN, checks cooldown and transitions to HALF_OPEN if elapsed.

    Matches bash can_execute() + _cb_check_cooldown() combined behavior.
    """
    if self._state == CBState.CLOSED:
        return True

    if self._state == CBState.HALF_OPEN:
        return True

    # OPEN: check cooldown
    if self._state == CBState.OPEN and self._opened_at is not None:
        elapsed_seconds = time.time() - self._opened_at
        elapsed_minutes = elapsed_seconds / 60

        if elapsed_minutes >= self.cooldown_minutes:
            logger.info(
                "Cooldown elapsed (%.1fm >= %dm), transitioning to HALF_OPEN",
                elapsed_minutes, self.cooldown_minutes,
            )
            old_state = self._state
            self._state = CBState.HALF_OPEN
            self._reason = (
                f"Cooldown recovery: {elapsed_minutes:.0f}m elapsed"
            )
            self._log_transition(
                old_state, CBState.HALF_OPEN,
                f"Cooldown elapsed ({elapsed_minutes:.0f}m >= {self.cooldown_minutes}m)",
            )
            self._save_state()
            return True

    return False
```

## Design Notes

- **Reload from backend**: `can_proceed()` should optionally reload state from the backend to support external resets (e.g., `ralph --reset-circuit` from bash). Consider calling `_load_state()` at the start. This is important for dual-mode operation where the bash loop might reset the breaker while the SDK is paused.
- **`_opened_at` as epoch float**: Stored as `time.time()` epoch for easy arithmetic. The bash implementation stores ISO timestamps and converts to epoch for comparison. Python uses floats directly.
- **Cooldown default 30 minutes**: Matches bash `CB_COOLDOWN_MINUTES=30`.

## Acceptance Criteria

- [ ] `can_proceed()` method exists on `CircuitBreaker`
- [ ] Returns `True` when state is CLOSED
- [ ] Returns `True` when state is HALF_OPEN
- [ ] Returns `False` when state is OPEN and cooldown not elapsed
- [ ] Transitions OPEN -> HALF_OPEN when cooldown elapsed, then returns `True`
- [ ] Transition is logged via `_log_transition()`
- [ ] State is persisted after OPEN -> HALF_OPEN transition
- [ ] Handles missing `_opened_at` gracefully (returns `False` for safety)

## Test Plan

```python
def test_can_proceed_closed():
    """CLOSED state always allows proceeding."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend)
    assert cb.can_proceed() is True

def test_can_proceed_half_open():
    """HALF_OPEN state allows proceeding (monitoring mode)."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend)
    cb._state = CBState.HALF_OPEN
    assert cb.can_proceed() is True

def test_can_proceed_open_before_cooldown():
    """OPEN state blocks proceeding when cooldown not elapsed."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, cooldown_minutes=30)
    cb._state = CBState.OPEN
    cb._opened_at = time.time()  # Just opened

    assert cb.can_proceed() is False

def test_can_proceed_open_after_cooldown():
    """OPEN state allows proceeding after cooldown, transitions to HALF_OPEN."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, cooldown_minutes=30)
    cb._state = CBState.OPEN
    cb._opened_at = time.time() - (31 * 60)  # 31 minutes ago

    assert cb.can_proceed() is True
    assert cb.state == CBState.HALF_OPEN

def test_can_proceed_open_no_opened_at():
    """OPEN state with missing opened_at returns False (safe default)."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend)
    cb._state = CBState.OPEN
    cb._opened_at = None

    assert cb.can_proceed() is False

def test_can_proceed_cooldown_logs_transition():
    """Cooldown recovery logs a transition event."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, cooldown_minutes=1)
    cb._state = CBState.OPEN
    cb._opened_at = time.time() - 120  # 2 minutes ago

    cb.can_proceed()

    assert len(backend.recorded_events) == 1
    event = backend.recorded_events[0]
    assert event["from_state"] == "OPEN"
    assert event["to_state"] == "HALF_OPEN"

def test_can_proceed_cooldown_persists():
    """Cooldown recovery persists state via backend."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend, cooldown_minutes=1)
    cb._state = CBState.OPEN
    cb._opened_at = time.time() - 120

    cb.can_proceed()

    assert backend.saved_state["state"] == "HALF_OPEN"
```
