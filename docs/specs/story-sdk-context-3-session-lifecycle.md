# Story SDK-CONTEXT-3: Session Lifecycle Management and Continue-As-New

**Epic:** [SDK Context Management](epic-sdk-context-management.md)
**Priority:** P2
**Status:** Pending
**Effort:** 2 days
**Component:** `ralph_sdk/agent.py`, `ralph_sdk/config.py`, `ralph_sdk/state.py`

---

## Problem

The CLI tracks session history, enforces expiry (`CLAUDE_SESSION_EXPIRY_HOURS=24`), and is implementing Continue-As-New for long sessions (CTXMGMT-3, in progress). The SDK persists session IDs but never expires or rotates them.

**Session staleness**: Claude sessions accumulate context (tool outputs, failed attempts, stale reasoning) that degrades agent effectiveness over time. Research shows agent success rate decreases after ~35 minutes, and doubling duration quadruples failure rate.

**TheStudio workaround**: `clear_session_if_stale(ttl_seconds=7200)` in `ralph_state.py` is a TheStudio-side workaround. If the SDK managed session lifecycle natively, the workaround could be removed.

**Continue-As-New**: The Temporal pattern of atomically ending a workflow and starting a fresh one with carried-over state. For Ralph, this means resetting the Claude session after N iterations while carrying only essential state (current task, progress summary, key findings). This is the "single most impactful unfinished story" per the evaluation.

