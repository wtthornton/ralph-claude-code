# Story RALPH-SDK-EVIDENCE-5: Preserve Full Raw Output in agent_summary

**Epic:** [EvidenceBundle Output](epic-sdk-evidence-bundle.md)
**Priority:** Medium
**Status:** Done
**Effort:** Trivial
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

The `EvidenceBundle.agent_summary` field needs to contain the full raw output from
Claude so that TheStudio (and any other consumer) has access to the complete context
of what the agent did. The extracted `test_results` and `lint_results` are summaries —
`agent_summary` is the authoritative full record.

This is the simplest mapping in the EvidenceBundle pipeline but must be explicitly
implemented and tested to ensure no truncation or transformation occurs.

## Solution

Map `TaskResult.output` (the full Claude response text) directly to
`EvidenceBundle.agent_summary` in the `to_evidence_bundle()` method. No transformation,
no truncation, no filtering.

## Implementation

**File:** `sdk/ralph_sdk/agent.py` — inside `to_evidence_bundle()`

This is already wired in Story 2's implementation:

```python
def to_evidence_bundle(self, ...) -> EvidenceBundle:
    return EvidenceBundle(
        # ...
        agent_summary=self.output,  # Full raw output, no transformation
        # ...
    )
```

### Key Notes

- `self.output` is the complete response text from Claude, including all tool calls,
  explanations, code, test output, and status blocks.
- No truncation is applied — the full output is preserved regardless of size.
- No filtering is applied — even if the output contains RALPH_STATUS blocks or
  stream metadata, those are included in the summary.
- This is intentionally a 1:1 mapping. Downstream consumers can parse the summary
  further if needed.

## Acceptance Criteria

- [ ] `EvidenceBundle.agent_summary` contains the exact value of `TaskResult.output`
- [ ] No truncation applied to the output
- [ ] No filtering or transformation applied
- [ ] Empty output produces empty `agent_summary`
- [ ] Large output (10,000+ characters) preserved in full

## Test Plan

```python
from uuid import uuid4
from ralph_sdk.agent import TaskResult
from ralph_sdk.status import RalphStatus


def test_agent_summary_is_full_output():
    full_output = "Line 1\nLine 2\nLine 3\nRALPH_STATUS: {}\nMore output"
    result = TaskResult(
        status=RalphStatus(),
        exit_code=0,
        output=full_output,
        error="",
        loop_count=1,
        duration_seconds=10.0,
    )
    bundle = result.to_evidence_bundle(taskpacket_id=uuid4(), intent_version=1)
    assert bundle.agent_summary == full_output


def test_agent_summary_empty_output():
    result = TaskResult(
        status=RalphStatus(),
        exit_code=0,
        output="",
        error="",
        loop_count=1,
        duration_seconds=5.0,
    )
    bundle = result.to_evidence_bundle(taskpacket_id=uuid4(), intent_version=1)
    assert bundle.agent_summary == ""


def test_agent_summary_large_output():
    large_output = "x" * 50000
    result = TaskResult(
        status=RalphStatus(),
        exit_code=0,
        output=large_output,
        error="",
        loop_count=1,
        duration_seconds=30.0,
    )
    bundle = result.to_evidence_bundle(taskpacket_id=uuid4(), intent_version=1)
    assert len(bundle.agent_summary) == 50000
    assert bundle.agent_summary == large_output
```
