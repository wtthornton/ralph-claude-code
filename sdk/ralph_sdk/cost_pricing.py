"""Model pricing tables — SDK-COST-1 pricing data.

Split out of ralph_sdk.cost: the ModelPricing dataclass and the
DEFAULT_PRICING table (USD per 1M tokens for each Claude model).
"""

from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class ModelPricing:
    """Pricing per model in USD per 1M tokens."""

    input_per_1m: float
    output_per_1m: float
    cache_write_per_1m: float = 0.0
    cache_read_per_1m: float = 0.0


# Default pricing for Claude models (USD per 1M tokens)
DEFAULT_PRICING: dict[str, ModelPricing] = {
    "claude-opus-4-8": ModelPricing(
        input_per_1m=5.0,
        output_per_1m=25.0,
        cache_write_per_1m=6.25,
        cache_read_per_1m=0.50,
    ),
    "claude-opus-4-7": ModelPricing(
        input_per_1m=5.0,
        output_per_1m=25.0,
        cache_write_per_1m=6.25,
        cache_read_per_1m=0.50,
    ),
    "claude-opus-4-6": ModelPricing(
        input_per_1m=5.0,
        output_per_1m=25.0,
        cache_write_per_1m=6.25,
        cache_read_per_1m=0.50,
    ),
    "claude-sonnet-4-6": ModelPricing(
        input_per_1m=3.0,
        output_per_1m=15.0,
        cache_write_per_1m=3.75,
        cache_read_per_1m=0.30,
    ),
    "claude-haiku-4-5": ModelPricing(
        input_per_1m=1.0,
        output_per_1m=5.0,
        cache_write_per_1m=1.25,
        cache_read_per_1m=0.10,
    ),
}
