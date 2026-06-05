"""Ralph SDK Cost Tracking, Budget Guardrails, Dynamic Model Routing, and Token Rate Limiting.

Implements:
- SDK-COST-1: CostTracker with per-iteration recording, session totals, and budget alerts
- SDK-COST-2: Dynamic model routing based on complexity band and retry escalation
- SDK-COST-3: TokenRateLimiter with hourly sliding window
"""

from __future__ import annotations

import time

from pydantic import BaseModel

from ralph_sdk.cost_models import (
    AlertLevel,
    BudgetStatus,
    IterationCost,
    ModelCostBreakdown,
    SessionCost,
)
from ralph_sdk.cost_pricing import DEFAULT_PRICING, ModelPricing
from ralph_sdk.cost_routing import (
    DEFAULT_MODEL_MAP,
    CostComplexityBand,
    select_model,
)

__all__ = [
    "DEFAULT_MODEL_MAP",
    "DEFAULT_PRICING",
    "AlertLevel",
    "BudgetStatus",
    "CostComplexityBand",
    "CostTracker",
    "IterationCost",
    "ModelCostBreakdown",
    "ModelPricing",
    "SessionCost",
    "TokenRateLimiter",
    "TokenUsage",
    "select_model",
]

# =============================================================================
# SDK-COST-1: Cost Tracking and Budget Guardrails
# (value models moved to cost_models.py, re-exported via __all__)
# =============================================================================


class CostTracker:
    """Tracks per-iteration and session-level costs with budget guardrails.

    Usage::

        tracker = CostTracker(pricing=DEFAULT_PRICING)
        cost = tracker.record_iteration("claude-sonnet-4-6", 1000, 500)
        session = tracker.get_session_cost()
        budget = tracker.check_budget(max_budget_usd=10.0)
    """

    def __init__(
        self,
        pricing: dict[str, ModelPricing] | None = None,
        *,
        budget_warning_pct: float = 50.0,
        budget_critical_pct: float = 80.0,
    ) -> None:
        self._pricing = pricing or dict(DEFAULT_PRICING)
        self._budget_warning_pct = budget_warning_pct
        self._budget_critical_pct = budget_critical_pct

        # Internal accumulators
        self._iterations: list[IterationCost] = []
        self._by_model: dict[str, ModelCostBreakdown] = {}

    @property
    def pricing(self) -> dict[str, ModelPricing]:
        """Current pricing table."""
        return dict(self._pricing)

    def record_iteration(
        self,
        model: str,
        input_tokens: int,
        output_tokens: int,
    ) -> IterationCost:
        """Record token usage for one iteration and return its cost.

        If the model is not in the pricing table, costs default to zero
        (unknown model — still tracked for token counts).
        """
        pricing = self._pricing.get(model)

        if pricing:
            input_usd = (input_tokens / 1_000_000) * pricing.input_per_1m
            output_usd = (output_tokens / 1_000_000) * pricing.output_per_1m
        else:
            input_usd = 0.0
            output_usd = 0.0

        iteration_cost = IterationCost(
            model=model,
            input_tokens=input_tokens,
            output_tokens=output_tokens,
            input_usd=input_usd,
            output_usd=output_usd,
            total_usd=input_usd + output_usd,
            iteration=len(self._iterations) + 1,
        )

        self._iterations.append(iteration_cost)

        # Update per-model breakdown
        if model not in self._by_model:
            self._by_model[model] = ModelCostBreakdown(model=model)
        breakdown = self._by_model[model]
        breakdown.input_tokens += input_tokens
        breakdown.output_tokens += output_tokens
        breakdown.total_usd += iteration_cost.total_usd
        breakdown.iterations += 1

        return iteration_cost

    def get_session_cost(self) -> SessionCost:
        """Return aggregate session cost across all recorded iterations."""
        total_input = sum(ic.input_tokens for ic in self._iterations)
        total_output = sum(ic.output_tokens for ic in self._iterations)
        total_usd = sum(ic.total_usd for ic in self._iterations)

        return SessionCost(
            total_input_tokens=total_input,
            total_output_tokens=total_output,
            total_usd=total_usd,
            by_model=list(self._by_model.values()),
            iteration_count=len(self._iterations),
        )

    def check_budget(self, max_budget_usd: float) -> BudgetStatus:
        """Check current spend against a budget and return alert status.

        Alert thresholds:
        - NONE: < warning_pct (default 50%)
        - WARNING: >= warning_pct and < critical_pct (default 80%)
        - CRITICAL: >= critical_pct and < 100%
        - EXHAUSTED: >= 100%

        Args:
            max_budget_usd: Maximum budget in USD. If <= 0, returns NONE alert.
        """
        session = self.get_session_cost()
        spent = session.total_usd

        if max_budget_usd <= 0:
            return BudgetStatus(
                total_spent_usd=spent,
                max_budget_usd=0.0,
                remaining_usd=0.0,
                percentage_used=0.0,
                alert_level=AlertLevel.NONE,
            )

        remaining = max(0.0, max_budget_usd - spent)
        pct_used = (spent / max_budget_usd) * 100.0

        if pct_used >= 100.0:
            alert = AlertLevel.EXHAUSTED
        elif pct_used >= self._budget_critical_pct:
            alert = AlertLevel.CRITICAL
        elif pct_used >= self._budget_warning_pct:
            alert = AlertLevel.WARNING
        else:
            alert = AlertLevel.NONE

        return BudgetStatus(
            total_spent_usd=spent,
            max_budget_usd=max_budget_usd,
            remaining_usd=remaining,
            percentage_used=pct_used,
            alert_level=alert,
        )


