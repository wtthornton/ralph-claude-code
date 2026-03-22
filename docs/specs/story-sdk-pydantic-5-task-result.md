# Story RALPH-SDK-PYDANTIC-5: Convert TaskResult to Pydantic BaseModel

**Epic:** [Pydantic v2 Models](epic-sdk-pydantic-models.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

`TaskResult` is a plain `@dataclass` with no validation. The `exit_code` field accepts any
integer (including negatives), `duration_seconds` accepts negative floats, and the `status`
field accepts any object (not just `RalphStatus`). Now that `RalphStatus` is a Pydantic
`BaseModel` (Story 2), `TaskResult` should follow suit to maintain a consistent model layer.

## Solution

1. Convert `TaskResult` from `@dataclass` to Pydantic `BaseModel`.
2. The `status` field references the Pydantic `RalphStatus` model (from Story 2).
3. Keep the `to_signal()` method with identical output format.
4. Add basic validation: `exit_code >= 0`, `duration_seconds >= 0.0`.

## Implementation

### BEFORE (`sdk/ralph_sdk/agent.py`, lines 114-135)

```python
@dataclass
class TaskResult:
    """Output compatible with status.json and TheStudio signals."""
    status: RalphStatus = field(default_factory=RalphStatus)
    exit_code: int = 0
    output: str = ""
    error: str = ""
    loop_count: int = 0
    duration_seconds: float = 0.0

    def to_signal(self) -> dict[str, Any]:
        """Convert to TheStudio-compatible signal format."""
        return {
            "type": "ralph_result",
            "task_result": self.status.to_dict(),
            "exit_code": self.exit_code,
            "output": self.output,
            "error": self.error,
            "loop_count": self.loop_count,
            "duration_seconds": self.duration_seconds,
        }
```

### AFTER (`sdk/ralph_sdk/agent.py`, TaskResult section)

```python
from pydantic import BaseModel, Field


class TaskResult(BaseModel):
    """Output compatible with status.json and TheStudio signals."""
    status: RalphStatus = Field(default_factory=RalphStatus)
    exit_code: int = Field(default=0, ge=0)
    output: str = ""
    error: str = ""
    loop_count: int = Field(default=0, ge=0)
    duration_seconds: float = Field(default=0.0, ge=0.0)

    def to_signal(self) -> dict[str, Any]:
        """Convert to TheStudio-compatible signal format."""
        return {
            "type": "ralph_result",
            "task_result": self.status.to_dict(),
            "exit_code": self.exit_code,
            "output": self.output,
            "error": self.error,
            "loop_count": self.loop_count,
            "duration_seconds": self.duration_seconds,
        }
```

### Key Changes

- `@dataclass` replaced with `BaseModel`.
- `field(default_factory=RalphStatus)` replaced with `Field(default_factory=RalphStatus)`.
- `exit_code` constrained to `ge=0` (exit codes are non-negative).
- `loop_count` constrained to `ge=0`.
- `duration_seconds` constrained to `ge=0.0`.
- `status` field typed as the Pydantic `RalphStatus` model — nested validation applies.
- `to_signal()` method is unchanged — `self.status.to_dict()` works identically because `RalphStatus.to_dict()` was preserved in Story 2.

### Import Changes

In `agent.py`, update the dataclass imports:

```python
# BEFORE
from dataclasses import dataclass, field

# AFTER
from pydantic import BaseModel, ConfigDict, Field
```

Note: `dataclass` import may still be needed if other classes in `agent.py` remain as
dataclasses during transition. Remove entirely when all models are converted.

## Acceptance Criteria

- [ ] `TaskResult` is a Pydantic `BaseModel` (not `@dataclass`)
- [ ] `status` field is typed as `RalphStatus` (Pydantic model from Story 2)
- [ ] `TaskResult(exit_code=-1)` raises `ValidationError`
- [ ] `TaskResult(duration_seconds=-5.0)` raises `ValidationError`
- [ ] `TaskResult()` succeeds with default `RalphStatus()` instance
- [ ] `to_signal()` output format is identical to the dataclass version
- [ ] Nested validation works: `TaskResult(status=RalphStatus(status="BANANA"))` raises `ValidationError`
- [ ] `model_json_schema()` returns valid JSON Schema including nested `RalphStatus` schema

## Test Plan

```python
import pytest
from pydantic import ValidationError
from ralph_sdk.agent import TaskResult
from ralph_sdk.status import RalphStatus, RalphLoopStatus, WorkType


def test_default_construction():
    """Default TaskResult has default RalphStatus and zero counters."""
    r = TaskResult()
    assert isinstance(r.status, RalphStatus)
    assert r.exit_code == 0
    assert r.output == ""
    assert r.duration_seconds == 0.0


def test_with_status():
    """TaskResult accepts a RalphStatus instance."""
    status = RalphStatus(
        work_type="IMPLEMENTATION",
        status="COMPLETE",
        exit_signal=True,
    )
    r = TaskResult(status=status, exit_code=0, loop_count=5, duration_seconds=120.5)
    assert r.status.work_type == WorkType.IMPLEMENTATION
    assert r.loop_count == 5


def test_negative_exit_code_raises():
    """Negative exit code raises ValidationError."""
    with pytest.raises(ValidationError):
        TaskResult(exit_code=-1)


def test_negative_duration_raises():
    """Negative duration raises ValidationError."""
    with pytest.raises(ValidationError):
        TaskResult(duration_seconds=-5.0)


def test_negative_loop_count_raises():
    """Negative loop count raises ValidationError."""
    with pytest.raises(ValidationError):
        TaskResult(loop_count=-1)


def test_nested_validation():
    """Invalid nested RalphStatus triggers validation error."""
    with pytest.raises(ValidationError):
        TaskResult(status=RalphStatus(status="INVALID_STATUS"))


def test_to_signal_format():
    """to_signal() matches TheStudio signal format."""
    status = RalphStatus(
        work_type="TESTING",
        completed_task="Run tests",
        status="COMPLETE",
        exit_signal=True,
        timestamp="2026-03-22T10:00:00+0000",
    )
    r = TaskResult(status=status, exit_code=0, output="All tests pass", loop_count=3)
    signal = r.to_signal()

    assert signal["type"] == "ralph_result"
    assert signal["task_result"]["WORK_TYPE"] == "TESTING"
    assert signal["task_result"]["COMPLETED_TASK"] == "Run tests"
    assert signal["task_result"]["status"] == "COMPLETE"
    assert signal["exit_code"] == 0
    assert signal["output"] == "All tests pass"
    assert signal["loop_count"] == 3


def test_to_signal_default():
    """to_signal() works with default TaskResult."""
    r = TaskResult()
    signal = r.to_signal()
    assert signal["type"] == "ralph_result"
    assert signal["task_result"]["WORK_TYPE"] == "UNKNOWN"
    assert signal["exit_code"] == 0


def test_json_schema():
    """model_json_schema() returns valid schema with nested RalphStatus."""
    schema = TaskResult.model_json_schema()
    assert "properties" in schema
    assert "status" in schema["properties"]
    assert "exit_code" in schema["properties"]
    # Verify nested model is referenced
    assert "$defs" in schema or "$ref" in str(schema["properties"]["status"])
```
