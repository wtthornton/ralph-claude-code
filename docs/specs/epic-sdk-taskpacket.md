# Epic: TaskPacket Conversion (BLOCKING-3)

**Epic ID:** RALPH-SDK-TASKPACKET
**Priority:** Critical (Blocking)
**Phase:** 3 — Integration (v2.0.0)
**Affects:** TheStudio → Ralph input pipeline, task context mapping
**Components:** `sdk/ralph_sdk/agent.py`, new `sdk/ralph_sdk/converters.py`
**Related specs:** [RFC-001 §4 BLOCKING-3](../../TheStudio/docs/architecture/RFC-001-ralph-sdk-integration.md), `epic-sdk-pydantic-models.md`
**Depends on:** Epic 1 (Pydantic Models)
**Target Version:** v2.0.0

---

## Problem Statement

`TaskInput.from_task_packet()` (agent.py:101-111) extracts only 4 fields from a raw dict:

```python
@classmethod
def from_task_packet(cls, packet: dict) -> "TaskInput":
    return cls(
        prompt=packet.get("prompt", ""),
        fix_plan=packet.get("fix_plan", ""),
        agent_instructions=packet.get("agent_instructions", ""),
        project_type=packet.get("project_type", "python"),
    )
```

TheStudio's `TaskPacket` has 20+ fields including `IntentSpec` (goal, constraints,
acceptance criteria), `complexity_index`, `risk_flags`, `context_packs`, `loopback_count`,
and `task_trust_tier`. The current conversion discards almost all of this context.

### Key Design Principle: Ralph Owns Its Models

**Ralph does NOT depend on TheStudio.** Ralph defines its own Pydantic models that
mirror the shape of TheStudio's models. TheStudio is responsible for mapping its models
to Ralph's interface. This keeps Ralph free and independent — it can be used by any
orchestration platform, not just TheStudio.

The `from_task_packet()` method accepts Ralph-defined input types. TheStudio writes a
thin mapper in its `primary_agent.py` to convert `TaskPacketRead` → Ralph's input format.

### Standalone Ralph Unaffected

`from_ralph_dir()` (loading from `.ralph/fix_plan.md` + `PROMPT.md`) is completely
unchanged. The `from_task_packet()` upgrade only matters for embedded mode. CLI users
never call it.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-SDK-TASKPACKET-1](story-sdk-taskpacket-1-models.md) | Define Ralph-side input mirror models | Critical | Small | Pending |
| [RALPH-SDK-TASKPACKET-2](story-sdk-taskpacket-2-signature.md) | Implement new from_task_packet() with full signature | Critical | Medium | Pending |
| [RALPH-SDK-TASKPACKET-3](story-sdk-taskpacket-3-intent.md) | Map IntentSpec fields (goal, constraints, criteria, non-goals) | Critical | Small | Pending |
| [RALPH-SDK-TASKPACKET-4](story-sdk-taskpacket-4-risk.md) | Map risk_flags, context_packs, trust_tier | High | Small | Pending |
| [RALPH-SDK-TASKPACKET-5](story-sdk-taskpacket-5-complexity.md) | Scale max_turns by complexity band | High | Small | Pending |
| [RALPH-SDK-TASKPACKET-6](story-sdk-taskpacket-6-loopback.md) | Include loopback_context for retry attempts | High | Small | Pending |
| [RALPH-SDK-TASKPACKET-7](story-sdk-taskpacket-7-deprecate.md) | Deprecate old from_task_packet(dict) with warning | Medium | Small | Pending |

## Implementation Order

1. **TASKPACKET-1** — Define Ralph-side models (no TheStudio dependency).
2. **TASKPACKET-2** — New method signature.
3. **TASKPACKET-3** — IntentSpec field mapping.
4. **TASKPACKET-4** — Risk flags and context packs mapping.
5. **TASKPACKET-5** — Complexity-based max_turns scaling.
6. **TASKPACKET-6** — Loopback context prepending.
7. **TASKPACKET-7** — Deprecate old dict-based method.

## Design Decisions

### Ralph-Side Mirror Models

Ralph defines lightweight Pydantic models that match the fields it needs:

```python
# In sdk/ralph_sdk/converters.py — Ralph's own models, NOT imported from TheStudio

class TaskPacketInput(BaseModel):
    """Ralph's view of an external task packet. Matches TheStudio TaskPacketRead shape."""
    id: UUID
    repo: str = ""
    complexity_index: dict[str, Any] | None = None  # {"score": float, "band": str}
    risk_flags: dict[str, bool] | None = None
    context_packs: list[dict[str, Any]] | None = None
    task_trust_tier: str = "suggest"
    loopback_count: int = 0

class IntentSpecInput(BaseModel):
    """Ralph's view of an intent specification. Matches TheStudio IntentSpecRead shape."""
    goal: str
    constraints: list[str] = Field(default_factory=list)
    acceptance_criteria: list[str] = Field(default_factory=list)
    non_goals: list[str] = Field(default_factory=list)
    version: int = 1
```

TheStudio maps from `TaskPacketRead` / `IntentSpecRead` → these types. The mapping
is trivial because the shapes are compatible, but Ralph does not import TheStudio code.

### Complexity → max_turns Scaling

| Complexity Band | max_turns |
|-----------------|-----------|
| low             | 20        |
| medium          | 30        |
| high            | 50        |
| (missing/unknown) | 30 (default) |

### Risk Flags → Constraints

```python
RISK_FLAG_CONSTRAINTS = {
    "touches_auth": "MUST NOT modify authentication or authorization code without explicit approval",
    "touches_payments": "MUST NOT modify payment processing code without explicit approval",
    "touches_pii": "MUST NOT expose or log personally identifiable information",
    "cross_service": "Changes may affect multiple services — verify integration points",
}
```

### Prompt Template Override (RFC §9 Q4)

`run_iteration()` accepts an optional `system_prompt: str` parameter. When provided, it
replaces the default PROMPT.md content. This enables TheStudio's `DeveloperRoleConfig.system_prompt_template`.

## Acceptance Criteria (Epic-level)

- [ ] Ralph defines its own input models (zero TheStudio dependency)
- [ ] `from_task_packet()` accepts Pydantic models (not raw dicts)
- [ ] All IntentSpec fields mapped (goal, constraints, acceptance_criteria, non_goals)
- [ ] Risk flags converted to constraint strings
- [ ] max_turns scaled by complexity band
- [ ] Loopback context prepended to prompt when non-empty
- [ ] Old dict-based `from_task_packet()` emits deprecation warning but still works
- [ ] `from_ralph_dir()` completely unchanged
- [ ] `ralph --sdk` works unchanged (never calls `from_task_packet()`)
- [ ] mypy strict mode passes

## Out of Scope

- TheStudio-side mapper implementation (TheStudio writes this)
- Expert output integration (future work — `expert_outputs` parameter accepted but unused initially)
- Prompt template system (accepts `system_prompt` override, does not build templates)
