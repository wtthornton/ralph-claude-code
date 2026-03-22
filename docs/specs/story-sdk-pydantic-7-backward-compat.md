# Story RALPH-SDK-PYDANTIC-7: Backward Compatibility Verification

**Epic:** [Pydantic v2 Models](epic-sdk-pydantic-models.md)
**Priority:** Critical
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/status.py`, `sdk/ralph_sdk/agent.py`, `sdk/ralph_sdk/config.py`

---

## Problem

Stories 1-6 convert all 5 SDK models from `@dataclass` to Pydantic `BaseModel`. While each
story includes unit tests for its own model, no story validates the **cross-cutting**
backward compatibility requirements:

1. **Round-trip**: Existing valid data from the bash loop (status.json, .circuit_breaker_state)
   must load, round-trip through `model_dump()` / `model_validate()`, and produce identical output.
2. **JSON Schema**: All models must produce valid JSON Schema via `model_json_schema()`.
3. **CLI mode**: `ralph --sdk --dry-run` must work unchanged.
4. **Bash loop**: The bash loop (`ralph_loop.sh`) reads `status.json` — its format must not change.
5. **Import paths**: All existing import statements must continue to work.

This story is a verification gate — it adds integration tests and a checklist, not new code.

## Solution

1. Create integration tests that use real-world data fixtures from the bash loop.
2. Verify `model_json_schema()` for all 5 models.
3. Run `ralph --sdk --dry-run` end-to-end.
4. Verify bash loop compatibility by checking `status.json` format against the `on-stop.sh` schema.

## Implementation

### No code changes — this story adds tests and verification only.

### Test Fixtures

Create test fixtures from real bash loop output:

**`sdk/tests/fixtures/status_from_bash.json`** (real status.json from bash loop)
```json
{
  "WORK_TYPE": "IMPLEMENTATION",
  "COMPLETED_TASK": "Add circuit breaker reset command",
  "NEXT_TASK": "Add integration tests",
  "PROGRESS_SUMMARY": "Circuit breaker reset implemented with --force flag",
  "EXIT_SIGNAL": false,
  "status": "IN_PROGRESS",
  "timestamp": "2026-03-20T14:30:00+0000",
  "loop_count": 7,
  "session_id": "sess-abc-123",
  "circuit_breaker_state": "CLOSED",
  "error": ""
}
```

**`sdk/tests/fixtures/circuit_breaker_from_bash.json`** (real .circuit_breaker_state from bash loop)
```json
{
  "state": "HALF_OPEN",
  "no_progress_count": 3,
  "same_error_count": 1,
  "last_error": "no output detected in claude response",
  "opened_at": "2026-03-20T14:00:00+0000",
  "last_transition": "HALF_OPEN: cooldown expired"
}
```

**`sdk/tests/fixtures/ralphrc_sample`** (real .ralphrc from a project)
```bash
PROJECT_NAME="ralph-claude-code"
PROJECT_TYPE="shell"
MAX_CALLS_PER_HOUR=100
CLAUDE_TIMEOUT_MINUTES=15
CLAUDE_OUTPUT_FORMAT="json"
ALLOWED_TOOLS="Write,Read,Edit,Bash(git add *),Bash(git commit *)"
SESSION_CONTINUITY="true"
CB_NO_PROGRESS_THRESHOLD=3
CB_SAME_ERROR_THRESHOLD=5
CB_COOLDOWN_MINUTES=30
```

**`sdk/tests/fixtures/ralph_config_sample.json`** (real ralph.config.json)
```json
{
  "projectName": "ralph-claude-code",
  "projectType": "shell",
  "maxCallsPerHour": 100,
  "timeoutMinutes": 15,
  "maxTurns": 50,
  "verbose": false
}
```

### Integration Tests

**`sdk/tests/test_backward_compat.py`**

```python
"""Backward compatibility verification for Pydantic v2 model migration.

These tests ensure that all existing valid data from the bash loop
round-trips correctly through the new Pydantic models.
"""

import json
from pathlib import Path

