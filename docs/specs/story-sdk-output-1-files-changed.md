# Story SDK-OUTPUT-1: Structured `files_changed` on TaskResult

**Epic:** [SDK Structured Output & Observability](epic-sdk-structured-output.md)
**Priority:** P1
**Status:** Pending
**Effort:** 0.5 day
**Component:** `ralph_sdk/parsing.py`, `ralph_sdk/agent.py`

---

## Problem

TheStudio uses a regex heuristic to extract changed file paths from Ralph's freeform output — look for lines starting with `"- "` containing dots or slashes. This heuristic is:

1. **Duplicated** in `ralph_bridge.py:203-218` and `primary_agent.py:125-141`
2. **Fragile**: False positives on markdown list items that happen to contain paths (e.g., `"- See docs/README.md for details"`)
3. **Incomplete**: Misses file changes made via tool calls that aren't mentioned in the summary

The SDK should return `files_changed: list[str]` as a structured field on `TaskResult`, populated from actual sources: Claude's tool use records (Write/Edit/Bash calls) and/or `git diff` output.

## Solution

Populate `TaskResult.files_changed` during response parsing by extracting file paths from tool use records in the JSONL stream. Falls back to `git diff --name-only` when tool use records aren't available.

## Implementation

```python
# In ralph_sdk/parsing.py:

import re

# Patterns for extracting file paths from tool use
WRITE_TOOL_PATTERN = re.compile(r'"file_path"\s*:\s*"([^"]+)"')
EDIT_TOOL_PATTERN = re.compile(r'"file_path"\s*:\s*"([^"]+)"')
BASH_FILE_PATTERN = re.compile(r'(?:cat|mv|cp|touch|mkdir)\s+(?:[-\w]+\s+)*"?([^\s"]+\.\w+)"?')


def extract_files_from_tool_use(tool_records: list[dict]) -> list[str]:
    """Extract file paths from Claude's tool use records.

    Looks at Write, Edit, and file-modifying Bash commands.
    Returns deduplicated list of file paths.
    """
    files: set[str] = set()

    for record in tool_records:
        tool_name = record.get("tool", "")
        params = record.get("params", {})

        if tool_name in ("Write", "Edit"):
            file_path = params.get("file_path", "")
            if file_path:
                files.add(file_path)
        elif tool_name == "Bash":
            command = params.get("command", "")
            # Look for file-modifying commands
            matches = BASH_FILE_PATTERN.findall(command)
            files.update(matches)

    return sorted(files)


def extract_files_from_git_diff(diff_output: str) -> list[str]:
    """Extract file paths from git diff --name-only output."""
    return [line.strip() for line in diff_output.strip().split("\n") if line.strip()]
```

### Integrate with TaskResult

```python
# In ralph_sdk/agent.py, when constructing TaskResult:

# Option 1: From tool use records (preferred)
tool_records = self._extract_tool_records_from_stream(raw_output)
files_changed = extract_files_from_tool_use(tool_records)

# Option 2: From git diff (fallback)
if not files_changed and self._config.working_directory:
    diff_result = await self._run_command(
        ["git", "diff", "--name-only", "HEAD~1"],
        cwd=self._config.working_directory,
    )
    if diff_result.returncode == 0:
        files_changed = extract_files_from_git_diff(diff_result.stdout)

result = TaskResult(
    ...,
    files_changed=files_changed,
)
```

## Design Notes

- **Tool use first, git diff fallback**: Tool use records are the most reliable source — they capture exactly what Claude did. Git diff catches changes made by Bash commands that don't match our patterns.
- **Deduplicated and sorted**: Consistent output regardless of tool use order.
- **No freeform text parsing**: Deliberately avoids the regex-on-summary approach that TheStudio currently uses. If tool use and git diff both fail, `files_changed` is an empty list — better than false positives.
- **Minimal scope**: This story only populates the field. Downstream consumers (TheStudio) decide how to use it.

## Acceptance Criteria

- [ ] `TaskResult.files_changed` is a `list[str]` field
- [ ] Populated from Write/Edit tool use records when available
- [ ] Falls back to `git diff --name-only` when tool records unavailable
- [ ] File paths are deduplicated and sorted
- [ ] No freeform text regex parsing
- [ ] Empty list returned when no files detected (not None)

## Test Plan

```python
import pytest
from ralph_sdk.parsing import extract_files_from_tool_use, extract_files_from_git_diff

class TestFilesChangedExtraction:
    def test_extract_from_write_tool(self):
        records = [
            {"tool": "Write", "params": {"file_path": "src/main.py"}},
            {"tool": "Write", "params": {"file_path": "tests/test_main.py"}},
        ]
        files = extract_files_from_tool_use(records)
        assert files == ["src/main.py", "tests/test_main.py"]

    def test_extract_from_edit_tool(self):
        records = [
            {"tool": "Edit", "params": {"file_path": "src/config.py", "old_string": "x", "new_string": "y"}},
        ]
        files = extract_files_from_tool_use(records)
        assert files == ["src/config.py"]

    def test_deduplicate(self):
        records = [
            {"tool": "Write", "params": {"file_path": "src/main.py"}},
            {"tool": "Edit", "params": {"file_path": "src/main.py"}},
        ]
        files = extract_files_from_tool_use(records)
        assert files == ["src/main.py"]

    def test_empty_tool_records(self):
        files = extract_files_from_tool_use([])
        assert files == []

    def test_extract_from_git_diff(self):
        diff = "src/main.py\ntests/test_main.py\n"
        files = extract_files_from_git_diff(diff)
        assert files == ["src/main.py", "tests/test_main.py"]

    def test_git_diff_empty(self):
        files = extract_files_from_git_diff("")
        assert files == []

    def test_ignores_non_file_tools(self):
        records = [
            {"tool": "Read", "params": {"file_path": "src/main.py"}},
            {"tool": "Grep", "params": {"pattern": "TODO"}},
        ]
        files = extract_files_from_tool_use(records)
        assert files == []  # Read and Grep don't modify files
```

## References

- TheStudio `ralph_bridge.py:203-218`: Regex heuristic (to be replaced)
- TheStudio `primary_agent.py:125-141`: Duplicated regex heuristic
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §2.1
