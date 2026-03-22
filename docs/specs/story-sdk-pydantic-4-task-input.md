# Story RALPH-SDK-PYDANTIC-4: Convert TaskInput to Frozen Pydantic BaseModel

**Epic:** [Pydantic v2 Models](epic-sdk-pydantic-models.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

`TaskInput` is a plain `@dataclass` that can be mutated after construction. There is no
validation on the `prompt` field — an empty string or a 100KB prompt are both silently
accepted. Since `TaskInput` represents the input contract for a loop iteration, it should
be immutable after creation to prevent accidental modification during processing.

Additionally, the `max_turns` field (currently in `RalphConfig`) has no range validation.
When `TaskInput` carries task-level overrides in the future, validation constraints need
to be in place.

## Solution

1. Convert `TaskInput` from `@dataclass` to Pydantic `BaseModel` with `ConfigDict(frozen=True)`.
2. Add validation: `prompt` with `min_length=1` and `max_length=50000`.
3. Keep `from_ralph_dir()` and `from_task_packet()` class methods with identical signatures.
4. Handle the frozen constraint carefully — `from_ralph_dir()` constructs the model once, not incrementally.

## Implementation

### BEFORE (`sdk/ralph_sdk/agent.py`, lines 60-111)

```python
@dataclass
class TaskInput:
    """Union type for task input — handles fix_plan.md and TheStudio TaskPackets.

    In standalone mode: reads from fix_plan.md + PROMPT.md
    In TheStudio mode: receives TaskPacket with structured fields
    """
    prompt: str = ""
    fix_plan: str = ""
    agent_instructions: str = ""
    # TheStudio fields (populated when embedded)
    task_packet_id: str = ""
    task_packet_type: str = ""
    task_packet_payload: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_ralph_dir(cls, ralph_dir: str | Path = ".ralph") -> TaskInput:
        """Load task input from .ralph/ directory (standalone mode)."""
        ralph_path = Path(ralph_dir)
        prompt = ""
        fix_plan = ""
        agent_instructions = ""

        prompt_file = ralph_path / "PROMPT.md"
        if prompt_file.exists():
            prompt = prompt_file.read_text(encoding="utf-8")

        fix_plan_file = ralph_path / "fix_plan.md"
        if fix_plan_file.exists():
            fix_plan = fix_plan_file.read_text(encoding="utf-8")

        agent_file = ralph_path / "AGENT.md"
        if agent_file.exists():
            agent_instructions = agent_file.read_text(encoding="utf-8")

        return cls(
            prompt=prompt,
            fix_plan=fix_plan,
            agent_instructions=agent_instructions,
        )

    @classmethod
    def from_task_packet(cls, packet: dict[str, Any]) -> TaskInput:
        """Load task input from TheStudio TaskPacket."""
        return cls(
            prompt=packet.get("prompt", ""),
            fix_plan=packet.get("fix_plan", ""),
            agent_instructions=packet.get("agent_instructions", ""),
            task_packet_id=packet.get("id", ""),
            task_packet_type=packet.get("type", ""),
            task_packet_payload=packet,
        )
```

### AFTER (`sdk/ralph_sdk/agent.py`, TaskInput section)

```python
from pydantic import BaseModel, ConfigDict, Field


class TaskInput(BaseModel):
    """Union type for task input — handles fix_plan.md and TheStudio TaskPackets.

    In standalone mode: reads from fix_plan.md + PROMPT.md
    In TheStudio mode: receives TaskPacket with structured fields

    Frozen after construction — task inputs should not be mutated during processing.
    """
    model_config = ConfigDict(frozen=True)

    prompt: str = Field(default="", min_length=0, max_length=50000)
    fix_plan: str = ""
    agent_instructions: str = ""
    # TheStudio fields (populated when embedded)
    task_packet_id: str = ""
    task_packet_type: str = ""
    task_packet_payload: dict[str, Any] = Field(default_factory=dict)

    @classmethod
    def from_ralph_dir(cls, ralph_dir: str | Path = ".ralph") -> TaskInput:
        """Load task input from .ralph/ directory (standalone mode)."""
        ralph_path = Path(ralph_dir)
        prompt = ""
        fix_plan = ""
        agent_instructions = ""

        prompt_file = ralph_path / "PROMPT.md"
        if prompt_file.exists():
            prompt = prompt_file.read_text(encoding="utf-8")

        fix_plan_file = ralph_path / "fix_plan.md"
        if fix_plan_file.exists():
            fix_plan = fix_plan_file.read_text(encoding="utf-8")

        agent_file = ralph_path / "AGENT.md"
        if agent_file.exists():
            agent_instructions = agent_file.read_text(encoding="utf-8")

        return cls(
            prompt=prompt,
            fix_plan=fix_plan,
            agent_instructions=agent_instructions,
        )

    @classmethod
    def from_task_packet(cls, packet: dict[str, Any]) -> TaskInput:
        """Load task input from TheStudio TaskPacket."""
        return cls(
            prompt=packet.get("prompt", ""),
            fix_plan=packet.get("fix_plan", ""),
            agent_instructions=packet.get("agent_instructions", ""),
            task_packet_id=packet.get("id", ""),
            task_packet_type=packet.get("type", ""),
            task_packet_payload=packet,
        )
```

### Key Changes

- `@dataclass` replaced with `BaseModel` + `ConfigDict(frozen=True)`.
- `field(default_factory=dict)` replaced with `Field(default_factory=dict)`.
- `prompt` uses `Field(min_length=0, max_length=50000)` — note `min_length=0` to allow empty prompts for backward compatibility with `from_ralph_dir()` when PROMPT.md is missing. Callers who require a non-empty prompt should validate at the call site or pass `min_length=1` via a wrapper.
- Frozen model: `task_input.prompt = "new"` raises `ValidationError` after construction.
- Class methods `from_ralph_dir()` and `from_task_packet()` are unchanged — they construct the model in a single `cls(...)` call, which works with frozen models.

### Design Note: Empty Prompt Handling

The default allows `prompt=""` because `from_ralph_dir()` may encounter a missing PROMPT.md
file. The validation constraint `max_length=50000` prevents accidentally loading a massive
file. For TheStudio integration where a non-empty prompt is required, validation can be
enforced at the TaskPacket level or via a `@field_validator` in a subclass.

## Acceptance Criteria

- [ ] `TaskInput` is a Pydantic `BaseModel` with `ConfigDict(frozen=True)`
- [ ] `TaskInput(prompt="x" * 50001)` raises `ValidationError` (max_length exceeded)
- [ ] `TaskInput(prompt="hello")` succeeds
- [ ] `TaskInput()` succeeds (empty prompt allowed for standalone mode)
- [ ] Mutation after construction raises error: `task.prompt = "new"` fails
- [ ] `from_ralph_dir()` loads from `.ralph/` directory correctly
- [ ] `from_task_packet()` loads from TheStudio packet correctly
- [ ] `task_packet_payload` default is an empty dict (not shared mutable reference)
- [ ] Existing code that reads `TaskInput` fields works unchanged
- [ ] `model_json_schema()` returns valid JSON Schema

## Test Plan

```python
import pytest
from pydantic import ValidationError
from ralph_sdk.agent import TaskInput


def test_default_construction():
    """Default TaskInput has empty strings and empty dict."""
    t = TaskInput()
    assert t.prompt == ""
    assert t.fix_plan == ""
    assert t.task_packet_payload == {}


def test_valid_prompt():
    """Normal prompt is accepted."""
    t = TaskInput(prompt="Fix the login bug in auth.py")
    assert t.prompt == "Fix the login bug in auth.py"


def test_prompt_max_length():
    """Prompt exceeding 50000 chars raises ValidationError."""
    with pytest.raises(ValidationError):
        TaskInput(prompt="x" * 50001)


def test_frozen_immutability():
    """Frozen model prevents mutation after construction."""
    t = TaskInput(prompt="original")
    with pytest.raises(ValidationError):
        t.prompt = "modified"


def test_from_ralph_dir(tmp_path):
    """from_ralph_dir() reads PROMPT.md, fix_plan.md, AGENT.md."""
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    (ralph_dir / "PROMPT.md").write_text("Build feature X")
    (ralph_dir / "fix_plan.md").write_text("- [ ] Step 1\n- [ ] Step 2")
    (ralph_dir / "AGENT.md").write_text("Use pytest for testing")

    t = TaskInput.from_ralph_dir(ralph_dir)
    assert t.prompt == "Build feature X"
    assert "Step 1" in t.fix_plan
    assert "pytest" in t.agent_instructions


def test_from_ralph_dir_missing_files(tmp_path):
    """from_ralph_dir() handles missing files gracefully."""
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    t = TaskInput.from_ralph_dir(ralph_dir)
    assert t.prompt == ""
    assert t.fix_plan == ""


def test_from_task_packet():
    """from_task_packet() loads TheStudio packet fields."""
    packet = {
        "prompt": "Fix bug #123",
        "fix_plan": "- [ ] Patch file",
        "agent_instructions": "Run tests after",
        "id": "task-456",
        "type": "bug_fix",
    }
    t = TaskInput.from_task_packet(packet)
    assert t.prompt == "Fix bug #123"
    assert t.task_packet_id == "task-456"
    assert t.task_packet_type == "bug_fix"
    assert t.task_packet_payload == packet


def test_separate_default_dicts():
    """Each instance gets its own default dict (no shared mutable state)."""
    t1 = TaskInput()
    t2 = TaskInput()
    assert t1.task_packet_payload is not t2.task_packet_payload


def test_json_schema():
    """model_json_schema() returns valid schema with constraints."""
    schema = TaskInput.model_json_schema()
    assert "properties" in schema
    assert "prompt" in schema["properties"]
    prompt_schema = schema["properties"]["prompt"]
    assert prompt_schema.get("maxLength") == 50000
```
