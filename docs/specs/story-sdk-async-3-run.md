# Story RALPH-SDK-ASYNC-3: Convert RalphAgent.run() to Async

**Epic:** [Async SDK](epic-sdk-async.md)
**Priority:** Critical
**Status:** Done
**Effort:** Medium
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

`RalphAgent.run()` (agent.py:175) is the main loop entry point. It is a synchronous method
that calls other synchronous methods (`check_rate_limit()`, `check_circuit_breaker()`,
`run_iteration()`, `should_exit()`) and uses `time.sleep(2)`. When embedded in TheStudio's
async runtime, this blocks the event loop for the entire duration of the autonomous loop
(potentially hours).

This story converts `run()` to `async def run()`. Internal calls to methods that will be
made async in subsequent stories (ASYNC-4 through ASYNC-6) are awaited. The method
signature change is the foundation that all other async stories depend on.

## Solution

Change `def run()` to `async def run()`. Add `await` to all internal calls that will
become async: `self.check_rate_limit()`, `self.check_circuit_breaker()`,
`self.run_iteration()`, `self.should_exit()`, and `time.sleep()` (replaced with
`asyncio.sleep()`). The `while` loop structure and exception handling are preserved.

## Implementation

**File:** `sdk/ralph_sdk/agent.py`

### Add asyncio import

BEFORE:
```python
import subprocess
import sys
import time
```

AFTER:
```python
import asyncio
import subprocess
import sys
import time
```

### Convert run() to async

BEFORE (agent.py:175-259):
```python
def run(self) -> TaskResult:
    """Execute the autonomous loop until exit conditions are met.

    Replicates ralph_loop.sh main() function:
    1. Load config
    2. Validate prerequisites
    3. Loop: invoke → parse → check exit → repeat
    """
    self.start_time = time.time()
    self._running = True

    logger.info("Ralph SDK starting (v%s)", self.config.model)
    logger.info("Project: %s (%s)", self.config.project_name, self.config.project_type)

    # Load session
    self._load_session()

    # Reset circuit breaker counters (matching bash behavior)
    cb = CircuitBreakerState.load(str(self.ralph_dir))
    cb.no_progress_count = 0
    cb.same_error_count = 0
    cb.save(str(self.ralph_dir))

    result = TaskResult()

    try:
        while self._running:
            self.loop_count += 1
            logger.info("Loop iteration %d", self.loop_count)

            # Rate limit check
            if not self.check_rate_limit():
                logger.warning("Rate limit reached, waiting for reset")
                result.error = "Rate limit reached"
                break

            # Circuit breaker check
            if not self.check_circuit_breaker():
                logger.warning("Circuit breaker OPEN, stopping")
                result.error = "Circuit breaker open"
                break

            # Dry run check
            if self.config.dry_run:
                logger.info("Dry run mode — skipping API call")
                status = RalphStatus(
                    status="DRY_RUN",
                    work_type="DRY_RUN",
                    loop_count=self.loop_count,
                )
                status.save(str(self.ralph_dir))
                result.status = status
                break

            # Load task input
            task_input = TaskInput.from_ralph_dir(str(self.ralph_dir))
            if not task_input.prompt and not task_input.fix_plan:
                logger.error("No PROMPT.md or fix_plan.md found")
                result.error = "No task input found"
                break

            # Execute one iteration
            iteration_status = self.run_iteration(task_input)

            # Check exit conditions (dual-condition gate)
            if self.should_exit(iteration_status, self.loop_count):
                logger.info("Exit conditions met after %d loops", self.loop_count)
                result.status = iteration_status
                break

            # Brief pause between iterations
            time.sleep(2)

    except KeyboardInterrupt:
        logger.info("Interrupted by user")
        result.error = "User interrupt"
    except Exception as e:
        logger.exception("Unexpected error in loop")
        result.error = str(e)
    finally:
        self._running = False
        result.loop_count = self.loop_count
        result.duration_seconds = time.time() - self.start_time

    return result
```

