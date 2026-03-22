# Story RALPH-SDK-STATE-5: Remove direct file I/O from agent.py

**Epic:** [Pluggable State Backend](epic-sdk-state-backend.md)
**Priority:** High
**Status:** Pending
**Effort:** Medium
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

After Story 4 wires `self.state_backend` into `RalphAgent`, the agent still bypasses it
entirely -- every method continues to use `Path.read_text()` / `Path.write_text()` and
direct calls to `RalphStatus.load()` / `CircuitBreakerState.load()`. The state backend
is present but unused.

The following methods in `agent.py` contain direct file I/O that must be replaced:

| Method | Current file I/O | Backend method to use |
|--------|------------------|-----------------------|
| `_load_session()` | `session_file.read_text()` | `state_backend.load_session_id()` |
| `_save_session()` | `session_file.write_text()` | `state_backend.save_session_id()` |
| `_increment_call_count()` | reads/writes `.call_count` and `.last_reset` | `state_backend.increment_call_count()` |
| `run()` | `CircuitBreakerState.load()` / `.save()` for reset | `state_backend.load_circuit_breaker()` / `.save_circuit_breaker()` |
| `run_iteration()` | `status.save()` | `state_backend.save_status()` |
| `check_rate_limit()` | calls `ralph_rate_check_tool()` which reads files | `state_backend.get_call_count()` (or keep tool, see below) |
| `check_circuit_breaker()` | calls `ralph_circuit_state_tool()` which reads files | `state_backend.load_circuit_breaker()` (or keep tool, see below) |

## Solution

Replace all direct `Path.read_text()` / `Path.write_text()` calls in `agent.py` with
corresponding `self.state_backend.*` method calls. Since the backend methods are `async`,
this requires wrapping them with `asyncio.run()` or converting the calling methods to
coroutines.

**Approach for async bridging (pre-Epic 4):** Use a helper that detects whether there is
a running event loop. If not, use `asyncio.run()`. If so, schedule the coroutine. This
keeps the public API synchronous in v1.4.0 while the backend methods are async-ready.

```python
import asyncio

def _run_async(coro):
    """Bridge async backend calls into the sync agent methods."""
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return asyncio.run(coro)
    # If already in an async context, create a task
    # (this path is used when the agent is embedded in an async framework)
    import concurrent.futures
    with concurrent.futures.ThreadPoolExecutor() as pool:
        return loop.run_in_executor(pool, asyncio.run, coro)
```

Alternatively, since `FileStateBackend` and `NullStateBackend` both use synchronous I/O
under their `async def` wrappers, a simpler approach is:

```python
def _run_async(coro):
    """Run an async backend method synchronously."""
    return asyncio.run(coro)
```

The simpler approach is preferred for v1.4.0 since the agent's `run()` method is
synchronous and there is no ambient event loop.

## Implementation

### 1. Add async bridge helper

Add `_run_async` as a module-level function or private method in `agent.py`.

### 2. Replace `_load_session()`

**Before:**
```python
def _load_session(self) -> None:
    session_file = self.ralph_dir / ".claude_session_id"
    if session_file.exists():
        try:
            self.session_id = session_file.read_text().strip()
        except OSError:
            pass
```

**After:**
```python
def _load_session(self) -> None:
    self.session_id = _run_async(self.state_backend.load_session_id())
```

### 3. Replace `_save_session()`

**Before:**
```python
def _save_session(self) -> None:
    session_file = self.ralph_dir / ".claude_session_id"
    try:
        session_file.write_text(self.session_id + "\n")
    except OSError:
        pass
```

**After:**
```python
def _save_session(self) -> None:
    _run_async(self.state_backend.save_session_id(self.session_id))
```

### 4. Replace `_increment_call_count()`

**Before:** 25 lines of direct `.call_count` / `.last_reset` file I/O.

**After:**
```python
def _increment_call_count(self) -> None:
    _run_async(self.state_backend.increment_call_count())
```