**Temporal best practice (2026)**: Use `workflow.info().is_continue_as_new_suggested()` to detect when event history is approaching limits (warning at 10,240 events / 10 MB) rather than arbitrary iteration counts. However, for Ralph's SDK, iteration-count-based triggering is appropriate because the goal is to reset *Claude's context* (not Temporal's event history). The SDK's `continue_as_new_threshold` serves a different purpose than Temporal's built-in check.

## Solution

Add session lifecycle management to the SDK:
1. `session_expiry_hours` config field with automatic session rotation on expiry
2. Session history tracking (previous session IDs with timestamps)
3. Continue-As-New: reset session after N iterations, carrying essential state

## Implementation

### Step 1: Add config fields

```python
# In ralph_sdk/config.py:
session_expiry_hours: int = Field(
    default=24, ge=1,
    description="Hours before a session is considered stale and rotated"
)
continue_as_new_threshold: int = Field(
    default=20, ge=5,
    description="Iterations before Continue-As-New triggers session reset"
)
continue_as_new_enabled: bool = Field(
    default=True,
    description="Enable automatic session rotation after N iterations"
)
```

### Step 2: Session lifecycle methods

```python
# In ralph_sdk/agent.py:

from datetime import datetime, timezone, timedelta


class SessionManager:
    """Manages session lifecycle: expiry, rotation, and Continue-As-New."""

    def __init__(
        self,
        state_backend: "RalphStateBackend",
        expiry_hours: int = 24,
        continue_threshold: int = 20,
        continue_enabled: bool = True,
    ):
        self._state = state_backend
        self._expiry_hours = expiry_hours
        self._continue_threshold = continue_threshold
        self._continue_enabled = continue_enabled
        self._session_history: list[dict[str, str]] = []
        self._iteration_count: int = 0

    async def get_session_id(self) -> str:
        """Get current session ID, rotating if expired."""
        session_id = await self._state.read_session_id()
        if not session_id:
            return ""

        # Check expiry
        if await self._is_expired():
            await self._rotate_session("expired")
            return ""

        return session_id

    async def check_continue_as_new(self, iteration: int) -> bool:
        """Check if Continue-As-New should trigger.

        Returns True if the session should be reset (caller builds
        the carry-over state and starts a fresh session).
        """
        if not self._continue_enabled:
            return False
        self._iteration_count = iteration
        return iteration > 0 and iteration % self._continue_threshold == 0

    async def rotate_session(self, reason: str = "manual") -> None:
        """Rotate the session: archive current, clear for fresh start."""
        await self._rotate_session(reason)

    async def get_session_history(self) -> list[dict[str, str]]:
        """Return list of previous session IDs with timestamps and reasons."""
        return list(self._session_history)

    def build_carry_over_state(
        self,
        current_task: str,
        progress_summary: str,
        key_findings: list[str],
    ) -> str:
        """Build minimal state to carry into the new session.

        Only essential information is preserved — the new session starts
        fresh without accumulated context from tool outputs and failed attempts.
        """
        parts = [
            f"## Continued Session (iteration {self._iteration_count})",
            f"\n### Current Task\n{current_task}",
            f"\n### Progress Summary\n{progress_summary}",
        ]
        if key_findings:
            parts.append("\n### Key Findings")
            for finding in key_findings:
                parts.append(f"- {finding}")
        return "\n".join(parts)

    async def _is_expired(self) -> bool:
        """Check if the current session has exceeded its TTL."""
        # Read session timestamp from state backend
        status = await self._state.read_status()
        if not status:
            return False

        session_started = status.get("session_started_at")
        if not session_started:
            return False

        started_at = datetime.fromisoformat(session_started)
        expiry = started_at + timedelta(hours=self._expiry_hours)
        return datetime.now(timezone.utc) > expiry

    async def _rotate_session(self, reason: str) -> None:
        """Archive current session and clear for new one."""
        current_id = await self._state.read_session_id()
        if current_id:
            self._session_history.append({
                "session_id": current_id,
                "rotated_at": datetime.now(timezone.utc).isoformat(),
                "reason": reason,
                "iteration": str(self._iteration_count),
            })
        await self._state.write_session_id("")
```

### Step 3: Integrate with agent loop

```python
# In ralph_sdk/agent.py, within run():

self._session_mgr = SessionManager(
    state_backend=self._state,
    expiry_hours=self._config.session_expiry_hours,
    continue_threshold=self._config.continue_as_new_threshold,
    continue_enabled=self._config.continue_as_new_enabled,
)

# Before each iteration:
session_id = await self._session_mgr.get_session_id()

# After each iteration:
if await self._session_mgr.check_continue_as_new(self._loop_count):
    carry_over = self._session_mgr.build_carry_over_state(
        current_task=self._current_task,
        progress_summary=self._build_progress_summary(),
        key_findings=self._key_findings,
    )
    await self._session_mgr.rotate_session("continue_as_new")
    # Inject carry_over into next iteration's context
    self._carry_over_context = carry_over
```

## Design Notes

- **Continue-As-New threshold**: Default 20 iterations. This is based on the observation that context fills with stale tool outputs after ~20 iterations. Configurable for different workloads.
- **Essential state only**: Carry-over includes only: current task, progress summary, key findings. All tool output history, failed attempts, and intermediate reasoning are discarded.
- **Session history**: Preserved in memory for the current run. Not persisted to state backend (lightweight; future enhancement could persist for analytics).
- **Temporal alignment**: The pattern matches Temporal's Continue-As-New semantics — atomically end the current execution and start fresh with minimal state.
- **Backward compatible**: `continue_as_new_enabled=True` by default but only triggers after 20 iterations. Short runs are unaffected.

## Acceptance Criteria

- [ ] `session_expiry_hours` configurable in `RalphConfig` (default 24)
- [ ] Sessions automatically rotated when expiry is reached
- [ ] Session history tracks previous session IDs with timestamps and rotation reasons
- [ ] Continue-As-New triggers after `continue_as_new_threshold` iterations (default 20)
- [ ] `continue_as_new_enabled` flag allows disabling the feature
- [ ] Carry-over state includes only: current task, progress summary, key findings
- [ ] New session starts fresh (no accumulated tool output or failed attempts)
- [ ] `build_carry_over_state()` produces a concise markdown summary
- [ ] Short runs (< threshold) are not affected

## Test Plan

```python
import pytest
from datetime import datetime, timezone, timedelta
from unittest.mock import AsyncMock

class TestSessionLifecycle:
    @pytest.fixture
    def mock_state(self):
        state = AsyncMock()
        state.read_session_id.return_value = "session-123"
        state.read_status.return_value = {
            "session_started_at": datetime.now(timezone.utc).isoformat()
        }
        return state

    async def test_session_expiry_detection(self, mock_state):
        mock_state.read_status.return_value = {
            "session_started_at": (
                datetime.now(timezone.utc) - timedelta(hours=25)
            ).isoformat()
        }
        mgr = SessionManager(state_backend=mock_state, expiry_hours=24)
        session_id = await mgr.get_session_id()
        assert session_id == ""  # Expired → rotated

    async def test_session_not_expired(self, mock_state):
        mgr = SessionManager(state_backend=mock_state, expiry_hours=24)
        session_id = await mgr.get_session_id()
        assert session_id == "session-123"

    async def test_continue_as_new_triggers(self, mock_state):
        mgr = SessionManager(
            state_backend=mock_state, continue_threshold=5, continue_enabled=True
        )
        assert not await mgr.check_continue_as_new(4)
        assert await mgr.check_continue_as_new(5)
        assert not await mgr.check_continue_as_new(6)
        assert await mgr.check_continue_as_new(10)

    async def test_continue_as_new_disabled(self, mock_state):
        mgr = SessionManager(
            state_backend=mock_state, continue_threshold=5, continue_enabled=False
        )
        assert not await mgr.check_continue_as_new(5)

    def test_carry_over_state_format(self):
        mgr = SessionManager(state_backend=AsyncMock())
        mgr._iteration_count = 20
        state = mgr.build_carry_over_state(
            current_task="Fix login bug",
            progress_summary="3 of 5 tasks complete",
            key_findings=["Auth module uses JWT", "Tests in tests/auth/"],
        )
        assert "Continued Session (iteration 20)" in state
        assert "Fix login bug" in state
        assert "3 of 5 tasks complete" in state
        assert "Auth module uses JWT" in state

    async def test_session_history_tracked(self, mock_state):
        mgr = SessionManager(state_backend=mock_state)
        await mgr.rotate_session("test_reason")
        history = await mgr.get_session_history()
        assert len(history) == 1
        assert history[0]["session_id"] == "session-123"
        assert history[0]["reason"] == "test_reason"
```

## References

- CLI `CLAUDE_SESSION_EXPIRY_HOURS=24`: Session expiry
- CTXMGMT-3: Continue-As-New (in progress)
- Temporal Continue-As-New pattern
- TheStudio `clear_session_if_stale(ttl_seconds=7200)`: Workaround to be replaced
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.10
