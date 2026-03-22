# Story RALPH-SDK-CB-6: Wire CircuitBreaker into RalphAgent Loop

**Epic:** [Active Circuit Breaker](epic-sdk-circuit-breaker.md)
**Priority:** High
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

The `RalphAgent.run()` loop (agent.py, lines 175-259) currently uses a passive `check_circuit_breaker()` method (line 354-357) that reads `.circuit_breaker_state` via `ralph_circuit_state_tool()` and returns a bool. It never calls `record_success()`, `record_failure()`, or `record_no_progress()`. The circuit breaker is read-only from the SDK's perspective.

After implementing the active `CircuitBreaker` class (CB-1 through CB-5), it must be wired into the agent loop to replace the passive check.

## Solution

1. Instantiate `CircuitBreaker` in `RalphAgent.__init__()` with config-driven thresholds
2. Replace `check_circuit_breaker()` call with `self._circuit_breaker.can_proceed()`
3. After each iteration, call `record_success()`, `record_failure()`, or `record_no_progress()` based on the iteration result

## Implementation

### Step 1: Add CircuitBreaker to __init__()

```python
from ralph_sdk.circuit_breaker import CircuitBreaker, FileStateBackend

class RalphAgent:
    def __init__(
        self,
        config: RalphConfig | None = None,
        project_dir: str | Path = ".",
    ) -> None:
        self.config = config or RalphConfig.load(project_dir)
        self.project_dir = Path(project_dir).resolve()
        self.ralph_dir = self.project_dir / self.config.ralph_dir
        # ... existing init ...

        # Active circuit breaker (replaces passive check)
        backend = FileStateBackend(str(self.ralph_dir))
        self._circuit_breaker = CircuitBreaker(
            backend=backend,
            failure_threshold=self.config.cb_same_error_threshold,  # default 5
            window_minutes=30,  # match bash CB_FAILURE_DECAY_MINUTES
            cooldown_minutes=self.config.cb_cooldown_minutes,  # default 30
            no_progress_threshold=self.config.cb_no_progress_threshold,  # default 3
        )
```

### Step 2: Replace check_circuit_breaker() in the loop

```python
# Before (passive):
if not self.check_circuit_breaker():
    logger.warning("Circuit breaker OPEN, stopping")
    result.error = "Circuit breaker open"
    break

# After (active):
if not self._circuit_breaker.can_proceed():
    logger.warning("Circuit breaker OPEN, stopping")
    result.error = "Circuit breaker open"
    break
```

### Step 3: Call record_* methods after each iteration

```python
# After run_iteration() returns:
iteration_status = self.run_iteration(task_input)

# Classify the result and update circuit breaker
if iteration_status.status == "ERROR" or iteration_status.status == "TIMEOUT":
    self._circuit_breaker.record_failure(
        reason=iteration_status.error or iteration_status.status
    )
elif self._is_no_progress(iteration_status):
    self._circuit_breaker.record_no_progress()
else:
    self._circuit_breaker.record_success()
```

### Step 4: Add _is_no_progress() helper

```python
def _is_no_progress(self, status: RalphStatus) -> bool:
    """Determine if an iteration made no progress.

    No progress = no completed task AND work_type is UNKNOWN/empty.
    """
    has_completed_task = bool(status.completed_task and status.completed_task.strip())
    has_work = status.work_type not in ("UNKNOWN", "", "NONE")
    return not has_completed_task and not has_work
```

### Step 5: Update check_circuit_breaker() for backward compatibility

```python
def check_circuit_breaker(self) -> bool:
    """Check circuit breaker — returns True if OK to proceed.

    Delegates to the active CircuitBreaker instance.
    Kept for backward compatibility with RalphAgentInterface.
    """
    return self._circuit_breaker.can_proceed()
```

### Step 6: Remove the startup counter reset

The current `run()` method resets `cb.no_progress_count = 0` at startup using the passive dataclass. This should be removed — the `CircuitBreaker` manages its own counters via the state backend.

## Acceptance Criteria

- [ ] `CircuitBreaker` instance created in `RalphAgent.__init__()`
- [ ] Config thresholds (`cb_same_error_threshold`, `cb_cooldown_minutes`, `cb_no_progress_threshold`) used for construction
- [ ] `can_proceed()` called before each loop iteration
- [ ] `record_success()` called after successful iterations with progress
- [ ] `record_failure(reason)` called after ERROR/TIMEOUT iterations
- [ ] `record_no_progress()` called after zero-work iterations
- [ ] `_is_no_progress()` correctly classifies iterations
- [ ] `check_circuit_breaker()` delegates to active circuit breaker (backward compatible)
- [ ] Passive `CircuitBreakerState` startup reset removed from `run()`

## Test Plan

```python
def test_agent_creates_circuit_breaker():
    """RalphAgent creates a CircuitBreaker instance."""
    agent = RalphAgent(config=mock_config, project_dir=tmp_dir)
    assert hasattr(agent, "_circuit_breaker")
    assert isinstance(agent._circuit_breaker, CircuitBreaker)

def test_agent_circuit_breaker_uses_config():
    """CircuitBreaker thresholds come from RalphConfig."""
    config = RalphConfig(
        cb_same_error_threshold=10,
        cb_cooldown_minutes=15,
        cb_no_progress_threshold=5,
    )
    agent = RalphAgent(config=config, project_dir=tmp_dir)
    assert agent._circuit_breaker.failure_threshold == 10
    assert agent._circuit_breaker.cooldown_minutes == 15
    assert agent._circuit_breaker.no_progress_threshold == 5

def test_agent_is_no_progress_empty_status():
    """Empty status (no completed task, UNKNOWN work) is no-progress."""
    agent = RalphAgent(config=mock_config, project_dir=tmp_dir)
    status = RalphStatus(work_type="UNKNOWN", completed_task="")
    assert agent._is_no_progress(status) is True

def test_agent_is_no_progress_with_task():
    """Status with completed task is not no-progress."""
    agent = RalphAgent(config=mock_config, project_dir=tmp_dir)
    status = RalphStatus(
        work_type="IMPLEMENTATION",
        completed_task="Fixed the bug",
    )
    assert agent._is_no_progress(status) is False

def test_agent_check_circuit_breaker_delegates():
    """check_circuit_breaker() delegates to active CircuitBreaker."""
    agent = RalphAgent(config=mock_config, project_dir=tmp_dir)
    # Breaker starts CLOSED, should allow
    assert agent.check_circuit_breaker() is True
```
