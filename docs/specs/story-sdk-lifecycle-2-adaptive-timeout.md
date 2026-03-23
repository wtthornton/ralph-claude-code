# Story SDK-LIFECYCLE-2: Adaptive Timeout

**Epic:** [SDK Lifecycle & Resilience](epic-sdk-lifecycle.md)
**Priority:** P3
**Status:** Pending
**Effort:** 1 day
**Component:** `ralph_sdk/agent.py`, `ralph_sdk/config.py`

---

## Problem

The SDK uses a static `timeout_minutes` from config. A 30-minute timeout is:
- **Too long for trivial tasks**: A small file edit normally completes in 2 minutes. Waiting 30 minutes before detecting a stuck session wastes budget.
- **Too short for architectural changes**: Complex tasks routinely need 35-45 minutes. TheStudio had 19 consecutive timeouts — many were likely productive sessions killed prematurely.

The CLI's `ADAPTIVE_TIMEOUT_ENABLED` adjusts timeout dynamically based on historical iteration durations using a P95 × multiplier approach, with configurable min/max bounds.

## Solution

Add `AdaptiveTimeout` class that tracks iteration durations and computes a dynamic timeout. Uses the same P95 × multiplier algorithm as the CLI's `ralph_compute_adaptive_timeout()`.

## Implementation

```python
# In ralph_sdk/agent.py or new ralph_sdk/timeout.py:

import bisect
from dataclasses import dataclass, field


@dataclass
class AdaptiveTimeout:
    """Adaptive timeout based on historical iteration durations.

    Computes timeout as P95 × multiplier, clamped to min/max bounds.
    Falls back to static timeout until minimum samples are collected.
    """
    enabled: bool = True
    multiplier: float = 2.0
    min_minutes: float = 10.0
    max_minutes: float = 60.0
    min_samples: int = 5
    static_fallback: float = 30.0
    max_samples: int = 50

    _durations: list[float] = field(default_factory=list)

    def record(self, duration_seconds: float, timed_out: bool = False) -> None:
        """Record an iteration duration. Timeouts are excluded to prevent feedback loops."""
        if timed_out:
            return  # Don't let timeouts inflate the P95

        self._durations.append(duration_seconds)

        # Bound the sample window
        if len(self._durations) > self.max_samples:
            self._durations = self._durations[-self.max_samples:]

    def get_timeout_minutes(self) -> float:
        """Compute the current adaptive timeout in minutes.

        Returns static fallback if:
        - Adaptive mode is disabled
        - Insufficient samples (< min_samples)
        """
        if not self.enabled:
            return self.static_fallback

        if len(self._durations) < self.min_samples:
            return self.static_fallback

        # Compute P95
        sorted_durations = sorted(self._durations)
        p95_index = int(len(sorted_durations) * 0.95)
        p95_index = max(0, min(p95_index, len(sorted_durations) - 1))
        p95_seconds = sorted_durations[p95_index]

        # Apply multiplier and convert to minutes
        timeout_seconds = p95_seconds * self.multiplier
        timeout_minutes = timeout_seconds / 60.0

        # Clamp to bounds
        timeout_minutes = max(self.min_minutes, min(self.max_minutes, timeout_minutes))

        return round(timeout_minutes, 1)

    @property
    def sample_count(self) -> int:
        return len(self._durations)

    @property
    def is_adaptive(self) -> bool:
        """Whether enough samples exist for adaptive mode."""
        return self.enabled and len(self._durations) >= self.min_samples
```

### Config fields

```python
# In ralph_sdk/config.py:
adaptive_timeout_enabled: bool = Field(default=False, description="Enable adaptive timeout based on iteration history")
adaptive_timeout_multiplier: float = Field(default=2.0, ge=1.0, description="P95 × multiplier for adaptive timeout")
adaptive_timeout_min_minutes: float = Field(default=10.0, ge=1.0, description="Minimum adaptive timeout (minutes)")
adaptive_timeout_max_minutes: float = Field(default=60.0, ge=5.0, description="Maximum adaptive timeout (minutes)")
adaptive_timeout_min_samples: int = Field(default=5, ge=2, description="Minimum samples before adaptive mode")
```

### Agent integration

```python
# In ralph_sdk/agent.py:
self._adaptive_timeout = AdaptiveTimeout(
    enabled=config.adaptive_timeout_enabled,
    multiplier=config.adaptive_timeout_multiplier,
    min_minutes=config.adaptive_timeout_min_minutes,
    max_minutes=config.adaptive_timeout_max_minutes,
    min_samples=config.adaptive_timeout_min_samples,
    static_fallback=config.timeout_minutes,
)

# Before each iteration:
timeout = self._adaptive_timeout.get_timeout_minutes()

# After each iteration:
self._adaptive_timeout.record(iteration_duration, timed_out=(exit_code == 124))
```

