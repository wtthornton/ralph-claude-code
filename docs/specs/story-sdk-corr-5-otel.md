# Story RALPH-SDK-CORR-5: Optional OpenTelemetry Span Attributes

**Epic:** [Correlation ID Threading](epic-sdk-correlation-id.md)
**Priority:** Medium
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

TheStudio uses OpenTelemetry for distributed tracing. When Ralph is embedded as the Primary Agent, TheStudio needs to see Ralph's loop iterations as spans within its trace tree, with `ralph.correlation_id` as a span attribute for cross-referencing.

Currently, the SDK has no OpenTelemetry integration. The `tracer` parameter added in CORR-1 is stored but never used.

## Solution

When `self._tracer` is not None, create OTel spans around key operations and set the `ralph.correlation_id` attribute. When `self._tracer` is None (standalone mode), all tracing code is a no-op.

Guard all OTel imports with `try/except ImportError` so the SDK works without `opentelemetry-api` installed.

## Implementation

### Step 1: Guard OTel imports (already done in CORR-1)

```python
try:
    from opentelemetry.trace import Tracer, StatusCode
except ImportError:
    Tracer = None  # type: ignore[assignment,misc]
    StatusCode = None  # type: ignore[assignment,misc]
```

### Step 2: Add span creation helper

```python
from contextlib import contextmanager
from typing import Iterator

@contextmanager
def _span(self, name: str, attributes: dict[str, str] | None = None) -> Iterator[Any]:
    """Create an OTel span if tracer is available, otherwise no-op.

    Usage:
        with self._span("loop_iteration", {"loop_count": str(self.loop_count)}):
            ...  # code is traced when tracer is set
    """
    if self._tracer is None:
        yield None
        return

    attrs = {"ralph.correlation_id": str(self.correlation_id)}
    if attributes:
        attrs.update(attributes)

    with self._tracer.start_as_current_span(name, attributes=attrs) as span:
        yield span
```

### Step 3: Wrap key operations with spans

```python
def run(self) -> TaskResult:
    """Execute the autonomous loop."""
    with self._span("ralph.run"):
        self.start_time = time.time()
        self._running = True
        # ... existing loop code ...

def run_iteration(self, task_input: TaskInput | None = None) -> RalphStatus:
    """Execute a single loop iteration."""
    with self._span("ralph.iteration", {
        "ralph.loop_count": str(self.loop_count),
    }) as span:
        # ... existing iteration code ...

        # On error, set span status
        if span and status.status == "ERROR":
            span.set_status(StatusCode.ERROR, status.error)

        return status
```

### Step 4: Trace circuit breaker checks

```python
def check_circuit_breaker(self) -> bool:
    """Check circuit breaker with optional tracing."""
    with self._span("ralph.circuit_breaker_check") as span:
        result = self._circuit_breaker.can_proceed()
        if span:
            span.set_attribute("ralph.cb_state", self._circuit_breaker.state.value)
            span.set_attribute("ralph.cb_can_proceed", result)
        return result
```

## Design Notes

- **No-op pattern**: The `_span()` context manager yields `None` when no tracer is set. All `if span:` checks prevent attribute-setting calls on `None`. This means zero overhead for standalone users.
- **Attribute naming**: OpenTelemetry convention uses dot-separated namespaces. All Ralph attributes are prefixed with `ralph.` to avoid conflicts.
- **No span propagation to subprocess**: The Claude CLI subprocess does not participate in the OTel trace. Spans only cover Ralph's orchestration layer. Propagating traces into Claude CLI would require environment variable injection (`TRACEPARENT`), which is out of scope.
- **StatusCode on errors**: Setting `StatusCode.ERROR` on failed iterations makes them visible as red spans in trace UIs (Jaeger, Grafana Tempo, etc.).
- **Depends on CORR-6**: This story requires `opentelemetry-api` to be available for testing. CORR-6 adds it as an optional dependency.

## Acceptance Criteria

- [ ] `_span()` context manager exists on `RalphAgent`
- [ ] Creates OTel span with `ralph.correlation_id` attribute when tracer provided
- [ ] Is a complete no-op when `self._tracer is None`
- [ ] `run()` method wrapped in `ralph.run` span
- [ ] `run_iteration()` wrapped in `ralph.iteration` span with `ralph.loop_count`
- [ ] Circuit breaker check traced with `ralph.cb_state` and `ralph.cb_can_proceed`
- [ ] Error iterations set `StatusCode.ERROR` on span
- [ ] No imports fail when `opentelemetry-api` is not installed
- [ ] Zero performance overhead when tracer is None

## Test Plan

```python
def test_span_noop_without_tracer():
    """_span() is no-op when tracer is None."""
    agent = RalphAgent(config=mock_config, project_dir=tmp_dir)
    assert agent._tracer is None

    with agent._span("test_span") as span:
        assert span is None  # No-op

def test_span_creates_otel_span(mock_tracer):
    """_span() creates OTel span when tracer is provided."""
    agent = RalphAgent(
        config=mock_config,
        project_dir=tmp_dir,
        tracer=mock_tracer,
    )

    with agent._span("test_span") as span:
        assert span is not None

    # Verify span was created with correlation_id attribute
    mock_tracer.start_as_current_span.assert_called_once()
    call_kwargs = mock_tracer.start_as_current_span.call_args
    assert "ralph.correlation_id" in call_kwargs.kwargs.get("attributes", {})

def test_span_sets_custom_attributes(mock_tracer):
    """_span() merges custom attributes with correlation_id."""
    agent = RalphAgent(
        config=mock_config,
        project_dir=tmp_dir,
        tracer=mock_tracer,
    )

    with agent._span("test", {"custom.key": "value"}):
        pass

    attrs = mock_tracer.start_as_current_span.call_args.kwargs["attributes"]
    assert attrs["custom.key"] == "value"
    assert "ralph.correlation_id" in attrs

def test_otel_import_failure_graceful():
    """SDK works when opentelemetry-api is not installed."""
    # This test verifies the try/except guard works.
    # In a clean environment without OTel:
    agent = RalphAgent(config=mock_config, project_dir=tmp_dir)
    assert agent._tracer is None
    # Should not raise
    with agent._span("test") as span:
        assert span is None
```
