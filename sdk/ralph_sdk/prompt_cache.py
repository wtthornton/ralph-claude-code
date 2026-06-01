"""Prompt cache optimization (SDK-CONTEXT-2).

Split out of context.py: the stable/dynamic prompt split models and the
``split_prompt`` helper that enables API-level prompt caching. Re-exported
from ``ralph_sdk.context`` so existing imports continue to work.
"""

from __future__ import annotations

import hashlib
from typing import Any

from pydantic import BaseModel, Field


class PromptParts(BaseModel):
    """Split prompt into stable prefix (cacheable) and dynamic suffix.

    The stable_prefix contains identity, build instructions, and tool permissions
    that rarely change between iterations. The dynamic_suffix contains loop count,
    progress updates, and current task details that change every iteration.

    Splitting allows API-level prompt caching to reuse the prefix across calls.
    """

    stable_prefix: str = Field(
        default="",
        description="Stable content: identity, build instructions, tool permissions",
    )
    dynamic_suffix: str = Field(
        default="",
        description="Dynamic content: loop count, progress, current task",
    )
    prefix_hash: str = Field(
        default="",
        description="SHA-256 hash of stable_prefix for cache validation",
    )

    def full_prompt(self) -> str:
        """Reconstruct the full prompt from parts."""
        if self.stable_prefix and self.dynamic_suffix:
            return f"{self.stable_prefix}\n\n{self.dynamic_suffix}"
        return self.stable_prefix or self.dynamic_suffix


class PromptCacheStats(BaseModel):
    """Tracks prompt cache hit/miss statistics."""

    cache_hits: int = 0
    cache_misses: int = 0
    last_prefix_hash: str = ""

    @property
    def hit_rate(self) -> float:
        """Cache hit rate as a fraction (0.0 to 1.0)."""
        total = self.cache_hits + self.cache_misses
        if total == 0:
            return 0.0
        return self.cache_hits / total

    def record(self, prefix_hash: str) -> bool:
        """Record a cache lookup and return whether it was a hit.

        Args:
            prefix_hash: Hash of the current stable prefix.

        Returns:
            True if this was a cache hit (prefix unchanged), False otherwise.
        """
        if prefix_hash == self.last_prefix_hash and self.last_prefix_hash:
            self.cache_hits += 1
            return True
        else:
            self.cache_misses += 1
            self.last_prefix_hash = prefix_hash
            return False


def _compute_prefix_hash(text: str) -> str:
    """Compute SHA-256 hash of text for cache validation."""
    return hashlib.sha256(text.encode("utf-8")).hexdigest()[:16]


def split_prompt(full_prompt: str, loop_context: dict[str, Any] | None = None) -> PromptParts:
    """Split a full prompt into stable prefix and dynamic suffix.

    The split point is determined by looking for dynamic markers in the prompt:
    - "## Current Fix Plan" — the fix plan section is dynamic
    - "## Loop Context" or "Loop:" — iteration-specific context
    - "## Progress" — progress updates

    Everything before the first dynamic marker is the stable prefix.
    Everything from the first dynamic marker onward is the dynamic suffix.

    If loop_context is provided, it is appended to the dynamic suffix.

    Args:
        full_prompt: The complete prompt text.
        loop_context: Optional dict with loop-specific context
            (loop_count, progress_summary, etc.).

    Returns:
        PromptParts with stable_prefix, dynamic_suffix, and prefix_hash.
    """
    if not full_prompt:
        return PromptParts()

    # Dynamic section markers (order matters — first match wins)
    dynamic_markers = [
        "\n## Current Fix Plan",
        "\n## Loop Context",
        "\n## Progress",
        "\nLoop:",
        "\nIteration:",
    ]

    split_idx = len(full_prompt)
    for marker in dynamic_markers:
        idx = full_prompt.find(marker)
        if idx != -1 and idx < split_idx:
            split_idx = idx

    stable_prefix = full_prompt[:split_idx].rstrip()
    dynamic_suffix = full_prompt[split_idx:].lstrip("\n")

    # Append loop context if provided
    if loop_context:
        context_lines = ["\n## Loop Context"]
        for key, value in loop_context.items():
            context_lines.append(f"- {key}: {value}")
        dynamic_suffix += "\n".join(context_lines)

    prefix_hash = _compute_prefix_hash(stable_prefix) if stable_prefix else ""

    return PromptParts(
        stable_prefix=stable_prefix,
        dynamic_suffix=dynamic_suffix,
        prefix_hash=prefix_hash,
    )
