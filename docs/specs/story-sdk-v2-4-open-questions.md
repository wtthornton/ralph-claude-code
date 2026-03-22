# Story RALPH-SDK-V2-4: Resolve and Document RFC Section 9 Open Questions

**Epic:** [Release, Integration Testing & v2.0.0](epic-sdk-v2-release.md)
**Priority:** Medium
**Status:** Pending
**Effort:** Small
**Component:** `docs/specs/epic-sdk-v2-release.md`, `docs/specs/sdk-migration-strategy.md`

---

## Problem

RFC-001 Section 9 identified four open questions that needed decisions before v2.0.0
could be finalized. These decisions have been made during implementation (Epics 1-8)
but are not formally documented in a single, discoverable location. Future contributors
and TheStudio engineers need to understand the rationale behind each decision.

## Solution

Document all four open question resolutions in the v2.0.0 release documentation.
Each question gets the decision, rationale, and any implementation notes.

## Implementation

Add a `### RFC Section 9 Open Question Resolutions` subsection to the migration docs:

```markdown
### RFC Section 9 Open Question Resolutions

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| 1 | Should Ralph SDK depend on TheStudio models? | **Own models** | Zero coupling. Ralph is free and independent. TheStudio writes a thin mapper (`TaskPacketRead` -> `TaskPacketInput`). |
| 2 | `anyio` vs `asyncio`? | **`asyncio` only** | TheStudio uses asyncio. No Trio requirement. Avoids the anyio dependency. |
| 3 | Include task queue ops in state backend? | **Exclude** | TheStudio manages tasks via TaskPacket lifecycle. Standalone Ralph reads `fix_plan.md` directly. Task queue is an orchestration concern, not a state concern. |
| 4 | Configurable system prompt template? | **Yes — `system_prompt` override** | `run_iteration()` accepts an optional `system_prompt: str` parameter. When provided, it replaces the default PROMPT.md content. Enables TheStudio's `DeveloperRoleConfig.system_prompt_template`. |

#### Q1: Own Models (Decision)

Ralph defines `TaskPacketInput`, `IntentSpecInput`, and `EvidenceBundle` in its own
codebase. These models mirror TheStudio's shapes but are independently versioned.
TheStudio maps from its internal models to Ralph's types. This means:

- Ralph can be used by any orchestration platform, not just TheStudio
- Ralph has zero dependency on TheStudio packages
- Model version drift is caught at TheStudio's mapper boundary, not at runtime

#### Q2: asyncio Only (Decision)

The SDK uses `asyncio` exclusively. The `FileStateBackend` uses `aiofiles` for async
file I/O. The `NullStateBackend` uses `asyncio.sleep(0)` for cooperative yielding.
There is no `anyio` or `trio` support.

For callers that need synchronous access, `run_iteration_sync()` wraps the async
method via `asyncio.run()`.

#### Q3: Exclude Task Queue (Decision)

`RalphStateBackend` Protocol covers: status, circuit breaker, rate limiting, session,
and metrics. It does NOT include task queue operations (create, claim, complete, fail).
Task lifecycle is managed by TheStudio's Temporal workflows, not by Ralph's state layer.

#### Q4: System Prompt Override (Decision)

`run_iteration(task_input, system_prompt="...")` replaces the default PROMPT.md content.
This enables TheStudio to inject its `DeveloperRoleConfig.system_prompt_template` which
includes role context, project conventions, and team-specific instructions.
```

### Key Notes

- Decisions are presented as a summary table first, then detailed explanations below.
- Each decision references the implementation that delivered it (e.g., "converters.py", "state.py").
- Rationale focuses on "why" not just "what" — future contributors need to understand trade-offs.

## Acceptance Criteria

- [ ] All 4 RFC Section 9 open questions documented with decisions and rationale
- [ ] Q1 decision: Own models (no TheStudio dependency)
- [ ] Q2 decision: asyncio only (no anyio/trio)
- [ ] Q3 decision: Exclude task queue from state backend
- [ ] Q4 decision: Accept system_prompt override in run_iteration()
- [ ] Summary table included for quick reference
- [ ] Detailed explanation for each decision included
- [ ] Documentation is discoverable in the migration strategy or release docs

## Test Plan

- **Manual review**: Verify all four decisions are documented and match the actual
  implementation in the codebase.
- **Cross-reference**: Confirm each decision references the correct epic/story where
  it was implemented.
- **Completeness**: Verify no open questions from RFC Section 9 are missing.
