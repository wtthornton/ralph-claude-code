# Story RALPH-SDK-PYDANTIC-2: Convert RalphStatus to Pydantic BaseModel

**Epic:** [Pydantic v2 Models](epic-sdk-pydantic-models.md)
**Priority:** Critical
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/status.py`

---

## Problem

`RalphStatus` is a plain `@dataclass` with no runtime validation. Invalid values like
`status="BANANA"` or `loop_count="not-a-number"` are silently accepted. The class also
uses raw string fields for values that have a fixed set of valid options (`status`,
`work_type`, `circuit_breaker_state`), providing no discoverability or IDE completion.

The `status.json` file format must not change — the bash loop (`on-stop.sh`, `ralph_loop.sh`)
reads and writes this file and must remain compatible.

## Solution

1. Introduce `RalphLoopStatus` and `WorkType` as `StrEnum` types for validated string fields.
2. Convert `RalphStatus` from `@dataclass` to Pydantic `BaseModel`.
3. Preserve `to_dict()`, `from_dict()`, `load()`, and `save()` method signatures and behavior.
4. The JSON output of `to_dict()` and `save()` must remain byte-identical for the same input data.

## Implementation

### BEFORE (`sdk/ralph_sdk/status.py`, lines 1-89)

```python
from __future__ import annotations

import json
import os
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Any


