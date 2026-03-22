# Story RALPH-SDK-EVIDENCE-2: Implement TaskResult.to_evidence_bundle()

**Epic:** [EvidenceBundle Output](epic-sdk-evidence-bundle.md)
**Priority:** Critical
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

`TaskResult` currently only has `to_signal()` which returns a flat dict. TheStudio's
Verification Gate needs an `EvidenceBundle` with structured fields. There is no method
to convert a `TaskResult` into the evidence format. The caller (TheStudio) would have
to manually extract `files_changed`, parse test/lint output, and assemble the bundle —
duplicating logic that belongs in the SDK.

## Solution

Add a `to_evidence_bundle()` method to `TaskResult` that accepts the external IDs
(`taskpacket_id`, `intent_version`, `loopback_attempt`) and maps internal fields to
an `EvidenceBundle`. The method calls extraction helpers for test and lint results
(implemented in Stories 3 and 4).

## Implementation

**File:** `sdk/ralph_sdk/agent.py`

```python
from uuid import UUID
from ralph_sdk.evidence import EvidenceBundle


class TaskResult(BaseModel):
    # ... existing fields and to_signal() ...

    def to_evidence_bundle(
        self,
        taskpacket_id: UUID,
        intent_version: int,
        loopback_attempt: int = 0,
    ) -> EvidenceBundle:
        """Convert this result into a structured EvidenceBundle.

        Args:
            taskpacket_id: ID of the TaskPacket that produced this result.
            intent_version: Version of the IntentSpec used.
            loopback_attempt: Which retry attempt this is (0 = first).

        Returns:
            EvidenceBundle with extracted test/lint results and file changes.
        """
        from ralph_sdk.evidence import extract_test_results, extract_lint_results

        return EvidenceBundle(
            taskpacket_id=taskpacket_id,
            intent_version=intent_version,
            files_changed=self._extract_files_changed(),
            test_results=extract_test_results(self.output),
            lint_results=extract_lint_results(self.output),
            agent_summary=self.output,
            loopback_attempt=loopback_attempt,
        )

    def _extract_files_changed(self) -> list[str]:
        """Extract list of changed files from status or output.

        Reads from self.status.files_modified_list if available,
        otherwise returns an empty list.
        """
        if hasattr(self.status, "files_modified_list"):
            return list(self.status.files_modified_list)
        return []
```

### Key Notes

- `taskpacket_id`, `intent_version`, and `loopback_attempt` come from the caller because `TaskResult` does not know its own task packet context.
- `files_changed` is extracted from `self.status` which already tracks modified files.
- `test_results` and `lint_results` delegate to extraction helpers (Stories 3 and 4). Initially these return empty strings until those stories are implemented.
- `agent_summary` is the full `self.output` (Story 5).
- `to_signal()` remains unchanged — both methods coexist.

## Acceptance Criteria

- [ ] `TaskResult.to_evidence_bundle()` exists and returns an `EvidenceBundle`
- [ ] Method accepts `taskpacket_id` (UUID), `intent_version` (int), `loopback_attempt` (int, default=0)
- [ ] `files_changed` populated from status when available
- [ ] `test_results` populated via `extract_test_results()` helper
- [ ] `lint_results` populated via `extract_lint_results()` helper
- [ ] `agent_summary` contains the full `self.output`
- [ ] `loopback_attempt` passed through to the bundle
- [ ] `to_signal()` still works unchanged (backward compatible)
- [ ] Method has docstring documenting parameters and return type

## Test Plan

```python
from uuid import uuid4
from ralph_sdk.agent import TaskResult
from ralph_sdk.evidence import EvidenceBundle
from ralph_sdk.status import RalphStatus


def test_to_evidence_bundle_basic():
    result = TaskResult(
        status=RalphStatus(),
        exit_code=0,
        output="Implemented feature X. All tests pass.",
        error="",
        loop_count=3,
        duration_seconds=45.0,
    )
    tid = uuid4()
    bundle = result.to_evidence_bundle(taskpacket_id=tid, intent_version=1)
    assert isinstance(bundle, EvidenceBundle)
    assert bundle.taskpacket_id == tid
    assert bundle.intent_version == 1
    assert bundle.loopback_attempt == 0
    assert bundle.agent_summary == "Implemented feature X. All tests pass."


def test_to_evidence_bundle_with_loopback():
    result = TaskResult(
        status=RalphStatus(),
        exit_code=0,
        output="Fixed the issue from previous attempt.",
        error="",
        loop_count=5,
        duration_seconds=60.0,
    )
    bundle = result.to_evidence_bundle(
        taskpacket_id=uuid4(),
        intent_version=2,
        loopback_attempt=3,
    )
    assert bundle.loopback_attempt == 3
    assert bundle.intent_version == 2


def test_to_signal_still_works():
    """Backward compatibility: to_signal() is unchanged."""
    result = TaskResult(
        status=RalphStatus(),
        exit_code=0,
        output="Done",
        error="",
        loop_count=1,
        duration_seconds=10.0,
    )
    signal = result.to_signal()
    assert signal["type"] == "ralph_result"
    assert signal["exit_code"] == 0
```
