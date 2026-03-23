# Story SDK-SAFETY-1: Stall Detection (Fast-Trip, Deferred-Test, Consecutive Timeout)

**Epic:** [SDK Loop Safety](epic-sdk-loop-safety.md)
**Priority:** P0
**Status:** Pending
**Effort:** 1–2 days
**Component:** `ralph_sdk/circuit_breaker.py`, `ralph_sdk/config.py`, `ralph_sdk/status.py`

---

## Problem

The SDK's circuit breaker detects failures via a sliding window but misses three stall patterns the CLI catches:

1. **Fast-trip**: Broken invocations (0 tool uses, <30s duration) indicate Claude can't access tools. The CLI trips CB after 3 consecutive occurrences (`MAX_CONSECUTIVE_FAST_FAILURES=3`). The SDK retries indefinitely.

2. **Deferred-test stall**: When `TESTS_STATUS: DEFERRED` appears in consecutive loops without progress, the agent is spinning without validation. The CLI trips CB after 5 consecutive deferred-test loops (`CB_MAX_DEFERRED_TESTS=5`). The SDK has no awareness of deferred test status.

3. **Consecutive timeout**: Repeated timeouts (exit code 124) suggest the task is too large or the API is unresponsive. The CLI trips CB after 5 consecutive timeouts (`MAX_CONSECUTIVE_TIMEOUTS=5`). The SDK treats each timeout independently.

**Production impact:** LOGFIX-6 occurred because deferred-test stall burned budget in TheStudio production.

## Solution

Add `FastTripDetector` and `StallDetector` classes to `circuit_breaker.py`. These compose with the existing `CircuitBreaker` class — they feed signals into the CB's `record_failure()` method rather than replacing the sliding window.

## Implementation

### Step 1: Add stall-related fields to RalphConfig

```python
# In ralph_sdk/config.py, add to RalphConfig:
fast_trip_max: int = Field(default=3, ge=1, description="Max consecutive fast-trip failures before CB trips")
fast_trip_duration_threshold: int = Field(default=30, ge=5, description="Duration in seconds below which a 0-tool run is a fast-trip")
deferred_stall_max: int = Field(default=5, ge=1, description="Max consecutive deferred-test loops before CB trips")
consecutive_timeout_max: int = Field(default=5, ge=1, description="Max consecutive timeouts before CB trips")
```

### Step 2: Add FastTripDetector

```python
# In ralph_sdk/circuit_breaker.py:

class FastTripDetector:
    """Detects broken invocations: 0 tool uses and completes in < threshold seconds."""

    def __init__(self, max_consecutive: int = 3, duration_threshold: int = 30):
        self.max_consecutive = max_consecutive
        self.duration_threshold = duration_threshold
        self._consecutive_count: int = 0

    def record(self, tool_count: int, duration_seconds: float) -> bool:
        """Record an iteration result. Returns True if fast-trip threshold is reached."""
        if tool_count == 0 and duration_seconds < self.duration_threshold:
            self._consecutive_count += 1
        else:
            self._consecutive_count = 0
        return self._consecutive_count >= self.max_consecutive

    def reset(self) -> None:
        self._consecutive_count = 0

    @property
    def count(self) -> int:
        return self._consecutive_count
```

### Step 3: Add StallDetector

```python
class StallDetector:
    """Detects stalls: deferred-test loops without progress, consecutive timeouts."""

    def __init__(self, deferred_max: int = 5, timeout_max: int = 5):
        self.deferred_max = deferred_max
        self.timeout_max = timeout_max
        self._deferred_count: int = 0
        self._timeout_count: int = 0

    def record_deferred(self, tests_deferred: bool, progress_made: bool) -> bool:
        """Record deferred-test status. Returns True if stall threshold reached."""
        if tests_deferred and not progress_made:
            self._deferred_count += 1
        else:
            self._deferred_count = 0
        return self._deferred_count >= self.deferred_max

    def record_timeout(self, timed_out: bool) -> bool:
        """Record timeout. Returns True if consecutive timeout threshold reached."""
        if timed_out:
            self._timeout_count += 1
        else:
            self._timeout_count = 0
        return self._timeout_count >= self.timeout_max

    def reset(self) -> None:
        self._deferred_count = 0
        self._timeout_count = 0

    @property
    def deferred_count(self) -> int:
        return self._deferred_count

    @property
    def timeout_count(self) -> int:
        return self._timeout_count
```

### Step 4: Integrate detectors with agent loop

