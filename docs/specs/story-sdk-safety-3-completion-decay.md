# Story SDK-SAFETY-3: Completion Indicator Decay

**Epic:** [SDK Loop Safety](epic-sdk-loop-safety.md)
**Priority:** P1
**Status:** Pending
**Effort:** 0.5 day
**Component:** `ralph_sdk/agent.py`

---

## Problem

The CLI resets `completion_indicators` to `[]` when productive work occurs (files modified or tasks completed) with `exit_signal=false` (`ralph_loop.sh:951-953`). The SDK's dual-condition exit gate doesn't decay stale indicators.

Without decay, a false "done" signal early in a multi-loop run can combine with a later legitimate "done" to trigger premature exit before all tasks are actually complete. Example:

1. Loop 3: Claude says "I've finished the refactoring" (completion indicator detected), but `exit_signal=false` and 10 more tasks remain.
2. Loop 4-8: Claude makes progress, modifies files, completes tasks. The stale indicator from loop 3 persists.
3. Loop 9: Claude says "done" again (second indicator). The exit gate sees 2 indicators + exit_signal=true → exits. But loops 4-8's progress was supposed to invalidate the loop 3 indicator.

## Solution

In `agent.py`, reset the completion indicator count when `status.exit_signal == False` and progress was detected (files changed > 0 or tasks completed > 0). This matches the CLI fix exactly.

## Implementation

```python
# In ralph_sdk/agent.py, within the iteration processing logic:

# After parsing status from the iteration:
progress_detected = (
    status.files_changed > 0 or
    status.tasks_completed > 0
)

if not status.exit_signal and progress_detected:
    # Decay stale completion indicators — productive work invalidates
    # previous "done" signals that weren't accompanied by exit_signal
    self._completion_indicators = []
    self._log("Completion indicators reset: progress detected with exit_signal=false")
```

## Design Notes

- **Exact CLI parity**: This matches `ralph_loop.sh:951-953` — the reset condition is identical.
- **Conservative reset**: Only resets when BOTH conditions are true: `exit_signal=false` AND progress detected. If there's no progress, stale indicators persist (the agent might genuinely be done but just hasn't set exit_signal yet).
- **Logging**: The reset is logged so TheStudio's OTEL spans can trace when decay occurs.
- **No config needed**: This is a correctness fix, not a configurable behavior. The dual-condition exit gate's invariant is that indicators must be fresh relative to progress.

## Acceptance Criteria

- [ ] Completion indicators reset to `[]` when `exit_signal=false` and `files_changed > 0`
- [ ] Completion indicators reset to `[]` when `exit_signal=false` and `tasks_completed > 0`
- [ ] Completion indicators preserved when no progress is detected
- [ ] Completion indicators preserved when `exit_signal=true` (even with progress)
- [ ] Reset is logged for observability
- [ ] Dual-condition exit gate still requires both indicators >= 2 AND exit_signal=true

## Test Plan

```python
import pytest
from unittest.mock import AsyncMock, MagicMock

class TestCompletionIndicatorDecay:
    def test_decay_on_progress_without_exit_signal(self):
        """Indicators reset when progress detected and exit_signal is false."""
        agent = make_test_agent()
        agent._completion_indicators = ["done signal 1"]

        status = make_status(exit_signal=False, files_changed=3, tasks_completed=0)
        agent._process_completion_decay(status)

        assert agent._completion_indicators == []

    def test_decay_on_task_completion_without_exit_signal(self):
        """Indicators reset when task completed and exit_signal is false."""
        agent = make_test_agent()
        agent._completion_indicators = ["done signal 1", "done signal 2"]

        status = make_status(exit_signal=False, files_changed=0, tasks_completed=1)
        agent._process_completion_decay(status)

        assert agent._completion_indicators == []

    def test_no_decay_when_no_progress(self):
        """Indicators preserved when no progress detected."""
        agent = make_test_agent()
        agent._completion_indicators = ["done signal 1"]

        status = make_status(exit_signal=False, files_changed=0, tasks_completed=0)
        agent._process_completion_decay(status)

        assert len(agent._completion_indicators) == 1

    def test_no_decay_when_exit_signal_true(self):
        """Indicators preserved when exit_signal is true (about to exit)."""
        agent = make_test_agent()
        agent._completion_indicators = ["done signal 1", "done signal 2"]

        status = make_status(exit_signal=True, files_changed=5, tasks_completed=2)
        agent._process_completion_decay(status)

        assert len(agent._completion_indicators) == 2

    def test_premature_exit_prevented(self):
        """Full scenario: stale indicator + progress + new indicator doesn't exit prematurely."""
        agent = make_test_agent()

        # Loop 3: false "done" signal
        agent._completion_indicators.append("I've finished the refactoring")

        # Loop 4: progress without exit → decay
        status_4 = make_status(exit_signal=False, files_changed=3, tasks_completed=1)
        agent._process_completion_decay(status_4)
        assert agent._completion_indicators == []

        # Loop 9: legitimate "done" — only 1 indicator, exit gate requires 2
        agent._completion_indicators.append("All tasks complete")
        assert not agent._should_exit()  # Only 1 indicator, needs 2
```

## References

- CLI `ralph_loop.sh:951-953`: Completion indicator reset on progress
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.6
