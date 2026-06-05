"""Ralph SDK Context Management — progressive loading and prompt cache optimization.

SDK-CONTEXT-1: Progressive Context Loading — trims fix_plan.md to current epic section.
SDK-CONTEXT-2: Prompt Cache Optimization — splits prompts into stable/dynamic parts.
"""

from __future__ import annotations

import re

from ralph_sdk.prompt_cache import (
    PromptCacheStats,
    PromptParts,
    split_prompt,
)

__all__ = [
    "ContextManager",
    "PromptCacheStats",
    "PromptParts",
    "estimate_tokens",
    "split_prompt",
]

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

    # ------------------------------------------------------------------
    # Public helpers
    # ------------------------------------------------------------------

    @staticmethod
    def estimate_tokens(text: str) -> int:
        """Estimate token count using the 4-char heuristic.

        Convenience method — delegates to the module-level
        :func:`estimate_tokens` so callers can use either form.
        """
        return estimate_tokens(text)

    # ------------------------------------------------------------------
    # trim_fix_plan — SDK-parity signature (Issue #226)
    # ------------------------------------------------------------------

    def trim_fix_plan(
        self,
        plan_content: str,
        current_section: str | None = None,
        max_items: int = 10,
    ) -> str:
        """Trim fix_plan.md to the active section with progressive summarization.

        Identifies the current epic section, includes only the current + next
        N unchecked items, and summarizes completed sections as
        "N/M tasks complete".

        Matches ``ralph_build_progressive_context()`` from
        ``lib/context_management.sh`` (CTXMGMT-1).

        Args:
            plan_content: Full fix_plan.md content.
            current_section: Optional section heading text (without ``##``)
                to force as the active section.  When *None*, the first
                section containing unchecked items is used.
            max_items: Maximum number of unchecked items to include
                from the active section (default 10, matching
                ``RALPH_MAX_PLAN_ITEMS``).

        Returns:
            Trimmed content with completed sections summarized.
        """
        if not plan_content or not plan_content.strip():
            return plan_content

        effective_max = max_items if max_items > 0 else self.max_unchecked_items

        return self._trim_sections(plan_content, current_section, effective_max)

    # ------------------------------------------------------------------
    # Internal implementation
    # ------------------------------------------------------------------

    @staticmethod
    def _parse_sections(
        content: str,
        section_marker: str = "##",
    ) -> tuple[list[str], list[tuple[str, list[str]]]]:
        """Parse markdown content into preamble and sections.

        Returns:
            (preamble_lines, sections) where each section is
            ``(heading_line, body_lines)``.
        """
        lines = content.splitlines()

        sections: list[tuple[str, list[str]]] = []
        current_heading = ""
        current_body: list[str] = []
        preamble_lines: list[str] = []

        for line in lines:
            if line.strip().startswith(section_marker) and not line.strip().startswith(
                section_marker + "#"
            ):
                # TAP-674: content before the first ##-heading is the
                # preamble, not an anonymous section. The previous branch
                # structure was unreachable (same predicate on both arms)
                # and silently folded preamble into a blank-heading section
                # which was then dropped downstream.
                if current_heading:
                    sections.append((current_heading, current_body))
                elif current_body:
                    preamble_lines = current_body
                current_heading = line
                current_body = []
            else:
                current_body.append(line)

        if current_heading:
            sections.append((current_heading, current_body))
        elif current_body and not preamble_lines:
            # Document has no ##-headings at all — treat entire doc as preamble
            preamble_lines = current_body

        return preamble_lines, sections

    def _trim_sections(
        self,
        content: str,
        current_section: str | None,
        max_items: int,
    ) -> str:
        """Core trimming logic shared by all calling paths."""
        preamble_lines, sections = self._parse_sections(content)
        if not sections:
            return content

        active_idx = _locate_active_section(sections, current_section)

        if active_idx == -1:
            return _format_all_complete_summary(preamble_lines, sections)
        return _format_active_section(preamble_lines, sections, active_idx, max_items)


# ---- Module-level helpers extracted from _trim_sections ----------------------

_UNCHECKED = re.compile(r"\s*- \[ \]")
_CHECKED = re.compile(r"\s*- \[x\]", re.IGNORECASE)
_CHECKBOX = re.compile(r"\s*- \[[xX ]\]")


def _normalize_heading(text: str) -> str:
    return text.strip().lstrip("#").strip().lower()


