# Story RALPH-SDK-V2-1: Write End-to-End Integration Test

**Epic:** [Release, Integration Testing & v2.0.0](epic-sdk-v2-release.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Medium
**Component:** `sdk/tests/integration/test_e2e_pipeline.py` (new file)

---

## Problem

Epics 1-8 implement the individual pieces of the v2.0.0 SDK: Pydantic models, async API,
state backend, correlation IDs, circuit breaker, structured parsing, TaskPacket conversion,
and EvidenceBundle output. But no test verifies that these pieces work together as a
complete pipeline: `TaskPacketInput` -> `TaskInput` -> `RalphAgent.run_iteration()` ->
`TaskResult` -> `EvidenceBundle`.

Without an integration test, subtle mismatches between components (wrong field names,
incompatible types, missing imports) would only surface in production when TheStudio
first calls the SDK.

## Solution

Write an end-to-end integration test that exercises the full pipeline using
`NullStateBackend` (no filesystem). The test:

1. Creates a `RalphAgent` with `NullStateBackend` and a `correlation_id`.
2. Builds a `TaskInput` from mock `TaskPacketInput` + `IntentSpecInput`.
3. Calls `run_iteration()` (may need dry-run mode to avoid actual Claude API calls).
4. Converts the result to an `EvidenceBundle`.
5. Verifies all fields are populated and correctly typed.

## Implementation

**File:** `sdk/tests/integration/test_e2e_pipeline.py` (new)

```python
import pytest
from uuid import uuid4

from ralph_sdk.agent import RalphAgent, TaskInput, TaskResult
from ralph_sdk.config import RalphConfig
from ralph_sdk.converters import TaskPacketInput, IntentSpecInput
from ralph_sdk.evidence import EvidenceBundle
from ralph_sdk.state import NullStateBackend


def mock_taskpacket() -> TaskPacketInput:
    return TaskPacketInput(
        id=uuid4(),
        repo="test-org/test-repo",
        complexity_index={"score": 0.5, "band": "medium"},
        risk_flags={"touches_auth": True, "touches_pii": False},
        context_packs=[{"path": "src/main.py", "reason": "entry point"}],
        task_trust_tier="suggest",
        loopback_count=0,
    )


def mock_intent_spec() -> IntentSpecInput:
    return IntentSpecInput(
        goal="Implement user authentication endpoint",
        constraints=["Must use existing auth library", "No new dependencies"],
        acceptance_criteria=["Tests pass", "Lint clean", "Auth flow works"],
        non_goals=["UI changes", "Database migration"],
        version=1,
    )


@pytest.mark.asyncio
async def test_full_pipeline():
    """End-to-end: TaskPacket -> Ralph -> EvidenceBundle.

    Uses NullStateBackend (no file system). Verifies the full conversion
    pipeline works without TheStudio running.
    """
    # 1. Create agent with null backend
    agent = RalphAgent(
        config=RalphConfig.load(),
        correlation_id=uuid4(),
        state_backend=NullStateBackend(),
    )

    # 2. Convert TaskPacket -> TaskInput
    packet = mock_taskpacket()
    intent = mock_intent_spec()
    task_input = TaskInput.from_task_packet(packet, intent)

    # Verify TaskInput is properly populated
    assert "Implement user authentication endpoint" in task_input.prompt
    assert "## Acceptance Criteria" in task_input.prompt
    assert "Must use existing auth library" in task_input.constraints
    assert "DO NOT: UI changes" in task_input.constraints
    assert task_input.max_turns == 30  # medium complexity

    # 3. Run iteration (dry-run to avoid Claude API)
    result = await agent.run_iteration(task_input, dry_run=True)
    assert isinstance(result, TaskResult)

    # 4. Convert result -> EvidenceBundle
    evidence = result.to_evidence_bundle(
        taskpacket_id=packet.id,
        intent_version=intent.version,
    )

    # 5. Verify EvidenceBundle
    assert isinstance(evidence, EvidenceBundle)
    assert evidence.taskpacket_id == packet.id
    assert evidence.intent_version == 1
    assert isinstance(evidence.files_changed, list)
    assert isinstance(evidence.agent_summary, str)
    assert evidence.loopback_attempt == 0

    # Verify JSON round-trip
    json_str = evidence.model_dump_json()
    restored = EvidenceBundle.model_validate_json(json_str)
    assert restored.taskpacket_id == evidence.taskpacket_id
```

### Key Notes

- `NullStateBackend` avoids all filesystem side effects.
- `dry_run=True` (if supported) avoids actual Claude API calls.
- The test verifies type correctness and field population, not Claude's response quality.
- Mock data covers all TaskPacket/IntentSpec fields to exercise all mapping paths.

## Acceptance Criteria

- [ ] Integration test file exists at `sdk/tests/integration/test_e2e_pipeline.py`
- [ ] Test creates `RalphAgent` with `NullStateBackend` and `correlation_id`
- [ ] Test builds `TaskInput` from `TaskPacketInput` + `IntentSpecInput`
- [ ] Test verifies all TaskInput fields populated correctly (prompt, constraints, max_turns)
- [ ] Test calls `run_iteration()` without hitting Claude API
- [ ] Test converts `TaskResult` to `EvidenceBundle`
- [ ] Test verifies EvidenceBundle fields (taskpacket_id, intent_version, files_changed, agent_summary)
- [ ] Test verifies JSON round-trip on the EvidenceBundle
- [ ] Test passes with `pytest sdk/tests/integration/`

## Test Plan

```bash
# Run the integration test
cd sdk && pytest tests/integration/test_e2e_pipeline.py -v

# Verify no filesystem side effects
ls /tmp/ralph-test-* 2>/dev/null  # should find nothing
```