## Design Notes

- **Disabled by default**: `adaptive_timeout_enabled=False` preserves backward compatibility. Embedders opt in after collecting baseline metrics.
- **P95, not P99**: P95 is more responsive to workload changes. P99 would be dominated by outliers.
- **2x multiplier**: Gives 100% headroom over normal P95. Aggressive enough to avoid premature kills but not so generous that stuck sessions run forever.
- **Timeout exclusion**: Timeouts are excluded from the duration record to prevent a feedback loop (timeout → higher P95 → higher timeout → more timeouts...).
- **50-sample window**: Covers ~1-2 days at typical loop cadence. Old enough to capture variation, recent enough to adapt.
- **Matches CLI**: Same algorithm as `ralph_compute_adaptive_timeout()` in the bash CLI.

## Acceptance Criteria

- [ ] `AdaptiveTimeout.get_timeout_minutes()` computes P95 × multiplier
- [ ] Falls back to static timeout with < min_samples
- [ ] Timeouts excluded from duration record
- [ ] Timeout clamped to min/max bounds
- [ ] Sample window bounded to max_samples (default 50)
- [ ] `adaptive_timeout_enabled=False` uses static timeout
- [ ] All parameters configurable via `RalphConfig`
- [ ] `is_adaptive` property indicates whether adaptive mode is active

## Test Plan

```python
import pytest
from ralph_sdk.timeout import AdaptiveTimeout

class TestAdaptiveTimeout:
    def test_static_fallback_with_insufficient_samples(self):
        at = AdaptiveTimeout(enabled=True, min_samples=5, static_fallback=30.0)
        at.record(120.0)
        assert at.get_timeout_minutes() == 30.0

    def test_adaptive_after_sufficient_samples(self):
        at = AdaptiveTimeout(
            enabled=True, min_samples=5, multiplier=2.0,
            min_minutes=1.0, max_minutes=120.0,
        )
        for d in [60, 120, 180, 240, 300, 360, 420, 480, 540, 600]:
            at.record(float(d))
        timeout = at.get_timeout_minutes()
        # P95 ≈ 570s, × 2 = 1140s = 19m
        assert 15 <= timeout <= 25

    def test_min_clamp(self):
        at = AdaptiveTimeout(
            enabled=True, min_samples=5, multiplier=2.0,
            min_minutes=10.0, max_minutes=60.0,
        )
        for _ in range(5):
            at.record(30.0)  # 30s each
        # P95 = 30s × 2 = 1m → clamped to 10m
        assert at.get_timeout_minutes() == 10.0

    def test_max_clamp(self):
        at = AdaptiveTimeout(
            enabled=True, min_samples=5, multiplier=2.0,
            min_minutes=10.0, max_minutes=60.0,
        )
        for _ in range(5):
            at.record(3600.0)  # 1 hour each
        # P95 = 3600s × 2 = 120m → clamped to 60m
        assert at.get_timeout_minutes() == 60.0

    def test_timeouts_excluded(self):
        at = AdaptiveTimeout(enabled=True, min_samples=5, static_fallback=30.0)
        for _ in range(10):
            at.record(120.0, timed_out=True)
        assert at.sample_count == 0  # All excluded
        assert at.get_timeout_minutes() == 30.0  # Falls back

    def test_disabled(self):
        at = AdaptiveTimeout(enabled=False, static_fallback=25.0)
        for _ in range(10):
            at.record(600.0)
        assert at.get_timeout_minutes() == 25.0

    def test_sample_window_bounded(self):
        at = AdaptiveTimeout(max_samples=10)
        for i in range(20):
            at.record(float(i * 60))
        assert at.sample_count == 10

    def test_is_adaptive_property(self):
        at = AdaptiveTimeout(enabled=True, min_samples=5)
        assert not at.is_adaptive
        for _ in range(5):
            at.record(120.0)
        assert at.is_adaptive
```

## References

- CLI `lib/complexity.sh` → `ralph_compute_adaptive_timeout()`: P95-based algorithm
- [story-adaptive-1-percentile-timeout.md](story-adaptive-1-percentile-timeout.md): CLI implementation
- AWS Builders Library: "Set timeouts based on measured latency distributions"
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.11
