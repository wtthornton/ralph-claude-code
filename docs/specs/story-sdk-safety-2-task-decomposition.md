# Story SDK-SAFETY-2: Task Decomposition Detection

**Epic:** [SDK Loop Safety](epic-sdk-loop-safety.md)
**Priority:** P1
**Status:** Pending
**Effort:** 1 day
**Component:** `ralph_sdk/agent.py`, `ralph_sdk/status.py`

---

## Problem

The CLI detects oversized tasks via a 4-factor heuristic: file count >= 5, previous timeout, complexity >= 4, consecutive no-progress >= 3. The SDK has no equivalent. Once Ralph is running, there's no detection that a task is too large for a single loop iteration. Oversized tasks run until timeout or circuit break, wasting budget.

TheStudio routes tasks by complexity band at intake but only at the intake level. Mid-run detection that a task needs decomposition would allow earlier intervention.

## Solution

Add `detect_decomposition_needed()` function that evaluates the current iteration status against the 4-factor heuristic and returns a structured hint.

## Implementation

### Step 1: Add DecompositionHint model

```python
# In ralph_sdk/status.py:

class DecompositionHint(BaseModel):
    """Hint that a task may need decomposition into smaller units."""
    decompose: bool
    reasons: list[str]
    recommendation: str
    score: int = Field(ge=0, le=4, description="Number of factors triggered (0-4)")
```

### Step 2: Add detection function

```python
# In ralph_sdk/agent.py or a new ralph_sdk/decomposition.py:

def detect_decomposition_needed(
    status: RalphStatus,
    config: RalphConfig,
    previous_timed_out: bool = False,
    consecutive_no_progress: int = 0,
    file_count_threshold: int = 5,
    complexity_threshold: int = 4,
    no_progress_threshold: int = 3,
) -> DecompositionHint:
    """Evaluate whether the current task should be decomposed.

    Uses a 4-factor heuristic matching the CLI's detection logic:
    1. Files touched >= file_count_threshold
    2. Previous iteration timed out
    3. Complexity >= complexity_threshold (from status or config)
    4. Consecutive iterations with no progress >= no_progress_threshold
    """
    reasons: list[str] = []
    score = 0

    # Factor 1: File count
    if status.files_changed >= file_count_threshold:
        reasons.append(f"Files touched ({status.files_changed}) >= threshold ({file_count_threshold})")
        score += 1

    # Factor 2: Previous timeout
    if previous_timed_out:
        reasons.append("Previous iteration timed out")
        score += 1

    # Factor 3: Complexity
    complexity = getattr(status, "complexity", 0) or 0
    if complexity >= complexity_threshold:
        reasons.append(f"Complexity ({complexity}) >= threshold ({complexity_threshold})")
        score += 1

    # Factor 4: Consecutive no-progress
    if consecutive_no_progress >= no_progress_threshold:
        reasons.append(
            f"Consecutive no-progress iterations ({consecutive_no_progress}) >= threshold ({no_progress_threshold})"
        )
        score += 1

    decompose = score >= 2  # Require at least 2 factors

    if decompose:
        recommendation = (
            "Task exceeds complexity bounds. Consider splitting into smaller subtasks "
            "targeting individual files or logical units."
        )
    else:
        recommendation = "Task is within normal bounds."

    return DecompositionHint(
        decompose=decompose,
        reasons=reasons,
        recommendation=recommendation,
        score=score,
    )
```

### Step 3: Integrate with agent loop

```python
# In ralph_sdk/agent.py, after each iteration:
hint = detect_decomposition_needed(
    status=self._last_status,
    config=self._config,
    previous_timed_out=self._last_timed_out,
    consecutive_no_progress=self._no_progress_count,
)
if hint.decompose:
    self._last_decomposition_hint = hint
    # Log the hint; caller can check agent.last_decomposition_hint after run()
```

## Design Notes

- **Detection, not action**: The function returns a hint; it doesn't decompose the task. The caller (TheStudio) decides how to split work based on the hint.
- **2-of-4 threshold**: Requiring at least 2 factors reduces false positives. A single timeout or high file count alone doesn't trigger decomposition.
- **Configurable thresholds**: All 4 factor thresholds are parameters with sensible defaults matching the CLI.
- **Status exposure**: The hint is available via `agent.last_decomposition_hint` for post-run inspection.

## Acceptance Criteria

- [ ] `detect_decomposition_needed()` evaluates 4 factors: file count, timeout, complexity, no-progress
- [ ] Returns `DecompositionHint` with `decompose: bool`, `reasons: list[str]`, `recommendation: str`, `score: int`
- [ ] Triggers decomposition when >= 2 factors are true
- [ ] All thresholds are configurable parameters
- [ ] Hint is available on `RalphAgent` after each iteration
- [ ] False positive rate: does not trigger on normal single-file edits

## Test Plan

```python
import pytest
from ralph_sdk.status import RalphStatus, DecompositionHint
from ralph_sdk.config import RalphConfig

class TestDecompositionDetection:
    def _make_status(self, files_changed: int = 1, complexity: int = 2):
        return RalphStatus(files_changed=files_changed, complexity=complexity)

    def test_no_decomposition_for_simple_task(self):
        hint = detect_decomposition_needed(
            status=self._make_status(files_changed=1, complexity=2),
            config=RalphConfig(),
            previous_timed_out=False,
            consecutive_no_progress=0,
        )
        assert not hint.decompose
        assert hint.score == 0

    def test_decomposition_on_two_factors(self):
        hint = detect_decomposition_needed(
            status=self._make_status(files_changed=8, complexity=5),
            config=RalphConfig(),
            previous_timed_out=False,
            consecutive_no_progress=0,
        )
        assert hint.decompose
        assert hint.score == 2
        assert len(hint.reasons) == 2

    def test_decomposition_on_timeout_plus_no_progress(self):
        hint = detect_decomposition_needed(
            status=self._make_status(files_changed=1, complexity=2),
            config=RalphConfig(),
            previous_timed_out=True,
            consecutive_no_progress=4,
        )
        assert hint.decompose
        assert hint.score == 2

    def test_single_factor_no_decomposition(self):
        hint = detect_decomposition_needed(
            status=self._make_status(files_changed=10, complexity=2),
            config=RalphConfig(),
            previous_timed_out=False,
            consecutive_no_progress=0,
        )
        assert not hint.decompose
        assert hint.score == 1

    def test_all_four_factors(self):
        hint = detect_decomposition_needed(
            status=self._make_status(files_changed=10, complexity=5),
            config=RalphConfig(),
            previous_timed_out=True,
            consecutive_no_progress=5,
        )
        assert hint.decompose
        assert hint.score == 4
```

## References

- CLI `ralph_loop.sh`: 4-factor heuristic
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.3
