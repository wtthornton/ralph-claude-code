# Story RALPH-SDK-TASKPACKET-6: Include Loopback Context for Retry Attempts

**Epic:** [TaskPacket Conversion](epic-sdk-taskpacket.md)
**Priority:** High
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

When TheStudio retries a failed task, it sends a `loopback_context` string containing
error details, failed test output, or reviewer feedback from the previous attempt. Without
incorporating this context into the prompt, Ralph will repeat the same mistakes and enter
an infinite retry loop.

## Solution

When `loopback_context` is non-empty, prepend it to the prompt with a structured header
that directs Claude to fix the previous issues while maintaining the original goal:

```
## Previous Attempt Failed

{loopback_context}

Fix the issues above while maintaining the original goal.
```

The original goal and acceptance criteria follow after this section.

## Implementation

**File:** `sdk/ralph_sdk/agent.py` — inside `from_task_packet()`

```python
# ... inside from_task_packet(), after building prompt from intent ...

# Prepend loopback context for retry attempts
if loopback_context:
    prompt = (
        f"## Previous Attempt Failed\n\n"
        f"{loopback_context}\n\n"
        f"Fix the issues above while maintaining the original goal.\n\n"
        f"{prompt}"
    )
```

### Key Notes

- The loopback context is **prepended**, not appended — Claude sees the failure context
  first, then the original goal. This ensures the failure details are in Claude's immediate
  attention window.
- Empty string `loopback_context` (the default) results in no modification to the prompt.
- The `## Previous Attempt Failed` header makes the section clearly identifiable in logs
  and debugging.
- The directive "Fix the issues above while maintaining the original goal" prevents Claude
  from abandoning the original task intent.

## Acceptance Criteria

- [ ] Non-empty `loopback_context` is prepended to prompt with `## Previous Attempt Failed` header
- [ ] Loopback section includes the directive "Fix the issues above while maintaining the original goal."
- [ ] Original prompt (goal + acceptance criteria) follows after the loopback section
- [ ] Empty `loopback_context` (default) results in unmodified prompt
- [ ] Whitespace-only `loopback_context` is treated as non-empty (prepended as-is)

## Test Plan

```python
from uuid import uuid4
from ralph_sdk.agent import TaskInput
from ralph_sdk.converters import TaskPacketInput, IntentSpecInput


def test_loopback_context_prepended():
    packet = TaskPacketInput(id=uuid4())
    intent = IntentSpecInput(goal="Implement feature X")
    task = TaskInput.from_task_packet(
        packet, intent,
        loopback_context="Tests failed: test_widget expected 42, got 0",
    )
    # Loopback section comes first
    assert task.prompt.startswith("## Previous Attempt Failed")
    assert "Tests failed: test_widget expected 42, got 0" in task.prompt
    assert "Fix the issues above while maintaining the original goal." in task.prompt
    # Original goal still present
    assert "Implement feature X" in task.prompt


def test_loopback_before_original_goal():
    packet = TaskPacketInput(id=uuid4())
    intent = IntentSpecInput(goal="Implement feature X")
    task = TaskInput.from_task_packet(
        packet, intent,
        loopback_context="Lint errors found",
    )
    loopback_pos = task.prompt.index("Previous Attempt Failed")
    goal_pos = task.prompt.index("Implement feature X")
    assert loopback_pos < goal_pos


def test_empty_loopback_no_modification():
    packet = TaskPacketInput(id=uuid4())
    intent = IntentSpecInput(goal="Fix the bug")
    task = TaskInput.from_task_packet(packet, intent, loopback_context="")
    assert "Previous Attempt Failed" not in task.prompt
    assert task.prompt.startswith("Fix the bug")


def test_default_loopback_no_modification():
    packet = TaskPacketInput(id=uuid4())
    intent = IntentSpecInput(goal="Fix the bug")
    task = TaskInput.from_task_packet(packet, intent)
    assert "Previous Attempt Failed" not in task.prompt


def test_loopback_with_acceptance_criteria():
    packet = TaskPacketInput(id=uuid4())
    intent = IntentSpecInput(
        goal="Build widget",
        acceptance_criteria=["Tests pass"],
    )
    task = TaskInput.from_task_packet(
        packet, intent,
        loopback_context="Widget crashes on None input",
    )
    assert "Previous Attempt Failed" in task.prompt
    assert "Widget crashes on None input" in task.prompt
    assert "## Acceptance Criteria" in task.prompt
    assert "Build widget" in task.prompt
```
