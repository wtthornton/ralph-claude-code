"""Permission denial detection from Claude CLI output (SDK-LIFECYCLE-3).

Scans both raw text lines and JSONL ``result`` / ``content`` fields for denial
indicators, then classifies each as user-fixable (resolvable by adding the tool
to ``ALLOWED_TOOLS``) or scope-locked (a built-in filesystem boundary the user
cannot lift via config alone).
"""

from __future__ import annotations

import json
import re
from typing import Any

from pydantic import BaseModel

# Patterns that indicate a user-fixable permission denial (bash command blocked
# by ALLOWED_TOOLS).  The user can resolve these by adding the tool to the
# allowed list.
_USER_FIXABLE_PATTERNS: list[re.Pattern[str]] = [
    re.compile(
        r"(?:tool|command)\s+(?:is\s+)?not\s+(?:allowed|permitted|in\s+allowed)",
        re.IGNORECASE,
    ),
    re.compile(
        r"Bash\(([^)]+)\)\s+(?:is\s+)?(?:not\s+allowed|blocked|denied)",
        re.IGNORECASE,
    ),
    re.compile(
        r"permission\s+denied.*?(?:Bash|tool)\s*\(",
        re.IGNORECASE,
    ),
    re.compile(
        r"not\s+in\s+(?:the\s+)?(?:allowed|permitted)\s+tools?\s+list",
        re.IGNORECASE,
    ),
]

# Patterns that indicate a scope-locked denial (built-in tool filesystem
# boundary, sandbox restriction).  These cannot be fixed by the user through
# config alone.
_SCOPE_LOCKED_PATTERNS: list[re.Pattern[str]] = [
    re.compile(
        r"outside\s+(?:the\s+)?(?:allowed|permitted)\s+(?:directory|directories|path|workspace)",
        re.IGNORECASE,
    ),
    re.compile(
        r"(?:cannot|can't)\s+(?:access|read|write|modify)\s+files?\s+outside",
        re.IGNORECASE,
    ),
    re.compile(
        r"filesystem\s+(?:boundary|restriction|sandbox)",
        re.IGNORECASE,
    ),
    re.compile(
        r"path\s+(?:is\s+)?(?:not\s+allowed|restricted|blocked)",
        re.IGNORECASE,
    ),
]

# General permission denial indicators — used to detect that the message is
# about a denial in the first place.
_DENIAL_INDICATORS: list[re.Pattern[str]] = [
    re.compile(r"permission\s+denied", re.IGNORECASE),
    re.compile(
        r"(?:tool|command)\s+(?:was\s+)?(?:denied|blocked|rejected|not\s+allowed)",
        re.IGNORECASE,
    ),
    re.compile(
        r"(?:cannot|can't|unable\s+to)\s+(?:use|run|execute|invoke)\s+(?:tool|command)",
        re.IGNORECASE,
    ),
]

# Pattern to extract tool name from denial messages.
_TOOL_NAME_PATTERN = re.compile(
    r"(?:tool|command)\s+[`'\"]?(\w+(?:\([^)]*\))?)[`'\"]?",
    re.IGNORECASE,
)


class PermissionDenialEvent(BaseModel):
    """A detected permission denial from Claude CLI output.

    Attributes:
        tool_name: The tool or command that was denied (e.g. ``"Bash(npm test)"``).
        denied_pattern: The pattern category that matched — one of
            ``"user_fixable"``, ``"scope_locked"``, or ``"unknown"``.
        is_user_fixable: True if the denial can be resolved by adding the tool
            to ``ALLOWED_TOOLS``; False for built-in filesystem boundary
            restrictions.
        raw_message: The raw line or message fragment containing the denial
            (truncated to 500 chars).
    """
    tool_name: str = ""
    denied_pattern: str = ""
    is_user_fixable: bool = False
    raw_message: str = ""


_CONTENT_BLOCK_TYPES = frozenset({"assistant", "content_block_delta", "content_block_stop"})


def _extract_content_strings(content: Any) -> list[str]:
    """Pull text strings out of a JSONL content field (str or list of blocks)."""
    if isinstance(content, str):
        return [content]
    if isinstance(content, list):
        return [
            item.get("text", "")
            for item in content
            if isinstance(item, dict) and item.get("type") == "text"
        ]
    return []


def _collect_jsonl_text(obj: dict[str, Any]) -> list[str]:
    """Pull denial-candidate text out of a single JSONL object."""
    out: list[str] = []
    obj_type = obj.get("type")
    if obj_type == "result":
        result_text = obj.get("result", "")
        if isinstance(result_text, str):
            out.append(result_text)
    elif obj_type in _CONTENT_BLOCK_TYPES:
        out.extend(_extract_content_strings(obj.get("content", "")))
    if obj.get("is_error"):
        error_text = obj.get("error", obj.get("result", ""))
        if isinstance(error_text, str):
            out.append(error_text)
    return out


def _gather_denial_candidates(output: str) -> list[str]:
    """Collect candidate denial lines from both JSONL fields and raw text."""
    candidates: list[str] = []
    for line in output.strip().splitlines():
        stripped = line.strip()
        if not stripped:
            continue
        try:
            obj = json.loads(stripped)
        except (json.JSONDecodeError, TypeError):
            candidates.append(stripped)
            continue
        candidates.extend(_collect_jsonl_text(obj))
    return candidates


def _classify_denial(text: str) -> tuple[str, bool] | None:
    """Return (denied_pattern, is_user_fixable) or None if `text` is not a denial."""
    is_user_fixable = any(p.search(text) for p in _USER_FIXABLE_PATTERNS)
    is_scope_locked = any(p.search(text) for p in _SCOPE_LOCKED_PATTERNS)
    has_indicator = any(p.search(text) for p in _DENIAL_INDICATORS)
    if not (is_user_fixable or is_scope_locked or has_indicator):
        return None
    if is_scope_locked and not is_user_fixable:
        return "scope_locked", False
    if is_user_fixable:
        return "user_fixable", True
    return "unknown", False


def _build_event(text: str, denied_pattern: str, fixable: bool) -> PermissionDenialEvent:
    tool_match = _TOOL_NAME_PATTERN.search(text)
    return PermissionDenialEvent(
        tool_name=tool_match.group(1) if tool_match else "",
        denied_pattern=denied_pattern,
        is_user_fixable=fixable,
        raw_message=text[:500],
    )


def detect_permission_denials(output: str) -> list[PermissionDenialEvent]:
    """Parse Claude's JSONL output for permission denial messages.

    Scans both raw text lines and JSONL ``result`` / ``content`` fields for
    denial indicators, then classifies each as user-fixable or scope-locked.
    """
    events: list[PermissionDenialEvent] = []
    seen: set[str] = set()
    for text in _gather_denial_candidates(output):
        classification = _classify_denial(text)
        if classification is None:
            continue
        dedup_key = text[:200]
        if dedup_key in seen:
            continue
        seen.add(dedup_key)
        denied_pattern, fixable = classification
        events.append(_build_event(text, denied_pattern, fixable))
    return events
