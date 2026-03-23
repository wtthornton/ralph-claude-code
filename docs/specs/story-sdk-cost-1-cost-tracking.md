# Story SDK-COST-1: Cost Tracking and Budget Guardrails

**Epic:** [SDK Cost Intelligence](epic-sdk-cost-intelligence.md)
**Priority:** P1
**Status:** Pending
**Effort:** 2 days
**Component:** `ralph_sdk/agent.py` (new: `ralph_sdk/cost.py`), `ralph_sdk/config.py`

---

## Problem

The CLI tracks per-model token costs (`lib/tracing.sh` lines 185-284), enforces budget alerts at configurable thresholds, and provides cost dashboards. The SDK has no cost awareness.

TheStudio's `BudgetEnforcer` estimates cost from `duration_seconds * cost_per_minute` — a fragile heuristic that diverges from actual spend. Per-token cost tracking from the SDK would replace this heuristic with accurate data.

Additionally, CLI issue #223 confirms the rate limiter counts invocations, not tokens — budget accuracy needs improvement.

## Solution

Add a `CostTracker` class to the SDK with per-model pricing, per-iteration cost recording, cumulative session cost tracking, and budget threshold alerts.

## Implementation

```python
# ralph_sdk/cost.py

from enum import Enum
from pydantic import BaseModel, Field
from dataclasses import dataclass, field


class BudgetStatus(str, Enum):
    OK = "ok"
    WARNING = "warning"          # Exceeded alert threshold
    EXCEEDED = "exceeded"        # Budget exhausted


class ModelPricing(BaseModel):
    """Per-model token pricing (USD per 1M tokens)."""
    input_per_million: float
    output_per_million: float
    cache_read_per_million: float = 0.0
    cache_write_per_million: float = 0.0


# March 2026 Claude pricing defaults
# Cache write = 1.25× base input price (5-minute TTL)
# Cache read = 0.1× base input price (90% discount)
# Batch API = 50% discount on all rates (not reflected here)
DEFAULT_PRICING: dict[str, ModelPricing] = {
    "claude-opus-4-6": ModelPricing(
        input_per_million=5.0,
        output_per_million=25.0,
        cache_read_per_million=0.50,
        cache_write_per_million=6.25,
    ),
    "claude-sonnet-4-6": ModelPricing(
        input_per_million=3.0,
        output_per_million=15.0,
        cache_read_per_million=0.30,
        cache_write_per_million=3.75,
    ),
    "claude-haiku-4-5": ModelPricing(
        input_per_million=1.0,
        output_per_million=5.0,
        cache_read_per_million=0.10,
        cache_write_per_million=1.25,
    ),
}


class IterationCost(BaseModel):
    """Cost record for a single iteration."""
    model: str
    input_tokens: int
    output_tokens: int
    cache_read_tokens: int = 0
    cache_write_tokens: int = 0
    cost_usd: float
    iteration: int


class CostTracker:
    """Tracks per-iteration and cumulative costs for a Ralph session.

    Provides budget awareness with configurable alert thresholds and
    hard stops when budget is exhausted.
    """

    def __init__(
        self,
        pricing: dict[str, ModelPricing] | None = None,
        budget_usd: float = 0.0,
        alert_threshold: float = 0.8,
    ):
        self._pricing = pricing or DEFAULT_PRICING
        self._budget_usd = budget_usd
        self._alert_threshold = alert_threshold
        self._iterations: list[IterationCost] = []
        self._total_cost: float = 0.0

    def record_iteration_cost(
        self,
        model: str,
        input_tokens: int,
        output_tokens: int,
        iteration: int,
        cache_read_tokens: int = 0,
        cache_write_tokens: int = 0,
    ) -> IterationCost:
        """Record cost for a single iteration. Returns the cost record."""
        pricing = self._pricing.get(model)
        if pricing is None:
            # Fall back to Sonnet pricing for unknown models
            pricing = self._pricing.get("claude-sonnet-4-6", ModelPricing(
                input_per_million=3.0, output_per_million=15.0
            ))

        cost = (
            (input_tokens * pricing.input_per_million / 1_000_000)
            + (output_tokens * pricing.output_per_million / 1_000_000)
            + (cache_read_tokens * pricing.cache_read_per_million / 1_000_000)
            + (cache_write_tokens * pricing.cache_write_per_million / 1_000_000)
        )

        record = IterationCost(
            model=model,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            cache_read_tokens=cache_read_tokens,
            cache_write_tokens=cache_write_tokens,
            cost_usd=round(cost, 6),
            iteration=iteration,
        )
        self._iterations.append(record)
        self._total_cost += cost
        return record

    def get_session_cost(self) -> float:
        """Return cumulative session cost in USD."""
        return round(self._total_cost, 6)

    def check_budget(
        self,
        budget_usd: float | None = None,
        alert_threshold: float | None = None,
    ) -> BudgetStatus:
        """Check current spend against budget.

        Args:
            budget_usd: Override budget (uses instance default if None).
                        0.0 means no budget limit.
            alert_threshold: Override alert threshold (0.0-1.0).

        Returns:
            BudgetStatus: OK, WARNING, or EXCEEDED.
        """
        budget = budget_usd if budget_usd is not None else self._budget_usd
        threshold = alert_threshold if alert_threshold is not None else self._alert_threshold

        if budget <= 0:
            return BudgetStatus.OK  # No budget limit

        if self._total_cost >= budget:
            return BudgetStatus.EXCEEDED

        if self._total_cost >= budget * threshold:
            return BudgetStatus.WARNING

        return BudgetStatus.OK

    def get_iteration_history(self) -> list[IterationCost]:
        """Return all iteration cost records."""
        return list(self._iterations)

    @property
    def remaining_budget(self) -> float | None:
        """Remaining budget in USD. None if no budget is set."""
        if self._budget_usd <= 0:
            return None
        return max(0.0, self._budget_usd - self._total_cost)
```

