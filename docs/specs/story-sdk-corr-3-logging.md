# Story RALPH-SDK-CORR-3: Thread correlation_id Through All Log Messages

**Epic:** [Correlation ID Threading](epic-sdk-correlation-id.md)
**Priority:** High
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

The SDK's log messages (via `logger = logging.getLogger("ralph.sdk")`) contain no correlation context. When multiple Ralph runs overlap (e.g., in CI pipelines), log messages from different runs are interleaved and indistinguishable. Filtering logs for a specific run requires manual timestamp correlation.

The `correlation_id` added in CORR-1 is stored as an instance attribute but never appears in log output.

## Solution

Add `extra={"correlation_id": str(self.correlation_id)}` to every `logger.info()`, `logger.warning()`, `logger.error()`, and `logger.debug()` call in `agent.py`. This uses Python's standard `extra` dict mechanism:

- **TheStudio's JSON formatter**: Picks up `extra` fields automatically and includes them in structured log output.
- **Standalone Ralph's default formatter**: Ignores `extra` fields — no visual change for CLI users unless they configure a formatter that includes them.

## Implementation

### Step 1: Create a logging helper

Rather than modifying every call site, add a helper that injects the correlation_id:

```python
def _log(self, level: int, msg: str, *args: Any, **kwargs: Any) -> None:
    """Log with correlation_id in extra dict."""
    extra = kwargs.pop("extra", {})
    extra["correlation_id"] = str(self.correlation_id)
    logger.log(level, msg, *args, extra=extra, **kwargs)
```

### Step 2: Update all log calls in RalphAgent

Replace direct `logger.*` calls with `self._log()`:

```python
# Before:
logger.info("Ralph SDK starting (v%s)", self.config.model)
logger.info("Loop iteration %d", self.loop_count)
logger.warning("Rate limit reached, waiting for reset")
logger.warning("Circuit breaker OPEN, stopping")
logger.debug("Invoking: %s", " ".join(cmd[:5]) + "...")
logger.error("No PROMPT.md or fix_plan.md found")
logger.exception("Unexpected error in loop")

# After:
self._log(logging.INFO, "Ralph SDK starting (v%s)", self.config.model)
self._log(logging.INFO, "Loop iteration %d", self.loop_count)
self._log(logging.WARNING, "Rate limit reached, waiting for reset")
self._log(logging.WARNING, "Circuit breaker OPEN, stopping")
self._log(logging.DEBUG, "Invoking: %s", " ".join(cmd[:5]) + "...")
self._log(logging.ERROR, "No PROMPT.md or fix_plan.md found")
# For exception, use logger directly with extra:
logger.exception("Unexpected error in loop",
                 extra={"correlation_id": str(self.correlation_id)})
```

### Step 3: Verify with a custom formatter (optional)

For users who want to see correlation_id in standalone mode:

```python
# Example: configure logging to show correlation_id
import logging
handler = logging.StreamHandler()
handler.setFormatter(logging.Formatter(
    "%(asctime)s [%(correlation_id)s] %(levelname)s %(message)s"
))
logging.getLogger("ralph.sdk").addHandler(handler)
```

## Design Notes

- **Helper method vs direct extra**: A `_log()` helper is cleaner than repeating `extra={"correlation_id": ...}` at every call site. It also provides a single point to add more context in the future (e.g., loop_count, session_id).
- **No changes to circuit_breaker.py**: The `CircuitBreaker` class uses its own logger (`ralph.sdk.circuit_breaker`). It does not have access to the agent's `correlation_id`. If correlation threading is needed there, the `CircuitBreaker` constructor would need to accept a `correlation_id` parameter — this is future work.
- **logger.exception special case**: Python's `logger.exception()` captures the traceback. It must be called at the exception handler level, so we pass `extra` directly rather than using `_log()`.

## Acceptance Criteria

- [ ] Every `logger.info/warning/error/debug` call in `agent.py` includes `correlation_id` in `extra`
- [ ] `_log()` helper method exists on `RalphAgent`
- [ ] `correlation_id` value is `str(self.correlation_id)` (stringified UUID)
- [ ] `logger.exception()` calls include `extra={"correlation_id": ...}`
- [ ] No visual change for standalone CLI users with default formatter
- [ ] JSON formatter picks up `correlation_id` from `extra` field
- [ ] No import changes needed beyond what CORR-1 adds

## Test Plan

```python
import logging

def test_log_messages_include_correlation_id(caplog):
    """All log messages include correlation_id in extra."""
    agent = RalphAgent(config=mock_config, project_dir=tmp_dir)

    with caplog.at_level(logging.DEBUG, logger="ralph.sdk"):
        agent._log(logging.INFO, "test message")

    assert len(caplog.records) == 1
    record = caplog.records[0]
    assert hasattr(record, "correlation_id")
    assert record.correlation_id == str(agent.correlation_id)

def test_log_helper_passes_args():
    """_log() passes format args correctly."""
    agent = RalphAgent(config=mock_config, project_dir=tmp_dir)

    with caplog.at_level(logging.INFO, logger="ralph.sdk"):
        agent._log(logging.INFO, "Loop %d of %d", 1, 10)

    assert "Loop 1 of 10" in caplog.records[0].getMessage()

def test_log_helper_merges_extra():
    """_log() merges caller-provided extra with correlation_id."""
    agent = RalphAgent(config=mock_config, project_dir=tmp_dir)

    with caplog.at_level(logging.INFO, logger="ralph.sdk"):
        agent._log(logging.INFO, "test", extra={"custom_key": "value"})

    record = caplog.records[0]
    assert record.correlation_id == str(agent.correlation_id)
    assert record.custom_key == "value"

def test_default_formatter_no_error():
    """Default formatter does not crash on extra fields."""
    agent = RalphAgent(config=mock_config, project_dir=tmp_dir)
    # This should not raise even with default formatter
    agent._log(logging.INFO, "safe message")
```
