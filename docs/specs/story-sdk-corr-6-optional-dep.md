# Story RALPH-SDK-CORR-6: Add opentelemetry-api as Optional Dependency

**Epic:** [Correlation ID Threading](epic-sdk-correlation-id.md)
**Priority:** Medium
**Status:** Done
**Effort:** Trivial
**Component:** `sdk/pyproject.toml`

---

## Problem

The SDK's `pyproject.toml` has no `opentelemetry-api` dependency. Story CORR-5 adds optional OTel span creation, but users who want tracing have no documented way to install the required package.

Currently `pyproject.toml` only has:

```toml
[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "pytest-cov>=4.0",
]
```

## Solution

Add a `tracing` optional dependency group to `pyproject.toml`:

```toml
[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "pytest-cov>=4.0",
]
tracing = [
    "opentelemetry-api>=1.20",
]
```

Users install tracing support with:

```bash
pip install ralph-sdk[tracing]
```

Standalone Ralph users who don't need tracing just run `pip install ralph-sdk` — no OTel dependency.

## Implementation

### Step 1: Update pyproject.toml

Add the `tracing` extra to `[project.optional-dependencies]`:

```toml
[project.optional-dependencies]
dev = [
    "pytest>=8.0",
    "pytest-cov>=4.0",
]
tracing = [
    "opentelemetry-api>=1.20",
]
```

### Step 2: Verify import guard in agent.py

Ensure the guard from CORR-1 is in place:

```python
try:
    from opentelemetry.trace import Tracer
except ImportError:
    Tracer = None  # type: ignore[assignment,misc]
```

This ensures `ralph-sdk` works without `opentelemetry-api` installed. The `tracing` extra is purely additive.

## Design Notes

- **`>=1.20` minimum**: OpenTelemetry API 1.20 (released 2023-09) is a stable release with the tracing API that CORR-5 uses (`Tracer`, `start_as_current_span`, `StatusCode`). No features from later versions are needed.
- **API only, not SDK**: We depend on `opentelemetry-api`, not `opentelemetry-sdk`. The API provides the `Tracer` interface. The actual exporter/SDK is configured by TheStudio or the user's application — Ralph just sets attributes on spans.
- **No runtime dependency**: The `tracing` extra is never auto-installed. CI tests for CORR-5 should install it explicitly: `pip install -e ".[tracing,dev]"`.

## Acceptance Criteria

- [ ] `pyproject.toml` has `tracing = ["opentelemetry-api>=1.20"]` under `[project.optional-dependencies]`
- [ ] `pip install ralph-sdk` does NOT install opentelemetry-api
- [ ] `pip install ralph-sdk[tracing]` installs opentelemetry-api
- [ ] `pip install ralph-sdk[dev,tracing]` installs both dev and tracing deps
- [ ] Import guard in agent.py handles missing opentelemetry gracefully
- [ ] Existing `dev` extra is unchanged

## Test Plan

```bash
# Test 1: Base install has no OTel
pip install -e .
python -c "import ralph_sdk; print('OK')"  # Should succeed
python -c "import opentelemetry" 2>&1 | grep -q "ModuleNotFoundError"  # Should fail

# Test 2: Tracing install has OTel
pip install -e ".[tracing]"
python -c "import opentelemetry; print('OK')"  # Should succeed
python -c "from opentelemetry.trace import Tracer; print('OK')"  # Should succeed

# Test 3: Existing tests pass without tracing extra
pip install -e ".[dev]"
pytest sdk/tests/ -v  # All pass, no OTel needed
```
