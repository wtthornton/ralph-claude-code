# Story RALPH-SDK-STATE-6: Test both backends

**Epic:** [Pluggable State Backend](epic-sdk-state-backend.md)
**Priority:** High
**Status:** Done
**Effort:** Small
**Component:** `sdk/tests/`

---

## Problem

After Stories 1-5, the state backend abstraction is in place and both `FileStateBackend`
and `NullStateBackend` exist. However, there is no systematic verification that:

1. The full existing test suite passes with `FileStateBackend` (the default).
2. The full existing test suite passes with `NullStateBackend` injected.
3. `NullStateBackend` truly creates zero files.

Without this verification, regressions in file format compatibility or missing method
implementations could go undetected.

## Solution

Add a dedicated test module that exercises both backends through the same test scenarios,
plus a filesystem-level assertion that `NullStateBackend` creates no files. Use pytest
parametrization to run shared tests against both backends.

## Implementation

Create `sdk/tests/test_state_backends.py`:

```python
import asyncio
import json
import os
import tempfile
import time
from pathlib import Path

import pytest

from ralph_sdk.state import FileStateBackend, NullStateBackend, RalphStateBackend
from ralph_sdk.status import CircuitBreakerState, RalphStatus


# -------------------------------------------------------------------------
# Fixtures
# -------------------------------------------------------------------------

@pytest.fixture
def tmp_ralph_dir(tmp_path):
    """Provide a temporary .ralph directory."""
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    return ralph_dir


@pytest.fixture
def file_backend(tmp_ralph_dir):
    return FileStateBackend(tmp_ralph_dir)


@pytest.fixture
def null_backend():
    return NullStateBackend()


@pytest.fixture(params=["file", "null"])
def backend(request, tmp_ralph_dir):
    """Parametrized fixture yielding both backends."""
    if request.param == "file":
        return FileStateBackend(tmp_ralph_dir)
    return NullStateBackend()


def run(coro):
    """Helper to run async backend methods in sync tests."""
    return asyncio.run(coro)


# -------------------------------------------------------------------------
# Shared tests (run against BOTH backends)
# -------------------------------------------------------------------------

class TestBothBackends:
    """Tests parametrized across FileStateBackend and NullStateBackend."""

    def test_status_round_trip(self, backend):
        status = RalphStatus(
            work_type="IMPLEMENTATION",
            completed_task="Built feature X",
            status="IN_PROGRESS",
            loop_count=3,
        )
        run(backend.save_status(status))
        loaded = run(backend.load_status())
        assert loaded.work_type == "IMPLEMENTATION"
        assert loaded.completed_task == "Built feature X"
        assert loaded.loop_count == 3

    def test_circuit_breaker_round_trip(self, backend):
        cb = CircuitBreakerState(state="OPEN", no_progress_count=5)
        run(backend.save_circuit_breaker(cb))
        loaded = run(backend.load_circuit_breaker())
        assert loaded.state == "OPEN"
        assert loaded.no_progress_count == 5

    def test_call_count_increment(self, backend):
        assert run(backend.get_call_count()) == 0
        run(backend.increment_call_count())
        run(backend.increment_call_count())
        run(backend.increment_call_count())
        assert run(backend.get_call_count()) == 3

    def test_call_count_reset(self, backend):
        run(backend.increment_call_count())
        run(backend.increment_call_count())
        run(backend.reset_call_count())
        assert run(backend.get_call_count()) == 0

    def test_session_lifecycle(self, backend):
        assert run(backend.load_session_id()) == ""
        run(backend.save_session_id("session-abc-123"))
        assert run(backend.load_session_id()) == "session-abc-123"
        run(backend.clear_session_id())
        assert run(backend.load_session_id()) == ""

    def test_record_circuit_event(self, backend):
        event = {"type": "trip", "reason": "no progress", "ts": 1234567890}
        run(backend.record_circuit_event(event))
        # Verify event was recorded (backend-specific assertion)

    def test_record_metric(self, backend):
        metric = {"type": "loop", "duration_ms": 4500, "ts": 1234567890}
        run(backend.record_metric(metric))
        # Verify metric was recorded (backend-specific assertion)


# -------------------------------------------------------------------------
# FileStateBackend-specific tests
# -------------------------------------------------------------------------

class TestFileStateBackend:
    """Tests specific to file-based persistence."""

    def test_status_json_format(self, file_backend, tmp_ralph_dir):
        status = RalphStatus(work_type="TESTING", exit_signal=True)
        run(file_backend.save_status(status))
        raw = (tmp_ralph_dir / "status.json").read_text(encoding="utf-8")
        data = json.loads(raw)
        assert data["WORK_TYPE"] == "TESTING"
        assert data["EXIT_SIGNAL"] is True

    def test_call_count_file_format(self, file_backend, tmp_ralph_dir):
        run(file_backend.increment_call_count())
        run(file_backend.increment_call_count())
        content = (tmp_ralph_dir / ".call_count").read_text()
        assert content == "2\n"

    def test_session_file_format(self, file_backend, tmp_ralph_dir):
        run(file_backend.save_session_id("sess-xyz"))
        content = (tmp_ralph_dir / ".claude_session_id").read_text()
        assert content == "sess-xyz\n"

    def test_circuit_event_jsonl(self, file_backend, tmp_ralph_dir):
        run(file_backend.record_circuit_event({"a": 1}))
        run(file_backend.record_circuit_event({"b": 2}))
        lines = (tmp_ralph_dir / ".circuit_breaker_events").read_text().strip().splitlines()
        assert len(lines) == 2
        assert json.loads(lines[0]) == {"a": 1}
        assert json.loads(lines[1]) == {"b": 2}

    def test_metric_jsonl(self, file_backend, tmp_ralph_dir):
        run(file_backend.record_metric({"type": "loop"}))
        month = time.strftime("%Y-%m")
        metrics_file = tmp_ralph_dir / "metrics" / f"{month}.jsonl"
        assert metrics_file.exists()
        data = json.loads(metrics_file.read_text().strip())
        assert data["type"] == "loop"

    def test_directory_auto_creation(self, tmp_path):
        new_dir = tmp_path / "nonexistent" / ".ralph"
        fb = FileStateBackend(new_dir)
        assert new_dir.exists()

    def test_bash_compatibility(self, file_backend, tmp_ralph_dir):
        """Verify status.json can be read by the bash loop (jq-compatible JSON)."""
        status = RalphStatus(
            work_type="IMPLEMENTATION",
            completed_task="task 1",
            next_task="task 2",
            progress_summary="50% complete",
            exit_signal=False,
            status="IN_PROGRESS",
        )
        run(file_backend.save_status(status))
        raw = (tmp_ralph_dir / "status.json").read_text(encoding="utf-8")
        # Must be valid JSON
        data = json.loads(raw)
        # Must have uppercase keys matching bash on-stop.sh format
        assert "WORK_TYPE" in data
        assert "COMPLETED_TASK" in data
        assert "EXIT_SIGNAL" in data


# -------------------------------------------------------------------------
# NullStateBackend-specific tests
# -------------------------------------------------------------------------

class TestNullStateBackend:
    """Tests specific to in-memory backend."""

    def test_no_files_created(self, tmp_path):
        """The core promise: NullStateBackend creates zero files."""
        before = set(tmp_path.rglob("*"))
        nb = NullStateBackend()
        # Exercise every method
        run(nb.save_status(RalphStatus(work_type="TEST")))
        run(nb.load_status())
        run(nb.save_circuit_breaker(CircuitBreakerState()))
        run(nb.load_circuit_breaker())
        run(nb.record_circuit_event({"x": 1}))
        run(nb.increment_call_count())
        run(nb.get_call_count())
        run(nb.reset_call_count())
        run(nb.save_session_id("test"))
        run(nb.load_session_id())
        run(nb.clear_session_id())
        run(nb.record_metric({"y": 2}))
        after = set(tmp_path.rglob("*"))
        assert before == after, f"NullStateBackend created files: {after - before}"

    def test_instance_isolation(self):
        """Two NullStateBackend instances must not share state."""
        a = NullStateBackend()
        b = NullStateBackend()
        run(a.save_session_id("from-a"))
        run(b.save_session_id("from-b"))
        assert run(a.load_session_id()) == "from-a"
        assert run(b.load_session_id()) == "from-b"

    def test_event_accumulation(self):
        nb = NullStateBackend()
        for i in range(5):
            run(nb.record_circuit_event({"seq": i}))
        assert len(nb._circuit_events) == 5

    def test_metric_accumulation(self):
        nb = NullStateBackend()
        for i in range(3):
            run(nb.record_metric({"loop": i}))
        assert len(nb._metrics) == 3


# -------------------------------------------------------------------------
# Agent integration tests
# -------------------------------------------------------------------------

class TestAgentWithBackends:
    """Verify RalphAgent works with both backends."""

    def test_agent_default_backend(self, tmp_path):
        from ralph_sdk.agent import RalphAgent
        agent = RalphAgent(project_dir=tmp_path)
        assert isinstance(agent.state_backend, FileStateBackend)

    def test_agent_null_backend(self, tmp_path):
        from ralph_sdk.agent import RalphAgent
        nb = NullStateBackend()
        agent = RalphAgent(project_dir=tmp_path, state_backend=nb)
        assert agent.state_backend is nb

    def test_agent_dry_run_file_backend(self, tmp_path):
        """Dry-run with FileStateBackend writes status.json."""
        from ralph_sdk.config import RalphConfig
        from ralph_sdk.agent import RalphAgent
        config = RalphConfig(dry_run=True)
        agent = RalphAgent(config=config, project_dir=tmp_path)
        # Create minimal PROMPT.md so the loop has input
        ralph_dir = tmp_path / ".ralph"
        (ralph_dir / "PROMPT.md").write_text("test prompt", encoding="utf-8")
        result = agent.run()
        assert result.status.status == "DRY_RUN"
        assert (ralph_dir / "status.json").exists()

    def test_agent_dry_run_null_backend(self, tmp_path):
        """Dry-run with NullStateBackend completes without file errors."""
        from ralph_sdk.config import RalphConfig
        from ralph_sdk.agent import RalphAgent
        config = RalphConfig(dry_run=True)
        nb = NullStateBackend()
        agent = RalphAgent(config=config, project_dir=tmp_path, state_backend=nb)
        ralph_dir = tmp_path / ".ralph"
        (ralph_dir / "PROMPT.md").write_text("test prompt", encoding="utf-8")
        result = agent.run()
        assert result.status.status == "DRY_RUN"
        # No status.json should exist (NullStateBackend doesn't write files)
        assert not (ralph_dir / "status.json").exists()
```

