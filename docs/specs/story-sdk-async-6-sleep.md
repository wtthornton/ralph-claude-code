# Story RALPH-SDK-ASYNC-6: Replace time.sleep with asyncio.sleep

**Epic:** [Async SDK](epic-sdk-async.md)
**Priority:** High
**Status:** Pending
**Effort:** Trivial
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

`time.sleep(2)` at agent.py:246 blocks the entire thread for 2 seconds between loop
iterations. In an async context, this prevents all other coroutines from executing during
the pause. While 2 seconds is short, it compounds across many iterations and is
incompatible with cooperative async scheduling.

## Solution

Replace `time.sleep(2)` with `await asyncio.sleep(2)`. This is a single-line change.
The `asyncio` import is already added by ASYNC-3.

## Implementation

**File:** `sdk/ralph_sdk/agent.py`

BEFORE (agent.py:246):
```python
            # Brief pause between iterations
            time.sleep(2)
```

AFTER:
```python
            # Brief pause between iterations
            await asyncio.sleep(2)
```

Note: This change is included in the ASYNC-3 BEFORE/AFTER diff as well, since ASYNC-3
converts the entire `run()` method. This story exists as a separate tracking item because
the sleep replacement is independently testable and verifiable. If ASYNC-3 is implemented
first, this story is automatically satisfied.

### Optional: Remove time import if unused

After all async conversions, check if `time` is still used elsewhere in agent.py.
`time.time()` is used in `__init__`, `run()`, `_increment_call_count()`, and
`_log_output()`, so the `import time` must remain.

## Acceptance Criteria

- [ ] No `time.sleep()` calls exist in agent.py
- [ ] `await asyncio.sleep(2)` used for inter-iteration pause
- [ ] `import asyncio` present (added by ASYNC-3)
- [ ] `import time` retained (still needed for `time.time()` and `time.strftime()`)
- [ ] Sleep duration unchanged (2 seconds)

## Test Plan

- **Non-blocking verification**: In an async test, start `agent.run()` as a task, and
  concurrently run a second coroutine that completes in <1 second. Verify the second
  coroutine completes while the agent is in its sleep pause (proving `asyncio.sleep` yields
  control).
- **Grep verification**: `grep -rn "time.sleep" sdk/ralph_sdk/agent.py` returns no matches.
- **Grep verification**: `grep -rn "asyncio.sleep" sdk/ralph_sdk/agent.py` returns exactly
  one match at the inter-iteration pause line.
