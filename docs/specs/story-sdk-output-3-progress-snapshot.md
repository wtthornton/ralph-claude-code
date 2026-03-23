# Story SDK-OUTPUT-3: Structured Heartbeat / Progress Snapshot

**Epic:** [SDK Structured Output & Observability](epic-sdk-structured-output.md)
**Priority:** P2
**Status:** Pending
**Effort:** 0.5 day
**Component:** `ralph_sdk/agent.py`

---

## Problem

TheStudio's heartbeat sends `f"ralph_running elapsed={elapsed_s}s"` as a plain string. Temporal dashboards can't extract loop count, work type, or progress. When operators look at the Temporal UI during a long-running Ralph activity, they see only elapsed time — no visibility into what the agent is doing, how many loops it has completed, or whether the circuit breaker is approaching a trip.

## Solution

Add `get_progress() -> ProgressSnapshot` to `RalphAgent` that returns a structured snapshot of current state. TheStudio serializes this into the Temporal heartbeat.

## Implementation

```python
# In ralph_sdk/agent.py:

from pydantic import BaseModel
import time


class ProgressSnapshot(BaseModel):
    """Structured progress for heartbeat reporting."""
    loop_count: int
    work_type: str
    current_task: str | None = None
    elapsed_seconds: float
    circuit_breaker_state: str
    files_changed_total: int = 0
    tasks_completed: int = 0
    last_status: str = "unknown"
    cost_usd: float = 0.0
    model: str = ""


class RalphAgent:
    # ... existing code ...

    def get_progress(self) -> ProgressSnapshot:
        """Return a structured snapshot of current agent progress.

        Designed for heartbeat reporting. TheStudio serializes this
        into the Temporal activity heartbeat so dashboards can show
        real-time progress.
        """
        elapsed = time.monotonic() - self._start_time if self._start_time else 0.0

        return ProgressSnapshot(
            loop_count=self._loop_count,
            work_type=self._last_work_type or "unknown",
            current_task=self._current_task,
            elapsed_seconds=round(elapsed, 1),
            circuit_breaker_state=self._circuit_breaker.state.value,
            files_changed_total=self._total_files_changed,
            tasks_completed=self._total_tasks_completed,
            last_status=self._last_loop_status or "unknown",
            cost_usd=self._cost_tracker.get_session_cost() if self._cost_tracker else 0.0,
            model=self._current_model or self._config.model,
        )
```

### TheStudio integration example

```python
# In TheStudio's activities.py heartbeat loop:
progress = agent.get_progress()
activity.heartbeat(progress.model_dump())
# Temporal UI now shows: {"loop_count": 5, "work_type": "IMPLEMENTATION", ...}
```

## Design Notes

- **Read-only snapshot**: `get_progress()` only reads agent state — no side effects, safe to call from any thread.
- **Pydantic model**: JSON-serializable for Temporal heartbeat and dashboard SSE.
- **Optional cost**: Includes cost when `CostTracker` is available (SDK-COST-1).
- **Minimal overhead**: No async operations — just reads in-memory fields.
- **Heartbeat frequency**: Temporal's SDK auto-throttles outbound heartbeats, so TheStudio can call `activity.heartbeat(agent.get_progress().model_dump())` every loop iteration without performance concern. Heartbeating is also the only way to receive cancellation requests from the workflow — frequent heartbeats enable responsive cancellation.
- **Checkpoint/resume**: Temporal delivers heartbeat details back via `activity.info().heartbeat_details` on retry. `ProgressSnapshot` can serve as checkpoint data for resume-from-last-known-state patterns.

## Acceptance Criteria

- [ ] `ProgressSnapshot` model with: loop_count, work_type, current_task, elapsed_seconds, circuit_breaker_state, files_changed_total, tasks_completed, last_status, cost_usd, model
- [ ] `RalphAgent.get_progress()` returns current state as `ProgressSnapshot`
- [ ] JSON-serializable (Pydantic `model_dump()`)
- [ ] No side effects — safe to call concurrently
- [ ] Includes cost when CostTracker is available

## Test Plan

```python
import pytest
from ralph_sdk.agent import ProgressSnapshot

class TestProgressSnapshot:
    def test_serializable(self):
        snap = ProgressSnapshot(
            loop_count=5,
            work_type="IMPLEMENTATION",
            current_task="Fix login bug",
            elapsed_seconds=120.5,
            circuit_breaker_state="CLOSED",
            files_changed_total=3,
            tasks_completed=2,
            cost_usd=0.45,
            model="claude-sonnet-4-6",
        )
        data = snap.model_dump()
        assert data["loop_count"] == 5
        assert data["work_type"] == "IMPLEMENTATION"
        assert data["cost_usd"] == 0.45

    def test_defaults(self):
        snap = ProgressSnapshot(
            loop_count=0,
            work_type="unknown",
            elapsed_seconds=0.0,
            circuit_breaker_state="CLOSED",
        )
        assert snap.current_task is None
        assert snap.files_changed_total == 0
        assert snap.cost_usd == 0.0

    def test_json_round_trip(self):
        snap = ProgressSnapshot(
            loop_count=10,
            work_type="QA",
            elapsed_seconds=300.0,
            circuit_breaker_state="HALF_OPEN",
        )
        json_str = snap.model_dump_json()
        restored = ProgressSnapshot.model_validate_json(json_str)
        assert restored.loop_count == 10
```

## References

- TheStudio `activities.py`: Current heartbeat sends plain string
- Temporal heartbeat best practices: Structured data enables dashboard filtering
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §2.3
