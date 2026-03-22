# Story RALPH-SDK-V2-6: Update CLAUDE.md with New SDK Architecture Patterns

**Epic:** [Release, Integration Testing & v2.0.0](epic-sdk-v2-release.md)
**Priority:** High
**Status:** Done
**Effort:** Small
**Component:** `CLAUDE.md`

---

## Problem

`CLAUDE.md` is the primary reference document for anyone working in the Ralph codebase,
including Claude itself. The current SDK section documents only the v1.x architecture:
four modules (`agent.py`, `config.py`, `tools.py`, `status.py`) with no mention of
the state backend protocol, async/sync duality, correlation ID threading, Pydantic
models, converter models, evidence bundle, or the active circuit breaker class.

Claude agents working on the codebase will make incorrect assumptions about the SDK
structure if CLAUDE.md is not updated.

## Solution

Update the SDK section of CLAUDE.md to document the v2.0.0 architecture:

1. Add new modules to the SDK table (`state.py`, `converters.py`, `evidence.py`).
2. Document the state backend protocol pattern.
3. Document async/sync duality (`run_iteration()` / `run_iteration_sync()`).
4. Document correlation ID threading.
5. Document Pydantic model usage and the "own models" design principle.
6. Document the circuit breaker active class.

## Implementation

**File:** `CLAUDE.md` — update the SDK section

### Updated SDK Module Table

```markdown
### SDK (sdk/)

Python Agent SDK for dual-mode operation (Phase 6, upgraded v2.0.0):

| Module | Purpose |
|--------|---------|
| `ralph_sdk/agent.py` | Core agent class — RalphAgent, TaskInput, TaskResult, async run_iteration() |
| `ralph_sdk/config.py` | Configuration loader — .ralphrc, ralph.config.json, environment, with full precedence chain |
| `ralph_sdk/tools.py` | Custom tools — ralph_status, ralph_rate_check, ralph_circuit_state, ralph_task_update |
| `ralph_sdk/status.py` | Status management — RalphStatus, RalphStatusBlock (Pydantic), CircuitBreakerState, enums |
| `ralph_sdk/state.py` | State backend protocol — RalphStateBackend, FileStateBackend, NullStateBackend |
| `ralph_sdk/converters.py` | TaskPacket conversion — TaskPacketInput, IntentSpecInput, RISK_FLAG_CONSTRAINTS |
| `ralph_sdk/evidence.py` | Evidence output — EvidenceBundle, extract_test_results(), extract_lint_results() |
| `ralph_sdk/__main__.py` | CLI entry point — `ralph --sdk` or `python -m ralph_sdk` |
```

### New SDK Design Patterns Section

```markdown
**State backend protocol**: `RalphStateBackend` (typing.Protocol) defines 12 async methods
for status, circuit breaker, rate limiting, session, and metrics persistence. Three
implementations: `FileStateBackend` (default, filesystem), `NullStateBackend` (testing,
no-op), and external backends (e.g., PostgresStateBackend for TheStudio). Backends are
structurally typed — no inheritance required.

**Async/sync duality**: `run_iteration()` is async by default. `run_iteration_sync()`
provides a synchronous wrapper via `asyncio.run()` for callers that cannot use async.

**Correlation ID threading**: `RalphAgent(correlation_id=uuid)` threads a UUID through
all state operations, log entries, and the EvidenceBundle for end-to-end traceability.

**Pydantic models (own models)**: All data models are Pydantic v2 BaseModel subclasses.
Ralph defines its own input models (`TaskPacketInput`, `IntentSpecInput`) and output
models (`EvidenceBundle`) — it does NOT import from TheStudio. TheStudio writes thin
mappers to convert its types to Ralph's interface.

**Circuit breaker active class**: `CircuitBreakerActive` in status.py manages state
transitions (CLOSED -> HALF_OPEN -> OPEN) with async state persistence via the backend.
```

### Key Notes

- Only the SDK section is updated — the rest of CLAUDE.md is unchanged.
- The module table replaces the existing v1.x table (same location).
- New design patterns are added after the existing "Key Design Patterns" section.
- Language is concise and factual — matches the existing CLAUDE.md style.

## Acceptance Criteria

- [ ] CLAUDE.md SDK module table includes `state.py`, `converters.py`, `evidence.py`
- [ ] State backend protocol pattern documented
- [ ] Async/sync duality documented
- [ ] Correlation ID threading documented
- [ ] Pydantic "own models" design principle documented
- [ ] Circuit breaker active class documented
- [ ] Existing non-SDK sections of CLAUDE.md unchanged
- [ ] Documentation style matches existing CLAUDE.md conventions

## Test Plan

- **Manual review**: Read the updated CLAUDE.md SDK section and verify it accurately
  describes the v2.0.0 architecture.
- **Module check**: Verify every module listed in the table actually exists in `sdk/ralph_sdk/`.
- **Pattern check**: Verify each documented design pattern references actual classes/methods
  that exist in the codebase.
- **Non-regression**: Verify sections outside the SDK section are unchanged (diff check).
