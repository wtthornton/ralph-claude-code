"""Task complexity classifier — 5-level heuristic without LLM calls.

Port of lib/complexity.sh to Python. Classifies tasks by:
1. Explicit size annotations ([TRIVIAL], [SMALL], [MEDIUM], [LARGE], [ARCH])
2. Keyword analysis (architectural terms score higher)
3. File count heuristic (referenced source files)
4. Multi-step indicators (checklists, phases)
5. Retry escalation (repeated failures bump complexity)

Feeds into cost.select_model() for dynamic model routing.
"""

from __future__ import annotations

import re

from ralph_sdk.cost import CostComplexityBand

# Annotation patterns — highest priority, short-circuits
_ANNOTATION_MAP: list[tuple[re.Pattern[str], CostComplexityBand]] = [
    (re.compile(r"\[TRIVIAL\]", re.IGNORECASE), CostComplexityBand.TRIVIAL),
    (re.compile(r"\[SMALL\]", re.IGNORECASE), CostComplexityBand.SMALL),
    (re.compile(r"\[MEDIUM\]", re.IGNORECASE), CostComplexityBand.MEDIUM),
    (re.compile(r"\[LARGE\]", re.IGNORECASE), CostComplexityBand.LARGE),
    (re.compile(r"\[ARCH(?:ITECTURAL)?\]", re.IGNORECASE), CostComplexityBand.ARCHITECTURAL),
]

# Keyword scoring
_HIGH_KEYWORDS = re.compile(
    r"architect|redesign|migrate|rewrite|overhaul|platform",
    re.IGNORECASE,
)
_MEDIUM_KEYWORDS = re.compile(
    r"refactor|integrate|implement|convert|restructure",
    re.IGNORECASE,
)
_LOW_KEYWORDS = re.compile(
    r"typo|comment|rename|bump|version|trivial|simple fix",
    re.IGNORECASE,
)

# File reference pattern
_FILE_PATTERN = re.compile(
    r"[a-zA-Z0-9_/.-]+\.(?:py|js|ts|tsx|jsx|sh|go|rs|java|rb|c|cpp|h)"
)

# Multi-step indicators
_STEP_PATTERN = re.compile(
    r"^\s*[-*]\s*\[.\]|step\s+\d|phase\s+\d|then\s|after that",
    re.IGNORECASE | re.MULTILINE,
)

# Score → band mapping
_SCORE_TO_BAND: list[tuple[int, CostComplexityBand]] = [
    (1, CostComplexityBand.TRIVIAL),
    (2, CostComplexityBand.SMALL),
    (3, CostComplexityBand.MEDIUM),
    (4, CostComplexityBand.LARGE),
    (5, CostComplexityBand.ARCHITECTURAL),
]


def classify_complexity(
    task_text: str,
    retry_count: int = 0,
) -> CostComplexityBand:
    """Classify a task into a 5-level complexity band.

    Args:
        task_text: Task description, fix_plan entry, or prompt text.
        retry_count: Number of previous failed attempts.

    Returns:
        CostComplexityBand (TRIVIAL through ARCHITECTURAL).
    """
    # 1. Explicit annotations — highest priority
    for pattern, band in _ANNOTATION_MAP:
        if pattern.search(task_text):
            return band

    # 2. Keyword scoring (base = 3 = MEDIUM)
    score = 3

    if _HIGH_KEYWORDS.search(task_text):
        score += 2
    if _MEDIUM_KEYWORDS.search(task_text):
        score += 1
    if _LOW_KEYWORDS.search(task_text):
        score -= 1

    # 3. File count heuristic
    files = set(_FILE_PATTERN.findall(task_text))
    if len(files) >= 10:
        score += 2
    elif len(files) >= 5:
        score += 1

    # 4. Multi-step indicators
    steps = len(_STEP_PATTERN.findall(task_text))
    if steps >= 5:
        score += 1

    # 5. Retry escalation
    if retry_count >= 3:
        score += 2
    elif retry_count >= 1:
        score += 1

    # Clamp to 1-5
    score = max(1, min(5, score))

    for threshold, band in _SCORE_TO_BAND:
        if score <= threshold:
            return band
    return CostComplexityBand.ARCHITECTURAL
