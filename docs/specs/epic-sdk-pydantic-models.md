# Epic: Pydantic v2 Models (BLOCKING-2)

**Epic ID:** RALPH-SDK-PYDANTIC
**Priority:** Critical (Blocking)
**Phase:** 1 — Non-Breaking Foundation (v1.4.0)
**Affects:** All SDK model serialization, validation, TheStudio embedding compatibility
**Components:** `sdk/ralph_sdk/status.py`, `sdk/ralph_sdk/agent.py`, `sdk/ralph_sdk/config.py`, `pyproject.toml`
**Related specs:** [RFC-001](../../TheStudio/docs/architecture/RFC-001-ralph-sdk-integration.md), `epic-sdk-state-backend.md`, `epic-sdk-structured-parsing.md`
**Target Version:** v1.4.0

---

## Problem Statement

The Ralph SDK uses plain `@dataclass` for all 5 data models (`TaskInput`, `TaskResult`,
`RalphStatus`, `CircuitBreakerState`, `RalphConfig`). These provide zero runtime
validation — invalid data silently propagates through the system. There is no schema
enforcement, no `model_dump()` / `model_validate()`, and no JSON Schema generation.

For standalone Ralph CLI usage, this is acceptable — the bash loop validates upstream.
For TheStudio embedding, all models crossing module boundaries must be Pydantic v2
`BaseModel` to interoperate with TheStudio's async SQLAlchemy / FastAPI / Temporal stack,
which is Pydantic-native throughout.

### Why This Matters for Standalone Ralph

Even without TheStudio, Pydantic models improve Ralph SDK reliability:
- Invalid `max_turns=0` or `max_calls_per_hour=-1` caught at construction, not mid-loop
- `model_json_schema()` enables config file validation tooling
- Frozen models prevent accidental mutation of shared state
- Better error messages when `.ralphrc` contains invalid values

### Backward Compatibility Requirement

**Ralph must continue to work identically without TheStudio.** All existing valid data
must round-trip through the new models. The CLI mode (`ralph --sdk`, `__main__.py`)
must not require Pydantic knowledge from users. The bash loop (`ralph_loop.sh`) is
completely unaffected — it reads/writes the same `status.json` format.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-SDK-PYDANTIC-1](story-sdk-pydantic-1-dependency.md) | Add Pydantic v2 dependency | Critical | Trivial | Pending |
| [RALPH-SDK-PYDANTIC-2](story-sdk-pydantic-2-status.md) | Convert RalphStatus to Pydantic BaseModel | Critical | Small | Pending |
| [RALPH-SDK-PYDANTIC-3](story-sdk-pydantic-3-circuit-breaker.md) | Convert CircuitBreakerState to Pydantic BaseModel | Critical | Small | Pending |
| [RALPH-SDK-PYDANTIC-4](story-sdk-pydantic-4-task-input.md) | Convert TaskInput to Pydantic BaseModel | Critical | Small | Pending |
| [RALPH-SDK-PYDANTIC-5](story-sdk-pydantic-5-task-result.md) | Convert TaskResult to Pydantic BaseModel | Critical | Small | Pending |
| [RALPH-SDK-PYDANTIC-6](story-sdk-pydantic-6-config.md) | Convert RalphConfig to Pydantic BaseModel | High | Medium | Pending |
| [RALPH-SDK-PYDANTIC-7](story-sdk-pydantic-7-backward-compat.md) | Backward compatibility verification | Critical | Small | Pending |

## Implementation Order

1. **PYDANTIC-1** — Add dependency. Zero risk, unblocks everything.
2. **PYDANTIC-2** — `RalphStatus` — most referenced model, validates the pattern.
3. **PYDANTIC-3** — `CircuitBreakerState` — closely related to status.
4. **PYDANTIC-4** — `TaskInput` — frozen model with validation constraints.
5. **PYDANTIC-5** — `TaskResult` — depends on RalphStatus model.
6. **PYDANTIC-6** — `RalphConfig` — largest model (30 fields), most complex loading.
7. **PYDANTIC-7** — Cross-cutting backward compatibility verification.

## Design Decisions

### Parallel Classes vs In-Place Replacement

The RFC suggests parallel classes (`TaskInputV2`) for Phase 1. However, since the SDK
is v1.3.0 with limited external consumers, **in-place replacement** is cleaner:
- Rename old classes to `*Legacy` only if needed for transition
- New Pydantic classes keep the original names
- `from_dict()` / `to_dict()` methods preserved for bash compatibility
- `model_config = ConfigDict(frozen=True)` where immutability is appropriate

### Enums

Introduce `StrEnum` types for validated string fields:
- `RalphLoopStatus`: `IN_PROGRESS`, `COMPLETE`, `BLOCKED`, `ERROR`, `TIMEOUT`, `DRY_RUN`
- `WorkType`: `IMPLEMENTATION`, `TESTING`, `DOCUMENTATION`, `REFACTORING`, `UNKNOWN`
- `CircuitBreakerStateEnum`: `CLOSED`, `HALF_OPEN`, `OPEN`

These are additive — the bash loop writes uppercase strings that match these values.

## Acceptance Criteria (Epic-level)

- [ ] All 5 models are Pydantic v2 `BaseModel`
- [ ] Invalid data raises `ValidationError` (not silent defaults)
- [ ] `model_dump()` and `model_validate()` work correctly for all models
- [ ] JSON Schema available via `model_json_schema()` for all models
- [ ] Existing valid data from bash loop (`status.json`, `.circuit_breaker_state`) still loads
- [ ] `ralph --sdk --dry-run` works unchanged
- [ ] All existing SDK tests pass
- [ ] No changes to bash loop (`ralph_loop.sh`) required

## Out of Scope

- TheStudio-specific model extensions (Epic 7, Epic 8)
- Async I/O (Epic 4)
- OpenTelemetry integration (Epic 6)
