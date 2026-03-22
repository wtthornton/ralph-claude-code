# Story RALPH-SDK-STATE-2: Implement FileStateBackend

**Epic:** [Pluggable State Backend](epic-sdk-state-backend.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Medium
**Component:** `sdk/ralph_sdk/state.py`

---

## Problem

The current file I/O for state persistence is spread across multiple modules:

| Operation | Current location | Files touched |
|-----------|-----------------|---------------|
| Status load/save | `RalphStatus.load()` / `.save()` in `status.py` | `status.json` |
| Circuit breaker load/save | `CircuitBreakerState.load()` / `.save()` in `status.py` | `.circuit_breaker_state` |
| Circuit breaker events | Not yet implemented | `.circuit_breaker_events` |
| Call count read/write/reset | `_increment_call_count()` in `agent.py` | `.call_count`, `.last_reset` |
| Session ID load/save/clear | `_load_session()` / `_save_session()` in `agent.py` | `.claude_session_id` |
| Rate limit check | `ralph_rate_check_tool()` in `tools.py` | `.call_count`, `.last_reset` |
| Metrics | Not yet implemented | `metrics/YYYY-MM.jsonl` |

This code must be consolidated into a single backend class that produces byte-for-byte
compatible output with the current implementations, so the bash loop and existing
`.ralph/` directory contents continue to work without changes.

## Solution

Implement `FileStateBackend` in `sdk/ralph_sdk/state.py` that satisfies the
`RalphStateBackend` protocol. The class wraps all current file I/O behavior,
reading/writing the same `.ralph/` files in the same formats.

All methods are `async def` but initially use synchronous file I/O internally.
The async upgrade to `aiofiles` is deferred to Epic 4 (Async SDK).

## Implementation

Add `FileStateBackend` class to `sdk/ralph_sdk/state.py`:

```python
class FileStateBackend:
    """File-based state backend — default for standalone Ralph.

    Reads/writes the same .ralph/ files as the bash loop.
    All methods are async-compatible but use sync I/O initially.
    """

    def __init__(self, ralph_dir: str | Path = ".ralph") -> None:
        self.ralph_dir = Path(ralph_dir)
        self.ralph_dir.mkdir(parents=True, exist_ok=True)

    # -- Status -----------------------------------------------------------
    async def load_status(self) -> RalphStatus:
        return RalphStatus.load(str(self.ralph_dir))

    async def save_status(self, status: RalphStatus) -> None:
        status.save(str(self.ralph_dir))

    # -- Circuit breaker --------------------------------------------------
    async def load_circuit_breaker(self) -> CircuitBreakerState:
        return CircuitBreakerState.load(str(self.ralph_dir))

    async def save_circuit_breaker(self, cb: CircuitBreakerState) -> None:
        cb.save(str(self.ralph_dir))

    async def record_circuit_event(self, event: dict[str, Any]) -> None:
        events_file = self.ralph_dir / ".circuit_breaker_events"
        line = json.dumps(event) + "\n"
        with open(events_file, "a", encoding="utf-8") as f:
            f.write(line)

    # -- Rate limiting ----------------------------------------------------
    async def get_call_count(self) -> int:
        call_count_file = self.ralph_dir / ".call_count"
        if not call_count_file.exists():
            return 0
        try:
            return int(call_count_file.read_text().strip())
        except (ValueError, OSError):
            return 0

    async def increment_call_count(self) -> int:
        # Mirrors agent.py _increment_call_count() logic:
        # reset counter if hour has elapsed, otherwise increment
        call_count_file = self.ralph_dir / ".call_count"
        last_reset_file = self.ralph_dir / ".last_reset"
        now = int(time.time())
        last_reset = 0
        if last_reset_file.exists():
            try:
                last_reset = int(last_reset_file.read_text().strip())
            except (ValueError, OSError):
                pass
        if now - last_reset >= 3600:
            call_count_file.write_text("1\n")
            last_reset_file.write_text(f"{now}\n")
            return 1
        count = 0
        if call_count_file.exists():
            try:
                count = int(call_count_file.read_text().strip())
            except (ValueError, OSError):
                pass
        new_count = count + 1
        call_count_file.write_text(f"{new_count}\n")
        return new_count

    async def reset_call_count(self) -> None:
        call_count_file = self.ralph_dir / ".call_count"
        last_reset_file = self.ralph_dir / ".last_reset"
        now = int(time.time())
        call_count_file.write_text("0\n")
        last_reset_file.write_text(f"{now}\n")

    # -- Session ----------------------------------------------------------
    async def load_session_id(self) -> str:
        session_file = self.ralph_dir / ".claude_session_id"
        if not session_file.exists():
            return ""
        try:
            return session_file.read_text().strip()
        except OSError:
            return ""

    async def save_session_id(self, session_id: str) -> None:
        session_file = self.ralph_dir / ".claude_session_id"
        session_file.write_text(session_id + "\n")

    async def clear_session_id(self) -> None:
        session_file = self.ralph_dir / ".claude_session_id"
        session_file.unlink(missing_ok=True)

    # -- Metrics ----------------------------------------------------------
    async def record_metric(self, metric: dict[str, Any]) -> None:
        metrics_dir = self.ralph_dir / "metrics"
        metrics_dir.mkdir(exist_ok=True)
        month = time.strftime("%Y-%m")
        metrics_file = metrics_dir / f"{month}.jsonl"
        line = json.dumps(metric) + "\n"
        with open(metrics_file, "a", encoding="utf-8") as f:
            f.write(line)
```

Key compatibility requirements:
- `save_status` must use the same atomic write pattern (write to `.tmp`, then `replace()`) as `RalphStatus.save()` -- delegated to the existing method.
- `save_circuit_breaker` must use the same atomic write pattern as `CircuitBreakerState.save()` -- delegated to the existing method.
- `increment_call_count` must replicate the exact hourly-reset logic from `agent.py:_increment_call_count()`.
- `save_session_id` must write `session_id + "\n"` (trailing newline) matching `agent.py:_save_session()`.
- Call count files must contain a single integer followed by `"\n"`.

## Acceptance Criteria

- [ ] `FileStateBackend` class added to `sdk/ralph_sdk/state.py`
- [ ] Constructor accepts `ralph_dir` parameter, creates directory if missing
- [ ] All 12 protocol methods implemented as `async def`
- [ ] `load_status` / `save_status` delegate to `RalphStatus.load()` / `.save()`
- [ ] `load_circuit_breaker` / `save_circuit_breaker` delegate to `CircuitBreakerState.load()` / `.save()`
- [ ] `record_circuit_event` appends JSONL to `.circuit_breaker_events`
- [ ] `increment_call_count` replicates hourly-reset logic from `agent.py`
- [ ] `load_session_id` / `save_session_id` / `clear_session_id` match current file format
- [ ] `record_metric` appends JSONL to `metrics/YYYY-MM.jsonl`
- [ ] Output is byte-for-byte compatible with current `status.py` and `agent.py` file writes
- [ ] Atomic write patterns preserved for status.json and circuit breaker state

## Test Plan

- **Round-trip status**: Create `FileStateBackend`, call `save_status(status)` then `load_status()`. Verify returned `RalphStatus` matches the original.
- **Round-trip circuit breaker**: Save and load `CircuitBreakerState`. Verify all fields match.
- **Increment counter**: Call `increment_call_count()` three times. Verify `get_call_count()` returns 3. Verify `.call_count` file contains `"3\n"`.
- **Hourly reset**: Set `.last_reset` to 4000 seconds ago. Call `increment_call_count()`. Verify counter resets to 1 and `.last_reset` is updated.
- **Session persistence**: Save session ID `"abc-123"`, load it back, verify match. Clear it, verify `load_session_id()` returns `""`.
- **Circuit event append**: Record two events. Read `.circuit_breaker_events`, verify two JSONL lines.
- **Metric append**: Record a metric. Verify `metrics/YYYY-MM.jsonl` contains exactly one line.
- **Bash compatibility**: Write status via `FileStateBackend`, read `status.json` with `json.loads()` directly. Verify output matches the dict produced by `RalphStatus.to_dict()`.
- **Directory creation**: Initialize `FileStateBackend` with a non-existent path. Verify directory is created.
