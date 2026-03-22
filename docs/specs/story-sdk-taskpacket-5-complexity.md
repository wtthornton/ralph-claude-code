# Story RALPH-SDK-TASKPACKET-5: Scale max_turns by Complexity Band

**Epic:** [TaskPacket Conversion](epic-sdk-taskpacket.md)
**Priority:** High
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`, `sdk/ralph_sdk/converters.py`

---

## Problem

Ralph currently uses a fixed `max_turns` value regardless of task complexity. TheStudio's
`TaskPacket` includes a `complexity_index` dict with a `"band"` field (`"low"`, `"medium"`,
`"high"`) that indicates how much work the task requires. Without complexity-based scaling,
simple tasks waste budget on unnecessary turns and complex tasks may be cut short.

## Solution

Define a `COMPLEXITY_MAX_TURNS` mapping and read the complexity band from
`packet.complexity_index["band"]` to set `max_turns` on the resulting `TaskInput`:

| Complexity Band | max_turns |
|-----------------|-----------|
| low             | 20        |
| medium          | 30        |
| high            | 50        |
| (missing/unknown) | 30 (default) |

## Implementation

**File:** `sdk/ralph_sdk/converters.py` — add constant

```python
COMPLEXITY_MAX_TURNS: dict[str, int] = {
    "low": 20,
    "medium": 30,
    "high": 50,
}

DEFAULT_MAX_TURNS: int = 30
```

**File:** `sdk/ralph_sdk/agent.py` — inside `from_task_packet()`

```python
from ralph_sdk.converters import COMPLEXITY_MAX_TURNS, DEFAULT_MAX_TURNS

# ... inside from_task_packet() ...

# Scale max_turns by complexity band
max_turns = DEFAULT_MAX_TURNS
if packet.complexity_index and "band" in packet.complexity_index:
    band = packet.complexity_index["band"]
    max_turns = COMPLEXITY_MAX_TURNS.get(band, DEFAULT_MAX_TURNS)

return cls(
    prompt=prompt,
    constraints=constraints,
    max_turns=max_turns,
    # ... other fields
)
```

### Key Notes

- Missing `complexity_index` (None) defaults to 30 turns.
- Missing `"band"` key in the dict defaults to 30 turns.
- Unknown band values (e.g., `"extreme"`) default to 30 turns.
- The mapping is a simple dict lookup — no complex logic.

## Acceptance Criteria

- [ ] `COMPLEXITY_MAX_TURNS` dict defined with `low=20`, `medium=30`, `high=50`
- [ ] `DEFAULT_MAX_TURNS` constant set to `30`
- [ ] `complexity_index={"band": "low"}` produces `max_turns=20`
- [ ] `complexity_index={"band": "medium"}` produces `max_turns=30`
- [ ] `complexity_index={"band": "high"}` produces `max_turns=50`
- [ ] `complexity_index=None` produces `max_turns=30`
- [ ] `complexity_index={}` (no "band" key) produces `max_turns=30`
- [ ] `complexity_index={"band": "unknown_value"}` produces `max_turns=30`

## Test Plan

```python
from uuid import uuid4
from ralph_sdk.agent import TaskInput
from ralph_sdk.converters import TaskPacketInput, IntentSpecInput


def test_low_complexity():
    packet = TaskPacketInput(
        id=uuid4(),
        complexity_index={"score": 0.2, "band": "low"},
    )
    intent = IntentSpecInput(goal="Fix typo")
    task = TaskInput.from_task_packet(packet, intent)
    assert task.max_turns == 20


def test_medium_complexity():
    packet = TaskPacketInput(
        id=uuid4(),
        complexity_index={"score": 0.5, "band": "medium"},
    )
    intent = IntentSpecInput(goal="Refactor module")
    task = TaskInput.from_task_packet(packet, intent)
    assert task.max_turns == 30


def test_high_complexity():
    packet = TaskPacketInput(
        id=uuid4(),
        complexity_index={"score": 0.9, "band": "high"},
    )
    intent = IntentSpecInput(goal="Rewrite subsystem")
    task = TaskInput.from_task_packet(packet, intent)
    assert task.max_turns == 50


def test_missing_complexity_index():
    packet = TaskPacketInput(id=uuid4())  # complexity_index defaults to None
    intent = IntentSpecInput(goal="Do something")
    task = TaskInput.from_task_packet(packet, intent)
    assert task.max_turns == 30


def test_missing_band_key():
    packet = TaskPacketInput(
        id=uuid4(),
        complexity_index={"score": 0.5},  # no "band" key
    )
    intent = IntentSpecInput(goal="Do something")
    task = TaskInput.from_task_packet(packet, intent)
    assert task.max_turns == 30


def test_unknown_band_value():
    packet = TaskPacketInput(
        id=uuid4(),
        complexity_index={"band": "extreme"},
    )
    intent = IntentSpecInput(goal="Do something")
    task = TaskInput.from_task_packet(packet, intent)
    assert task.max_turns == 30
```