def _section_has_unchecked(body: list[str]) -> bool:
    return any(_UNCHECKED.match(line) for line in body)


def _count_section(body: list[str]) -> tuple[int, int]:
    """Return (total_items, checked_items) for a section body."""
    total = checked = 0
    for line in body:
        if _CHECKED.match(line):
            total += 1
            checked += 1
        elif _UNCHECKED.match(line):
            total += 1
    return total, checked


def _locate_active_section(
    sections: list[tuple[str, list[str]]],
    current_section: str | None,
) -> int:
    """Return the index of the active section, or -1 if all are complete."""
    if current_section is not None:
        needle = _normalize_heading(current_section)
        for i, (heading, _body) in enumerate(sections):
            if _normalize_heading(heading) == needle:
                return i
    for i, (_heading, body) in enumerate(sections):
        if _section_has_unchecked(body):
            return i
    return -1


def _format_all_complete_summary(
    preamble_lines: list[str],
    sections: list[tuple[str, list[str]]],
) -> str:
    """Render the section shape when every task is complete (TAP-674)."""
    total_items = total_checked = 0
    section_summaries: list[str] = []
    for heading, body in sections:
        section_total, section_checked = _count_section(body)
        total_items += section_total
        total_checked += section_checked
        if section_total > 0:
            section_summaries.append(
                f"{heading.rstrip()}  ({section_checked}/{section_total} done)"
            )
        elif heading.strip():
            section_summaries.append(heading.rstrip())

    parts: list[str] = []
    if preamble_lines:
        parts.extend(preamble_lines)
        parts.append("")
    if section_summaries:
        parts.extend(section_summaries)
        parts.append("")
    if total_items > 0:
        parts.append(
            f"({total_checked}/{total_items} tasks complete — all tasks done)"
        )
    return "\n".join(parts).rstrip()


def _summarize_completed_section(heading: str, body: list[str]) -> str | None:
    """Render a one-line summary for a section above the active one."""
    total = sum(1 for line in body if _CHECKBOX.match(line))
    checked = sum(1 for line in body if _CHECKED.match(line))
    if total == 0:
        return None
    return f"{heading.rstrip()}  ({checked}/{total} tasks complete)"


def _emit_active_body(
    body: list[str], max_items: int, parts: list[str]
) -> int:
    """Emit lines from the active section body. Returns remaining_unchecked count."""
    checked = total = unchecked_count = remaining = 0
    for line in body:
        if _CHECKED.match(line):
            checked += 1
            total += 1
            continue
        if _UNCHECKED.match(line):
            total += 1
            if unchecked_count < max_items:
                if checked > 0 and unchecked_count == 0:
                    parts.append(
                        f"  ({checked}/{total} tasks complete in this section)"
                    )
                parts.append(line)
                unchecked_count += 1
            else:
                remaining += 1
            continue
        # Non-checkbox lines: include while inside the unchecked window
        if unchecked_count <= max_items:
            parts.append(line)

    if checked > 0 and unchecked_count == 0:
        parts.append(f"  ({checked}/{total} tasks complete in this section)")
    return remaining


def _format_active_section(
    preamble_lines: list[str],
    sections: list[tuple[str, list[str]]],
    active_idx: int,
    max_items: int,
) -> str:
    parts: list[str] = []
    if preamble_lines:
        parts.extend(preamble_lines)
        parts.append("")

    for heading, body in sections[:active_idx]:
        summary = _summarize_completed_section(heading, body)
        if summary:
            parts.append(summary)
    if active_idx > 0:
        parts.append("")

    active_heading, active_body = sections[active_idx]
    parts.append(active_heading)

    remaining = _emit_active_body(active_body, max_items, parts)
    if remaining > 0:
        parts.append(f"  ... and {remaining} more unchecked items")

    _emit_sections_below_summary(sections, active_idx, parts)

    return "\n".join(parts)


def _emit_sections_below_summary(
    sections: list[tuple[str, list[str]]], active_idx: int, parts: list[str]
) -> None:
    """Append a one-line summary of unchecked work in sections after the active one."""
    sections_below = len(sections) - active_idx - 1
    if sections_below <= 0:
        return
    total_below = sum(
        1
        for _heading, body in sections[active_idx + 1:]
        for line in body
        if _UNCHECKED.match(line)
    )
    if total_below > 0:
        parts.append("")
        parts.append(
            f"({sections_below} more sections below with {total_below} unchecked items)"
        )


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
