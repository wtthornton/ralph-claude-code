"""Dynamic model routing — SDK-COST-2.

Split out of ralph_sdk.cost: the complexity band enum, the default
complexity->model mapping, and the retry-escalation select_model helper.
"""

from __future__ import annotations

from enum import Enum


class CostComplexityBand(str, Enum):
    """Five-level task complexity classification matching the CLI complexity.sh.

    This is distinct from converters.ComplexityBand (which maps to max_turns).
    CostComplexityBand drives model selection and cost optimization.
    """

    TRIVIAL = "TRIVIAL"
    SMALL = "SMALL"
    MEDIUM = "MEDIUM"
    LARGE = "LARGE"
    ARCHITECTURAL = "ARCHITECTURAL"


# Default complexity -> model mapping
DEFAULT_MODEL_MAP: dict[CostComplexityBand, str] = {
    CostComplexityBand.TRIVIAL: "claude-haiku-4-5",
    CostComplexityBand.SMALL: "claude-haiku-4-5",
    CostComplexityBand.MEDIUM: "claude-sonnet-4-6",
    CostComplexityBand.LARGE: "claude-opus-4-8",
    CostComplexityBand.ARCHITECTURAL: "claude-opus-4-8",
}

# Retry escalation order
_ESCALATION_ORDER = [
    "claude-haiku-4-5",
    "claude-sonnet-4-6",
    "claude-opus-4-8",
]


def select_model(
    complexity: CostComplexityBand,
    retry_count: int = 0,
    *,
    model_map: dict[CostComplexityBand, str] | None = None,
) -> str:
    """Select the appropriate model based on complexity band and retry count.

    Base mapping (configurable via model_map):
    - TRIVIAL/SMALL -> haiku
    - MEDIUM -> sonnet
    - LARGE/ARCHITECTURAL -> opus

    Retry escalation: each retry bumps the model one tier up the escalation
    chain (haiku -> sonnet -> opus). Already at opus stays at opus.

    Args:
        complexity: The task complexity band.
        retry_count: Number of previous failed attempts (0 = first try).
        model_map: Override the default complexity-to-model mapping.

    Returns:
        Model identifier string.
    """
    effective_map = model_map or DEFAULT_MODEL_MAP
    base_model = effective_map.get(complexity, "claude-sonnet-4-6")

    if retry_count <= 0:
        return base_model

    # Find the base model's position in escalation order
    try:
        base_idx = _ESCALATION_ORDER.index(base_model)
    except ValueError:
        # Unknown model — no escalation possible
        return base_model

    # Escalate by retry_count, capped at max tier
    escalated_idx = min(base_idx + retry_count, len(_ESCALATION_ORDER) - 1)
    return _ESCALATION_ORDER[escalated_idx]
