# Story RALPH-SDK-ASYNC-7: Add run_sync() Wrapper and Update __main__.py

**Epic:** [Async SDK](epic-sdk-async.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`, `sdk/ralph_sdk/__main__.py`

---

## Problem

After ASYNC-3 converts `run()` to async, the CLI entry point in `__main__.py` (line 119)
calls `agent.run()` synchronously. This will break because `run()` now returns a coroutine
object instead of a `TaskResult`. Users running `ralph --sdk` or `python -m ralph_sdk` will
get a `RuntimeWarning: coroutine 'RalphAgent.run' was never awaited` and the agent will not
execute.

CLI users should not need to understand asyncio. A synchronous `run_sync()` method must
bridge the gap.

## Solution

Add a `run_sync()` method to `RalphAgent` that wraps `asyncio.run(self.run())`. Update
`__main__.py` to call `agent.run_sync()` instead of `agent.run()`. This maintains full
backward compatibility for CLI users while keeping the primary interface async.

## Implementation

### Add run_sync() to RalphAgent

**File:** `sdk/ralph_sdk/agent.py`

Add after the `run()` method (after the existing line 259):

```python
    def run_sync(self) -> TaskResult:
        """Synchronous entry point for CLI mode.

        Wraps the async run() method with asyncio.run() so that CLI users
        (ralph --sdk, python -m ralph_sdk) don't need to manage an event loop.
        """
        return asyncio.run(self.run())
```

### Update __main__.py

**File:** `sdk/ralph_sdk/__main__.py`

BEFORE (line 118-119):
```python
    # Run the agent
    agent = RalphAgent(config=config, project_dir=args.project_dir)
    result = agent.run()
```

AFTER:
```python
    # Run the agent
    agent = RalphAgent(config=config, project_dir=args.project_dir)
    result = agent.run_sync()
```

### Update process_task_packet() (TheStudio adapter)

**File:** `sdk/ralph_sdk/agent.py`

BEFORE (agent.py:556-568):
```python
    def process_task_packet(self, packet: dict[str, Any]) -> dict[str, Any]:
        """Process a TheStudio TaskPacket and return a Signal.

        Converts TaskPacket → TaskInput, runs iteration, returns TaskResult as Signal.
        """
        task_input = TaskInput.from_task_packet(packet)
        status = self.run_iteration(task_input)
        result = TaskResult(
            status=status,
            loop_count=self.loop_count,
            duration_seconds=time.time() - self.start_time if self.start_time else 0,
        )
        return result.to_signal()
```

AFTER:
```python
    async def process_task_packet(self, packet: dict[str, Any]) -> dict[str, Any]:
        """Process a TheStudio TaskPacket and return a Signal.

        Converts TaskPacket → TaskInput, runs iteration, returns TaskResult as Signal.
        """
        task_input = TaskInput.from_task_packet(packet)
        status = await self.run_iteration(task_input)
        result = TaskResult(
            status=status,
            loop_count=self.loop_count,
            duration_seconds=time.time() - self.start_time if self.start_time else 0,
        )
        return result.to_signal()
```

## Acceptance Criteria

- [ ] `RalphAgent.run_sync()` exists as a synchronous method
- [ ] `run_sync()` calls `asyncio.run(self.run())` and returns `TaskResult`
- [ ] `__main__.py` calls `agent.run_sync()` instead of `agent.run()`
- [ ] `process_task_packet()` converted to `async def` with `await self.run_iteration()`
- [ ] `ralph --sdk --dry-run` works from command line without errors
- [ ] `python -m ralph_sdk --dry-run` works from command line without errors
- [ ] No `RuntimeWarning: coroutine was never awaited` in any execution path
- [ ] `run_sync()` raises `RuntimeError` if called from within an existing event loop
  (this is standard `asyncio.run()` behavior -- no custom handling needed)

## Test Plan

- **CLI dry run**: Run `python -m ralph_sdk --dry-run --project-dir /tmp/test_project` (with
  a valid .ralph/ setup). Verify exit code 0 and status is DRY_RUN.
- **run_sync returns TaskResult**: Call `agent.run_sync()` with dry-run config, verify
  return type is `TaskResult`.
- **run_sync bridges async**: Verify `run_sync()` correctly executes the async `run()` and
  returns the same result that `await run()` would.
- **Nested event loop error**: From within an `async def` test, verify that calling
  `agent.run_sync()` raises `RuntimeError("asyncio.run() cannot be called from a running event loop")`.
- **process_task_packet async**: Call `await agent.process_task_packet(packet)` in an async
  test, verify it returns a signal dict.
- **__main__ integration**: Invoke `python -m ralph_sdk --version` and verify it prints
  version without warnings.