# =============================================================================
# SDK-COST-3: Token-Based Rate Limiting
# =============================================================================


class TokenUsage(BaseModel):
    """Current token usage within the rate-limiting window."""

    tokens_used_this_hour: int = 0
    limit: int = 0
    reset_at: float = 0.0
    can_proceed: bool = True


class TokenRateLimiter:
    """Token-based rate limiter with an hourly sliding window.

    Complements the existing invocation-count rate limiter in RalphAgent.
    When max_tokens_per_hour is 0 (default), the limiter is disabled and
    always allows requests.

    Usage::

        limiter = TokenRateLimiter(max_tokens_per_hour=500_000)
        limiter.record_tokens(10000, 5000)  # 15000 total
        if limiter.can_proceed():
            # OK to make another call
            ...
        usage = limiter.get_usage()
    """

    def __init__(self, max_tokens_per_hour: int = 0) -> None:
        self._max_tokens_per_hour = max_tokens_per_hour
        self._tokens_used: int = 0
        self._window_start: float = time.time()

    def _maybe_reset_window(self) -> None:
        """Reset the window if an hour has elapsed."""
        now = time.time()
        if now - self._window_start >= 3600:
            self._tokens_used = 0
            self._window_start = now

    def record_tokens(self, input_tokens: int, output_tokens: int) -> None:
        """Record token usage (both input and output count toward the limit)."""
        self._maybe_reset_window()
        self._tokens_used += input_tokens + output_tokens

    def can_proceed(self) -> bool:
        """Check if we are under the token-per-hour limit.

        Returns True if:
        - max_tokens_per_hour is 0 (disabled), OR
        - tokens_used_this_hour < max_tokens_per_hour
        """
        if self._max_tokens_per_hour <= 0:
            return True
        self._maybe_reset_window()
        return self._tokens_used < self._max_tokens_per_hour

    def get_usage(self) -> TokenUsage:
        """Return current token usage stats."""
        self._maybe_reset_window()
        return TokenUsage(
            tokens_used_this_hour=self._tokens_used,
            limit=self._max_tokens_per_hour,
            reset_at=self._window_start + 3600,
            can_proceed=self.can_proceed(),
        )