### 5. Replace circuit breaker reset in `run()`

**Before:**
```python
cb = CircuitBreakerState.load(str(self.ralph_dir))
cb.no_progress_count = 0
cb.same_error_count = 0
cb.save(str(self.ralph_dir))
```

**After:**
```python
cb = _run_async(self.state_backend.load_circuit_breaker())
cb.no_progress_count = 0
cb.same_error_count = 0
_run_async(self.state_backend.save_circuit_breaker(cb))
```

### 6. Replace `status.save()` in `run_iteration()`

**Before:**
```python
status.save(str(self.ralph_dir))
```

**After:**
```python
_run_async(self.state_backend.save_status(status))
```

(Apply to both the success path and the timeout path in `run_iteration()`.)

### 7. Rate limit and circuit breaker checks

`check_rate_limit()` and `check_circuit_breaker()` currently delegate to tool functions
in `tools.py` that do their own file I/O. Two options:

**Option A (minimal):** Leave the tool functions unchanged. They are also used by Claude
as registered tools, so their file I/O is intentional. The agent's `check_rate_limit()`
and `check_circuit_breaker()` continue to call the tools.

**Option B (complete):** Replace the agent's check methods to use the state backend, and
update the tools to also accept an optional state backend.

**Recommendation:** Option A for v1.4.0. The tools are a separate concern (they serve
the Claude agent, not the Python agent). The direct file I/O removal scope is limited to
`agent.py`'s own methods. Tool refactoring can follow in a later story.

### 8. Remove unused imports

After all replacements, remove `CircuitBreakerState` import from agent.py if it is no
longer directly referenced (it will be accessed through the backend). Keep
`RalphStatus` import since it is used as a return type.

## Acceptance Criteria

- [ ] `_load_session()` uses `self.state_backend.load_session_id()`
- [ ] `_save_session()` uses `self.state_backend.save_session_id()`
- [ ] `_increment_call_count()` uses `self.state_backend.increment_call_count()`
- [ ] Circuit breaker reset in `run()` uses `self.state_backend.load_circuit_breaker()` / `.save_circuit_breaker()`
- [ ] `status.save()` calls in `run_iteration()` replaced with `self.state_backend.save_status()`
- [ ] No `Path.read_text()` or `Path.write_text()` calls remain in `agent.py` for state files
- [ ] `_run_async()` helper bridges async backend calls to sync agent methods
- [ ] `RalphAgent()` with default `FileStateBackend` produces identical behavior
- [ ] `RalphAgent(state_backend=NullStateBackend())` runs without filesystem errors
- [ ] Existing tests pass without modification

## Test Plan

- **File backend parity**: Run `RalphAgent` with `FileStateBackend` (default). Execute a dry-run loop. Compare `.ralph/status.json`, `.call_count`, `.claude_session_id` against expected content. Output must be identical to pre-refactor behavior.
- **Null backend isolation**: Run `RalphAgent(state_backend=NullStateBackend())` with dry-run mode. Verify loop completes successfully. Verify no state files are created in `.ralph/` (only the directory and `logs/` subdirectory exist, which are created by `__init__`, not by state operations).
- **Session round-trip via backend**: Start agent, trigger `_save_session()` with a known session ID. Create a new agent with the same `FileStateBackend` path. Call `_load_session()`. Verify session ID is recovered.
- **Call count via backend**: Start agent, call `_increment_call_count()` three times. Read `.call_count` file. Verify it contains `"3\n"`.
- **Circuit breaker via backend**: Start agent, modify circuit breaker via `state_backend.save_circuit_breaker()`. Verify `check_circuit_breaker()` reflects the updated state (this tests that the tool and backend are reading the same file).
- **No direct Path I/O audit**: `grep -n "read_text\|write_text" sdk/ralph_sdk/agent.py` returns zero matches for state file operations (TaskInput file reads in `from_ralph_dir()` are excluded from scope since they are task content, not state).