### Integration with agent

```python
# In ralph_sdk/agent.py, within RalphAgent.__init__():
self._cost_tracker = CostTracker(
    budget_usd=config.budget_usd,
    alert_threshold=config.budget_alert_threshold,
)

# In ralph_sdk/config.py:
budget_usd: float = Field(default=0.0, ge=0, description="Session budget in USD (0 = unlimited)")
budget_alert_threshold: float = Field(default=0.8, ge=0, le=1, description="Budget alert threshold (0.0-1.0)")

# After each iteration:
cost_record = self._cost_tracker.record_iteration_cost(
    model=self._config.model,
    input_tokens=result_input_tokens,
    output_tokens=result_output_tokens,
    iteration=self._loop_count,
)

budget_status = self._cost_tracker.check_budget()
if budget_status == BudgetStatus.EXCEEDED:
    self._circuit_breaker.trip(f"budget_exceeded: ${self._cost_tracker.get_session_cost():.2f} >= ${self._config.budget_usd:.2f}")
elif budget_status == BudgetStatus.WARNING:
    self._log(f"Budget warning: ${self._cost_tracker.get_session_cost():.2f} / ${self._config.budget_usd:.2f}")
```

## Design Notes

- **Default pricing**: Defaults to March 2026 Claude pricing. Configurable via `pricing` parameter for future price changes.
- **Sonnet fallback**: Unknown model IDs fall back to Sonnet pricing (middle tier) rather than failing.
- **Budget = 0 means unlimited**: Consistent with the CLI's behavior where no budget means no limit.
- **CB integration**: Budget exceeded trips the circuit breaker, preventing further iterations.
- **Cache-aware pricing**: Tracks cache read/write tokens separately with their discounted rates.

## Acceptance Criteria

- [ ] `CostTracker.record_iteration_cost()` records per-model cost with token counts
- [ ] `get_session_cost()` returns cumulative USD spend
- [ ] `check_budget()` returns OK, WARNING, or EXCEEDED based on thresholds
- [ ] Budget exceeded trips the circuit breaker
- [ ] Budget warning is logged
- [ ] Per-model pricing is configurable (defaults to March 2026 Claude pricing)
- [ ] Cache read/write tokens tracked with discounted rates
- [ ] Unknown models fall back to Sonnet pricing
- [ ] `budget_usd` and `budget_alert_threshold` configurable via `RalphConfig`
- [ ] Iteration history queryable via `get_iteration_history()`

## Test Plan

```python
import pytest
from ralph_sdk.cost import CostTracker, BudgetStatus, ModelPricing, DEFAULT_PRICING

class TestCostTracker:
    def test_record_and_accumulate(self):
        tracker = CostTracker()
        tracker.record_iteration_cost(
            model="claude-sonnet-4-6", input_tokens=1000, output_tokens=500, iteration=1
        )
        tracker.record_iteration_cost(
            model="claude-sonnet-4-6", input_tokens=2000, output_tokens=1000, iteration=2
        )
        assert tracker.get_session_cost() > 0
        assert len(tracker.get_iteration_history()) == 2

    def test_budget_ok(self):
        tracker = CostTracker(budget_usd=10.0)
        tracker.record_iteration_cost(
            model="claude-haiku-4-5", input_tokens=1000, output_tokens=500, iteration=1
        )
        assert tracker.check_budget() == BudgetStatus.OK

    def test_budget_warning(self):
        tracker = CostTracker(budget_usd=0.01, alert_threshold=0.5)
        tracker.record_iteration_cost(
            model="claude-sonnet-4-6", input_tokens=5000, output_tokens=2000, iteration=1
        )
        status = tracker.check_budget()
        assert status in (BudgetStatus.WARNING, BudgetStatus.EXCEEDED)

    def test_budget_exceeded(self):
        tracker = CostTracker(budget_usd=0.001)
        tracker.record_iteration_cost(
            model="claude-opus-4-6", input_tokens=10000, output_tokens=5000, iteration=1
        )
        assert tracker.check_budget() == BudgetStatus.EXCEEDED

    def test_no_budget_always_ok(self):
        tracker = CostTracker(budget_usd=0.0)
        tracker.record_iteration_cost(
            model="claude-opus-4-6", input_tokens=1000000, output_tokens=500000, iteration=1
        )
        assert tracker.check_budget() == BudgetStatus.OK

    def test_unknown_model_falls_back(self):
        tracker = CostTracker()
        record = tracker.record_iteration_cost(
            model="unknown-model", input_tokens=1000, output_tokens=500, iteration=1
        )
        assert record.cost_usd > 0  # Falls back to Sonnet pricing

    def test_cache_token_pricing(self):
        tracker = CostTracker()
        record = tracker.record_iteration_cost(
            model="claude-sonnet-4-6",
            input_tokens=0,
            output_tokens=0,
            cache_read_tokens=100000,
            cache_write_tokens=50000,
            iteration=1,
        )
        assert record.cost_usd > 0

    def test_remaining_budget(self):
        tracker = CostTracker(budget_usd=5.0)
        tracker.record_iteration_cost(
            model="claude-sonnet-4-6", input_tokens=100000, output_tokens=50000, iteration=1
        )
        remaining = tracker.remaining_budget
        assert remaining is not None
        assert remaining < 5.0
        assert remaining > 0.0
```

## References

- CLI `lib/tracing.sh` lines 185-284: Per-model token cost tracking
- Ralph issue #223: Rate limiter counts invocations, not tokens
- Anthropic API pricing page (March 2026)
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.4
