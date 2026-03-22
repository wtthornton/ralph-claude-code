# Story RALPH-SDK-TASKPACKET-4: Map Risk Flags, Context Packs, Trust Tier

**Epic:** [TaskPacket Conversion](epic-sdk-taskpacket.md)
**Priority:** High
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/converters.py`, `sdk/ralph_sdk/agent.py`

---

## Problem

TheStudio attaches `risk_flags`, `context_packs`, and `task_trust_tier` to every TaskPacket.
These fields carry critical safety and context information:

- `risk_flags` like `touches_auth` or `touches_payments` should generate explicit safety
  constraints that Claude must follow.
- `context_packs` contain file paths and metadata that should be loaded as context files.
- `task_trust_tier` controls permission levels (`"suggest"`, `"auto"`, etc.).

Currently all three fields are ignored, meaning Claude operates without these guardrails.

## Solution

1. Define a `RISK_FLAG_CONSTRAINTS` dict mapping flag names to constraint strings.
2. When `risk_flags` contains active flags (`True` values), look up the corresponding
   constraint and append it to the constraints list.
3. Resolve `context_packs` to a `context_files` list on `TaskInput`.
4. Store `task_trust_tier` as `permission_mode` on `TaskInput`.

## Implementation

**File:** `sdk/ralph_sdk/converters.py` — add constant

```python
RISK_FLAG_CONSTRAINTS: dict[str, str] = {
    "touches_auth": "MUST NOT modify authentication or authorization code without explicit approval",
    "touches_payments": "MUST NOT modify payment processing code without explicit approval",
    "touches_pii": "MUST NOT expose or log personally identifiable information",
    "cross_service": "Changes may affect multiple services — verify integration points",
}
```

**File:** `sdk/ralph_sdk/agent.py` — inside `from_task_packet()`

```python
from ralph_sdk.converters import RISK_FLAG_CONSTRAINTS

# ... inside from_task_packet() ...

# Map risk flags to constraint strings
if packet.risk_flags:
    for flag, active in packet.risk_flags.items():
        if active and flag in RISK_FLAG_CONSTRAINTS:
            constraints.append(RISK_FLAG_CONSTRAINTS[flag])

# Resolve context packs to file paths
context_files: list[str] = []
if packet.context_packs:
    for pack in packet.context_packs:
        if "path" in pack:
            context_files.append(pack["path"])

# Store trust tier as permission mode hint
permission_mode = packet.task_trust_tier

return cls(
    prompt=prompt,
    constraints=constraints,
    context_files=context_files,
    permission_mode=permission_mode,
    # ... other fields
)
```

### Key Notes

- Only active risk flags (`True`) generate constraints. Inactive flags are ignored.
- Unknown risk flags (not in `RISK_FLAG_CONSTRAINTS`) are silently skipped — forward compatible.
- Context packs are resolved by extracting the `"path"` key from each dict. Packs without a `"path"` key are skipped.
- `task_trust_tier` is stored directly as `permission_mode` — no transformation needed.

## Acceptance Criteria

- [ ] `RISK_FLAG_CONSTRAINTS` dict defined in `converters.py` with 4 entries: `touches_auth`, `touches_payments`, `touches_pii`, `cross_service`
- [ ] Active risk flags (`True`) produce corresponding constraint strings in `TaskInput.constraints`
- [ ] Inactive risk flags (`False`) are ignored
- [ ] Unknown risk flags not in the dict are silently skipped
- [ ] `None` risk_flags produces no additional constraints
- [ ] `context_packs` with `"path"` keys resolved to `context_files` list
- [ ] Context packs without `"path"` key are skipped without error
- [ ] `None` context_packs produces empty `context_files`
- [ ] `task_trust_tier` mapped to `permission_mode` on TaskInput
- [ ] Default trust tier `"suggest"` produces `permission_mode="suggest"`

## Test Plan

```python
from uuid import uuid4
from ralph_sdk.agent import TaskInput
from ralph_sdk.converters import TaskPacketInput, IntentSpecInput, RISK_FLAG_CONSTRAINTS


def test_active_risk_flags():
    packet = TaskPacketInput(
        id=uuid4(),
        risk_flags={"touches_auth": True, "touches_payments": True},
    )
    intent = IntentSpecInput(goal="Update user service")
    task = TaskInput.from_task_packet(packet, intent)
    assert RISK_FLAG_CONSTRAINTS["touches_auth"] in task.constraints
    assert RISK_FLAG_CONSTRAINTS["touches_payments"] in task.constraints


def test_inactive_risk_flags():
    packet = TaskPacketInput(
        id=uuid4(),
        risk_flags={"touches_auth": False},
    )
    intent = IntentSpecInput(goal="Update user service")
    task = TaskInput.from_task_packet(packet, intent)
    assert RISK_FLAG_CONSTRAINTS["touches_auth"] not in task.constraints


def test_unknown_risk_flag_skipped():
    packet = TaskPacketInput(
        id=uuid4(),
        risk_flags={"unknown_flag": True},
    )
    intent = IntentSpecInput(goal="Fix bug")
    task = TaskInput.from_task_packet(packet, intent)
    # No error raised, unknown flag silently skipped
    assert len([c for c in task.constraints if "unknown" in c.lower()]) == 0


def test_context_packs_to_files():
    packet = TaskPacketInput(
        id=uuid4(),
        context_packs=[
            {"path": "src/main.py", "reason": "entry point"},
            {"path": "tests/test_main.py", "reason": "test file"},
        ],
    )
    intent = IntentSpecInput(goal="Fix bug")
    task = TaskInput.from_task_packet(packet, intent)
    assert "src/main.py" in task.context_files
    assert "tests/test_main.py" in task.context_files


def test_context_packs_missing_path():
    packet = TaskPacketInput(
        id=uuid4(),
        context_packs=[{"reason": "no path here"}],
    )
    intent = IntentSpecInput(goal="Fix bug")
    task = TaskInput.from_task_packet(packet, intent)
    assert task.context_files == []


def test_trust_tier_to_permission_mode():
    packet = TaskPacketInput(id=uuid4(), task_trust_tier="auto")
    intent = IntentSpecInput(goal="Deploy")
    task = TaskInput.from_task_packet(packet, intent)
    assert task.permission_mode == "auto"
```
