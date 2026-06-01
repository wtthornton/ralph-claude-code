"""Structured files_changed extraction from JSONL tool_use (SDK-OUTPUT-1).

Three strategies, applied while scanning the JSONL stream:
  1. Write/Edit/MultiEdit `file_path` input parameter.
  2. Bash `git add <path>` argument tokens.
  3. The body of a `git diff --name-only` tool_result that follows a matching
     Bash tool_use.
"""

from __future__ import annotations

import json
import re
from typing import Any

# Tool names whose `file_path` input parameter represents a changed file
_FILE_CHANGE_TOOLS = frozenset({"Write", "Edit", "MultiEdit"})

# Pattern matching ``git add <path>`` arguments inside a Bash command string.
# Handles both ``Bash(git add ...)`` and plain ``git add ...`` invocations.
_GIT_ADD_PATTERN = re.compile(
    r"git\s+add\s+(?:-[A-Za-z]+\s+)*(.+)",
    re.IGNORECASE,
)

# Pattern matching ``git diff --name-only`` output lines (plain file paths,
# one per line).  Used to extract paths from tool_result content.
_DIFF_NAME_ONLY_TRIGGER = re.compile(
    r"git\s+diff\s+.*--name-only",
    re.IGNORECASE,
)


_GIT_ADD_SKIP_TOKENS = frozenset({".", "-A", "--all", "-u", "--update"})
_DIFF_PREFIXES = ("diff ", "index ", "---", "+++")


def _harvest_diff_paths(content: Any, seen: dict[str, None]) -> None:
    """Pull plain file paths out of a ``git diff --name-only`` tool_result body."""
    if not isinstance(content, str):
        return
    for diff_line in content.splitlines():
        path = diff_line.strip()
        if path and not path.startswith(_DIFF_PREFIXES):
            seen.setdefault(path, None)


def _harvest_git_add_tokens(command: str, seen: dict[str, None]) -> None:
    match = _GIT_ADD_PATTERN.search(command)
    if not match:
        return
    for token in match.group(1).strip().split():
        token = token.strip("'\"")
        if token and token not in _GIT_ADD_SKIP_TOKENS:
            seen.setdefault(token, None)


def _process_tool_use(
    tool_name: str, tool_input: dict[str, Any], seen: dict[str, None]
) -> bool:
    """Update `seen` from a tool_use record. Returns True iff this is git diff --name-only."""
    if tool_name in _FILE_CHANGE_TOOLS:
        file_path = tool_input.get("file_path")
        if isinstance(file_path, str) and file_path:
            seen.setdefault(file_path, None)
        return False
    if tool_name == "Bash":
        command = tool_input.get("command", "")
        if isinstance(command, str):
            _harvest_git_add_tokens(command, seen)
            if _DIFF_NAME_ONLY_TRIGGER.search(command):
                return True
    return False


def extract_files_changed(text: str) -> list[str]:
    """Extract unique file paths from Claude JSONL output.

    Three strategies: Write/Edit/MultiEdit `file_path`, Bash `git add <path>`,
    and the body of a `git diff --name-only` tool_result that follows a
    matching Bash tool_use. Returns paths in first-seen order, deduplicated.
    """
    seen: dict[str, None] = {}
    awaiting_diff = False

    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            continue

        obj_type = obj.get("type", "")

        if awaiting_diff and obj_type == "tool_result":
            awaiting_diff = False
            _harvest_diff_paths(obj.get("content", ""), seen)
            continue

        if obj_type != "tool_use":
            if obj_type != "tool_result":
                awaiting_diff = False
            continue

        tool_input = obj.get("input")
        if not isinstance(tool_input, dict):
            continue

        if _process_tool_use(obj.get("name", ""), tool_input, seen):
            awaiting_diff = True

    return list(seen)