## Acceptance Criteria

- [ ] `sdk/tests/test_state_backends.py` exists with all test classes above
- [ ] All shared tests pass with `FileStateBackend` (parametrized `backend` fixture, `param="file"`)
- [ ] All shared tests pass with `NullStateBackend` (parametrized `backend` fixture, `param="null"`)
- [ ] `test_no_files_created` confirms zero filesystem side effects from `NullStateBackend`
- [ ] `test_instance_isolation` confirms two `NullStateBackend` instances are independent
- [ ] `test_bash_compatibility` confirms `status.json` output is jq-compatible with uppercase keys
- [ ] `test_agent_default_backend` confirms `RalphAgent()` defaults to `FileStateBackend`
- [ ] `test_agent_dry_run_null_backend` confirms the agent loop works end-to-end with `NullStateBackend`
- [ ] Full existing test suite continues to pass (no regressions)
- [ ] `pytest sdk/tests/test_state_backends.py -v` shows all tests green

## Test Plan

This story *is* the test plan. Run:

```bash
# All new state backend tests
pytest sdk/tests/test_state_backends.py -v

# Full existing test suite (regression check)
pytest sdk/tests/ -v

# Verify no regressions in bash tests (state files unchanged)
npm test
```

Verify every test class passes. The parametrized `TestBothBackends` class should show
each test running twice (once for `file`, once for `null`).
