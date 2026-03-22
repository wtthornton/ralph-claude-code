# Story RALPH-SDK-PARSING-1: Define RalphStatusBlock Pydantic Model with Enums

**Epic:** [Structured Response Parsing](epic-sdk-structured-parsing.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/status.py`

---

## Problem

The current `RalphStatus` dataclass (status.py:14-60) uses plain strings for all fields
with no validation. This allows malformed data to flow through the system silently:

- `work_type` accepts any string, including typos like `"IMPLMENTATION"`
- `exit_signal` is typed as `bool` but parsed from strings without consistent coercion
- `status` has no enum constraint — `"IN_PROGRSS"` passes without error
- There is no schema version field, so format changes break parsing silently
- Numeric fields like `tasks_completed` don't exist yet, and when added need `ge=0` guards

A Pydantic model with enums and validators catches bad data at parse time instead of
propagating it through the loop.

## Solution

Define a `RalphStatusBlock` Pydantic model alongside the existing `RalphStatus` dataclass.
The dataclass remains for backward compatibility with `status.json` read/write; the Pydantic
model is used by the new parser (PARSING-2) for validated extraction from Claude output.

Add `TestsStatus` enum alongside the existing status/work-type concepts. Share enums if
an enums module already exists from Epic 1; otherwise define them in `status.py`.

## Implementation

### Change 1: `sdk/ralph_sdk/status.py` — Add enums and Pydantic model

```python
# BEFORE (only dataclass exists):
from dataclasses import asdict, dataclass, field

@dataclass
class RalphStatus:
    work_type: str = "UNKNOWN"
    completed_task: str = ""
    ...

# AFTER (add enums + Pydantic model after the dataclass):
from enum import Enum
from pydantic import BaseModel, Field

class RalphLoopStatus(str, Enum):
    """Loop iteration outcome."""
    IN_PROGRESS = "IN_PROGRESS"
    COMPLETED = "COMPLETED"
    ERROR = "ERROR"
    BLOCKED = "BLOCKED"

class WorkType(str, Enum):
    """Type of work performed in this iteration."""
    IMPLEMENTATION = "IMPLEMENTATION"
    TESTING = "TESTING"
    REFACTORING = "REFACTORING"
    DOCUMENTATION = "DOCUMENTATION"
    INVESTIGATION = "INVESTIGATION"
    PLANNING = "PLANNING"
    REVIEW = "REVIEW"
    UNKNOWN = "UNKNOWN"

class TestsStatus(str, Enum):
    """Test suite status after this iteration."""
    PASSING = "PASSING"
    FAILING = "FAILING"
    DEFERRED = "DEFERRED"
    NOT_RUN = "NOT_RUN"

class RalphStatusBlock(BaseModel):
    """Validated status block extracted from Claude response.

    Used by parse_ralph_status() (PARSING-2) to validate structured output.
    The existing RalphStatus dataclass remains for status.json I/O.
    """
    version: int = Field(default=1, ge=1, description="Schema version for forward compat")
    status: RalphLoopStatus = RalphLoopStatus.IN_PROGRESS
    exit_signal: bool = False
    tasks_completed: int = Field(default=0, ge=0)
    files_modified: int = Field(default=0, ge=0)
    progress_summary: str = ""
    work_type: WorkType = WorkType.UNKNOWN
    tests_status: TestsStatus = TestsStatus.NOT_RUN

    def to_ralph_status(self) -> "RalphStatus":
        """Convert validated block to RalphStatus for downstream consumption."""
        return RalphStatus(
            work_type=self.work_type.value,
            progress_summary=self.progress_summary,
            exit_signal=self.exit_signal,
            status=self.status.value,
        )
```

### Change 2: Add pydantic to dependencies

```toml
# sdk/pyproject.toml (or setup.cfg / requirements.txt)
# BEFORE:
# (no pydantic dependency)

# AFTER:
dependencies = [
    "pydantic>=2.0,<3.0",
]
```

## Acceptance Criteria

- [ ] `RalphLoopStatus` enum has values: `IN_PROGRESS`, `COMPLETED`, `ERROR`, `BLOCKED`
- [ ] `WorkType` enum has values: `IMPLEMENTATION`, `TESTING`, `REFACTORING`, `DOCUMENTATION`, `INVESTIGATION`, `PLANNING`, `REVIEW`, `UNKNOWN`
- [ ] `TestsStatus` enum has values: `PASSING`, `FAILING`, `DEFERRED`, `NOT_RUN`
- [ ] `RalphStatusBlock` is a Pydantic BaseModel with `version` (int, default=1, ge=1), `status`, `exit_signal`, `tasks_completed` (int, ge=0), `files_modified` (int, ge=0), `progress_summary` (str), `work_type`, `tests_status`
- [ ] `RalphStatusBlock(tasks_completed=-1)` raises `ValidationError`
- [ ] `RalphStatusBlock(version=0)` raises `ValidationError`
- [ ] `RalphStatusBlock(work_type="BANANA")` raises `ValidationError`
- [ ] `RalphStatusBlock()` succeeds with all defaults (version=1, status=IN_PROGRESS, etc.)
- [ ] `to_ralph_status()` produces a valid `RalphStatus` dataclass instance
- [ ] Existing `RalphStatus` dataclass and its `load()`/`save()` behavior unchanged
- [ ] pydantic added to SDK dependencies

## Test Plan

```python
import pytest
from pydantic import ValidationError
from ralph_sdk.status import (
    RalphLoopStatus, WorkType, TestsStatus, RalphStatusBlock, RalphStatus,
)

def test_defaults():
    block = RalphStatusBlock()
    assert block.version == 1
    assert block.status == RalphLoopStatus.IN_PROGRESS
    assert block.exit_signal is False
    assert block.tasks_completed == 0
    assert block.files_modified == 0
    assert block.work_type == WorkType.UNKNOWN
    assert block.tests_status == TestsStatus.NOT_RUN

def test_valid_construction():
    block = RalphStatusBlock(
        version=1, status="COMPLETED", exit_signal=True,
        tasks_completed=3, files_modified=7,
        progress_summary="Finished all tasks",
        work_type="IMPLEMENTATION", tests_status="PASSING",
    )
    assert block.status == RalphLoopStatus.COMPLETED
    assert block.work_type == WorkType.IMPLEMENTATION

def test_invalid_tasks_completed():
    with pytest.raises(ValidationError):
        RalphStatusBlock(tasks_completed=-1)

def test_invalid_version_zero():
    with pytest.raises(ValidationError):
        RalphStatusBlock(version=0)

def test_invalid_work_type():
    with pytest.raises(ValidationError):
        RalphStatusBlock(work_type="BANANA")

def test_to_ralph_status():
    block = RalphStatusBlock(status="COMPLETED", work_type="TESTING", exit_signal=True)
    rs = block.to_ralph_status()
    assert isinstance(rs, RalphStatus)
    assert rs.status == "COMPLETED"
    assert rs.work_type == "TESTING"
    assert rs.exit_signal is True

def test_existing_dataclass_unaffected():
    """RalphStatus dataclass must still work exactly as before."""
    rs = RalphStatus(work_type="IMPLEMENTATION", exit_signal=True)
    d = rs.to_dict()
    assert d["WORK_TYPE"] == "IMPLEMENTATION"
    assert d["EXIT_SIGNAL"] is True
    rs2 = RalphStatus.from_dict(d)
    assert rs2.work_type == "IMPLEMENTATION"
```
