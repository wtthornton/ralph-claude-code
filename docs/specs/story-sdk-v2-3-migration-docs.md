# Story RALPH-SDK-V2-3: Update sdk-migration-strategy.md with v2.0.0 Guide

**Epic:** [Release, Integration Testing & v2.0.0](epic-sdk-v2-release.md)
**Priority:** High
**Status:** Done
**Effort:** Small
**Component:** `docs/specs/sdk-migration-strategy.md`

---

## Problem

The existing `sdk-migration-strategy.md` documents the v1.x SDK and does not cover
the v2.0.0 changes: async API, state backend protocol, correlation ID threading,
TaskPacket conversion with Pydantic models, or EvidenceBundle output. Developers
(both standalone Ralph users and TheStudio integration engineers) need a clear
migration guide to adopt v2.0.0.

## Solution

Add a `## v2.0.0 Migration Guide` section to `sdk-migration-strategy.md` documenting
all breaking and non-breaking changes, with code examples for each new feature. The
guide should cover:

1. New async API (`run_iteration()` is now `async`)
2. State backend protocol (pluggable backends)
3. Correlation ID threading
4. TaskPacket conversion with Pydantic models (replaces raw dict)
5. EvidenceBundle output (new structured output format)
6. TheStudio embedding code example

## Implementation

**File:** `docs/specs/sdk-migration-strategy.md` — append new section

```markdown
## v2.0.0 Migration Guide

### Breaking Changes

1. **`run_iteration()` is now `async`**
   ```python
   # Before (v1.x)
   result = agent.run_iteration(task_input)

   # After (v2.0.0)
   result = await agent.run_iteration(task_input)
   # Or synchronous wrapper:
   result = agent.run_iteration_sync(task_input)
   ```

2. **`RalphAgent` constructor requires `state_backend`**
   ```python
   # Before (v1.x)
   agent = RalphAgent(config=config)

   # After (v2.0.0)
   agent = RalphAgent(
       config=config,
       correlation_id=uuid4(),
       state_backend=FileStateBackend(project_dir),
   )
   ```

### New Features (Non-Breaking)

3. **TaskPacket conversion with Pydantic models**
   ```python
   from ralph_sdk import TaskInput, TaskPacketInput, IntentSpecInput

   task = TaskInput.from_task_packet(
       packet=TaskPacketInput(id=uuid4(), repo="org/repo"),
       intent=IntentSpecInput(goal="Implement feature X"),
   )
   ```

4. **EvidenceBundle output**
   ```python
   from ralph_sdk import EvidenceBundle

   evidence = result.to_evidence_bundle(
       taskpacket_id=packet.id,
       intent_version=1,
   )
   json_output = evidence.model_dump_json()
   ```

5. **TheStudio embedding example**
   ```python
   agent = RalphAgent(
       config=RalphConfig.load(),
       correlation_id=taskpacket.id,
       state_backend=PostgresStateBackend(pool),
   )
   task = TaskInput.from_task_packet(packet, intent)
   result = await agent.run_iteration(task)
   evidence = result.to_evidence_bundle(
       taskpacket_id=packet.id,
       intent_version=intent.version,
   )
   ```

### Standalone Ralph Users

No action needed. `ralph`, `ralph --sdk`, `ralph --live`, and `ralph --monitor`
continue to work exactly as before. The v2.0.0 changes add capabilities for
embedded usage — they do not remove or change anything for standalone users.
```

### Key Notes

- Breaking changes are clearly labeled with before/after code examples.
- Non-breaking additions are documented with usage examples.
- Standalone users get an explicit "no action needed" message.
- TheStudio embedding gets a complete code example showing the full pipeline.

## Acceptance Criteria

- [ ] `sdk-migration-strategy.md` has a `## v2.0.0 Migration Guide` section
- [ ] Documents async `run_iteration()` change with before/after examples
- [ ] Documents `state_backend` constructor requirement with code example
- [ ] Documents TaskPacket conversion with Pydantic models
- [ ] Documents EvidenceBundle output with code example
- [ ] Includes complete TheStudio embedding example
- [ ] Explicitly states standalone Ralph users need no changes
- [ ] All code examples use correct v2.0.0 API signatures

## Test Plan

- **Manual review**: Read the migration guide and verify all code examples match the
  actual v2.0.0 API signatures implemented in Epics 1-8.
- **Link check**: Verify any cross-references to other docs/specs files are valid.
- **Standalone reassurance**: Confirm the "no action needed" section is present and accurate.
