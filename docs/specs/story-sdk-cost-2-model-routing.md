# Story SDK-COST-2: Dynamic Model Routing

**Epic:** [SDK Cost Intelligence](epic-sdk-cost-intelligence.md)
**Priority:** P1
**Status:** Pending
**Effort:** 1 day
**Component:** `ralph_sdk/config.py`, `ralph_sdk/agent.py`

---

## Problem

The CLI's `lib/complexity.sh` routes trivial tasks to Haiku, standard to Sonnet, and complex/architectural to Opus. The SDK uses a static model from config, meaning every task — from a one-line docstring fix to an architectural redesign — hits the same model at the same cost.

Cost differential for the same 10K input / 5K output task:
- Haiku: ~$0.035
- Sonnet: ~$0.105
- Opus: ~$0.175

That's a ~5x difference between Haiku and Opus. For a high-volume system like TheStudio processing a mix of task complexities, routing to the cheapest capable model directly reduces per-task costs.

The CLI also implements retry escalation: if Haiku fails, retry with Sonnet; if Sonnet fails, retry with Opus. This optimizes the cost-success tradeoff.

## Solution

Add `select_model()` function to the SDK config layer that routes tasks to models based on complexity band, with retry escalation support.

## Implementation

```python
# In ralph_sdk/config.py or new ralph_sdk/routing.py:

from enum import IntEnum


class ComplexityBand(IntEnum):
    """5-level task complexity classifier matching the CLI."""
    TRIVIAL = 1       # One-line changes, docstrings, typo fixes
    SIMPLE = 2        # Single-file changes, small bug fixes
    STANDARD = 3      # Multi-file changes, feature additions
    COMPLEX = 4       # Cross-module changes, refactoring
    ARCHITECTURAL = 5  # System-wide changes, new subsystems


# Default model routing: complexity band → model
DEFAULT_MODEL_ROUTING: dict[ComplexityBand, str] = {
    ComplexityBand.TRIVIAL: "claude-haiku-4-5",
    ComplexityBand.SIMPLE: "claude-haiku-4-5",
    ComplexityBand.STANDARD: "claude-sonnet-4-6",
    ComplexityBand.COMPLEX: "claude-sonnet-4-6",
    ComplexityBand.ARCHITECTURAL: "claude-opus-4-6",
}

# Retry escalation path: model → next model to try on failure
DEFAULT_ESCALATION: dict[str, str] = {
    "claude-haiku-4-5": "claude-sonnet-4-6",
    "claude-sonnet-4-6": "claude-opus-4-6",
    "claude-opus-4-6": "claude-opus-4-6",  # Opus is the ceiling
}


def select_model(
    task: str,
    complexity: ComplexityBand,
    retry_count: int = 0,
    model_routing: dict[ComplexityBand, str] | None = None,
    escalation_path: dict[str, str] | None = None,
    model_override: str | None = None,
) -> str:
    """Select the appropriate model based on complexity and retry count.

    Args:
        task: Task description (currently unused; reserved for future NLP classification)
        complexity: Task complexity band
        retry_count: Number of previous failed attempts (triggers escalation)
        model_routing: Override default complexity → model mapping
        escalation_path: Override default model → escalation model mapping
        model_override: Force a specific model (ignores routing and escalation)

    Returns:
        Model identifier string (e.g., "claude-sonnet-4-6")
    """
    if model_override:
        return model_override

    routing = model_routing or DEFAULT_MODEL_ROUTING
    escalation = escalation_path or DEFAULT_ESCALATION

    # Start with the routed model for this complexity
    model = routing.get(complexity, "claude-sonnet-4-6")

    # Escalate on retries
    for _ in range(retry_count):
        next_model = escalation.get(model, model)
        if next_model == model:
            break  # Already at ceiling
        model = next_model

    return model
```

### Config fields

```python
# In ralph_sdk/config.py, add to RalphConfig:
model_routing_enabled: bool = Field(default=False, description="Enable dynamic model routing based on complexity")
model_routing: dict[str, str] = Field(
    default_factory=dict,
    description="Complexity band → model override (e.g., {'TRIVIAL': 'claude-haiku-4-5'})"
)
retry_escalation_enabled: bool = Field(default=True, description="Escalate to more capable model on retry")
```

