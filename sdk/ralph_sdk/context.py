"""Ralph SDK Context Management — progressive loading and prompt cache optimization.

SDK-CONTEXT-1: Progressive Context Loading — trims fix_plan.md to current epic section.
SDK-CONTEXT-2: Prompt Cache Optimization — splits prompts into stable/dynamic parts.
"""

from __future__ import annotations

import hashlib
import re
from typing import Any

from pydantic import BaseModel, Field


# =============================================================================
# SDK-CONTEXT-1: Progressive Context Loading
# =============================================================================


class ContextManager:
    """Manages progressive loading of fix_plan.md content.

    Trims fix_plan content to include only the current epic section (## heading)
    plus the next N unchecked items, summarizing completed sections to reduce
    token usage.
    """

    def __init__(self, max_unchecked_items: int = 5) -> None:
        self.max_unchecked_items = max_unchecked_items

    def trim_fix_plan(
        self,
        content: str,
        current_section_marker: str = "##",
    ) -> str:
        """Trim fix_plan.md to the active section with progressive summarization.

        Finds the first section (identified by current_section_marker) that contains
        unchecked items (``- [ ]``), includes up to max_unchecked_items from that
        section, and summarizes all completed sections above it.

        Args:
            content: Full fix_plan.md content.
            current_section_marker: Markdown heading marker for section boundaries.

        Returns:
            Trimmed content with completed sections summarized.
        """
        if not content or not content.strip():
            return content

        lines = content.splitlines()

        # Parse into sections: list of (heading_line, body_lines)
        sections: list[tuple[str, list[str]]] = []
        current_heading = ""
        current_body: list[str] = []

        # Collect any preamble (lines before the first section heading)
        preamble_lines: list[str] = []

        for line in lines:
            if line.strip().startswith(current_section_marker) and not line.strip().startswith(
                current_section_marker + "#"
            ):
                # This is a section heading at the target level (e.g., ## but not ###)
                if current_heading or current_body:
                    sections.append((current_heading, current_body))
                elif not current_heading and current_body:
                    preamble_lines = current_body
                current_heading = line
                current_body = []
            else:
                current_body.append(line)

        # Don't forget the last section
        if current_heading:
            sections.append((current_heading, current_body))
        elif current_body and not sections:
            # No sections found at all — return as-is
            return content

        # If there's only preamble and no sections, return as-is
        if not sections and preamble_lines:
            return content

        # Find the active section (first one with unchecked items)
        active_idx = -1
        for i, (heading, body) in enumerate(sections):
            if any(re.match(r"\s*- \[ \]", line) for line in body):
                active_idx = i
                break

        # If no unchecked items anywhere, return a summary of everything
        if active_idx == -1:
            total_checked = sum(
                sum(1 for line in body if re.match(r"\s*- \[x\]", line, re.IGNORECASE))
                for _, body in sections
            )
            result_parts = []
            if preamble_lines:
                result_parts.extend(preamble_lines)
                result_parts.append("")
            if total_checked > 0:
                result_parts.append(f"({total_checked} completed items — all tasks done)")
            return "\n".join(result_parts)

        # Build output
        result_parts: list[str] = []

        # Include preamble (title, description)
        if preamble_lines:
            result_parts.extend(preamble_lines)
            result_parts.append("")

        # Summarize completed sections above the active one
        completed_above = 0
        for i in range(active_idx):
            heading, body = sections[i]
            checked_count = sum(
                1 for line in body if re.match(r"\s*- \[x\]", line, re.IGNORECASE)
            )
            completed_above += checked_count

        if completed_above > 0:
            result_parts.append(f"({completed_above} completed items above)")
            result_parts.append("")

        # Include the active section heading
        active_heading, active_body = sections[active_idx]
        result_parts.append(active_heading)

        # Include checked items as a summary count, then unchecked items up to limit
        checked_in_section = 0
        unchecked_count = 0
        remaining_unchecked = 0

        for line in active_body:
            if re.match(r"\s*- \[x\]", line, re.IGNORECASE):
                checked_in_section += 1
            elif re.match(r"\s*- \[ \]", line):
                if unchecked_count < self.max_unchecked_items:
                    if checked_in_section > 0 and unchecked_count == 0:
                        result_parts.append(
                            f"  ({checked_in_section} completed items in this section)"
                        )
                    result_parts.append(line)
                    unchecked_count += 1
                else:
                    remaining_unchecked += 1
            else:
                # Non-checkbox lines (descriptions, blank lines) — include if we're
                # still within the unchecked window
                if unchecked_count > 0 and unchecked_count <= self.max_unchecked_items:
                    result_parts.append(line)
                elif unchecked_count == 0:
                    # Lines before any unchecked item (section description)
                    if not re.match(r"\s*- \[x\]", line, re.IGNORECASE):
                        result_parts.append(line)

        # If there were checked items but no unchecked items were added yet
        if checked_in_section > 0 and unchecked_count == 0:
            result_parts.append(
                f"  ({checked_in_section} completed items in this section)"
            )

        if remaining_unchecked > 0:
            result_parts.append(f"  ... and {remaining_unchecked} more unchecked items")

        # Summarize sections below the active one
        sections_below = len(sections) - active_idx - 1
        if sections_below > 0:
            total_below = 0
            for i in range(active_idx + 1, len(sections)):
                _, body = sections[i]
                total_below += sum(
                    1 for line in body if re.match(r"\s*- \[ \]", line)
                )
            if total_below > 0:
                result_parts.append("")
                result_parts.append(
                    f"({sections_below} more sections below with {total_below} unchecked items)"
                )

        return "\n".join(result_parts)


def estimate_tokens(text: str) -> int:
    """Estimate token count using the 4-char heuristic (~250 tokens per 1K chars).

    This is a fast approximation. Actual tokenization varies by model,
    but 4 chars/token is a reasonable average for English text + code.

    Args:
        text: Input text to estimate tokens for.

    Returns:
        Estimated token count.
    """
    if not text:
        return 0
    return max(1, len(text) // 4)


# =============================================================================
# SDK-CONTEXT-2: Prompt Cache Optimization
# =============================================================================


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
