# Story RALPH-SDK-TASKPACKET-7: Deprecate Old from_task_packet(dict)

**Epic:** [TaskPacket Conversion](epic-sdk-taskpacket.md)
**Priority:** Medium
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

The old `from_task_packet(dict)` method is still in use by any callers that pass raw
dictionaries. It needs to continue working for backward compatibility, but new callers
should use the typed Pydantic models. Without a deprecation warning, callers have no
incentive to migrate and no signal that the dict-based API is going away.

## Solution

Keep the old method working but detect when a raw `dict` is passed (instead of
`TaskPacketInput`). When a dict is detected:

1. Emit `warnings.warn()` with `DeprecationWarning` category.
2. Wrap the dict into `TaskPacketInput` and create a minimal `IntentSpecInput`.
3. Delegate to the new typed method.

This way, existing callers get a clear warning in their logs/test output while
continuing to function correctly.

## Implementation

**File:** `sdk/ralph_sdk/agent.py`

```python
import warnings
from typing import overload

class TaskInput(BaseModel):

    @classmethod
    def from_task_packet(
        cls,
        packet: TaskPacketInput | dict,
        intent: IntentSpecInput | None = None,
        *,
        loopback_context: str = "",
        expert_outputs: list[str] | None = None,
    ) -> "TaskInput":
        """Convert a TaskPacket into a TaskInput.

        Accepts either typed Pydantic models (preferred) or a raw dict (deprecated).
        """
        if isinstance(packet, dict):
            warnings.warn(
                "Passing a raw dict to from_task_packet() is deprecated. "
                "Use TaskPacketInput and IntentSpecInput models instead. "
                "See sdk-migration-strategy.md for details.",
                DeprecationWarning,
                stacklevel=2,
            )
            # Wrap legacy dict into new models
            from uuid import uuid4
            wrapped_packet = TaskPacketInput(
                id=packet.get("id", uuid4()),
                repo=packet.get("repo", ""),
            )
            wrapped_intent = IntentSpecInput(
                goal=packet.get("prompt", ""),
                constraints=packet.get("constraints", []),
            )
            return cls.from_task_packet(
                wrapped_packet,
                wrapped_intent,
                loopback_context=loopback_context,
                expert_outputs=expert_outputs,
            )

        # New typed path (packet is TaskPacketInput, intent is required)
        if intent is None:
            raise TypeError(
                "intent is required when using TaskPacketInput. "
                "Pass IntentSpecInput as the second argument."
            )
        # ... proceed with typed conversion (Stories 2-6) ...
```

### Key Notes

- `isinstance(packet, dict)` check dispatches between old and new paths.
- The deprecation warning includes `stacklevel=2` so it points to the caller, not the method itself.
- Legacy dict fields `"prompt"` and `"constraints"` are mapped to `IntentSpecInput.goal` and `IntentSpecInput.constraints`.
- When `packet` is a `TaskPacketInput` but `intent` is `None`, a `TypeError` is raised with a clear message.
- The `uuid4()` fallback for missing `"id"` ensures the wrapped model is always valid.

## Acceptance Criteria

- [ ] Passing a `dict` to `from_task_packet()` emits a `DeprecationWarning`
- [ ] Warning message mentions `TaskPacketInput`, `IntentSpecInput`, and `sdk-migration-strategy.md`
- [ ] Legacy dict call still returns a valid `TaskInput`
- [ ] Legacy dict `"prompt"` field maps to `IntentSpecInput.goal`
- [ ] Legacy dict `"constraints"` field maps to `IntentSpecInput.constraints`
- [ ] Passing `TaskPacketInput` without `intent` raises `TypeError`
- [ ] Passing `TaskPacketInput` with `IntentSpecInput` works without warnings
- [ ] `stacklevel=2` ensures warning points to the caller

## Test Plan

```python
import warnings
from uuid import uuid4
from ralph_sdk.agent import TaskInput
from ralph_sdk.converters import TaskPacketInput, IntentSpecInput


def test_legacy_dict_emits_warning():
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        task = TaskInput.from_task_packet({
            "prompt": "Fix the bug",
            "fix_plan": "1. Find bug\n2. Fix it",
        })
        assert len(w) == 1
        assert issubclass(w[0].category, DeprecationWarning)
        assert "TaskPacketInput" in str(w[0].message)


def test_legacy_dict_still_works():
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        task = TaskInput.from_task_packet({
            "prompt": "Fix the bug",
            "project_type": "python",
        })
        assert isinstance(task, TaskInput)
        assert "Fix the bug" in task.prompt


def test_new_typed_no_warning():
    with warnings.catch_warnings(record=True) as w:
        warnings.simplefilter("always")
        packet = TaskPacketInput(id=uuid4())
        intent = IntentSpecInput(goal="Implement feature")
        task = TaskInput.from_task_packet(packet, intent)
        deprecation_warnings = [x for x in w if issubclass(x.category, DeprecationWarning)]
        assert len(deprecation_warnings) == 0


def test_typed_packet_without_intent_raises():
    packet = TaskPacketInput(id=uuid4())
    with pytest.raises(TypeError, match="intent is required"):
        TaskInput.from_task_packet(packet)


def test_legacy_dict_with_constraints():
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        task = TaskInput.from_task_packet({
            "prompt": "Do the thing",
            "constraints": ["Keep API stable"],
        })
        assert "Keep API stable" in task.constraints
```
