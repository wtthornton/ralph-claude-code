"""Task decomposition detection (SDK-SAFETY-2).

Split out of agent_models.py: the decomposition hint/record models and the
heuristic ``detect_decomposition_needed`` helper. Re-exported from
``ralph_sdk.agent_models`` so existing imports continue to work.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from ralph_sdk.config import RalphConfig
from ralph_sdk.status import RalphStatus

__all__ = [
    "DecompositionHint",
    "IterationRecord",
    "detect_decomposition_needed",
]


@dataclass(frozen=True)
class DecompositionHint:
    """Hint that a task should be decomposed into smaller sub-tasks."""

    should_decompose: bool = False
    reason: str = ""
    suggested_split: int = 1
    factors: dict[str, bool] = field(default_factory=dict)


@dataclass
class IterationRecord:
    """Record of a single iteration's key metrics for history tracking."""

    loop_count: int = 0
    files_modified: int = 0
    tasks_completed: int = 0
    timed_out: bool = False
    complexity: int = 0
    file_count: int = 0
    had_progress: bool = False


def _estimate_file_count(status: RalphStatus) -> int:
    """Count distinct file paths referenced in next_task / progress_summary."""
    text = f"{status.next_task} {status.progress_summary}"
    file_patterns = re.findall(
        r'(?:^|[\s,])([a-zA-Z0-9_./-]+\.[a-zA-Z]{1,10})(?:[\s,]|$)',
        text,
    )
    return len(set(file_patterns))


_HIGH_COMPLEXITY_KEYWORDS = (
    "refactor", "architect", "redesign", "migration", "overhaul",
    "rewrite", "breaking change", "cross-cutting",
)
_MEDIUM_COMPLEXITY_KEYWORDS = (
    "implement", "integrate", "complex", "multiple", "several",
    "significant", "extensive", "large",
)


def _estimate_complexity(status: RalphStatus) -> int:
    """Estimate task complexity from status text on a 1-5 scale."""
    text = f"{status.next_task} {status.progress_summary}".lower()
    complexity = 1
    if any(k in text for k in _HIGH_COMPLEXITY_KEYWORDS):
        complexity += 2
    if any(k in text for k in _MEDIUM_COMPLEXITY_KEYWORDS):
        complexity += 1
    file_count = _estimate_file_count(status)
    if file_count >= 8:
        complexity += 2
    elif file_count >= 4:
        complexity += 1
    return min(complexity, 5)


def _consecutive_no_progress(history: list[IterationRecord]) -> int:
    count = 0
    for record in reversed(history):
        if record.had_progress:
            break
        count += 1
    return count


def _decomposition_reasons(
    factors: dict[str, bool],
    file_count: int,
    complexity: int,
    no_progress: int,
    cfg: RalphConfig,
) -> list[str]:
    reasons: list[str] = []
    if factors["file_count"]:
        reasons.append(
            f"file_count={file_count}>={cfg.decomposition_file_count_threshold}"
        )
    if factors["previous_timeout"]:
        reasons.append("previous iteration timed out")
    if factors["complexity"]:
        reasons.append(
            f"complexity={complexity}>={cfg.decomposition_complexity_threshold}"
        )
    if factors["consecutive_no_progress"]:
        reasons.append(
            f"consecutive_no_progress={no_progress}"
            f">={cfg.decomposition_no_progress_threshold}"
        )
    return reasons


def detect_decomposition_needed(
    status: RalphStatus,
    iteration_history: list[IterationRecord],
    config: RalphConfig | None = None,
) -> DecompositionHint:
    """Detect whether the current task should be decomposed (SDK-SAFETY-2).

    Returns a DecompositionHint with should_decompose=True when 2+ of the
    4 factors (file_count, previous_timeout, complexity, no_progress) trip.
    """
    cfg = config or RalphConfig()
    file_count = _estimate_file_count(status)
    complexity = _estimate_complexity(status)
    no_progress = _consecutive_no_progress(iteration_history)
    previous_timeout = bool(iteration_history and iteration_history[-1].timed_out)

    factors = {
        "file_count": file_count >= cfg.decomposition_file_count_threshold,
        "previous_timeout": previous_timeout,
        "complexity": complexity >= cfg.decomposition_complexity_threshold,
        "consecutive_no_progress": no_progress >= cfg.decomposition_no_progress_threshold,
    }
    active_count = sum(1 for v in factors.values() if v)

    if active_count < 2:
        return DecompositionHint(factors=factors)

    reasons = _decomposition_reasons(factors, file_count, complexity, no_progress, cfg)
    suggested_split = max(2, file_count // cfg.decomposition_file_count_threshold + 1)
    suggested_split = min(suggested_split, 5)

    return DecompositionHint(
        should_decompose=True,
        reason=f"Decomposition recommended ({active_count}/4 factors): {'; '.join(reasons)}",
        suggested_split=suggested_split,
        factors=factors,
    )
