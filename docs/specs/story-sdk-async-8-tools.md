# Story RALPH-SDK-ASYNC-8: Convert Tool Handlers to Async

**Epic:** [Async SDK](epic-sdk-async.md)
**Priority:** Medium
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/tools.py`, `sdk/ralph_sdk/agent.py`

---

## Problem

The four tool handler functions in `tools.py` — `ralph_status_tool`, `ralph_rate_check_tool`,
`ralph_circuit_state_tool`, and `ralph_task_update_tool` — perform synchronous file I/O via
`Path.read_text()` and `Path.write_text()`. They are called from `check_rate_limit()` and
`check_circuit_breaker()` in agent.py (now async per ASYNC-5) and from
`handle_tool_call()`. All file reads/writes must use aiofiles to avoid blocking the event
loop.

The `handle_tool_call()` dispatcher in agent.py must also become async to `await` the tool
handlers.

## Solution

Convert all four tool functions to `async def` and replace `Path.read_text()` /
`Path.write_text()` with `aiofiles.open()`. Convert `handle_tool_call()` to `async def`.
The internal logic of each tool is unchanged.

## Implementation

### ralph_status_tool

**File:** `sdk/ralph_sdk/tools.py`

BEFORE (tools.py:15-55):
```python
def ralph_status_tool(
    work_type: str = "UNKNOWN",
    completed_task: str = "",
    next_task: str = "",
    progress_summary: str = "",
    exit_signal: bool = False,
    ralph_dir: str = ".ralph",
) -> dict[str, Any]:
    """Report status at end of each loop iteration."""
    from ralph_sdk.status import RalphStatus

    status = RalphStatus.load(ralph_dir)
    status.work_type = work_type
    status.completed_task = completed_task
    status.next_task = next_task
    status.progress_summary = progress_summary
    status.exit_signal = exit_signal
    status.timestamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    status.status = "COMPLETED" if exit_signal else "IN_PROGRESS"
    status.save(ralph_dir)

    return {
        "ok": True,
        "status": status.to_dict(),
        "message": f"Status updated: {work_type} — exit_signal={exit_signal}",
    }
```

AFTER:
```python
async def ralph_status_tool(
    work_type: str = "UNKNOWN",
    completed_task: str = "",
    next_task: str = "",
    progress_summary: str = "",
    exit_signal: bool = False,
    ralph_dir: str = ".ralph",
) -> dict[str, Any]:
    """Report status at end of each loop iteration."""
    from ralph_sdk.status import RalphStatus

    status = await RalphStatus.aload(ralph_dir)
    status.work_type = work_type
    status.completed_task = completed_task
    status.next_task = next_task
    status.progress_summary = progress_summary
    status.exit_signal = exit_signal
    status.timestamp = time.strftime("%Y-%m-%dT%H:%M:%S%z")
    status.status = "COMPLETED" if exit_signal else "IN_PROGRESS"
    await status.asave(ralph_dir)

    return {
        "ok": True,
        "status": status.to_dict(),
        "message": f"Status updated: {work_type} — exit_signal={exit_signal}",
    }
```

### ralph_rate_check_tool

BEFORE (tools.py:58-104):
```python
def ralph_rate_check_tool(
    ralph_dir: str = ".ralph",
    max_calls_per_hour: int = 100,
) -> dict[str, Any]:
    """Check current rate limit status."""
    ralph_path = Path(ralph_dir)
    call_count_file = ralph_path / ".call_count"
    last_reset_file = ralph_path / ".last_reset"

    call_count = 0
    last_reset = 0

    if call_count_file.exists():
        try:
            call_count = int(call_count_file.read_text().strip())
        except (ValueError, OSError):
            pass

    if last_reset_file.exists():
        try:
            last_reset = int(last_reset_file.read_text().strip())
        except (ValueError, OSError):
            pass

    now = int(time.time())
    elapsed = now - last_reset if last_reset > 0 else 3600
    remaining = max(0, max_calls_per_hour - call_count)
    reset_in = max(0, 3600 - elapsed)

    return {
        "ok": True,
        "calls_used": call_count,
        "calls_remaining": remaining,
        "max_calls_per_hour": max_calls_per_hour,
        "reset_in_seconds": reset_in,
        "rate_limited": remaining <= 0,
    }