import pytest

from ralph_sdk.agent import TaskInput, TaskResult
from ralph_sdk.config import RalphConfig
from ralph_sdk.status import (
    CircuitBreakerState,
    CircuitBreakerStateEnum,
    RalphLoopStatus,
    RalphStatus,
    WorkType,
)

FIXTURES = Path(__file__).parent / "fixtures"


# --- Round-trip tests ---

class TestStatusRoundTrip:
    """Verify status.json from bash loop loads and round-trips."""

    def test_load_bash_status(self):
        """Real status.json from bash loop loads without error."""
        data = json.loads((FIXTURES / "status_from_bash.json").read_text())
        status = RalphStatus.from_dict(data)
        assert status.work_type == WorkType.IMPLEMENTATION
        assert status.status == RalphLoopStatus.IN_PROGRESS
        assert status.loop_count == 7

    def test_round_trip_preserves_format(self):
        """from_dict(to_dict(x)) produces identical JSON."""
        data = json.loads((FIXTURES / "status_from_bash.json").read_text())
        status = RalphStatus.from_dict(data)
        output = status.to_dict()

        # All original keys present with same values
        assert output["WORK_TYPE"] == data["WORK_TYPE"]
        assert output["COMPLETED_TASK"] == data["COMPLETED_TASK"]
        assert output["EXIT_SIGNAL"] == data["EXIT_SIGNAL"]
        assert output["status"] == data["status"]
        assert output["loop_count"] == data["loop_count"]
        assert output["session_id"] == data["session_id"]
        assert output["circuit_breaker_state"] == data["circuit_breaker_state"]

    def test_model_dump_validate_round_trip(self):
        """model_dump() -> model_validate() round-trips."""
        status = RalphStatus(
            work_type="IMPLEMENTATION",
            status="COMPLETE",
            exit_signal=True,
            loop_count=10,
        )
        dumped = status.model_dump()
        restored = RalphStatus.model_validate(dumped)
        assert restored == status


class TestCircuitBreakerRoundTrip:
    """Verify .circuit_breaker_state from bash loop loads and round-trips."""

    def test_load_bash_circuit_breaker(self):
        """Real .circuit_breaker_state from bash loop loads without error."""
        data = json.loads((FIXTURES / "circuit_breaker_from_bash.json").read_text())
        cb = CircuitBreakerState(
            state=data["state"],
            no_progress_count=data["no_progress_count"],
            same_error_count=data["same_error_count"],
            last_error=data["last_error"],
            opened_at=data["opened_at"],
            last_transition=data["last_transition"],
        )
        assert cb.state == CircuitBreakerStateEnum.HALF_OPEN
        assert cb.no_progress_count == 3

    def test_model_dump_validate_round_trip(self):
        """model_dump() -> model_validate() round-trips."""
        cb = CircuitBreakerState(
            state="OPEN", no_progress_count=5, last_error="timeout"
        )
        dumped = cb.model_dump()
        restored = CircuitBreakerState.model_validate(dumped)
        assert restored == cb


class TestConfigRoundTrip:
    """Verify config loading from all three sources."""

    def test_load_ralphrc(self, tmp_path):
        """Real .ralphrc loads correctly."""
        import shutil
        shutil.copy(FIXTURES / "ralphrc_sample", tmp_path / ".ralphrc")
        config = RalphConfig.load(tmp_path)
        assert config.project_name == "ralph-claude-code"
        assert config.max_calls_per_hour == 100

    def test_load_json_config(self, tmp_path):
        """Real ralph.config.json loads correctly."""
        import shutil
        shutil.copy(FIXTURES / "ralph_config_sample.json", tmp_path / "ralph.config.json")
        config = RalphConfig.load(tmp_path)
        assert config.project_name == "ralph-claude-code"
        assert config.max_turns == 50

    def test_model_dump_validate_round_trip(self):
        """model_dump() -> model_validate() round-trips."""
        config = RalphConfig(
            project_name="test", max_calls_per_hour=50, max_turns=100
        )
        dumped = config.model_dump()
        restored = RalphConfig.model_validate(dumped)
        assert restored == config


