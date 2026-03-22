# Story RALPH-SDK-ASYNC-4: Convert run_iteration() to Async Subprocess

**Epic:** [Async SDK](epic-sdk-async.md)
**Priority:** Critical
**Status:** Done
**Effort:** Medium
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

`RalphAgent.run_iteration()` (agent.py:261) calls `subprocess.run()` which blocks the
event loop for the entire duration of a Claude CLI invocation (potentially 10+ minutes per
iteration). This is the single most impactful blocking call in the SDK. While blocked, no
other async tasks can execute, cancellation signals are ignored, and TheStudio's health
checks will time out.

## Solution

Replace `subprocess.run()` with `asyncio.create_subprocess_exec()` and use
`asyncio.wait_for()` for timeout handling. On timeout, explicitly kill the subprocess with
`proc.kill()` and `await proc.wait()` to prevent zombie processes. The `FileNotFoundError`
handling for missing Claude CLI is preserved.

## Implementation

**File:** `sdk/ralph_sdk/agent.py`

### Convert run_iteration() to async

BEFORE (agent.py:261-318):
```python
def run_iteration(self, task_input: TaskInput | None = None) -> RalphStatus:
    """Execute a single loop iteration via Claude Code CLI.

    Matches ralph_loop.sh behavior: builds command, invokes CLI,
    parses JSONL response, extracts status.
    """
    if task_input is None:
        task_input = TaskInput.from_ralph_dir(str(self.ralph_dir))

    # Build the prompt for this iteration
    prompt = self._build_iteration_prompt(task_input)

    # Build Claude CLI command
    cmd = self._build_claude_command(prompt)

    logger.debug("Invoking: %s", " ".join(cmd[:5]) + "...")

    # Execute Claude CLI
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=self.config.timeout_minutes * 60,
            cwd=str(self.project_dir),
        )

        # Increment call count
        self._increment_call_count()

        # Parse response
        status = self._parse_response(result.stdout, result.returncode)
        status.loop_count = self.loop_count
        status.session_id = self.session_id
        status.save(str(self.ralph_dir))

        # Log output
        self._log_output(result.stdout, result.stderr, self.loop_count)

        return status

    except subprocess.TimeoutExpired:
        logger.warning("Claude CLI timed out after %d minutes", self.config.timeout_minutes)
        status = RalphStatus(
            status="TIMEOUT",
            work_type="UNKNOWN",
            error=f"Timeout after {self.config.timeout_minutes} minutes",
            loop_count=self.loop_count,
        )
        status.save(str(self.ralph_dir))
        return status

    except FileNotFoundError:
        logger.error("Claude CLI not found: %s", self.config.claude_code_cmd)
        return RalphStatus(
            status="ERROR",
            error=f"Claude CLI not found: {self.config.claude_code_cmd}",
        )
```

AFTER:
```python
async def run_iteration(self, task_input: TaskInput | None = None) -> RalphStatus:
    """Execute a single loop iteration via Claude Code CLI.

    Matches ralph_loop.sh behavior: builds command, invokes CLI,
    parses JSONL response, extracts status.

    Uses asyncio.create_subprocess_exec for non-blocking execution and
    asyncio.wait_for for cooperative timeout handling.
    """
    if task_input is None:
        task_input = TaskInput.from_ralph_dir(str(self.ralph_dir))

    # Build the prompt for this iteration
    prompt = self._build_iteration_prompt(task_input)

    # Build Claude CLI command
    cmd = self._build_claude_command(prompt)

    logger.debug("Invoking: %s", " ".join(cmd[:5]) + "...")

    # Execute Claude CLI (async)
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(self.project_dir),
        )

        try:
            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                proc.communicate(),
                timeout=self.config.timeout_minutes * 60,
            )
        except asyncio.TimeoutError:
            logger.warning("Claude CLI timed out after %d minutes", self.config.timeout_minutes)
            proc.kill()
            await proc.wait()
            status = RalphStatus(
                status="TIMEOUT",
                work_type="UNKNOWN",
                error=f"Timeout after {self.config.timeout_minutes} minutes",
                loop_count=self.loop_count,
            )
            status.save(str(self.ralph_dir))
            return status

        stdout = stdout_bytes.decode("utf-8", errors="replace")
        stderr = stderr_bytes.decode("utf-8", errors="replace")

        # Increment call count
        self._increment_call_count()

        # Parse response
        status = self._parse_response(stdout, proc.returncode or 0)
        status.loop_count = self.loop_count
        status.session_id = self.session_id
        status.save(str(self.ralph_dir))

        # Log output
        self._log_output(stdout, stderr, self.loop_count)

        return status

    except FileNotFoundError:
        logger.error("Claude CLI not found: %s", self.config.claude_code_cmd)
        return RalphStatus(
            status="ERROR",
            error=f"Claude CLI not found: {self.config.claude_code_cmd}",
        )
```

### Remove subprocess import (if no other usages remain)

BEFORE:
```python
import subprocess
```

AFTER:
```python
# subprocess import removed — replaced by asyncio.create_subprocess_exec
```

Note: Verify no other code in agent.py uses `subprocess` before removing the import.

## Acceptance Criteria

- [ ] `run_iteration()` is `async def run_iteration(self, ...) -> RalphStatus`
- [ ] Uses `asyncio.create_subprocess_exec()` instead of `subprocess.run()`
- [ ] Uses `asyncio.wait_for(proc.communicate(), timeout=...)` for timeout
- [ ] On `asyncio.TimeoutError`: calls `proc.kill()` then `await proc.wait()`
- [ ] Decodes stdout/stderr bytes to str with `errors="replace"`
- [ ] `FileNotFoundError` handling preserved for missing Claude CLI
- [ ] `proc.returncode` used instead of `result.returncode`
- [ ] No `subprocess.run()` calls remain in agent.py
- [ ] `_parse_response()`, `_increment_call_count()`, `_log_output()` still called correctly

## Test Plan

- **Normal execution**: Mock `asyncio.create_subprocess_exec` to return a process with
  known stdout. Verify `await agent.run_iteration(task_input)` returns parsed `RalphStatus`.
- **Timeout handling**: Mock process to hang, set `timeout_minutes=0.001`. Verify
  `asyncio.TimeoutError` is caught, `proc.kill()` is called, and a TIMEOUT status is returned.
- **Process kill cleanup**: After timeout, verify `proc.wait()` was awaited (no zombie).
- **CLI not found**: Set `claude_code_cmd` to a nonexistent binary. Verify `FileNotFoundError`
  is caught and ERROR status returned.
- **Non-zero exit code**: Mock process with returncode=1. Verify `_parse_response` receives
  returncode=1 and status reflects the error.
- **UTF-8 decode**: Mock process stdout with mixed UTF-8 and invalid bytes. Verify
  `errors="replace"` handles gracefully without exceptions.
