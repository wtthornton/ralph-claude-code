# Story RALPH-SDK-EVIDENCE-1: Define Ralph-Side EvidenceBundle Model

**Epic:** [EvidenceBundle Output](epic-sdk-evidence-bundle.md)
**Priority:** Critical
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/evidence.py` (new file)

---

## Problem

After Ralph completes a task, TheStudio needs structured evidence of what was done:
which files changed, whether tests passed, what lint issues remain, and a summary of
the agent's actions. Currently `TaskResult.to_signal()` returns a flat dict with raw
output that TheStudio cannot feed into its Verification Gate without manual parsing.

Ralph needs its own `EvidenceBundle` Pydantic model that matches TheStudio's expected
schema while remaining independently owned — Ralph does not import from TheStudio.

## Solution

Create a new `sdk/ralph_sdk/evidence.py` module containing an `EvidenceBundle` Pydantic
model with all fields required by TheStudio's Verification Gate.

## Implementation

**File:** `sdk/ralph_sdk/evidence.py` (new)

```python
from __future__ import annotations

from datetime import UTC, datetime
from uuid import UUID

from pydantic import BaseModel, Field


class EvidenceBundle(BaseModel):
    """Structured evidence of what Ralph did during execution.

    Compatible with TheStudio's EvidenceBundle schema. Ralph owns this
    model — TheStudio can use it directly without transformation.
    """
    taskpacket_id: UUID
    intent_version: int
    files_changed: list[str] = Field(default_factory=list)
    test_results: str = ""
    lint_results: str = ""
    agent_summary: str = ""
    loopback_attempt: int = 0
    created_at: datetime = Field(default_factory=lambda: datetime.now(UTC))
```

### Key Notes

- `taskpacket_id` is a `UUID` to match the TaskPacket's ID type.
- `intent_version` is an `int` for traceability — which version of the IntentSpec was this evidence produced against.
- `files_changed` is a list of file paths (strings) extracted from the agent's output.
- `test_results` and `lint_results` are best-effort text extractions (Stories 3 and 4).
- `agent_summary` holds the full raw output from Claude (Story 5).
- `loopback_attempt` tracks which retry this evidence came from (0 = first attempt).
- `created_at` defaults to UTC now — serializes as ISO 8601.
- No TheStudio imports anywhere in this file.

## Acceptance Criteria

- [ ] `sdk/ralph_sdk/evidence.py` exists with `EvidenceBundle` class
- [ ] `EvidenceBundle` has fields: `taskpacket_id` (UUID), `intent_version` (int), `files_changed` (list[str]), `test_results` (str), `lint_results` (str), `agent_summary` (str), `loopback_attempt` (int), `created_at` (datetime)
- [ ] `files_changed` defaults to empty list
- [ ] `test_results`, `lint_results`, `agent_summary` default to empty string
- [ ] `loopback_attempt` defaults to 0
- [ ] `created_at` defaults to `datetime.now(UTC)`
- [ ] `from ralph_sdk.evidence import EvidenceBundle` imports cleanly
- [ ] Model is a Pydantic `BaseModel` subclass
- [ ] No TheStudio imports — Ralph owns this model
- [ ] `mypy sdk/ralph_sdk/evidence.py` passes cleanly

## Test Plan

```python
from datetime import datetime, UTC
from uuid import uuid4
from pydantic import ValidationError
from ralph_sdk.evidence import EvidenceBundle


def test_minimal_construction():
    """Only required fields are taskpacket_id and intent_version."""
    bundle = EvidenceBundle(taskpacket_id=uuid4(), intent_version=1)
    assert bundle.files_changed == []
    assert bundle.test_results == ""
    assert bundle.lint_results == ""
    assert bundle.agent_summary == ""
    assert bundle.loopback_attempt == 0
    assert isinstance(bundle.created_at, datetime)


def test_full_construction():
    tid = uuid4()
    bundle = EvidenceBundle(
        taskpacket_id=tid,
        intent_version=3,
        files_changed=["src/main.py", "tests/test_main.py"],
        test_results="5 passed, 0 failed",
        lint_results="All checks passed",
        agent_summary="Implemented the feature and added tests.",
        loopback_attempt=1,
    )
    assert bundle.taskpacket_id == tid
    assert bundle.intent_version == 3
    assert len(bundle.files_changed) == 2
    assert bundle.loopback_attempt == 1


def test_created_at_is_utc():
    bundle = EvidenceBundle(taskpacket_id=uuid4(), intent_version=1)
    assert bundle.created_at.tzinfo is not None


def test_missing_required_fields():
    with pytest.raises(ValidationError):
        EvidenceBundle()  # taskpacket_id and intent_version required

    with pytest.raises(ValidationError):
        EvidenceBundle(taskpacket_id=uuid4())  # intent_version required

    with pytest.raises(ValidationError):
        EvidenceBundle(intent_version=1)  # taskpacket_id required
```