AFTER:
```python
async def run(self) -> TaskResult:
    """Execute the autonomous loop until exit conditions are met.

    Replicates ralph_loop.sh main() function:
    1. Load config
    2. Validate prerequisites
    3. Loop: invoke → parse → check exit → repeat
    """
    self.start_time = time.time()
    self._running = True

    logger.info("Ralph SDK starting (v%s)", self.config.model)
    logger.info("Project: %s (%s)", self.config.project_name, self.config.project_type)

    # Load session
    self._load_session()

    # Reset circuit breaker counters (matching bash behavior)
    cb = CircuitBreakerState.load(str(self.ralph_dir))
    cb.no_progress_count = 0
    cb.same_error_count = 0
    cb.save(str(self.ralph_dir))

    result = TaskResult()

    try:
        while self._running:
            self.loop_count += 1
            logger.info("Loop iteration %d", self.loop_count)

            # Rate limit check
            if not await self.check_rate_limit():
                logger.warning("Rate limit reached, waiting for reset")
                result.error = "Rate limit reached"
                break

            # Circuit breaker check
            if not await self.check_circuit_breaker():
                logger.warning("Circuit breaker OPEN, stopping")
                result.error = "Circuit breaker open"
                break

            # Dry run check
            if self.config.dry_run:
                logger.info("Dry run mode — skipping API call")
                status = RalphStatus(
                    status="DRY_RUN",
                    work_type="DRY_RUN",
                    loop_count=self.loop_count,
                )
                status.save(str(self.ralph_dir))
                result.status = status
                break

            # Load task input
            task_input = TaskInput.from_ralph_dir(str(self.ralph_dir))
            if not task_input.prompt and not task_input.fix_plan:
                logger.error("No PROMPT.md or fix_plan.md found")
                result.error = "No task input found"
                break

            # Execute one iteration
            iteration_status = await self.run_iteration(task_input)

            # Check exit conditions (dual-condition gate)
            if await self.should_exit(iteration_status, self.loop_count):
                logger.info("Exit conditions met after %d loops", self.loop_count)
                result.status = iteration_status
                break

            # Brief pause between iterations
            await asyncio.sleep(2)

    except KeyboardInterrupt:
        logger.info("Interrupted by user")
        result.error = "User interrupt"
    except Exception as e:
        logger.exception("Unexpected error in loop")
        result.error = str(e)
    finally:
        self._running = False
        result.loop_count = self.loop_count
        result.duration_seconds = time.time() - self.start_time

    return result
```

### Update RalphAgentInterface Protocol

BEFORE:
```python
class RalphAgentInterface(Protocol):
    def run_iteration(self, prompt: str, context: dict[str, Any]) -> RalphStatus: ...
    def should_exit(self, status: RalphStatus, loop_count: int) -> bool: ...
    def check_rate_limit(self) -> bool: ...
    def check_circuit_breaker(self) -> bool: ...
```

AFTER:
```python
class RalphAgentInterface(Protocol):
    async def run_iteration(self, prompt: str, context: dict[str, Any]) -> RalphStatus: ...
    async def should_exit(self, status: RalphStatus, loop_count: int) -> bool: ...
    async def check_rate_limit(self) -> bool: ...
    async def check_circuit_breaker(self) -> bool: ...
```

## Acceptance Criteria

- [ ] `RalphAgent.run()` is `async def run(self) -> TaskResult`
- [ ] `import asyncio` added to agent.py
- [ ] `await` used for `check_rate_limit()`, `check_circuit_breaker()`, `run_iteration()`, `should_exit()`
- [ ] `time.sleep(2)` replaced with `await asyncio.sleep(2)` (see also ASYNC-6)
- [ ] `RalphAgentInterface` protocol methods updated to async
- [ ] Exception handling (KeyboardInterrupt, Exception) preserved
- [ ] `finally` block preserved (sets `_running = False`, computes duration)
- [ ] `while self._running` loop structure unchanged

## Test Plan

- **Async invocation**: `result = await agent.run()` completes in an async test with dry-run config.
- **Dry run**: Set `config.dry_run = True`, call `await agent.run()`, verify `result.status.status == "DRY_RUN"`.
- **No task input**: Remove PROMPT.md and fix_plan.md, call `await agent.run()`, verify `result.error == "No task input found"`.
- **Loop count**: Verify `result.loop_count >= 1` after a successful run.
- **Duration tracking**: Verify `result.duration_seconds > 0`.
- **Protocol conformance**: Verify `RalphAgent` still satisfies `RalphAgentInterface` (mypy check).
