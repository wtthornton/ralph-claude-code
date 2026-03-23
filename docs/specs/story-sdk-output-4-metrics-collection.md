# Story SDK-OUTPUT-4: Metrics Collection

**Epic:** [SDK Structured Output & Observability](epic-sdk-structured-output.md)
**Priority:** P2
**Status:** Pending
**Effort:** 1–2 days
**Component:** New: `ralph_sdk/metrics.py`

---

## Problem

The CLI records per-iteration metrics to monthly JSONL files (`lib/metrics.sh`) and provides aggregated dashboards (success rate, avg loops, CB trips, cost per iteration). The SDK collects no metrics.

TheStudio's Analytics & Learning epic (Epic 39) needs historical Ralph performance data — success rates, average loop counts, cost per task, circuit breaker trip frequency. This data doesn't exist today because the SDK has no metrics collection.

## Solution

Add a `MetricsCollector` protocol with `record()` and `query()` methods. Ship two implementations: `NullMetricsCollector` (no-op) and `JsonlMetricsCollector` (monthly JSONL files matching the CLI format).

## Implementation

```python
# ralph_sdk/metrics.py

import json
import os
from datetime import datetime, timezone
from pathlib import Path
from typing import Protocol, runtime_checkable

from pydantic import BaseModel


class IterationMetric(BaseModel):
    """Metric record for a single iteration."""
    timestamp: str
    session_id: str
    iteration: int
    work_type: str
    loop_status: str
    exit_signal: bool
    files_changed: int
    tasks_completed: int
    duration_seconds: float
    model: str
    input_tokens: int = 0
    output_tokens: int = 0
    cost_usd: float = 0.0
    circuit_breaker_state: str = "CLOSED"
    error_category: str | None = None
    timed_out: bool = False


@runtime_checkable
class MetricsCollector(Protocol):
    """Protocol for metrics collection backends."""

    def record(self, metric: IterationMetric) -> None:
        """Record a single iteration metric."""
        ...

    def query(self, period: str = "current") -> list[IterationMetric]:
        """Query metrics for a period.

        Args:
            period: "current" (current month), "YYYY-MM" (specific month), or "all"
        """
        ...


class NullMetricsCollector:
    """No-op metrics collector for testing and embedding without persistence."""

    def record(self, metric: IterationMetric) -> None:
        pass

    def query(self, period: str = "current") -> list[IterationMetric]:
        return []


class JsonlMetricsCollector:
    """JSONL-based metrics collector matching the CLI's monthly file format.

    Writes one JSONL file per month: metrics_YYYY-MM.jsonl
    """

    def __init__(self, metrics_dir: str | Path):
        self._dir = Path(metrics_dir)
        self._dir.mkdir(parents=True, exist_ok=True)

    def record(self, metric: IterationMetric) -> None:
        """Append metric to the current month's JSONL file."""
        path = self._dir / self._month_filename()
        with open(path, "a", encoding="utf-8") as f:
            f.write(metric.model_dump_json() + "\n")

    def query(self, period: str = "current") -> list[IterationMetric]:
        """Read metrics from JSONL files.

        Args:
            period: "current", "YYYY-MM", or "all"
        """
        if period == "all":
            return self._read_all()
        elif period == "current":
            filename = self._month_filename()
        else:
            filename = f"metrics_{period}.jsonl"

        path = self._dir / filename
        return self._read_file(path)

    def _month_filename(self) -> str:
        return f"metrics_{datetime.now(timezone.utc).strftime('%Y-%m')}.jsonl"

    def _read_file(self, path: Path) -> list[IterationMetric]:
        if not path.exists():
            return []
        metrics = []
        with open(path, "r", encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    metrics.append(IterationMetric.model_validate_json(line))
        return metrics

    def _read_all(self) -> list[IterationMetric]:
        metrics = []
        for path in sorted(self._dir.glob("metrics_*.jsonl")):
            metrics.extend(self._read_file(path))
        return metrics
```

### Agent integration

```python
# In ralph_sdk/agent.py:
from ralph_sdk.metrics import MetricsCollector, NullMetricsCollector, IterationMetric

# In RalphAgent.__init__():
self._metrics: MetricsCollector = metrics_collector or NullMetricsCollector()

# After each iteration:
metric = IterationMetric(
    timestamp=datetime.now(timezone.utc).isoformat(),
    session_id=self._session_id,
    iteration=self._loop_count,
    work_type=status.work_type or "unknown",
    loop_status=status.loop_status or "unknown",
    exit_signal=status.exit_signal,
    files_changed=status.files_changed,
    tasks_completed=status.tasks_completed,
    duration_seconds=iteration_duration,
    model=self._current_model,
    input_tokens=result_input_tokens,
    output_tokens=result_output_tokens,
    cost_usd=cost_record.cost_usd if cost_record else 0.0,
    circuit_breaker_state=self._circuit_breaker.state.value,
    error_category=status.error.category if status.error else None,
    timed_out=(exit_code == 124),
)
self._metrics.record(metric)
```