```

AFTER:
```python
async def ralph_rate_check_tool(
    ralph_dir: str = ".ralph",
    max_calls_per_hour: int = 100,
) -> dict[str, Any]:
    """Check current rate limit status."""
    import aiofiles

    ralph_path = Path(ralph_dir)
    call_count_file = ralph_path / ".call_count"
    last_reset_file = ralph_path / ".last_reset"

    call_count = 0
    last_reset = 0

    if call_count_file.exists():
        try:
            async with aiofiles.open(call_count_file) as f:
                call_count = int((await f.read()).strip())
        except (ValueError, OSError):
            pass

    if last_reset_file.exists():
        try:
            async with aiofiles.open(last_reset_file) as f:
                last_reset = int((await f.read()).strip())
        except (ValueError, OSError):
            pass

    now = int(time.time())
    elapsed = now - last_reset if last_reset > 0 else 3600
    remaining = max(0, max_calls_per_hour - call_count)
    reset_in = max(0, 3600 - elapsed)

    return {
        "ok": True,
        "calls_used": call_count,
        "calls_remaining": remaining,
        "max_calls_per_hour": max_calls_per_hour,
        "reset_in_seconds": reset_in,
        "rate_limited": remaining <= 0,
    }
```

### ralph_circuit_state_tool

BEFORE (tools.py:107-131):
```python
def ralph_circuit_state_tool(
    ralph_dir: str = ".ralph",
) -> dict[str, Any]:
    """Get current circuit breaker state."""
    from ralph_sdk.status import CircuitBreakerState

    cb = CircuitBreakerState.load(ralph_dir)
    return {
        "ok": True,
        "state": cb.state,
        "no_progress_count": cb.no_progress_count,
        "same_error_count": cb.same_error_count,
        "last_error": cb.last_error,
        "opened_at": cb.opened_at,
        "can_proceed": cb.state in ("CLOSED", "HALF_OPEN"),
    }
```

AFTER:
```python
async def ralph_circuit_state_tool(
    ralph_dir: str = ".ralph",
) -> dict[str, Any]:
    """Get current circuit breaker state."""
    from ralph_sdk.status import CircuitBreakerState

    cb = await CircuitBreakerState.aload(ralph_dir)
    return {
        "ok": True,
        "state": cb.state,
        "no_progress_count": cb.no_progress_count,
        "same_error_count": cb.same_error_count,
        "last_error": cb.last_error,
        "opened_at": cb.opened_at,
        "can_proceed": cb.state in ("CLOSED", "HALF_OPEN"),
    }
```

### ralph_task_update_tool

BEFORE (tools.py:134-182):
```python
def ralph_task_update_tool(
    task_description: str,
    completed: bool = False,
    ralph_dir: str = ".ralph",
) -> dict[str, Any]:
    """Update task status in fix_plan.md."""
    fix_plan_path = Path(ralph_dir) / "fix_plan.md"
    if not fix_plan_path.exists():
        return {"ok": False, "error": "fix_plan.md not found"}

    content = fix_plan_path.read_text(encoding="utf-8")
    lines = content.splitlines()
    updated = False

    for i, line in enumerate(lines):
        stripped = line.strip()
        if task_description in stripped:
            if completed:
                lines[i] = line.replace("- [ ]", "- [x]")
            else:
                lines[i] = line.replace("- [x]", "- [ ]")
            updated = True
            break

    if updated:
        fix_plan_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        return {
            "ok": True,
            "task": task_description,
            "completed": completed,
            "message": f"Task {'completed' if completed else 'reopened'}: {task_description}",
        }

    return {
        "ok": False,
        "error": f"Task not found in fix_plan.md: {task_description}",
    }
```

AFTER:
```python
async def ralph_task_update_tool(
    task_description: str,
    completed: bool = False,
    ralph_dir: str = ".ralph",
) -> dict[str, Any]:
    """Update task status in fix_plan.md."""
    import aiofiles

    fix_plan_path = Path(ralph_dir) / "fix_plan.md"
    if not fix_plan_path.exists():
        return {"ok": False, "error": "fix_plan.md not found"}

    async with aiofiles.open(fix_plan_path, encoding="utf-8") as f:
        content = await f.read()
    lines = content.splitlines()
    updated = False

    for i, line in enumerate(lines):
        stripped = line.strip()
        if task_description in stripped:
            if completed:
                lines[i] = line.replace("- [ ]", "- [x]")
            else:
                lines[i] = line.replace("- [x]", "- [ ]")
            updated = True
            break

    if updated:
        async with aiofiles.open(fix_plan_path, "w", encoding="utf-8") as f:
            await f.write("\n".join(lines) + "\n")
        return {
            "ok": True,
            "task": task_description,
            "completed": completed,
            "message": f"Task {'completed' if completed else 'reopened'}: {task_description}",
        }

    return {
        "ok": False,
        "error": f"Task not found in fix_plan.md: {task_description}",
    }
