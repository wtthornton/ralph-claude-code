# Epic: Release, Integration Testing & v2.0.0

**Epic ID:** RALPH-SDK-V2
**Priority:** Critical
**Phase:** 3 — Integration (v2.0.0)
**Affects:** Version, documentation, release packaging, integration verification
**Components:** `package.json`, `ralph_loop.sh`, `sdk/`, `docs/`, `CLAUDE.md`
**Related specs:** All SDK epics, [RFC-001](../../TheStudio/docs/architecture/RFC-001-ralph-sdk-integration.md)
**Depends on:** All previous SDK epics (1-8)
**Target Version:** v2.0.0
**Status:** Done

---

## Problem Statement

After implementing all 8 RFC changes across Epics 1-8, the SDK needs:
1. End-to-end integration testing to verify the full pipeline works
2. Version promotion from v1.x to v2.0.0
3. Documentation updates for the new API surface
4. Backward compatibility verification for all standalone Ralph users
5. Resolution of RFC open questions

### Critical Constraint: Ralph Free Must Not Break

Ralph v2.0.0 is a **free** upgrade. Every standalone user running `ralph`, `ralph --sdk`,
`ralph --live`, or `ralph --monitor` must experience zero breakage. The v2.0.0 changes
add capabilities for TheStudio embedding — they do not remove or change anything for
standalone users.

Version bump in both `package.json` and `ralph_loop.sh` `RALPH_VERSION` must stay in sync.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-SDK-V2-1](story-sdk-v2-1-integration-test.md) | Write end-to-end integration test (TaskPacket → Ralph → EvidenceBundle) | Critical | Medium | Done |
| [RALPH-SDK-V2-2](story-sdk-v2-2-promote-models.md) | Promote Pydantic TaskInput as default | High | Small | Done |
| [RALPH-SDK-V2-3](story-sdk-v2-3-migration-docs.md) | Update sdk-migration-strategy.md with v2.0.0 guide | High | Small | Done |
| [RALPH-SDK-V2-4](story-sdk-v2-4-open-questions.md) | Resolve and document RFC §9 open questions | Medium | Small | Done |
| [RALPH-SDK-V2-5](story-sdk-v2-5-version-bump.md) | Bump version to 2.0.0 in package.json and ralph_loop.sh | Critical | Trivial | Done |
| [RALPH-SDK-V2-6](story-sdk-v2-6-claude-md.md) | Update CLAUDE.md with new SDK architecture | High | Small | Done |
| [RALPH-SDK-V2-7](story-sdk-v2-7-cli-regression.md) | Full CLI regression test (bash loop + SDK mode) | Critical | Medium | Done |

## Implementation Order

1. **V2-1** — Integration test. Proves everything works together.
2. **V2-4** — Document open question resolutions.
3. **V2-2** — Promote Pydantic models as default.
4. **V2-3** — Update migration docs.
5. **V2-6** — Update CLAUDE.md.
6. **V2-5** — Version bump (last code change).
7. **V2-7** — Full regression test (final gate).

## Design Decisions

### Open Questions Resolution (RFC §9)

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| 1 | Ralph SDK depend on TheStudio models? | **Own models** | Zero coupling. Ralph is free and independent. TheStudio writes a thin mapper. |
| 2 | `anyio` vs `asyncio`? | **`asyncio` only** | TheStudio uses asyncio. No Trio requirement. |
| 3 | Task queue ops in state backend? | **Exclude** | TheStudio manages tasks via TaskPacket. Standalone Ralph reads fix_plan.md directly. |
| 4 | Configurable prompt template? | **Yes** | `run_iteration()` accepts `system_prompt` override. Default is PROMPT.md. |

### Integration Test Structure

```python
async def test_ralph_thestudio_integration():
    """End-to-end: TaskPacket → Ralph → EvidenceBundle.

    Uses NullStateBackend (no file system). Verifies the full conversion
    pipeline works without TheStudio running.
    """
    agent = RalphAgent(
        config=RalphConfig.load(),
        correlation_id=uuid4(),
        state_backend=NullStateBackend(),
    )
    task_input = TaskInput.from_task_packet(
        packet=mock_taskpacket(),
        intent=mock_intent_spec(),
    )
    result = await agent.run_iteration(task_input)
    evidence = result.to_evidence_bundle(
        taskpacket_id=mock_taskpacket().id,
        intent_version=1,
    )
    assert isinstance(evidence.files_changed, list)
    assert evidence.taskpacket_id == mock_taskpacket().id
    assert evidence.agent_summary != ""
```

### Version Bump Checklist

Per CLAUDE.md and existing memory:
1. `package.json` → `"version": "2.0.0"`
2. `ralph_loop.sh` → `RALPH_VERSION="2.0.0"`
3. Both must match exactly

## Acceptance Criteria (Epic-level)

- [ ] End-to-end integration test passes with `NullStateBackend`
- [ ] Pydantic `TaskInput` is the default import
- [ ] `sdk-migration-strategy.md` documents v2.0.0 changes and TheStudio embedding
- [ ] All 4 open questions documented with decisions
- [ ] Version 2.0.0 in both `package.json` and `ralph_loop.sh`
- [ ] `CLAUDE.md` documents new SDK patterns (state backend, async, correlation ID)
- [ ] `ralph` (bash loop) works unchanged
- [ ] `ralph --sdk` works unchanged
- [ ] `ralph --sdk --dry-run` works unchanged
- [ ] `ralph --live` works unchanged
- [ ] All 736+ existing BATS tests pass
- [ ] New SDK integration tests pass

## Out of Scope

- TheStudio-side integration work (their `PostgresStateBackend`, Temporal wrapper, etc.)
- Deployment / publishing to PyPI (separate process)
- Marketing / announcement (separate process)
