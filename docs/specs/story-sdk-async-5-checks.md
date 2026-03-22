# Story RALPH-SDK-ASYNC-5: Convert should_exit, check_rate_limit, check_circuit_breaker to Async

**Epic:** [Async SDK](epic-sdk-async.md)
**Priority:** High
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

`check_rate_limit()` (agent.py:346) and `check_circuit_breaker()` (agent.py:354) call tool
handler functions that read state files. After ASYNC-2 makes the state backend async, these
methods must also be async to await the backend calls. `should_exit()` (agent.py:320) does
not directly read files, but `run()` (ASYNC-3) already awaits it, so it must be async to
match the protocol signature.

Additionally, the tool functions called by these methods (`ralph_rate_check_tool`,
`ralph_circuit_state_tool`) currently do synchronous file reads internally. While ASYNC-8
converts the tool handlers themselves, this story ensures the agent methods that call them
are async-ready.

## Solution

Convert all three methods to `async def`. The internal logic is unchanged -- the only
difference is the `async` keyword and `await` on any calls that become async in other
stories. `should_exit()` has no I/O calls, but becomes async for protocol consistency.

## Implementation

**File:** `sdk/ralph_sdk/agent.py`

### Convert should_exit() to async

BEFORE (agent.py:320-344):
```python
def should_exit(self, status: RalphStatus, loop_count: int) -> bool:
    """Dual-condition exit gate (matching bash implementation).

    Requires BOTH:
    1. completion_indicators >= 2 (NLP heuristics)
    2. EXIT_SIGNAL: true (explicit from Claude)
    """
    if status.exit_signal:
        self._completion_indicators += 1

    # Check for completion phrases in progress summary
    completion_phrases = [
        "all tasks complete",
        "all tasks done",
        "nothing left",
        "no remaining tasks",
        "work is complete",
        "all items checked",
    ]
    summary_lower = status.progress_summary.lower()
    if any(phrase in summary_lower for phrase in completion_phrases):
        self._completion_indicators += 1

    # Dual condition: need both indicators and explicit exit signal
    return self._completion_indicators >= 2 and status.exit_signal
```

AFTER:
```python
async def should_exit(self, status: RalphStatus, loop_count: int) -> bool:
    """Dual-condition exit gate (matching bash implementation).

    Requires BOTH:
    1. completion_indicators >= 2 (NLP heuristics)
    2. EXIT_SIGNAL: true (explicit from Claude)
    """
    if status.exit_signal:
        self._completion_indicators += 1

    # Check for completion phrases in progress summary
    completion_phrases = [
        "all tasks complete",
        "all tasks done",
        "nothing left",
        "no remaining tasks",
        "work is complete",
        "all items checked",
    ]
    summary_lower = status.progress_summary.lower()
    if any(phrase in summary_lower for phrase in completion_phrases):
        self._completion_indicators += 1

    # Dual condition: need both indicators and explicit exit signal
    return self._completion_indicators >= 2 and status.exit_signal
```

### Convert check_rate_limit() to async

BEFORE (agent.py:346-352):
```python
def check_rate_limit(self) -> bool:
    """Check if within rate limits."""
    result = ralph_rate_check_tool(
        ralph_dir=str(self.ralph_dir),
        max_calls_per_hour=self.config.max_calls_per_hour,
    )
    return not result["rate_limited"]
```

AFTER:
```python
async def check_rate_limit(self) -> bool:
    """Check if within rate limits."""
    result = await ralph_rate_check_tool(
        ralph_dir=str(self.ralph_dir),
        max_calls_per_hour=self.config.max_calls_per_hour,
    )
    return not result["rate_limited"]
```

### Convert check_circuit_breaker() to async

BEFORE (agent.py:354-357):
```python
def check_circuit_breaker(self) -> bool:
    """Check circuit breaker — returns True if OK to proceed."""
    result = ralph_circuit_state_tool(ralph_dir=str(self.ralph_dir))
    return result["can_proceed"]
```

AFTER:
```python
async def check_circuit_breaker(self) -> bool:
    """Check circuit breaker — returns True if OK to proceed."""
    result = await ralph_circuit_state_tool(ralph_dir=str(self.ralph_dir))
    return result["can_proceed"]
```

Note: The `await` on tool functions takes effect after ASYNC-8 converts them to async.
During the transition, if ASYNC-5 is implemented before ASYNC-8, the tool functions remain
synchronous and the `await` on a non-coroutine will cause a TypeError. Therefore, ASYNC-5
and ASYNC-8 should be implemented together, or ASYNC-8 should be completed first.

## Acceptance Criteria

- [ ] `should_exit()` is `async def should_exit(self, ...) -> bool`
- [ ] `check_rate_limit()` is `async def check_rate_limit(self) -> bool`
- [ ] `check_circuit_breaker()` is `async def check_circuit_breaker(self) -> bool`
- [ ] `check_rate_limit()` uses `await` when calling `ralph_rate_check_tool()`
- [ ] `check_circuit_breaker()` uses `await` when calling `ralph_circuit_state_tool()`
- [ ] Dual-condition exit gate logic in `should_exit()` is unchanged
- [ ] NLP completion phrase matching is unchanged
- [ ] `RalphAgentInterface` protocol updated (done in ASYNC-3)

## Test Plan

- **should_exit with indicators**: Create status with `exit_signal=True` and
  `progress_summary="all tasks complete"`. Call `await agent.should_exit(status, 1)` twice
  (to accumulate indicators). Verify returns `True` on the second call.
- **should_exit without signal**: Status with `exit_signal=False`. Verify returns `False`
  regardless of progress summary content.
- **check_rate_limit OK**: Set up state with 5 calls used, max 100. Verify
  `await agent.check_rate_limit()` returns `True`.
- **check_rate_limit exceeded**: Set up state with 100 calls used, max 100. Verify
  `await agent.check_rate_limit()` returns `False`.
- **check_circuit_breaker closed**: Default state (CLOSED). Verify
  `await agent.check_circuit_breaker()` returns `True`.
- **check_circuit_breaker open**: Trip the circuit breaker. Verify
  `await agent.check_circuit_breaker()` returns `False`.