```

### Convert handle_tool_call() to async

**File:** `sdk/ralph_sdk/agent.py`

BEFORE (agent.py:574-595):
```python
    def handle_tool_call(self, tool_name: str, tool_input: dict[str, Any]) -> dict[str, Any]:
        """Dispatch tool calls to appropriate handlers."""
        handlers = {
            "ralph_status": lambda inp: ralph_status_tool(
                ralph_dir=str(self.ralph_dir), **inp
            ),
            "ralph_rate_check": lambda inp: ralph_rate_check_tool(
                ralph_dir=str(self.ralph_dir),
                max_calls_per_hour=self.config.max_calls_per_hour,
            ),
            "ralph_circuit_state": lambda inp: ralph_circuit_state_tool(
                ralph_dir=str(self.ralph_dir),
            ),
            "ralph_task_update": lambda inp: ralph_task_update_tool(
                ralph_dir=str(self.ralph_dir), **inp
            ),
        }

        handler = handlers.get(tool_name)
        if handler:
            return handler(tool_input)
        return {"ok": False, "error": f"Unknown tool: {tool_name}"}
```

AFTER:
```python
    async def handle_tool_call(self, tool_name: str, tool_input: dict[str, Any]) -> dict[str, Any]:
        """Dispatch tool calls to appropriate handlers."""
        handlers = {
            "ralph_status": lambda inp: ralph_status_tool(
                ralph_dir=str(self.ralph_dir), **inp
            ),
            "ralph_rate_check": lambda inp: ralph_rate_check_tool(
                ralph_dir=str(self.ralph_dir),
                max_calls_per_hour=self.config.max_calls_per_hour,
            ),
            "ralph_circuit_state": lambda inp: ralph_circuit_state_tool(
                ralph_dir=str(self.ralph_dir),
            ),
            "ralph_task_update": lambda inp: ralph_task_update_tool(
                ralph_dir=str(self.ralph_dir), **inp
            ),
        }

        handler = handlers.get(tool_name)
        if handler:
            return await handler(tool_input)
        return {"ok": False, "error": f"Unknown tool: {tool_name}"}
```

## Acceptance Criteria

- [ ] `ralph_status_tool` is `async def` and uses `await RalphStatus.aload()` / `await status.asave()`
- [ ] `ralph_rate_check_tool` is `async def` and uses `aiofiles.open()` for file reads
- [ ] `ralph_circuit_state_tool` is `async def` and uses `await CircuitBreakerState.aload()`
- [ ] `ralph_task_update_tool` is `async def` and uses `aiofiles.open()` for read and write
- [ ] `handle_tool_call()` is `async def` and uses `await handler(tool_input)`
- [ ] No `Path.read_text()` or `Path.write_text()` in any tool handler
- [ ] RALPH_TOOLS list still contains correct handler references
- [ ] Return types and return values unchanged for all four tools

## Test Plan

- **ralph_status_tool**: Call `await ralph_status_tool(work_type="TESTING", ...)` with a
  tmp .ralph dir. Verify status.json is written with correct fields.
- **ralph_rate_check_tool**: Write `.call_count` and `.last_reset` files, call
  `await ralph_rate_check_tool(...)`, verify returned dict has correct `calls_used`,
  `calls_remaining`, and `rate_limited` values.
- **ralph_circuit_state_tool**: Write a `.circuit_breaker_state` file with `state: "OPEN"`.
  Call `await ralph_circuit_state_tool(...)`, verify `can_proceed` is `False`.
- **ralph_task_update_tool**: Create fix_plan.md with `- [ ] Implement feature`. Call
  `await ralph_task_update_tool(task_description="Implement feature", completed=True)`.
  Re-read file and verify `- [x] Implement feature`.
- **handle_tool_call dispatch**: Call `await agent.handle_tool_call("ralph_status", {...})`,
  verify correct tool is invoked and result returned.
- **handle_tool_call unknown**: Call `await agent.handle_tool_call("unknown_tool", {})`,
  verify `{"ok": False, "error": "Unknown tool: unknown_tool"}` returned.