```python
# In ralph_sdk/agent.py, within RalphAgent.__init__():
self._fast_trip = FastTripDetector(
    max_consecutive=config.fast_trip_max,
    duration_threshold=config.fast_trip_duration_threshold,
)
self._stall = StallDetector(
    deferred_max=config.deferred_stall_max,
    timeout_max=config.consecutive_timeout_max,
)

# In run_iteration(), after processing result:
if self._fast_trip.record(status.tool_count, iteration_duration):
    self._circuit_breaker.trip("fast_trip: {self._fast_trip.count} consecutive 0-tool fast completions")

if self._stall.record_deferred(
    tests_deferred=(status.tests_status == "DEFERRED"),
    progress_made=(status.files_changed > 0 or status.tasks_completed > 0),
):
    self._circuit_breaker.trip(f"deferred_stall: {self._stall.deferred_count} consecutive deferred-test loops without progress")

if self._stall.record_timeout(timed_out=(exit_code == 124)):
    self._circuit_breaker.trip(f"consecutive_timeout: {self._stall.timeout_count} consecutive timeouts")
```

## Design Notes

- **Composition over replacement**: Detectors feed into the existing `CircuitBreaker.trip()` method. The CB's cooldown, auto-recovery, and state machine are unchanged.
- **Progress definition**: Progress = files changed > 0 OR tasks completed > 0. This matches the CLI's definition at `ralph_loop.sh:951-953`.
- **Reset on recovery**: When the circuit breaker transitions HALF_OPEN → CLOSED, both detectors reset their counters.
- **Configurable thresholds**: All thresholds are exposed via `RalphConfig` for embedder customization. Defaults match CLI values.

## Acceptance Criteria

- [ ] `FastTripDetector` trips CB after N consecutive 0-tool runs under threshold duration
- [ ] `StallDetector.record_deferred()` trips CB after N consecutive deferred-test loops without progress
- [ ] `StallDetector.record_timeout()` trips CB after N consecutive timeouts
- [ ] All thresholds configurable via `RalphConfig`
- [ ] Detectors reset on circuit breaker recovery (HALF_OPEN → CLOSED)
- [ ] Progress detection uses files_changed > 0 OR tasks_completed > 0
- [ ] Existing sliding window CB behavior is not regressed
- [ ] Trip reason is included in circuit breaker state for debugging

## Test Plan

```python
import pytest
from ralph_sdk.circuit_breaker import FastTripDetector, StallDetector

class TestFastTripDetector:
    def test_trips_after_threshold(self):
        det = FastTripDetector(max_consecutive=3, duration_threshold=30)
        assert not det.record(tool_count=0, duration_seconds=10)
        assert not det.record(tool_count=0, duration_seconds=15)
        assert det.record(tool_count=0, duration_seconds=20)  # 3rd consecutive

    def test_resets_on_normal_iteration(self):
        det = FastTripDetector(max_consecutive=3, duration_threshold=30)
        det.record(tool_count=0, duration_seconds=10)
        det.record(tool_count=0, duration_seconds=15)
        det.record(tool_count=5, duration_seconds=120)  # Normal iteration
        assert det.count == 0

    def test_no_trip_when_duration_exceeds_threshold(self):
        det = FastTripDetector(max_consecutive=3, duration_threshold=30)
        for _ in range(5):
            assert not det.record(tool_count=0, duration_seconds=60)

    def test_no_trip_when_tools_used(self):
        det = FastTripDetector(max_consecutive=3, duration_threshold=30)
        for _ in range(5):
            assert not det.record(tool_count=3, duration_seconds=10)


class TestStallDetector:
    def test_deferred_trips_after_threshold(self):
        det = StallDetector(deferred_max=5, timeout_max=5)
        for i in range(4):
            assert not det.record_deferred(tests_deferred=True, progress_made=False)
        assert det.record_deferred(tests_deferred=True, progress_made=False)  # 5th

    def test_deferred_resets_on_progress(self):
        det = StallDetector(deferred_max=5, timeout_max=5)
        det.record_deferred(tests_deferred=True, progress_made=False)
        det.record_deferred(tests_deferred=True, progress_made=False)
        det.record_deferred(tests_deferred=True, progress_made=True)  # Progress!
        assert det.deferred_count == 0

    def test_deferred_resets_when_tests_not_deferred(self):
        det = StallDetector(deferred_max=5, timeout_max=5)
        det.record_deferred(tests_deferred=True, progress_made=False)
        det.record_deferred(tests_deferred=False, progress_made=False)
        assert det.deferred_count == 0

    def test_timeout_trips_after_threshold(self):
        det = StallDetector(deferred_max=5, timeout_max=5)
        for i in range(4):
            assert not det.record_timeout(timed_out=True)
        assert det.record_timeout(timed_out=True)  # 5th

    def test_timeout_resets_on_success(self):
        det = StallDetector(deferred_max=5, timeout_max=5)
        det.record_timeout(timed_out=True)
        det.record_timeout(timed_out=True)
        det.record_timeout(timed_out=False)  # Success
        assert det.timeout_count == 0
```

## References

- CLI `ralph_loop.sh`: Fast-trip detection at lines 920-935
- CLI `lib/circuit_breaker.sh`: `MAX_CONSECUTIVE_FAST_FAILURES`, `CB_MAX_DEFERRED_TESTS`, `MAX_CONSECUTIVE_TIMEOUTS`
- Production issue LOGFIX-6: Deferred-test stall budget burn
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.1
