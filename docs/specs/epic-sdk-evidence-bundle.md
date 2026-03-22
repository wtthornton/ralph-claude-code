# Epic: EvidenceBundle Output (BLOCKING-4)

**Epic ID:** RALPH-SDK-EVIDENCE
**Priority:** Critical (Blocking)
**Phase:** 3 — Integration (v2.0.0)
**Affects:** Ralph → TheStudio output pipeline, verification gate input
**Components:** `sdk/ralph_sdk/agent.py`, new `sdk/ralph_sdk/evidence.py`
**Related specs:** [RFC-001 §4 BLOCKING-4](../../TheStudio/docs/architecture/RFC-001-ralph-sdk-integration.md), `epic-sdk-pydantic-models.md`, `epic-sdk-taskpacket.md`
**Depends on:** Epic 1 (Pydantic Models), Epic 7 (TaskPacket Conversion)
**Target Version:** v2.0.0
**Status:** Done

---

## Problem Statement

`TaskResult.to_signal()` (agent.py:124-134) returns a flat dict with 6 keys:

```python
def to_signal(self) -> dict:
    return {
        "type": "ralph_result",
        "task_result": self.status.to_dict(),
        "exit_code": self.exit_code,
        "output": self.output,
        "error": self.error,
        "loop_count": self.loop_count,
        "duration_seconds": self.duration_seconds,
    }
```

TheStudio requires `EvidenceBundle` — a structured model with `files_changed`,
`test_results`, `lint_results`, `agent_summary`, `loopback_attempt`, and IDs for
traceability. The current signal output cannot feed TheStudio's Verification Gate.

### Key Design Principle: Ralph Owns Its Model

Ralph defines its own `EvidenceBundle` Pydantic model that matches TheStudio's schema.
TheStudio does not need to transform the output — the shapes are compatible. But Ralph
does not import from TheStudio.

### Standalone Ralph Benefit

Even without TheStudio, `to_evidence_bundle()` provides structured output:
- Explicit `files_changed` list (extracted from agent output)
- Separated `test_results` and `lint_results` (currently mixed in raw output)
- Useful for CI integrations that want structured results from `ralph --sdk`

`to_signal()` is **not removed** — it continues to work for backward compatibility.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-SDK-EVIDENCE-1](story-sdk-evidence-1-model.md) | Define Ralph-side EvidenceBundle model | Critical | Small | Done |
| [RALPH-SDK-EVIDENCE-2](story-sdk-evidence-2-method.md) | Implement TaskResult.to_evidence_bundle() | Critical | Small | Done |
| [RALPH-SDK-EVIDENCE-3](story-sdk-evidence-3-tests.md) | Extract test results from raw output | High | Medium | Done |
| [RALPH-SDK-EVIDENCE-4](story-sdk-evidence-4-lint.md) | Extract lint results from raw output | High | Small | Done |
| [RALPH-SDK-EVIDENCE-5](story-sdk-evidence-5-summary.md) | Preserve full raw output in agent_summary | Medium | Trivial | Done |
| [RALPH-SDK-EVIDENCE-6](story-sdk-evidence-6-roundtrip.md) | JSON round-trip verification | High | Small | Done |

## Implementation Order

1. **EVIDENCE-1** — Model definition.
2. **EVIDENCE-2** — Method implementation.
3. **EVIDENCE-5** — Raw output preservation (simplest mapping).
4. **EVIDENCE-3** — Test result extraction (needs pattern matching).
5. **EVIDENCE-4** — Lint result extraction.
6. **EVIDENCE-6** — Round-trip serialization test.

## Design Decisions

### Ralph's EvidenceBundle Model

```python
# In sdk/ralph_sdk/evidence.py — Ralph's own model

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

### Extraction Patterns

**Test results** — look for common patterns in raw output:
- `pytest` output blocks (lines starting with `PASSED`, `FAILED`, `ERROR`)
- `npm test` / `jest` output blocks
- Test summary lines ("X passed, Y failed")

**Lint results** — look for:
- `ruff` output blocks
- `eslint` output blocks
- Lint summary lines ("X errors, Y warnings")

Extraction is best-effort. If patterns don't match, `test_results` and `lint_results`
remain empty strings. The full output is always available in `agent_summary`.

### to_signal() Preserved

```python
class TaskResult(BaseModel):
    def to_signal(self) -> dict[str, Any]:
        """Legacy signal format — backward compatible."""
        ...  # unchanged

    def to_evidence_bundle(
        self,
        taskpacket_id: UUID,
        intent_version: int,
        loopback_attempt: int = 0,
    ) -> EvidenceBundle:
        """Structured evidence format — for TheStudio and CI integrations."""
        ...
```

Both methods coexist. `to_signal()` for standalone, `to_evidence_bundle()` for embedding.

## Acceptance Criteria (Epic-level)

- [ ] `EvidenceBundle` Pydantic model defined in Ralph SDK
- [ ] `to_evidence_bundle()` returns valid `EvidenceBundle` with all required fields
- [ ] Test results extracted from raw output when work_type=TESTING
- [ ] Lint results extracted from raw output when present
- [ ] Full raw output preserved in `agent_summary`
- [ ] `taskpacket_id`, `intent_version`, `loopback_attempt` populated from caller
- [ ] JSON round-trip: `model_dump_json()` → `model_validate_json()` works
- [ ] `to_signal()` still works unchanged (backward compatible)
- [ ] `ralph --sdk` unaffected (never calls `to_evidence_bundle()`)

## Out of Scope

- TheStudio EvidenceBundle import (shapes are compatible, TheStudio uses Ralph's model directly or maps trivially)
- Verification Gate integration (TheStudio responsibility)
- Structured test result parsing beyond pattern matching (future work)
