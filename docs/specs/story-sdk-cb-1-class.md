# Story RALPH-SDK-CB-1: Implement CircuitBreaker Class with State Machine

**Epic:** [Active Circuit Breaker](epic-sdk-circuit-breaker.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Medium
**Component:** New file `sdk/ralph_sdk/circuit_breaker.py`

---

## Problem

The SDK has a passive `CircuitBreakerState` dataclass in `status.py` (lines 91-172) with `trip()`, `half_open()`, `close()`, and `reset()` methods, but no orchestrating class that drives state transitions based on runtime events. The agent loop calls `check_circuit_breaker()` which reads a file and returns a bool — it never triggers transitions itself.

The bash implementation (`lib/circuit_breaker.sh`) has a full active state machine with three states (CLOSED, HALF_OPEN, OPEN) and functions that drive transitions automatically. The SDK needs an equivalent active `CircuitBreaker` class.

## Solution

Create a new `CircuitBreaker` class in `sdk/ralph_sdk/circuit_breaker.py` that encapsulates the three-state machine and accepts a state backend for persistence. The constructor takes configurable thresholds matching the bash defaults. The class owns the state machine logic; individual `record_*` and `can_proceed()` methods (Stories CB-2 through CB-5) will be added in subsequent stories.

## Implementation

### Step 1: Define the CircuitBreaker class

```python
# sdk/ralph_sdk/circuit_breaker.py
"""Active Circuit Breaker — state machine with sliding window failure detection.

Replicates lib/circuit_breaker.sh behavior in Python.
State transitions are persisted via RalphStateBackend.
"""
from __future__ import annotations

import logging
import time
from enum import Enum
from typing import TYPE_CHECKING, Protocol

if TYPE_CHECKING:
    pass

logger = logging.getLogger("ralph.sdk.circuit_breaker")


class CBState(str, Enum):
    """Circuit breaker states matching bash CB_STATE_* constants."""
    CLOSED = "CLOSED"
    HALF_OPEN = "HALF_OPEN"
    OPEN = "OPEN"
```

### Step 2: Define the state backend protocol

```python
class RalphStateBackend(Protocol):
    """Protocol for circuit breaker state persistence."""

    def load_circuit_breaker(self) -> dict:
        """Load circuit breaker state from storage."""
        ...

    def save_circuit_breaker(self, state: dict) -> None:
        """Save circuit breaker state to storage."""
        ...

    def record_circuit_event(self, event: dict) -> None:
        """Append a circuit breaker event to the audit trail."""
        ...
```

### Step 3: Implement the CircuitBreaker constructor

```python
class CircuitBreaker:
    """Active circuit breaker with three-state machine.

    States: CLOSED -> OPEN -> HALF_OPEN -> CLOSED

    Constructor parameters:
        backend: RalphStateBackend for persistence
        failure_threshold: failures within window to trip (default 5)
        window_minutes: sliding window size (default 30)
        cooldown_minutes: time in OPEN before HALF_OPEN (default 30)
        no_progress_threshold: consecutive zero-work loops to trip (default 3)
    """

    def __init__(
        self,
        backend: RalphStateBackend,
        failure_threshold: int = 5,
        window_minutes: int = 30,
        cooldown_minutes: int = 30,
        no_progress_threshold: int = 3,
    ) -> None:
        self._backend = backend
        self.failure_threshold = failure_threshold
        self.window_minutes = window_minutes
        self.cooldown_minutes = cooldown_minutes
        self.no_progress_threshold = no_progress_threshold

        # Internal state
        self._state = CBState.CLOSED
        self._failure_timestamps: list[float] = []
        self._consecutive_no_progress = 0
        self._opened_at: float | None = None
        self._total_opens = 0
        self._reason = ""

        # Load persisted state
        self._load_state()

    def _load_state(self) -> None:
        """Load state from backend."""
        data = self._backend.load_circuit_breaker()
        if data:
            self._state = CBState(data.get("state", "CLOSED"))
            self._consecutive_no_progress = data.get("consecutive_no_progress", 0)
            self._total_opens = data.get("total_opens", 0)
            self._reason = data.get("reason", "")
            opened_at = data.get("opened_at")
            if opened_at:
                self._opened_at = opened_at  # epoch float

    def _save_state(self) -> None:
        """Persist current state via backend."""
        self._backend.save_circuit_breaker({
            "state": self._state.value,
            "consecutive_no_progress": self._consecutive_no_progress,
            "total_opens": self._total_opens,
            "opened_at": self._opened_at,
            "reason": self._reason,
            "last_change": time.time(),
        })

    def _log_transition(self, from_state: CBState, to_state: CBState, reason: str) -> None:
        """Log state transition and record event."""
        logger.info(
            "Circuit breaker: %s -> %s (%s)",
            from_state.value, to_state.value, reason,
        )
        self._backend.record_circuit_event({
            "timestamp": time.time(),
            "from_state": from_state.value,
            "to_state": to_state.value,
            "reason": reason,
        })

    @property
    def state(self) -> CBState:
        """Current circuit breaker state."""
        return self._state
```

### Step 4: Add `__init__.py` export

Add `CircuitBreaker` and `CBState` to the `ralph_sdk` package exports.

## Acceptance Criteria

- [ ] `CircuitBreaker` class exists in `sdk/ralph_sdk/circuit_breaker.py`
- [ ] Constructor accepts `backend`, `failure_threshold`, `window_minutes`, `cooldown_minutes`, `no_progress_threshold`
- [ ] Default values match bash: threshold=5, window=30, cooldown=30, no_progress=3
- [ ] `CBState` enum has CLOSED, HALF_OPEN, OPEN values
- [ ] `RalphStateBackend` protocol defines `load_circuit_breaker`, `save_circuit_breaker`, `record_circuit_event`
- [ ] State is loaded from backend on construction
- [ ] `_save_state()` persists via backend after transitions
- [ ] `_log_transition()` logs to Python logger and records event via backend
- [ ] `state` property returns current `CBState`

## Test Plan

```python
def test_circuit_breaker_default_construction():
    """Constructor sets correct defaults matching bash."""
    backend = MockStateBackend()
    cb = CircuitBreaker(backend)
    assert cb.state == CBState.CLOSED
    assert cb.failure_threshold == 5
    assert cb.window_minutes == 30
    assert cb.cooldown_minutes == 30
    assert cb.no_progress_threshold == 3

def test_circuit_breaker_custom_thresholds():
    """Constructor accepts custom threshold values."""
    backend = MockStateBackend()
    cb = CircuitBreaker(
        backend,
        failure_threshold=10,
        window_minutes=60,
        cooldown_minutes=15,
        no_progress_threshold=5,
    )
    assert cb.failure_threshold == 10
    assert cb.window_minutes == 60
    assert cb.cooldown_minutes == 15
    assert cb.no_progress_threshold == 5

def test_circuit_breaker_loads_persisted_state():
    """Constructor loads state from backend."""
    backend = MockStateBackend(stored_state={
        "state": "OPEN",
        "consecutive_no_progress": 2,
        "total_opens": 1,
        "opened_at": 1700000000.0,
        "reason": "failure_threshold",
    })
    cb = CircuitBreaker(backend)
    assert cb.state == CBState.OPEN

def test_circuit_breaker_loads_empty_backend():
    """Constructor handles empty/missing backend state gracefully."""
    backend = MockStateBackend(stored_state={})
    cb = CircuitBreaker(backend)
    assert cb.state == CBState.CLOSED

def test_cbstate_enum_values():
    """CBState enum matches bash CB_STATE_* constants."""
    assert CBState.CLOSED.value == "CLOSED"
    assert CBState.HALF_OPEN.value == "HALF_OPEN"
    assert CBState.OPEN.value == "OPEN"
```