class TestTaskInputRoundTrip:
    """Verify TaskInput construction and round-trip."""

    def test_from_ralph_dir(self, tmp_path):
        """from_ralph_dir() with real .ralph/ directory."""
        ralph_dir = tmp_path / ".ralph"
        ralph_dir.mkdir()
        (ralph_dir / "PROMPT.md").write_text("Build feature X")
        (ralph_dir / "fix_plan.md").write_text("- [ ] Step 1")

        t = TaskInput.from_ralph_dir(ralph_dir)
        assert t.prompt == "Build feature X"
        assert "Step 1" in t.fix_plan

    def test_model_dump_validate_round_trip(self):
        """model_dump() -> model_validate() round-trips."""
        t = TaskInput(prompt="Fix bug", fix_plan="- [ ] Patch")
        dumped = t.model_dump()
        restored = TaskInput.model_validate(dumped)
        assert restored == t


class TestTaskResultRoundTrip:
    """Verify TaskResult and to_signal() compatibility."""

    def test_to_signal_format(self):
        """to_signal() output matches TheStudio expected format."""
        status = RalphStatus(
            work_type="IMPLEMENTATION",
            status="COMPLETE",
            exit_signal=True,
            timestamp="2026-03-22T10:00:00+0000",
        )
        result = TaskResult(status=status, exit_code=0, loop_count=5)
        signal = result.to_signal()

        # Verify TheStudio-expected keys
        assert signal["type"] == "ralph_result"
        assert "task_result" in signal
        assert signal["task_result"]["WORK_TYPE"] == "IMPLEMENTATION"
        assert signal["exit_code"] == 0

    def test_model_dump_validate_round_trip(self):
        """model_dump() -> model_validate() round-trips."""
        result = TaskResult(exit_code=0, output="done", loop_count=3)
        dumped = result.model_dump()
        restored = TaskResult.model_validate(dumped)
        assert restored == result


# --- JSON Schema tests ---

class TestJsonSchemas:
    """Verify model_json_schema() works for all models."""

    def test_ralph_status_schema(self):
        schema = RalphStatus.model_json_schema()
        assert "properties" in schema
        assert "work_type" in schema["properties"]

    def test_circuit_breaker_schema(self):
        schema = CircuitBreakerState.model_json_schema()
        assert "properties" in schema
        assert "state" in schema["properties"]

    def test_task_input_schema(self):
        schema = TaskInput.model_json_schema()
        assert "properties" in schema
        assert "prompt" in schema["properties"]

    def test_task_result_schema(self):
        schema = TaskResult.model_json_schema()
        assert "properties" in schema
        assert "status" in schema["properties"]

    def test_ralph_config_schema(self):
        schema = RalphConfig.model_json_schema()
        assert "properties" in schema
        assert "max_calls_per_hour" in schema["properties"]

    def test_schemas_are_valid_json(self):
        """All schemas are serializable to valid JSON."""
        for model in [RalphStatus, CircuitBreakerState, TaskInput, TaskResult, RalphConfig]:
            schema = model.model_json_schema()
            j = json.dumps(schema)
            assert json.loads(j) == schema


# --- Import path tests ---

class TestImportPaths:
    """Verify all existing import statements still work."""

    def test_status_imports(self):
        from ralph_sdk.status import RalphStatus
        from ralph_sdk.status import CircuitBreakerState
        from ralph_sdk.status import RalphLoopStatus
        from ralph_sdk.status import WorkType
        from ralph_sdk.status import CircuitBreakerStateEnum
        assert RalphStatus is not None

    def test_agent_imports(self):
        from ralph_sdk.agent import TaskInput
        from ralph_sdk.agent import TaskResult
        assert TaskInput is not None

    def test_config_imports(self):
        from ralph_sdk.config import RalphConfig
        assert RalphConfig is not None


# --- Bash loop compatibility tests ---