### Agent integration

```python
# In ralph_sdk/agent.py, before each iteration:
if self._config.model_routing_enabled:
    model = select_model(
        task=self._current_task,
        complexity=self._complexity_band,
        retry_count=self._retry_count,
        model_routing=self._parse_model_routing(self._config.model_routing),
        model_override=None,
    )
    self._current_model = model
else:
    self._current_model = self._config.model
```

## Design Notes

- **Disabled by default**: `model_routing_enabled=False` preserves backward compatibility. When disabled, the static `model` from config is used.
- **Override wins**: `model_override` parameter bypasses all routing logic. Useful for testing or forcing a specific model.
- **Escalation ceiling**: Opus is the ceiling; escalation stops there.
- **Task parameter reserved**: The `task` string is accepted but not used for NLP-based classification. Future enhancement could use it for automatic complexity detection.
- **Configurable routing**: Both the complexity→model mapping and the escalation path are configurable. Embedders can route STANDARD tasks to Opus if quality is more important than cost.

## Acceptance Criteria

- [ ] `select_model()` routes TRIVIAL/SIMPLE to Haiku, STANDARD/COMPLEX to Sonnet, ARCHITECTURAL to Opus
- [ ] Retry escalation moves Haiku → Sonnet → Opus on consecutive failures
- [ ] `model_override` bypasses routing and escalation
- [ ] Default routing configurable via `RalphConfig.model_routing`
- [ ] `model_routing_enabled=False` (default) uses static model from config
- [ ] Agent uses selected model for Claude CLI invocation
- [ ] Escalation ceiling: Opus does not escalate further

## Test Plan

```python
import pytest
from ralph_sdk.routing import select_model, ComplexityBand

class TestModelRouting:
    def test_trivial_routes_to_haiku(self):
        model = select_model(task="Fix typo", complexity=ComplexityBand.TRIVIAL)
        assert model == "claude-haiku-4-5"

    def test_standard_routes_to_sonnet(self):
        model = select_model(task="Add endpoint", complexity=ComplexityBand.STANDARD)
        assert model == "claude-sonnet-4-6"

    def test_architectural_routes_to_opus(self):
        model = select_model(task="Redesign auth", complexity=ComplexityBand.ARCHITECTURAL)
        assert model == "claude-opus-4-6"

    def test_retry_escalation_haiku_to_sonnet(self):
        model = select_model(
            task="Fix typo", complexity=ComplexityBand.TRIVIAL, retry_count=1
        )
        assert model == "claude-sonnet-4-6"

    def test_retry_escalation_sonnet_to_opus(self):
        model = select_model(
            task="Add endpoint", complexity=ComplexityBand.STANDARD, retry_count=1
        )
        assert model == "claude-opus-4-6"

    def test_escalation_ceiling_at_opus(self):
        model = select_model(
            task="Redesign auth", complexity=ComplexityBand.ARCHITECTURAL, retry_count=5
        )
        assert model == "claude-opus-4-6"

    def test_model_override_wins(self):
        model = select_model(
            task="Fix typo",
            complexity=ComplexityBand.TRIVIAL,
            model_override="claude-opus-4-6",
        )
        assert model == "claude-opus-4-6"

    def test_custom_routing(self):
        custom_routing = {ComplexityBand.TRIVIAL: "claude-opus-4-6"}
        model = select_model(
            task="Fix typo",
            complexity=ComplexityBand.TRIVIAL,
            model_routing=custom_routing,
        )
        assert model == "claude-opus-4-6"

    def test_unknown_complexity_falls_back_to_sonnet(self):
        model = select_model(
            task="Unknown",
            complexity=99,  # Not a valid band
        )
        assert model == "claude-sonnet-4-6"
```

## References

- CLI `lib/complexity.sh`: 5-level classifier with model routing
- Claude API pricing (March 2026): Haiku $1/1M, Sonnet $3/1M, Opus $5/1M input
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.5
