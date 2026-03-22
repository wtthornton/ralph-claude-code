# Story RALPH-SDK-CORR-2: Add correlation_id Field to TaskResult and RalphStatusBlock

**Epic:** [Correlation ID Threading](epic-sdk-correlation-id.md)
**Priority:** High
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`, `sdk/ralph_sdk/status.py`

---

## Problem

The `TaskResult` dataclass (agent.py, lines 114-134) and `RalphStatus` dataclass (status.py, lines 14-60) have no `correlation_id` field. When a result is returned to TheStudio or written to status.json, there is no way to trace it back to the originating request.

Note: The epic references "RalphStatusBlock" — this corresponds to the existing `RalphStatus` dataclass in `status.py`, which represents the status block written to `status.json`.

## Solution

Add an optional `correlation_id: str` field to both `TaskResult` and `RalphStatus`. The field defaults to empty string for backward compatibility — existing code that does not set it continues to work. The agent loop populates it from `self.correlation_id` after CORR-1.

## Implementation

### Step 1: Add correlation_id to RalphStatus

```python
# status.py
@dataclass
class RalphStatus:
    """Structured status compatible with on-stop.sh -> status.json format."""

    work_type: str = "UNKNOWN"
    completed_task: str = ""
    next_task: str = ""
    progress_summary: str = ""
    exit_signal: bool = False
    status: str = "IN_PROGRESS"
    timestamp: str = ""
    loop_count: int = 0
    session_id: str = ""
    circuit_breaker_state: str = "CLOSED"
    error: str = ""
    correlation_id: str = ""  # NEW: trace ID for request correlation
```

### Step 2: Update RalphStatus.to_dict()

```python
def to_dict(self) -> dict[str, Any]:
    """Export as dictionary matching status.json schema."""
    d = {
        "WORK_TYPE": self.work_type,
        # ... existing fields ...
        "error": self.error,
    }
    # Only include correlation_id if set (backward compatible)
    if self.correlation_id:
        d["correlation_id"] = self.correlation_id
    return d
```

### Step 3: Update RalphStatus.from_dict()

```python
@classmethod
def from_dict(cls, data: dict[str, Any]) -> RalphStatus:
    """Create from status.json dictionary."""
    return cls(
        # ... existing fields ...
        error=data.get("error", ""),
        correlation_id=data.get("correlation_id", ""),
    )
```

### Step 4: Add correlation_id to TaskResult

```python
# agent.py
@dataclass
class TaskResult:
    """Output compatible with status.json and TheStudio signals."""
    status: RalphStatus = field(default_factory=RalphStatus)
    exit_code: int = 0
    output: str = ""
    error: str = ""
    loop_count: int = 0
    duration_seconds: float = 0.0
    correlation_id: str = ""  # NEW: trace ID for request correlation
```

### Step 5: Update TaskResult.to_signal()

```python
def to_signal(self) -> dict[str, Any]:
    """Convert to TheStudio-compatible signal format."""
    signal = {
        "type": "ralph_result",
        "task_result": self.status.to_dict(),
        "exit_code": self.exit_code,
        "output": self.output,
        "error": self.error,
        "loop_count": self.loop_count,
        "duration_seconds": self.duration_seconds,
    }
    if self.correlation_id:
        signal["correlation_id"] = self.correlation_id
    return signal
```

### Step 6: Populate from agent loop

In `RalphAgent.run()`, set the correlation_id on results:

```python
# In run_iteration():
status.correlation_id = str(self.correlation_id)

# In run():
result.correlation_id = str(self.correlation_id)
```

## Design Notes

- **String type, not UUID**: The field is `str` (not `UUID`) because it's serialized to JSON. Using `str` avoids import and serialization complexity in dataclasses.
- **Optional for backward compatibility**: Defaults to empty string. The `to_dict()` method omits it when empty, so existing status.json consumers are unaffected.
- **Bash loop unaffected**: The bash loop reads status.json via `jq`. An extra `correlation_id` field in status.json is harmless — `jq` queries for specific fields and ignores extras.

## Acceptance Criteria

- [ ] `RalphStatus.correlation_id` field exists, defaults to empty string
- [ ] `RalphStatus.to_dict()` includes `correlation_id` when set
- [ ] `RalphStatus.from_dict()` reads `correlation_id` from data
- [ ] `TaskResult.correlation_id` field exists, defaults to empty string
- [ ] `TaskResult.to_signal()` includes `correlation_id` when set
- [ ] Agent loop sets `correlation_id` on `RalphStatus` and `TaskResult`
- [ ] Omitted from JSON output when empty (backward compatible)
- [ ] Existing tests pass without modification

## Test Plan

```python
def test_ralph_status_correlation_id_default():
    """Default correlation_id is empty string."""
    status = RalphStatus()
    assert status.correlation_id == ""

def test_ralph_status_to_dict_omits_empty_correlation():
    """to_dict() omits correlation_id when empty."""
    status = RalphStatus()
    d = status.to_dict()
    assert "correlation_id" not in d

def test_ralph_status_to_dict_includes_correlation():
    """to_dict() includes correlation_id when set."""
    status = RalphStatus(correlation_id="abc-123")
    d = status.to_dict()
    assert d["correlation_id"] == "abc-123"

def test_ralph_status_from_dict_with_correlation():
    """from_dict() reads correlation_id."""
    status = RalphStatus.from_dict({"correlation_id": "xyz-789"})
    assert status.correlation_id == "xyz-789"

def test_ralph_status_from_dict_without_correlation():
    """from_dict() defaults correlation_id to empty."""
    status = RalphStatus.from_dict({})
    assert status.correlation_id == ""

def test_task_result_correlation_id():
    """TaskResult includes correlation_id in signal."""
    result = TaskResult(correlation_id="test-id")
    signal = result.to_signal()
    assert signal["correlation_id"] == "test-id"

def test_task_result_signal_omits_empty_correlation():
    """TaskResult omits correlation_id from signal when empty."""
    result = TaskResult()
    signal = result.to_signal()
    assert "correlation_id" not in signal
```
