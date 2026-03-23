# Story SDK-LIFECYCLE-1: Cancel Semantics Documentation and Hardening

**Epic:** [SDK Lifecycle & Resilience](epic-sdk-lifecycle.md)
**Priority:** P1
**Status:** Pending
**Effort:** 0.5 day
**Component:** `ralph_sdk/agent.py`

---

## Problem

TheStudio's Temporal activity calls `agent.cancel()` on timeout (`activities.py:954`), then waits 10s, then force-cancels the asyncio task. It's unclear whether `cancel()`:

1. Actually sends SIGTERM to the Claude subprocess, or just sets a flag
2. Waits for the subprocess to exit or returns immediately
3. Collects partial output from the interrupted run
4. Handles the case where the subprocess is already dead

Undocumented shutdown behavior is a production risk. If `cancel()` only sets `_running = False` but the subprocess continues, TheStudio leaks Claude processes.

**Temporal context**: Cancellation requests from workflows are only delivered to activities when they call `activity.heartbeat()`. An activity that never heartbeats can never be cancelled — this is why TheStudio's heartbeat loop (Story 43.11) is critical for the cancel path. When `asyncio.CancelledError` is raised, the activity must re-raise it after cleanup for proper cancellation reporting.

## Solution

Harden `RalphAgent.cancel()` to guarantee:
1. SIGTERM is sent to the Claude subprocess
2. A `CancelResult` is returned with any partial output collected
3. Completion within a configurable grace period (default 10s)
4. SIGKILL after grace period if subprocess is still alive

Document the behavior in docstrings and a brief section in the SDK README.

## Implementation

```python
# In ralph_sdk/agent.py:

import asyncio
import signal
from pydantic import BaseModel


class CancelResult(BaseModel):
    """Result from cancelling a running agent."""
    cancelled: bool
    partial_output: str
    loop_count_at_cancel: int
    reason: str
    graceful: bool  # True if subprocess exited before SIGKILL


class RalphAgent:
    # ... existing code ...

    async def cancel(
        self,
        reason: str = "caller_requested",
        grace_seconds: float = 10.0,
    ) -> CancelResult:
        """Cancel the running agent loop and its Claude subprocess.

        Guarantees:
        1. Sends SIGTERM to the Claude subprocess (if running)
        2. Waits up to `grace_seconds` for graceful exit
        3. Sends SIGKILL if subprocess is still alive after grace period
        4. Returns partial output collected before cancellation

        Args:
            reason: Why the cancel was requested (for logging/metrics)
            grace_seconds: Seconds to wait for graceful exit before SIGKILL

        Returns:
            CancelResult with partial output and cancellation details
        """
        self._running = False
        partial_output = self._collected_output or ""
        loop_count = self._loop_count
        graceful = True

        # Terminate the subprocess if it exists and is running
        if self._process and self._process.returncode is None:
            try:
                self._process.terminate()  # SIGTERM
                try:
                    await asyncio.wait_for(
                        self._process.wait(),
                        timeout=grace_seconds,
                    )
                except asyncio.TimeoutError:
                    # Subprocess didn't exit gracefully — force kill
                    self._process.kill()  # SIGKILL
                    await self._process.wait()
                    graceful = False
            except ProcessLookupError:
                pass  # Process already dead

        self._log(f"Cancelled: reason={reason}, graceful={graceful}, loops={loop_count}")

        return CancelResult(
            cancelled=True,
            partial_output=partial_output,
            loop_count_at_cancel=loop_count,
            reason=reason,
            graceful=graceful,
        )
```

## Design Notes

- **SIGTERM first, SIGKILL after grace**: Industry-standard graceful shutdown. Gives Claude a chance to flush output.
- **ProcessLookupError handled**: If the process already exited (race condition), don't raise.
- **Partial output**: Whatever output was collected before cancellation is returned. TheStudio can decide whether to use it.
- **Configurable grace**: Default 10s matches TheStudio's current wait. Other embedders may want longer for cleanup.
- **Idempotent**: Calling `cancel()` twice is safe — second call sees `_running=False` and process already dead.

## Acceptance Criteria

- [ ] `cancel()` sends SIGTERM to the Claude subprocess
- [ ] Waits up to `grace_seconds` for graceful exit
- [ ] Sends SIGKILL after grace period if subprocess still alive
- [ ] Returns `CancelResult` with partial output
- [ ] `CancelResult.graceful` indicates whether SIGKILL was needed
- [ ] Safe to call when no subprocess is running
- [ ] Safe to call multiple times (idempotent)
- [ ] Behavior documented in docstring
- [ ] `_running` flag set to False immediately

## Test Plan

```python
import pytest
import asyncio
from unittest.mock import AsyncMock, MagicMock, patch

class TestCancelSemantics:
    async def test_cancel_terminates_subprocess(self):
        agent = make_test_agent()
        agent._process = AsyncMock()
        agent._process.returncode = None  # Still running
        agent._process.wait = AsyncMock()

        result = await agent.cancel(reason="timeout")
        agent._process.terminate.assert_called_once()
        assert result.cancelled is True
        assert result.graceful is True

    async def test_cancel_force_kills_on_timeout(self):
        agent = make_test_agent()
        agent._process = AsyncMock()
        agent._process.returncode = None
        agent._process.wait = AsyncMock(side_effect=asyncio.TimeoutError())

        result = await agent.cancel(grace_seconds=0.1)
        agent._process.kill.assert_called_once()
        assert result.graceful is False

    async def test_cancel_handles_dead_process(self):
        agent = make_test_agent()
        agent._process = AsyncMock()
        agent._process.returncode = 0  # Already exited

        result = await agent.cancel()
        agent._process.terminate.assert_not_called()
        assert result.cancelled is True

    async def test_cancel_no_process(self):
        agent = make_test_agent()
        agent._process = None

        result = await agent.cancel()
        assert result.cancelled is True

    async def test_cancel_returns_partial_output(self):
        agent = make_test_agent()
        agent._collected_output = "Partial work done..."
        agent._loop_count = 3
        agent._process = None

        result = await agent.cancel()
        assert result.partial_output == "Partial work done..."
        assert result.loop_count_at_cancel == 3

    async def test_cancel_sets_running_false(self):
        agent = make_test_agent()
        agent._running = True
        agent._process = None

        await agent.cancel()
        assert agent._running is False
```

## References

- TheStudio `activities.py:954`: Current cancel + 10s wait + force-cancel pattern
- Python asyncio subprocess: `terminate()` = SIGTERM, `kill()` = SIGKILL
- Temporal activity cancellation: CancelledError → cleanup → return partial result
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §2.2