class TestBashLoopCompatibility:
    """Verify status.json format is compatible with bash loop expectations."""

    def test_status_json_has_uppercase_keys(self):
        """Bash loop expects WORK_TYPE, COMPLETED_TASK, etc. (uppercase with underscores)."""
        s = RalphStatus(work_type="IMPLEMENTATION", status="IN_PROGRESS")
        d = s.to_dict()
        assert "WORK_TYPE" in d
        assert "COMPLETED_TASK" in d
        assert "NEXT_TASK" in d
        assert "PROGRESS_SUMMARY" in d
        assert "EXIT_SIGNAL" in d

    def test_status_json_has_lowercase_keys(self):
        """Bash loop also expects lowercase: status, timestamp, loop_count, etc."""
        s = RalphStatus()
        d = s.to_dict()
        assert "status" in d
        assert "timestamp" in d
        assert "loop_count" in d
        assert "session_id" in d
        assert "circuit_breaker_state" in d
        assert "error" in d

    def test_exit_signal_is_boolean(self):
        """Bash loop checks EXIT_SIGNAL as boolean, not string."""
        s = RalphStatus(exit_signal=True)
        d = s.to_dict()
        assert d["EXIT_SIGNAL"] is True
        assert not isinstance(d["EXIT_SIGNAL"], str)

    def test_enum_values_serialize_as_strings(self):
        """StrEnum values must serialize as plain strings in JSON, not enum repr."""
        s = RalphStatus(work_type="IMPLEMENTATION", status="COMPLETE")
        j = json.dumps(s.to_dict())
        assert '"IMPLEMENTATION"' in j
        assert '"COMPLETE"' in j
        assert "WorkType" not in j
        assert "RalphLoopStatus" not in j

    def test_save_produces_valid_json(self, tmp_path):
        """save() writes valid JSON that bash jq can parse."""
        ralph_dir = tmp_path / ".ralph"
        s = RalphStatus(work_type="TESTING", status="IN_PROGRESS", loop_count=5)
        s.save(ralph_dir)
        status_file = ralph_dir / "status.json"
        assert status_file.exists()
        data = json.loads(status_file.read_text())
        assert data["WORK_TYPE"] == "TESTING"
        assert data["loop_count"] == 5
```

### CLI Verification (Manual)

```bash
# Verify ralph --sdk --dry-run still works end-to-end
cd /path/to/ralph-managed-project
ralph --sdk --dry-run
echo $?  # Should be 0

# Verify status.json is valid and parseable by jq
jq . .ralph/status.json

# Verify bash loop can still read status.json
source ralph_loop.sh  # (in test mode)
# Check that status.json fields are read correctly
```

## Acceptance Criteria

- [ ] All existing valid `status.json` files from bash loop load via `RalphStatus.from_dict()`
- [ ] All existing valid `.circuit_breaker_state` files load via `CircuitBreakerState.load()`
- [ ] All existing valid `.ralphrc` files load via `RalphConfig.load()`
- [ ] All existing valid `ralph.config.json` files load via `RalphConfig.load()`
- [ ] `model_json_schema()` returns valid JSON Schema for all 5 models
- [ ] `model_dump()` -> `model_validate()` round-trips for all 5 models
- [ ] `ralph --sdk --dry-run` completes successfully (exit code 0)
- [ ] `status.json` output is parseable by `jq` (bash loop compatibility)
- [ ] StrEnum values serialize as plain strings, not enum representations
- [ ] All existing import paths (`from ralph_sdk.status import RalphStatus`, etc.) still work
- [ ] No changes required to bash loop (`ralph_loop.sh`, `on-stop.sh`, `circuit_breaker.sh`)
- [ ] Test fixtures represent real-world data from production bash loop output
- [ ] All existing SDK tests pass without modification

## Test Plan

```bash
# Run the full test suite
cd sdk && pytest tests/test_backward_compat.py -v

# Run all existing tests to verify no regressions
cd sdk && pytest -v

# Manual CLI verification
ralph --sdk --dry-run
jq . .ralph/status.json
```
