# Epic: Correlation ID Threading (HIGH-1)

**Epic ID:** RALPH-SDK-CORR
**Priority:** High
**Phase:** 2 — Async + Core (v1.5.0)
**Affects:** Observability, tracing, debugging across loop iterations
**Components:** `sdk/ralph_sdk/agent.py`, all model files
**Related specs:** [RFC-001 §4 HIGH-1](../../TheStudio/docs/architecture/RFC-001-ralph-sdk-integration.md), `epic-sdk-pydantic-models.md`, `epic-sdk-async.md`
**Depends on:** Epic 1 (Pydantic Models), Epic 4 (Async SDK)
**Target Version:** v1.5.0
**Status:** Done

---

## Problem Statement

The SDK has zero correlation tracking. No `correlation_id` parameter on any constructor,
method, or tool call. No structured logging with trace context. When debugging a failed
loop iteration, there's no way to trace a request from TheStudio through Ralph's execution
and back to the result.

### Why This Benefits Standalone Ralph

Even without TheStudio, correlation IDs improve debugging:
- Each `ralph --sdk` run gets a unique ID
- Log messages include the ID for filtering (`grep correlation_id ralph.log`)
- Status files include the ID for cross-referencing
- When Ralph runs multiple times in CI, each run is distinguishable

### Optional OpenTelemetry

TheStudio uses OpenTelemetry for distributed tracing. Ralph supports it optionally:
- `opentelemetry-api` is an **optional** dependency (`pip install ralph-sdk[tracing]`)
- When a `Tracer` is provided, Ralph sets span attributes
- When no tracer is provided, tracing is a no-op
- Standalone Ralph never needs to install OTel

## Stories

| Story | Title | Priority | Effort | Status |
|-------|-------|----------|--------|--------|
| [RALPH-SDK-CORR-1](story-sdk-corr-1-constructor.md) | Add correlation_id and tracer to RalphAgent.__init__() | Critical | Small | Done |
| [RALPH-SDK-CORR-2](story-sdk-corr-2-models.md) | Add correlation_id field to TaskResult and RalphStatusBlock | High | Small | Done |
| [RALPH-SDK-CORR-3](story-sdk-corr-3-logging.md) | Thread correlation_id through all log messages | High | Small | Done |
| [RALPH-SDK-CORR-4](story-sdk-corr-4-state.md) | Include correlation_id in status.json and circuit breaker events | Medium | Small | Done |
| [RALPH-SDK-CORR-5](story-sdk-corr-5-otel.md) | Optional OpenTelemetry span attributes | Medium | Small | Done |
| [RALPH-SDK-CORR-6](story-sdk-corr-6-optional-dep.md) | Add opentelemetry-api as optional dependency | Medium | Trivial | Done |

## Implementation Order

1. **CORR-1** — Constructor changes. Foundation for everything else.
2. **CORR-2** — Model field additions.
3. **CORR-3** — Log message threading.
4. **CORR-4** — State persistence.
5. **CORR-6** — Optional dependency.
6. **CORR-5** — OTel span attributes.

## Design Decisions

### correlation_id Behavior by Mode

| Mode | correlation_id behavior |
|------|------------------------|
| Standalone CLI (`ralph --sdk`) | Auto-generated `uuid4()` per run |
| TheStudio embedded | Provided by caller (from `TaskPacket.correlation_id`) |
| Missing in embedded mode | Warning logged, auto-generated as fallback |

The constructor signature:
```python
def __init__(
    self,
    config: RalphConfig,
    *,
    correlation_id: UUID | None = None,
    tracer: Tracer | None = None,
):
    self.correlation_id = correlation_id or uuid4()
```

### Structured Logging

Use Python's `extra` dict for structured logging:
```python
logger.info("Loop iteration %d", self.loop_count, extra={"correlation_id": str(self.correlation_id)})
```

This works with any log formatter. TheStudio's JSON formatter picks up `extra` fields.
Standalone Ralph's default formatter ignores them (no visual change for CLI users).

### No Hard OTel Dependency

```python
try:
    from opentelemetry.trace import Tracer
except ImportError:
    Tracer = None  # type: ignore
```

All OTel code is guarded by `if self._tracer is not None:` checks. Import failure
is not an error.

## Acceptance Criteria (Epic-level)

- [ ] `correlation_id` auto-generated for standalone mode
- [ ] `correlation_id` accepted from caller for embedded mode
- [ ] All log messages include `correlation_id` in `extra` field
- [ ] `TaskResult.correlation_id` populated
- [ ] `status.json` includes `correlation_id` field
- [ ] OTel spans set `ralph.correlation_id` attribute when tracer provided
- [ ] OTel is optional — base install does not require it
- [ ] `ralph --sdk` works unchanged (correlation_id auto-generated silently)
- [ ] Bash loop unaffected (extra field in status.json is harmless)

## Out of Scope

- OTel exporter configuration (TheStudio responsibility)
- Distributed tracing setup (TheStudio responsibility)
- Correlation ID propagation to sub-agents (future work)
