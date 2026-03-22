# Epic: Async SDK (BLOCKING-1)

**Epic ID:** RALPH-SDK-ASYNC
**Priority:** Critical (Blocking)
**Phase:** 2 — Async Layer (v1.5.0)
**Affects:** All SDK public methods, subprocess execution, file I/O, tool handlers
**Components:** `sdk/ralph_sdk/agent.py`, `sdk/ralph_sdk/status.py`, `sdk/ralph_sdk/tools.py`, `sdk/ralph_sdk/__main__.py`, `pyproject.toml`
**Related specs:** [RFC-001 §4 BLOCKING-1](../../TheStudio/docs/architecture/RFC-001-ralph-sdk-integration.md), `epic-sdk-pydantic-models.md`, `epic-sdk-state-backend.md`
**Depends on:** Epic 1 (Pydantic Models), Epic 2 (State Backend Protocol)
**Target Version:** v1.5.0

---

## Problem Statement

The Ralph SDK is fully synchronous:
- `subprocess.run()` at agent.py:280 blocks the event loop
- `Path.read_text()` throughout blocks on file I/O
- `time.sleep(2)` at agent.py:246 blocks the thread
- All tool handlers are synchronous functions

TheStudio's runtime is entirely async — FastAPI routes, Temporal activities, SQLAlchemy
sessions. Importing a synchronous SDK into an async context requires wrapping every call
in `asyncio.to_thread()`, which imposes a permanent performance penalty and prevents
cooperative cancellation.

### Standalone Ralph Benefit

Even without TheStudio, async support enables:
- Non-blocking subprocess monitoring (can check for kill signals during execution)
- Future integration with async MCP servers
- Better timeout handling via `asyncio.wait_for()` vs subprocess timeout

### Backward Compatibility — Critical

**The CLI must keep working synchronously.** Users running `ralph --sdk` or
`python -m ralph_sdk` must not need to understand asyncio. The solution:

```python
class RalphAgent:
    async def run(self) -> TaskResult:
        """Async entry point for platform embedding."""
        ...

    def run_sync(self) -> TaskResult:
        """Synchronous entry point for CLI mode."""
        return asyncio.run(self.run())
```

`__main__.py` calls `run_sync()`. TheStudio calls `await run()`.

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-SDK-ASYNC-1](story-sdk-async-1-aiofiles.md) | Add aiofiles dependency | Critical | Trivial | Pending |
| [RALPH-SDK-ASYNC-2](story-sdk-async-2-file-backend.md) | Make FileStateBackend async with aiofiles | Critical | Medium | Pending |
| [RALPH-SDK-ASYNC-3](story-sdk-async-3-run.md) | Convert RalphAgent.run() to async | Critical | Medium | Pending |
| [RALPH-SDK-ASYNC-4](story-sdk-async-4-iteration.md) | Convert RalphAgent.run_iteration() to async subprocess | Critical | Medium | Pending |
| [RALPH-SDK-ASYNC-5](story-sdk-async-5-checks.md) | Convert should_exit, check_rate_limit, check_circuit_breaker to async | High | Small | Pending |
| [RALPH-SDK-ASYNC-6](story-sdk-async-6-sleep.md) | Replace time.sleep with asyncio.sleep | High | Trivial | Pending |
| [RALPH-SDK-ASYNC-7](story-sdk-async-7-sync-wrapper.md) | Add run_sync() wrapper and update __main__.py | Critical | Small | Pending |
| [RALPH-SDK-ASYNC-8](story-sdk-async-8-tools.md) | Convert tool handlers to async | Medium | Small | Pending |
| [RALPH-SDK-ASYNC-9](story-sdk-async-9-cli-verify.md) | Verify CLI mode end-to-end | Critical | Small | Pending |

## Implementation Order

1. **ASYNC-1** — Add `aiofiles` dependency. Zero risk.
2. **ASYNC-2** — Upgrade `FileStateBackend` to use `aiofiles`.
3. **ASYNC-3** — Main `run()` method becomes async.
4. **ASYNC-4** — `run_iteration()` uses `asyncio.create_subprocess_exec()`.
5. **ASYNC-5** — Check methods become async (read from state backend).
6. **ASYNC-6** — Replace `time.sleep(2)` with `await asyncio.sleep(2)`.
7. **ASYNC-7** — Add `run_sync()`, update `__main__.py`.
8. **ASYNC-8** — Tool handlers become async.
9. **ASYNC-9** — End-to-end CLI verification.

## Design Decisions

### asyncio Only (Not anyio)

Per RFC §9 Q2: TheStudio uses `asyncio` exclusively. No Trio requirement. Using raw
`asyncio` avoids an unnecessary dependency and complexity.

### Keep `_sync` Variants?

The RFC suggests keeping synchronous methods as `_sync` variants. Simpler approach:
- Primary interface is async (`run()`, `run_iteration()`)
- Single `run_sync()` convenience method wraps with `asyncio.run()`
- No parallel `_sync` variants for every method — unnecessary complexity
- Internal helper methods that don't do I/O remain plain (non-async)

### subprocess Timeout

`asyncio.create_subprocess_exec()` + `asyncio.wait_for()` provides cooperative timeout:
```python
proc = await asyncio.create_subprocess_exec(*cmd, stdout=PIPE, stderr=PIPE)
try:
    stdout, stderr = await asyncio.wait_for(
        proc.communicate(), timeout=self.config.timeout_minutes * 60
    )
except asyncio.TimeoutError:
    proc.kill()
    await proc.wait()
    # return timeout status
```

This is superior to `subprocess.run(timeout=...)` because it cooperates with the event
loop and allows cancellation from the caller.

## Acceptance Criteria (Epic-level)

- [ ] `await RalphAgent(config).run()` works in an async context
- [ ] No `subprocess.run()` calls in the async path
- [ ] No `time.sleep()` calls in the async path
- [ ] No synchronous `Path.read_text()` / `Path.write_text()` in the async path
- [ ] All file I/O uses `aiofiles` in async path
- [ ] CLI mode (`ralph --sdk`, `python -m ralph_sdk`) still works synchronously
- [ ] `run_sync()` wraps async with `asyncio.run()`
- [ ] `--dry-run` mode works in both async and sync paths
- [ ] All existing tests pass

## Out of Scope

- Async MCP server integration (future work)
- Concurrent sub-agent execution (depends on Claude Agent SDK async support)
- Async configuration loading (config is read once at startup — sync is fine)