@dataclass
class RalphStatus:
    """Structured status compatible with on-stop.sh -> status.json format."""

    work_type: str = "UNKNOWN"
    completed_task: str = ""
    next_task: str = ""
    progress_summary: str = ""
    exit_signal: bool = False
    status: str = "IN_PROGRESS"
    timestamp: str = ""
    loop_count: int = 0
    session_id: str = ""
    circuit_breaker_state: str = "CLOSED"
    error: str = ""

    def to_dict(self) -> dict[str, Any]:
        """Export as dictionary matching status.json schema."""
        return {
            "WORK_TYPE": self.work_type,
            "COMPLETED_TASK": self.completed_task,
            "NEXT_TASK": self.next_task,
            "PROGRESS_SUMMARY": self.progress_summary,
            "EXIT_SIGNAL": self.exit_signal,
            "status": self.status,
            "timestamp": self.timestamp or time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "loop_count": self.loop_count,
            "session_id": self.session_id,
            "circuit_breaker_state": self.circuit_breaker_state,
            "error": self.error,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> RalphStatus:
        """Create from status.json dictionary."""
        return cls(
            work_type=data.get("WORK_TYPE", "UNKNOWN"),
            completed_task=data.get("COMPLETED_TASK", ""),
            next_task=data.get("NEXT_TASK", ""),
            progress_summary=data.get("PROGRESS_SUMMARY", ""),
            exit_signal=data.get("EXIT_SIGNAL", False),
            status=data.get("status", "IN_PROGRESS"),
            timestamp=data.get("timestamp", ""),
            loop_count=data.get("loop_count", 0),
            session_id=data.get("session_id", ""),
            circuit_breaker_state=data.get("circuit_breaker_state", "CLOSED"),
            error=data.get("error", ""),
        )

    @classmethod
    def load(cls, ralph_dir: str | Path = ".ralph") -> RalphStatus:
        ...

    def save(self, ralph_dir: str | Path = ".ralph") -> None:
        ...
```

### AFTER (`sdk/ralph_sdk/status.py`, lines 1-100)

```python
from __future__ import annotations

import json
import os
import time
from enum import StrEnum
from pathlib import Path
from typing import Any

from pydantic import BaseModel


class RalphLoopStatus(StrEnum):
    """Valid status values for the Ralph loop."""
    IN_PROGRESS = "IN_PROGRESS"
    COMPLETE = "COMPLETE"
    BLOCKED = "BLOCKED"
    ERROR = "ERROR"
    TIMEOUT = "TIMEOUT"
    DRY_RUN = "DRY_RUN"


class WorkType(StrEnum):
    """Valid work type categories."""
    IMPLEMENTATION = "IMPLEMENTATION"
    TESTING = "TESTING"
    DOCUMENTATION = "DOCUMENTATION"
    REFACTORING = "REFACTORING"
    UNKNOWN = "UNKNOWN"


class RalphStatus(BaseModel):
    """Structured status compatible with on-stop.sh -> status.json format."""

    work_type: WorkType = WorkType.UNKNOWN
    completed_task: str = ""
    next_task: str = ""
    progress_summary: str = ""
    exit_signal: bool = False
    status: RalphLoopStatus = RalphLoopStatus.IN_PROGRESS
    timestamp: str = ""
    loop_count: int = 0
    session_id: str = ""
    circuit_breaker_state: str = "CLOSED"
    error: str = ""

    def to_dict(self) -> dict[str, Any]:
        """Export as dictionary matching status.json schema."""
        return {
            "WORK_TYPE": self.work_type,
            "COMPLETED_TASK": self.completed_task,
            "NEXT_TASK": self.next_task,
            "PROGRESS_SUMMARY": self.progress_summary,
            "EXIT_SIGNAL": self.exit_signal,
            "status": self.status,
            "timestamp": self.timestamp or time.strftime("%Y-%m-%dT%H:%M:%S%z"),
            "loop_count": self.loop_count,
            "session_id": self.session_id,
            "circuit_breaker_state": self.circuit_breaker_state,
            "error": self.error,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> RalphStatus:
        """Create from status.json dictionary."""
        return cls(
            work_type=data.get("WORK_TYPE", "UNKNOWN"),
            completed_task=data.get("COMPLETED_TASK", ""),
            next_task=data.get("NEXT_TASK", ""),
            progress_summary=data.get("PROGRESS_SUMMARY", ""),
            exit_signal=data.get("EXIT_SIGNAL", False),
            status=data.get("status", "IN_PROGRESS"),
            timestamp=data.get("timestamp", ""),
            loop_count=data.get("loop_count", 0),
            session_id=data.get("session_id", ""),
            circuit_breaker_state=data.get("circuit_breaker_state", "CLOSED"),
            error=data.get("error", ""),
        )

    @classmethod
    def load(cls, ralph_dir: str | Path = ".ralph") -> RalphStatus:
        """Load status from .ralph/status.json."""
        status_file = Path(ralph_dir) / "status.json"
        if not status_file.exists():
            return cls()
        try:
            data = json.loads(status_file.read_text(encoding="utf-8"))
            return cls.from_dict(data)
        except (json.JSONDecodeError, OSError):
            return cls()

    def save(self, ralph_dir: str | Path = ".ralph") -> None:
        """Write status atomically to .ralph/status.json (matching bash atomic write pattern)."""
        ralph_dir = Path(ralph_dir)
        ralph_dir.mkdir(parents=True, exist_ok=True)
        status_file = ralph_dir / "status.json"
        tmp_file = status_file.with_suffix(f".{os.getpid()}.tmp")
        try:
            tmp_file.write_text(
                json.dumps(self.to_dict(), indent=2) + "\n",
                encoding="utf-8",
            )
            tmp_file.replace(status_file)
        finally:
            tmp_file.unlink(missing_ok=True)
```

### Key Changes

- `from dataclasses import asdict, dataclass, field` removed entirely.
- `from pydantic import BaseModel` and `from enum import StrEnum` added.
- `work_type` typed as `WorkType` (StrEnum) instead of `str`.
- `status` typed as `RalphLoopStatus` (StrEnum) instead of `str`.
- `circuit_breaker_state` remains `str` here (typed in Story 3 via `CircuitBreakerStateEnum`).
- `StrEnum` values serialize to plain strings in JSON — bash loop sees identical output.
- `to_dict()` output is unchanged because `StrEnum.__str__()` returns the value.
- `from_dict()` accepts plain strings — Pydantic coerces `"UNKNOWN"` to `WorkType.UNKNOWN`.

## Acceptance Criteria

- [ ] `RalphStatus` is a Pydantic `BaseModel` (not `@dataclass`)
- [ ] `RalphLoopStatus` StrEnum with values: `IN_PROGRESS`, `COMPLETE`, `BLOCKED`, `ERROR`, `TIMEOUT`, `DRY_RUN`
- [ ] `WorkType` StrEnum with values: `IMPLEMENTATION`, `TESTING`, `DOCUMENTATION`, `REFACTORING`, `UNKNOWN`
- [ ] `to_dict()` output is identical to the dataclass version for the same input data
- [ ] `from_dict()` accepts both string and enum values
- [ ] `load()` and `save()` preserve atomic write behavior
- [ ] `RalphStatus(status="BANANA")` raises `ValidationError`
- [ ] `RalphStatus(work_type="IMPLEMENTATION")` succeeds (string coercion to enum)
- [ ] `model_json_schema()` returns valid JSON Schema
- [ ] Existing `status.json` files produced by the bash loop still load correctly

## Test Plan

```python
import json
import pytest
from pydantic import ValidationError
from ralph_sdk.status import RalphStatus, RalphLoopStatus, WorkType


def test_default_construction():
    """Default RalphStatus matches previous dataclass defaults."""
    s = RalphStatus()
    assert s.work_type == WorkType.UNKNOWN
    assert s.status == RalphLoopStatus.IN_PROGRESS
    assert s.exit_signal is False
    assert s.loop_count == 0


def test_string_coercion_to_enum():
    """Plain strings from bash loop coerce to StrEnum values."""
    s = RalphStatus(work_type="IMPLEMENTATION", status="COMPLETE")
    assert s.work_type == WorkType.IMPLEMENTATION
    assert s.status == RalphLoopStatus.COMPLETE


def test_invalid_status_raises():
    """Invalid status value raises ValidationError."""
    with pytest.raises(ValidationError):
        RalphStatus(status="BANANA")


def test_invalid_work_type_raises():
    """Invalid work_type value raises ValidationError."""
    with pytest.raises(ValidationError):
        RalphStatus(work_type="GARDENING")


def test_to_dict_format_unchanged():
    """to_dict() output matches the bash loop status.json format."""
    s = RalphStatus(
        work_type="IMPLEMENTATION",
        completed_task="Fix bug",
        status="IN_PROGRESS",
        loop_count=5,
        timestamp="2026-03-22T10:00:00+0000",
    )
    d = s.to_dict()
    assert d["WORK_TYPE"] == "IMPLEMENTATION"
    assert d["COMPLETED_TASK"] == "Fix bug"
    assert d["status"] == "IN_PROGRESS"
    assert d["loop_count"] == 5


def test_round_trip():
    """from_dict(to_dict(x)) preserves all fields."""
    original = RalphStatus(
        work_type="TESTING",
        completed_task="Add tests",
        next_task="Deploy",
        status="COMPLETE",
        exit_signal=True,
        loop_count=10,
        timestamp="2026-03-22T10:00:00+0000",
    )
    restored = RalphStatus.from_dict(original.to_dict())
    assert restored.work_type == original.work_type
    assert restored.status == original.status
    assert restored.exit_signal == original.exit_signal


def test_load_from_bash_status_json(tmp_path):
    """Load a status.json file written by the bash loop."""
    status_json = {
        "WORK_TYPE": "IMPLEMENTATION",
        "COMPLETED_TASK": "Fix parser",
        "NEXT_TASK": "Add tests",
        "PROGRESS_SUMMARY": "Parser fixed",
        "EXIT_SIGNAL": False,
        "status": "IN_PROGRESS",
        "timestamp": "2026-03-22T10:00:00+0000",
        "loop_count": 3,
        "session_id": "abc-123",
        "circuit_breaker_state": "CLOSED",
        "error": "",
    }
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    (ralph_dir / "status.json").write_text(json.dumps(status_json, indent=2))

    s = RalphStatus.load(ralph_dir)
    assert s.work_type == WorkType.IMPLEMENTATION
    assert s.loop_count == 3


def test_save_load_round_trip(tmp_path):
    """save() then load() preserves all data."""
    ralph_dir = tmp_path / ".ralph"
    original = RalphStatus(work_type="TESTING", status="COMPLETE", loop_count=7)
    original.save(ralph_dir)
    restored = RalphStatus.load(ralph_dir)
    assert restored.work_type == original.work_type
    assert restored.status == original.status
    assert restored.loop_count == original.loop_count


def test_json_schema():
    """model_json_schema() returns valid schema."""
    schema = RalphStatus.model_json_schema()
    assert "properties" in schema
    assert "work_type" in schema["properties"]
    assert "status" in schema["properties"]
```
