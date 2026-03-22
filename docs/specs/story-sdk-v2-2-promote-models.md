# Story RALPH-SDK-V2-2: Promote Pydantic TaskInput as Default

**Epic:** [Release, Integration Testing & v2.0.0](epic-sdk-v2-release.md)
**Priority:** High
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/__init__.py`, `sdk/ralph_sdk/agent.py`

---

## Problem

During the Epic 1 migration, the legacy `@dataclass` versions of `TaskInput`, `TaskResult`,
and `RalphStatus` may still exist alongside the new Pydantic `BaseModel` versions. If
`from ralph_sdk import TaskInput` returns the dataclass version, callers silently get the
old type without validation, missing the new `from_task_packet()` method that accepts
Pydantic models.

All public imports must resolve to the Pydantic versions for v2.0.0.

## Solution

Ensure the `__init__.py` public API exports the Pydantic versions of all models. Remove
or alias any legacy dataclass references so that:

- `from ralph_sdk import TaskInput` returns the Pydantic BaseModel version
- `from ralph_sdk import TaskResult` returns the Pydantic BaseModel version
- `from ralph_sdk import RalphStatus` returns the Pydantic BaseModel version
- `from ralph_sdk import EvidenceBundle` is available
- `from ralph_sdk import TaskPacketInput, IntentSpecInput` are available

## Implementation

**File:** `sdk/ralph_sdk/__init__.py`

```python
"""Ralph Agent SDK — autonomous AI development loop for Claude Code."""

from ralph_sdk.agent import RalphAgent, TaskInput, TaskResult
from ralph_sdk.config import RalphConfig
from ralph_sdk.converters import IntentSpecInput, TaskPacketInput
from ralph_sdk.evidence import EvidenceBundle
from ralph_sdk.state import FileStateBackend, NullStateBackend, RalphStateBackend
from ralph_sdk.status import RalphStatus

__all__ = [
    "EvidenceBundle",
    "FileStateBackend",
    "IntentSpecInput",
    "NullStateBackend",
    "RalphAgent",
    "RalphConfig",
    "RalphStateBackend",
    "RalphStatus",
    "TaskInput",
    "TaskPacketInput",
    "TaskResult",
]
```

### Key Notes

- `__all__` explicitly lists every public name — no implicit exports.
- All model classes are the Pydantic BaseModel versions.
- Legacy dataclass versions (if they still exist internally) are not exported.
- `TaskPacketInput` and `IntentSpecInput` from `converters.py` are promoted to top-level exports.
- `EvidenceBundle` from `evidence.py` is promoted to top-level export.
- State backend classes are exported for TheStudio integration.

## Acceptance Criteria

- [ ] `from ralph_sdk import TaskInput` returns Pydantic BaseModel version
- [ ] `from ralph_sdk import TaskResult` returns Pydantic BaseModel version
- [ ] `from ralph_sdk import RalphStatus` returns Pydantic BaseModel version
- [ ] `from ralph_sdk import EvidenceBundle` works
- [ ] `from ralph_sdk import TaskPacketInput, IntentSpecInput` works
- [ ] `from ralph_sdk import RalphStateBackend, FileStateBackend, NullStateBackend` works
- [ ] `__all__` is defined and lists all public exports
- [ ] No legacy dataclass versions accessible via top-level import
- [ ] `isinstance(TaskInput(...), BaseModel)` is `True`

## Test Plan

```python
import ralph_sdk
from pydantic import BaseModel


def test_taskinput_is_pydantic():
    from ralph_sdk import TaskInput
    assert issubclass(TaskInput, BaseModel)


def test_taskresult_is_pydantic():
    from ralph_sdk import TaskResult
    assert issubclass(TaskResult, BaseModel)


def test_evidence_bundle_importable():
    from ralph_sdk import EvidenceBundle
    assert issubclass(EvidenceBundle, BaseModel)


def test_converter_models_importable():
    from ralph_sdk import TaskPacketInput, IntentSpecInput
    assert issubclass(TaskPacketInput, BaseModel)
    assert issubclass(IntentSpecInput, BaseModel)


def test_state_backends_importable():
    from ralph_sdk import RalphStateBackend, FileStateBackend, NullStateBackend
    assert RalphStateBackend is not None
    assert FileStateBackend is not None
    assert NullStateBackend is not None


def test_all_exports_defined():
    assert hasattr(ralph_sdk, "__all__")
    expected = {
        "RalphAgent", "TaskInput", "TaskResult", "RalphConfig",
        "RalphStatus", "EvidenceBundle", "TaskPacketInput",
        "IntentSpecInput", "RalphStateBackend", "FileStateBackend",
        "NullStateBackend",
    }
    assert expected.issubset(set(ralph_sdk.__all__))
```