### Config

```python
# In ralph_sdk/config.py:
metrics_dir: str = Field(default="", description="Directory for JSONL metrics (empty = no file metrics)")
```

## Design Notes

- **Protocol-based**: `MetricsCollector` is a protocol, not a base class. Embedders can implement their own backends (e.g., Postgres, InfluxDB, OTEL) without inheriting from the SDK.
- **Monthly JSONL**: Matches the CLI format. Monthly files prevent unbounded growth while keeping data queryable.
- **NullMetricsCollector**: Default when no `metrics_dir` is configured. Zero overhead.
- **Sync I/O**: File writes are synchronous (append-only JSONL). Async would add complexity for a write that takes <1ms. If this becomes a bottleneck, the embedder can implement an async collector.
- **No aggregation**: Raw metrics only. Aggregation (success rate, avg cost, etc.) is the embedder's responsibility — TheStudio Epic 39 will build the analytics layer.

## Acceptance Criteria

- [ ] `MetricsCollector` protocol defines `record()` and `query()` methods
- [ ] `NullMetricsCollector` is a no-op implementation
- [ ] `JsonlMetricsCollector` writes monthly JSONL files (metrics_YYYY-MM.jsonl)
- [ ] `query("current")` reads current month's metrics
- [ ] `query("YYYY-MM")` reads a specific month
- [ ] `query("all")` reads all months
- [ ] `IterationMetric` captures: timestamp, session_id, iteration, work_type, loop_status, exit_signal, files_changed, tasks_completed, duration, model, tokens, cost, CB state, error category, timeout
- [ ] Agent records a metric after each iteration
- [ ] `metrics_dir` configurable via `RalphConfig`
- [ ] `isinstance(collector, MetricsCollector)` works (runtime checkable)

## Test Plan

```python
import pytest
import tempfile
from pathlib import Path
from ralph_sdk.metrics import (
    JsonlMetricsCollector, NullMetricsCollector, MetricsCollector,
    IterationMetric,
)

class TestNullMetricsCollector:
    def test_record_noop(self):
        collector = NullMetricsCollector()
        collector.record(IterationMetric(
            timestamp="2026-03-23T10:00:00Z", session_id="s1",
            iteration=1, work_type="IMPL", loop_status="CONTINUE",
            exit_signal=False, files_changed=2, tasks_completed=1,
            duration_seconds=120.0, model="claude-sonnet-4-6",
        ))
        assert collector.query() == []

    def test_implements_protocol(self):
        assert isinstance(NullMetricsCollector(), MetricsCollector)


class TestJsonlMetricsCollector:
    def test_write_and_read(self, tmp_path):
        collector = JsonlMetricsCollector(tmp_path)
        metric = IterationMetric(
            timestamp="2026-03-23T10:00:00Z", session_id="s1",
            iteration=1, work_type="IMPL", loop_status="CONTINUE",
            exit_signal=False, files_changed=2, tasks_completed=1,
            duration_seconds=120.0, model="claude-sonnet-4-6",
            cost_usd=0.05,
        )
        collector.record(metric)
        results = collector.query("current")
        assert len(results) == 1
        assert results[0].cost_usd == 0.05

    def test_multiple_records(self, tmp_path):
        collector = JsonlMetricsCollector(tmp_path)
        for i in range(5):
            collector.record(IterationMetric(
                timestamp=f"2026-03-23T10:0{i}:00Z", session_id="s1",
                iteration=i, work_type="IMPL", loop_status="CONTINUE",
                exit_signal=False, files_changed=i, tasks_completed=0,
                duration_seconds=60.0, model="claude-sonnet-4-6",
            ))
        assert len(collector.query("current")) == 5

    def test_query_nonexistent_month(self, tmp_path):
        collector = JsonlMetricsCollector(tmp_path)
        assert collector.query("2020-01") == []

    def test_implements_protocol(self, tmp_path):
        assert isinstance(JsonlMetricsCollector(tmp_path), MetricsCollector)
```

## References

- CLI `lib/metrics.sh`: Monthly JSONL metrics, `ralph --stats` aggregation
- TheStudio Epic 39 (Analytics & Learning): Needs historical performance data
- TheStudio Epic 43, Story 43.14: OTEL spans (complementary, not replaced by metrics)
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.9
