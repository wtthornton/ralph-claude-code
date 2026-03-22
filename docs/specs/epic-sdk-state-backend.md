# Epic: Pluggable State Backend (HIGH-2)

**Epic ID:** RALPH-SDK-STATE
**Priority:** High
**Phase:** 1 — Non-Breaking Foundation (v1.4.0)
**Affects:** All state persistence (status, circuit breaker, rate limiting, session, metrics)
**Components:** New `sdk/ralph_sdk/state.py`, `sdk/ralph_sdk/agent.py`, `sdk/ralph_sdk/status.py`
**Related specs:** [RFC-001 §4 HIGH-2](../../TheStudio/docs/architecture/RFC-001-ralph-sdk-integration.md), `epic-sdk-pydantic-models.md`
**Target Version:** v1.4.0
**Status:** Done

---

## Problem Statement

The Ralph SDK hardcodes 10+ state files to the `.ralph/` filesystem:

| File | Purpose |
|------|---------|
| `.circuit_breaker_state` | CB state JSON |
| `.circuit_breaker_events` | JSONL failure log |
| `.call_count` | Hourly API counter |
| `.last_reset` | Counter reset timestamp |
| `.claude_session_id` | Session persistence |
| `status.json` | Loop status |
| `metrics/YYYY-MM.jsonl` | Monthly metrics |
| `fix_plan.md` | Task queue |

For standalone Ralph, file-based state is perfect — simple, inspectable, zero dependencies.

For TheStudio embedding, file-based state breaks in multi-instance, container, and
Temporal activity contexts where state must live in PostgreSQL or Redis.

### Design: Protocol Pattern

Abstract state operations behind a Python `Protocol` so that:
1. **Standalone Ralph** uses `FileStateBackend` (default) — identical current behavior
2. **Testing** uses `NullStateBackend` — in-memory, no persistence
3. **TheStudio** implements `PostgresStateBackend` on their side using the protocol

Ralph SDK ships only `FileStateBackend` and `NullStateBackend`. The protocol is the
contract — TheStudio owns their implementation.

### Backward Compatibility

- `RalphAgent()` with no `state_backend` argument defaults to `FileStateBackend`
- All `.ralph/` file paths and formats remain identical
- Bash loop (`ralph_loop.sh`) reads/writes the same files — completely unaffected
- `ralph --sdk` works exactly as before

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-SDK-STATE-1](story-sdk-state-1-protocol.md) | Define RalphStateBackend Protocol | Critical | Small | Done |
| [RALPH-SDK-STATE-2](story-sdk-state-2-file-backend.md) | Implement FileStateBackend | Critical | Medium | Done |
| [RALPH-SDK-STATE-3](story-sdk-state-3-null-backend.md) | Implement NullStateBackend | High | Small | Done |
| [RALPH-SDK-STATE-4](story-sdk-state-4-wire-agent.md) | Wire state_backend into RalphAgent | Critical | Small | Done |
| [RALPH-SDK-STATE-5](story-sdk-state-5-remove-direct-io.md) | Remove direct file I/O from agent.py | High | Medium | Done |
| [RALPH-SDK-STATE-6](story-sdk-state-6-tests.md) | Test both backends | High | Small | Done |

## Implementation Order

1. **STATE-1** — Protocol definition. Pure interface, zero risk.
2. **STATE-2** — `FileStateBackend`. Wraps existing file I/O code.
3. **STATE-3** — `NullStateBackend`. Simple in-memory implementation.
4. **STATE-4** — Wire into `RalphAgent.__init__()`.
5. **STATE-5** — Remove all direct `Path.read_text()` / `Path.write_text()` from agent.py.
6. **STATE-6** — Verify both backends pass full test suite.

## Design Decisions

### Task Queue Excluded

Per RFC §9 Q3: TheStudio manages tasks via TaskPacket, not `fix_plan.md`. The state
backend does **not** include `load_fix_plan()` or `mark_task_complete()`. In standalone
mode, Ralph reads `fix_plan.md` directly. In TheStudio mode, fix_plan is bypassed entirely.

### Sync Methods Initially, Async in Epic 4

The protocol methods are defined as `async def` from the start (matching the RFC contract),
but the `FileStateBackend` initial implementation can use synchronous file I/O wrapped in
the async signature. Epic 4 (Async SDK) upgrades to `aiofiles`.

## Acceptance Criteria (Epic-level)

- [ ] `RalphStateBackend` protocol defined with 12 async methods
- [ ] `FileStateBackend` reads/writes same `.ralph/` files as current code
- [ ] `NullStateBackend` works for testing — all methods functional, no files created
- [ ] `RalphAgent(state_backend=NullStateBackend())` works
- [ ] `RalphAgent()` defaults to `FileStateBackend` (backward compatible)
- [ ] No direct `Path.read_text()` or `Path.write_text()` in `agent.py`
- [ ] `ralph --sdk` works unchanged
- [ ] Bash loop completely unaffected

## Out of Scope

- `PostgresStateBackend` (TheStudio responsibility)
- `RedisStateBackend` (TheStudio responsibility)
- Task queue operations (fix_plan.md management)
- Async file I/O with aiofiles (Epic 4)
