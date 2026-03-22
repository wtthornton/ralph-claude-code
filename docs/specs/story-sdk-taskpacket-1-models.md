# Story RALPH-SDK-TASKPACKET-1: Define Ralph-Side Input Mirror Models

**Epic:** [TaskPacket Conversion](epic-sdk-taskpacket.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/converters.py` (new file)

---

## Problem

TheStudio sends `TaskPacket` and `IntentSpec` objects to Ralph, but Ralph has no typed
models to receive them. The current `from_task_packet()` accepts a raw `dict` with no
validation. Before implementing the new conversion pipeline (Stories 2-7), Ralph needs
its own Pydantic models that mirror the shape of TheStudio's models without importing
from TheStudio.

Ralph must remain free and independent — it can be used by any orchestration platform,
not just TheStudio. Therefore Ralph defines its own input models, and TheStudio writes
a thin mapper to convert its `TaskPacketRead` / `IntentSpecRead` into Ralph's types.

## Solution

Create a new `sdk/ralph_sdk/converters.py` module containing two Pydantic `BaseModel`
classes: `TaskPacketInput` and `IntentSpecInput`. These are Ralph's own models —
NOT imported from TheStudio.

## Implementation

**File:** `sdk/ralph_sdk/converters.py` (new)

```python
from __future__ import annotations

from typing import Any
from uuid import UUID

from pydantic import BaseModel, Field


class TaskPacketInput(BaseModel):
    """Ralph's view of an external task packet.

    Matches TheStudio TaskPacketRead shape. Ralph owns this model —
    TheStudio maps its models to this interface.
    """
    id: UUID
    repo: str = ""
    complexity_index: dict[str, Any] | None = None  # {"score": float, "band": str}
    risk_flags: dict[str, bool] | None = None
    context_packs: list[dict[str, Any]] | None = None
    task_trust_tier: str = "suggest"
    loopback_count: int = 0


class IntentSpecInput(BaseModel):
    """Ralph's view of an intent specification.

    Matches TheStudio IntentSpecRead shape. Ralph owns this model —
    TheStudio maps its models to this interface.
    """
    goal: str
    constraints: list[str] = Field(default_factory=list)
    acceptance_criteria: list[str] = Field(default_factory=list)
    non_goals: list[str] = Field(default_factory=list)
    version: int = 1
```

### Key Notes

- `TaskPacketInput.id` is a `UUID`, not a string — ensures type safety at the boundary.
- `complexity_index` is `dict[str, Any] | None` to accommodate the flexible `{"score": float, "band": str}` shape without coupling to a specific schema.
- `risk_flags` is `dict[str, bool] | None` — keys are flag names, values indicate active/inactive.
- `context_packs` is `list[dict[str, Any]] | None` — each dict is a context pack with file paths and metadata.
- `task_trust_tier` defaults to `"suggest"` (most restrictive) for safety.
- `IntentSpecInput.version` defaults to `1` for forward compatibility.
- No TheStudio imports anywhere in this file.

## Acceptance Criteria

- [ ] `sdk/ralph_sdk/converters.py` exists with `TaskPacketInput` and `IntentSpecInput`
- [ ] `TaskPacketInput` has fields: `id` (UUID), `repo` (str), `complexity_index` (dict|None), `risk_flags` (dict[str,bool]|None), `context_packs` (list[dict]|None), `task_trust_tier` (str, default="suggest"), `loopback_count` (int, default=0)
- [ ] `IntentSpecInput` has fields: `goal` (str), `constraints` (list[str]), `acceptance_criteria` (list[str]), `non_goals` (list[str]), `version` (int, default=1)
- [ ] `from ralph_sdk.converters import TaskPacketInput, IntentSpecInput` imports cleanly
- [ ] Both models are Pydantic `BaseModel` subclasses (not dataclasses)
- [ ] No TheStudio imports — Ralph owns these models
- [ ] `mypy sdk/ralph_sdk/converters.py` passes cleanly

## Test Plan

```python
from uuid import uuid4
from pydantic import ValidationError
from ralph_sdk.converters import TaskPacketInput, IntentSpecInput


def test_taskpacket_minimal():
    """Only required field is id."""
    pkt = TaskPacketInput(id=uuid4())
    assert pkt.repo == ""
    assert pkt.complexity_index is None
    assert pkt.risk_flags is None
    assert pkt.context_packs is None
    assert pkt.task_trust_tier == "suggest"
    assert pkt.loopback_count == 0


def test_taskpacket_full():
    pkt = TaskPacketInput(
        id=uuid4(),
        repo="my-org/my-repo",
        complexity_index={"score": 0.7, "band": "high"},
        risk_flags={"touches_auth": True, "touches_payments": False},
        context_packs=[{"path": "src/main.py", "reason": "entry point"}],
        task_trust_tier="auto",
        loopback_count=2,
    )
    assert pkt.repo == "my-org/my-repo"
    assert pkt.complexity_index["band"] == "high"
    assert pkt.loopback_count == 2


def test_taskpacket_invalid_id():
    with pytest.raises(ValidationError):
        TaskPacketInput(id="not-a-uuid")


def test_intentspec_minimal():
    intent = IntentSpecInput(goal="Fix the bug")
    assert intent.constraints == []
    assert intent.acceptance_criteria == []
    assert intent.non_goals == []
    assert intent.version == 1


def test_intentspec_full():
    intent = IntentSpecInput(
        goal="Implement feature X",
        constraints=["Must not break API"],
        acceptance_criteria=["Tests pass", "Lint clean"],
        non_goals=["Performance optimization"],
        version=2,
    )
    assert len(intent.constraints) == 1
    assert intent.version == 2


def test_intentspec_requires_goal():
    with pytest.raises(ValidationError):
        IntentSpecInput()  # goal is required
```
