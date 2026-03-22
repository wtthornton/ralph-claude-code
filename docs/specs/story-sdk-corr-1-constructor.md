# Story RALPH-SDK-CORR-1: Add correlation_id and tracer to RalphAgent.__init__()

**Epic:** [Correlation ID Threading](epic-sdk-correlation-id.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

The `RalphAgent.__init__()` (agent.py, lines 153-168) accepts only `config` and `project_dir`. There is no `correlation_id` parameter for tracing requests across loop iterations, and no `tracer` parameter for optional OpenTelemetry integration.

When debugging a failed run, there is no way to correlate log messages, status files, and results back to a specific invocation. When multiple Ralph instances run in CI, their outputs are indistinguishable.

## Solution

Add two keyword-only parameters to `RalphAgent.__init__()`:

- `correlation_id: UUID | None = None` — defaults to `uuid4()` when not provided (standalone mode). When provided (TheStudio embedded mode), uses the caller's ID.
- `tracer: Tracer | None = None` — optional OpenTelemetry tracer. Defaults to `None` (no-op). Only used when `opentelemetry-api` is installed.

Both are stored as instance attributes for use by subsequent stories (CORR-2 through CORR-5).

## Implementation

### Step 1: Add imports

```python
from uuid import UUID, uuid4
```

### Step 2: Guard OTel import

```python
try:
    from opentelemetry.trace import Tracer
except ImportError:
    Tracer = None  # type: ignore[assignment,misc]
```

### Step 3: Update constructor signature

```python
class RalphAgent:
    def __init__(
        self,
        config: RalphConfig | None = None,
        project_dir: str | Path = ".",
        *,
        correlation_id: UUID | None = None,
        tracer: Tracer | None = None,  # type: ignore[valid-type]
    ) -> None:
        self.config = config or RalphConfig.load(project_dir)
        self.project_dir = Path(project_dir).resolve()
        self.ralph_dir = self.project_dir / self.config.ralph_dir

        # Correlation ID: auto-generate for standalone, accept from caller
        self.correlation_id = correlation_id or uuid4()

        # Optional OpenTelemetry tracer (no-op when None)
        self._tracer = tracer

        # ... rest of existing init ...
```

### Step 4: Update process_task_packet for embedded mode

```python
def process_task_packet(self, packet: dict[str, Any]) -> dict[str, Any]:
    """Process a TheStudio TaskPacket and return a Signal."""
    # Accept correlation_id from packet if not already set by constructor
    if "correlation_id" in packet and not self._correlation_id_from_caller:
        self.correlation_id = UUID(packet["correlation_id"])
    # ... existing logic ...
```

## Design Notes

- **Keyword-only parameters**: Using `*` separator ensures `correlation_id` and `tracer` cannot be passed positionally, preventing breakage of existing code that passes `config` and `project_dir` positionally.
- **uuid4() default**: Matches the epic design decision. Every standalone run gets a unique ID automatically.
- **Tracer type guard**: The `try/except` import means `Tracer` is `None` when OTel is not installed. The type ignore comments suppress mypy errors for the conditional type.
- **No behavioral change**: This story only adds the parameters and stores them. Subsequent stories (CORR-3, CORR-4, CORR-5) use them in logging, status, and tracing.

## Acceptance Criteria

- [ ] `correlation_id` keyword-only parameter added to `RalphAgent.__init__()`
- [ ] Defaults to `uuid4()` when not provided
- [ ] Accepts caller-provided `UUID` for embedded mode
- [ ] Stored as `self.correlation_id` instance attribute
- [ ] `tracer` keyword-only parameter added to `RalphAgent.__init__()`
- [ ] Defaults to `None` when not provided
- [ ] Stored as `self._tracer` instance attribute
- [ ] OTel import is guarded with `try/except ImportError`
- [ ] Existing code calling `RalphAgent(config, project_dir)` still works (no positional breakage)

## Test Plan

```python
from uuid import UUID, uuid4

def test_agent_auto_generates_correlation_id():
    """Standalone mode: correlation_id auto-generated."""
    agent = RalphAgent(config=mock_config, project_dir=tmp_dir)
    assert isinstance(agent.correlation_id, UUID)

def test_agent_accepts_caller_correlation_id():
    """Embedded mode: correlation_id provided by caller."""
    cid = uuid4()
    agent = RalphAgent(
        config=mock_config,
        project_dir=tmp_dir,
        correlation_id=cid,
    )
    assert agent.correlation_id == cid

def test_agent_tracer_defaults_none():
    """Tracer defaults to None when not provided."""
    agent = RalphAgent(config=mock_config, project_dir=tmp_dir)
    assert agent._tracer is None

def test_agent_accepts_tracer():
    """Tracer can be provided (mock tracer for test)."""
    mock_tracer = object()  # Stand-in for OTel Tracer
    agent = RalphAgent(
        config=mock_config,
        project_dir=tmp_dir,
        tracer=mock_tracer,
    )
    assert agent._tracer is mock_tracer

def test_agent_backward_compatible_positional():
    """Existing positional usage still works."""
    agent = RalphAgent(mock_config, tmp_dir)
    assert isinstance(agent.correlation_id, UUID)

def test_agent_correlation_id_unique_per_instance():
    """Each agent instance gets a unique correlation_id."""
    a1 = RalphAgent(config=mock_config, project_dir=tmp_dir)
    a2 = RalphAgent(config=mock_config, project_dir=tmp_dir)
    assert a1.correlation_id != a2.correlation_id
```
