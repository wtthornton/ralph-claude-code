# Story RALPH-SDK-TASKPACKET-2: Implement New from_task_packet() with Full Signature

**Epic:** [TaskPacket Conversion](epic-sdk-taskpacket.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Medium
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

The current `from_task_packet()` is a classmethod on `TaskInput` that accepts a raw `dict`
and extracts only 4 fields (`prompt`, `fix_plan`, `agent_instructions`, `project_type`).
It ignores all the rich context from TheStudio's `TaskPacket` and `IntentSpec`. With the
new mirror models defined in Story 1, Ralph needs a proper conversion method that accepts
typed Pydantic inputs and produces a fully-populated `TaskInput`.

## Solution

Implement a new `from_task_packet()` classmethod on `TaskInput` with the full signature:

```python
@classmethod
def from_task_packet(
    cls,
    packet: TaskPacketInput,
    intent: IntentSpecInput,
    *,
    loopback_context: str = "",
    expert_outputs: list[str] | None = None,
) -> TaskInput:
```

This method orchestrates the mapping by calling into field-specific helpers (Stories 3-6).
In this story, the method is wired up with the basic structure and direct field mappings.
The detailed mapping logic for intent fields, risk flags, complexity, and loopback context
are implemented in subsequent stories.

## Implementation

**File:** `sdk/ralph_sdk/agent.py`

```python
from ralph_sdk.converters import TaskPacketInput, IntentSpecInput

class TaskInput(BaseModel):
    # ... existing fields ...

    @classmethod
    def from_task_packet(
        cls,
        packet: TaskPacketInput,
        intent: IntentSpecInput,
        *,
        loopback_context: str = "",
        expert_outputs: list[str] | None = None,
    ) -> "TaskInput":
        """Convert a TaskPacket + IntentSpec into a TaskInput.

        This is the primary entry point for TheStudio embedding. Each field
        mapping is handled by a dedicated helper (Stories 3-6):
        - intent fields → prompt + constraints (Story 3)
        - risk_flags, context_packs, trust_tier → constraints + context (Story 4)
        - complexity_index → max_turns (Story 5)
        - loopback_context → prompt prefix (Story 6)

        Args:
            packet: Ralph-side mirror of TheStudio's TaskPacket.
            intent: Ralph-side mirror of TheStudio's IntentSpec.
            loopback_context: Error context from a previous failed attempt.
            expert_outputs: Reserved for future expert agent integration.

        Returns:
            A fully-populated TaskInput ready for run_iteration().
        """
        prompt = intent.goal
        constraints: list[str] = list(intent.constraints)

        return cls(
            prompt=prompt,
            constraints=constraints,
            # Other fields populated by Stories 3-6
        )
```

### Key Notes

- The method accepts Pydantic models, not raw dicts.
- Keyword-only arguments (`*`) after `intent` prevent positional misuse.
- `expert_outputs` is accepted but unused in this story (reserved for future work).
- The body is intentionally minimal — subsequent stories fill in the mapping logic.
- The old dict-based `from_task_packet()` is preserved (Story 7 handles deprecation).

## Acceptance Criteria

- [ ] `TaskInput.from_task_packet(packet, intent)` accepts `TaskPacketInput` and `IntentSpecInput`
- [ ] Method signature includes keyword-only `loopback_context: str = ""` and `expert_outputs: list[str] | None = None`
- [ ] Returns a valid `TaskInput` instance
- [ ] `intent.goal` maps to `prompt`
- [ ] `intent.constraints` maps to `constraints`
- [ ] Method has docstring documenting all parameters and the story-by-story mapping plan
- [ ] Old dict-based `from_task_packet()` still works (not yet deprecated — Story 7)
- [ ] `mypy sdk/ralph_sdk/agent.py` passes

## Test Plan

```python
from uuid import uuid4
from ralph_sdk.agent import TaskInput
from ralph_sdk.converters import TaskPacketInput, IntentSpecInput


def test_from_task_packet_basic():
    packet = TaskPacketInput(id=uuid4(), repo="org/repo")
    intent = IntentSpecInput(
        goal="Implement the widget",
        constraints=["Must not break API"],
    )
    task = TaskInput.from_task_packet(packet, intent)
    assert "Implement the widget" in task.prompt
    assert "Must not break API" in task.constraints


def test_from_task_packet_keyword_only():
    """loopback_context and expert_outputs must be keyword-only."""
    packet = TaskPacketInput(id=uuid4())
    intent = IntentSpecInput(goal="Fix bug")
    # These must work as keyword arguments
    task = TaskInput.from_task_packet(
        packet, intent,
        loopback_context="Previous attempt failed",
        expert_outputs=["output1"],
    )
    assert isinstance(task, TaskInput)


def test_from_task_packet_defaults():
    packet = TaskPacketInput(id=uuid4())
    intent = IntentSpecInput(goal="Do something")
    task = TaskInput.from_task_packet(packet, intent)
    assert isinstance(task, TaskInput)
    assert task.prompt != ""
```
