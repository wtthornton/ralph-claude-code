# Story RALPH-SDK-TASKPACKET-3: Map IntentSpec Fields

**Epic:** [TaskPacket Conversion](epic-sdk-taskpacket.md)
**Priority:** Critical
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

`IntentSpecInput` carries four distinct fields — `goal`, `constraints`, `acceptance_criteria`,
and `non_goals` — but the current conversion only maps `goal` to `prompt` and `constraints`
to `constraints` (Story 2 baseline). The `acceptance_criteria` and `non_goals` fields are
completely lost, meaning TheStudio's detailed requirements and explicit exclusions never
reach the Claude prompt.

## Solution

Map all four `IntentSpec` fields into the `TaskInput`:

1. `intent.goal` → `prompt` (already done in Story 2).
2. `intent.constraints` → `constraints` list (already done in Story 2).
3. `intent.acceptance_criteria` → appended to `prompt` as an "Acceptance Criteria" section.
4. `intent.non_goals` → appended to `constraints` as exclusion directives (`"DO NOT: ..."`).

## Implementation

**File:** `sdk/ralph_sdk/agent.py` — inside `from_task_packet()`

```python
@classmethod
def from_task_packet(
    cls,
    packet: TaskPacketInput,
    intent: IntentSpecInput,
    *,
    loopback_context: str = "",
    expert_outputs: list[str] | None = None,
) -> "TaskInput":
    # Base prompt from goal
    prompt = intent.goal

    # Append acceptance criteria as a structured section
    if intent.acceptance_criteria:
        criteria_lines = "\n".join(f"- {c}" for c in intent.acceptance_criteria)
        prompt += f"\n\n## Acceptance Criteria\n\n{criteria_lines}"

    # Build constraints list
    constraints = list(intent.constraints)

    # Non-goals become explicit exclusion constraints
    for ng in intent.non_goals:
        constraints.append(f"DO NOT: {ng}")

    return cls(
        prompt=prompt,
        constraints=constraints,
        # ... other mappings from Stories 4-6
    )
```

### Key Notes

- Acceptance criteria are formatted as a Markdown list under a `## Acceptance Criteria` heading, making them clearly visible in the Claude prompt.
- Non-goals are prefixed with `"DO NOT: "` to create strong exclusion constraints that Claude will respect.
- The ordering is deliberate: goal first, then criteria section — this matches how Claude processes instructions (important context first).

## Acceptance Criteria

- [ ] `intent.goal` maps to the beginning of `prompt`
- [ ] `intent.acceptance_criteria` appended to `prompt` as `## Acceptance Criteria` section with bullet points
- [ ] Empty `acceptance_criteria` list results in no criteria section appended
- [ ] `intent.non_goals` converted to `"DO NOT: {non_goal}"` constraint strings
- [ ] Non-goal constraints appended after regular constraints
- [ ] Empty `non_goals` list adds no extra constraints
- [ ] All four IntentSpec fields are represented in the output TaskInput

## Test Plan

```python
from uuid import uuid4
from ralph_sdk.agent import TaskInput
from ralph_sdk.converters import TaskPacketInput, IntentSpecInput


def test_acceptance_criteria_in_prompt():
    packet = TaskPacketInput(id=uuid4())
    intent = IntentSpecInput(
        goal="Implement login",
        acceptance_criteria=["Tests pass", "No security warnings"],
    )
    task = TaskInput.from_task_packet(packet, intent)
    assert "## Acceptance Criteria" in task.prompt
    assert "- Tests pass" in task.prompt
    assert "- No security warnings" in task.prompt


def test_empty_acceptance_criteria():
    packet = TaskPacketInput(id=uuid4())
    intent = IntentSpecInput(goal="Simple fix")
    task = TaskInput.from_task_packet(packet, intent)
    assert "## Acceptance Criteria" not in task.prompt


def test_non_goals_as_constraints():
    packet = TaskPacketInput(id=uuid4())
    intent = IntentSpecInput(
        goal="Refactor module",
        non_goals=["Performance optimization", "UI changes"],
    )
    task = TaskInput.from_task_packet(packet, intent)
    assert "DO NOT: Performance optimization" in task.constraints
    assert "DO NOT: UI changes" in task.constraints


def test_empty_non_goals():
    packet = TaskPacketInput(id=uuid4())
    intent = IntentSpecInput(goal="Fix bug", constraints=["Keep API stable"])
    task = TaskInput.from_task_packet(packet, intent)
    assert len(task.constraints) == 1
    assert task.constraints[0] == "Keep API stable"


def test_all_intent_fields_together():
    packet = TaskPacketInput(id=uuid4())
    intent = IntentSpecInput(
        goal="Build feature X",
        constraints=["Must not break API"],
        acceptance_criteria=["Unit tests pass"],
        non_goals=["Mobile support"],
    )
    task = TaskInput.from_task_packet(packet, intent)
    assert "Build feature X" in task.prompt
    assert "## Acceptance Criteria" in task.prompt
    assert "- Unit tests pass" in task.prompt
    assert "Must not break API" in task.constraints
    assert "DO NOT: Mobile support" in task.constraints
```
