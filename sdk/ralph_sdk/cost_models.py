"""Cost tracking value models — SDK-COST-1.

Split out of ralph_sdk.cost: the budget alert enum and the pydantic models
describing per-iteration, per-model, session, and budget cost state.
"""

from __future__ import annotations

from enum import Enum

from pydantic import BaseModel, Field


class AlertLevel(str, Enum):
    """Budget alert level."""

    NONE = "NONE"
    WARNING = "WARNING"
    CRITICAL = "CRITICAL"
    EXHAUSTED = "EXHAUSTED"


class IterationCost(BaseModel):
    """Cost for a single iteration."""

    model: str
    input_tokens: int
    output_tokens: int
    input_usd: float
    output_usd: float
    total_usd: float
    iteration: int


class ModelCostBreakdown(BaseModel):
    """Cost breakdown for a single model."""

    model: str
    input_tokens: int = 0
    output_tokens: int = 0
    total_usd: float = 0.0
    iterations: int = 0


class SessionCost(BaseModel):
    """Aggregate cost for the entire session."""

    total_input_tokens: int = 0
    total_output_tokens: int = 0
    total_usd: float = 0.0
    by_model: list[ModelCostBreakdown] = Field(default_factory=list)
    iteration_count: int = 0


class BudgetStatus(BaseModel):
    """Budget status after a budget check."""

    total_spent_usd: float = 0.0
    max_budget_usd: float = 0.0
    remaining_usd: float = 0.0
    percentage_used: float = 0.0
    alert_level: AlertLevel = AlertLevel.NONE
