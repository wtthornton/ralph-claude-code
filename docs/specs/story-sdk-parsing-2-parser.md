# Story RALPH-SDK-PARSING-2: Implement Multi-Strategy parse_ralph_status()

**Epic:** [Structured Response Parsing](epic-sdk-structured-parsing.md)
**Priority:** Critical
**Status:** Pending
**Effort:** Medium
**Component:** New file `sdk/ralph_sdk/parsing.py`

---

## Problem

The SDK currently parses Claude output using a single strategy — regex extraction in
`_extract_ralph_status()` (agent.py:454-485). This has three failure modes:

1. **JSON-escaped newlines**: JSONL output contains `\\n` which breaks regex line matching
   (the `replace("\\n", "\n")` workaround on line 460 is fragile)
2. **No structured path**: When Claude outputs a properly formatted JSON status block,
   the regex path still runs — slower and less reliable than direct JSON parse
3. **Silent failures**: If no regex matches, the method returns a default `RalphStatus`
   with no indication that parsing failed

Claude Code's output format varies: sometimes a fenced JSON code block, sometimes JSONL
with `{"type": "result"}`, sometimes plain text with `WORK_TYPE: ...` lines. A single
parser that tries all three strategies in reliability order is needed.

## Solution

Create `sdk/ralph_sdk/parsing.py` with a `parse_ralph_status()` function that tries
three strategies in order:

1. **JSON path** — Find a ` ```json ` fenced code block containing a `"version"` key,
   parse it, validate with `RalphStatusBlock` Pydantic model
2. **JSONL path** — Find a `{"type": "result"}` line, extract the result text, then
   look for status fields in that text (either as embedded JSON or regex)
3. **Text fallback** — Current regex extraction from `_extract_ralph_status()`

Returns a `RalphStatusBlock` (from PARSING-1). Raises `ValidationError` only if all
three strategies fail and no usable data was extracted.

## Implementation

### New file: `sdk/ralph_sdk/parsing.py`

```python
"""Multi-strategy parser for Ralph status blocks from Claude output."""

from __future__ import annotations

import json
import logging
import re
from typing import Any

from pydantic import ValidationError

from ralph_sdk.status import RalphStatusBlock, RalphStatus

logger = logging.getLogger("ralph.sdk.parsing")


def parse_ralph_status(raw_output: str) -> RalphStatusBlock:
    """Parse Claude output into a validated RalphStatusBlock.

    Tries three strategies in order:
    1. JSON fenced code block with "version" key
    2. JSONL {"type": "result"} line
    3. Text fallback (regex extraction)

    Returns RalphStatusBlock with validated fields.
    Raises ValidationError if no strategy produces valid data.
    """
    # Strategy 1: JSON fenced code block
    block = _try_json_code_block(raw_output)
    if block is not None:
        logger.info("Parsed status via JSON code block (strategy=json)")
        return block

    # Strategy 2: JSONL result object
    block = _try_jsonl_result(raw_output)
    if block is not None:
        logger.info("Parsed status via JSONL result (strategy=jsonl)")
        return block

    # Strategy 3: Text fallback (regex)
    block = _try_text_fallback(raw_output)
    if block is not None:
        logger.info("Parsed status via text fallback (strategy=text)")
        return block

    # All strategies failed
    raise ValidationError.from_exception_data(
        title="RalphStatusBlock",
        line_errors=[],
    )


def _try_json_code_block(text: str) -> RalphStatusBlock | None:
    """Strategy 1: Find ```json fenced code block with 'version' key."""
    # Match ```json ... ``` blocks
    pattern = r"```json\s*\n(.*?)\n\s*```"
    for match in re.finditer(pattern, text, re.DOTALL):
        try:
            data = json.loads(match.group(1))
            if isinstance(data, dict) and "version" in data:
                return RalphStatusBlock.model_validate(data)
        except (json.JSONDecodeError, ValidationError):
            continue
    return None


def _try_jsonl_result(text: str) -> RalphStatusBlock | None:
    """Strategy 2: Find {"type": "result"} line, extract status fields."""
    for line in reversed(text.strip().splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if obj.get("type") != "result":
                continue
            # Extract result text from the result object
            result_text = _extract_result_text(obj)
            if result_text:
                # Try parsing result text as JSON status block first
                try:
                    data = json.loads(result_text)
                    if isinstance(data, dict) and "version" in data:
                        return RalphStatusBlock.model_validate(data)
                except (json.JSONDecodeError, ValidationError):
                    pass
                # Try finding JSON block within result text
                block = _try_json_code_block(result_text)
                if block is not None:
                    return block
                # Fall through to extract fields via regex from result text
                return _extract_fields_from_text(result_text)
        except json.JSONDecodeError:
            continue
    return None


def _try_text_fallback(text: str) -> RalphStatusBlock | None:
    """Strategy 3: Regex extraction matching _extract_ralph_status()."""
    # Auto-unescape JSON-encoded newlines (matching STREAM-3)
    text = text.replace("\\n", "\n")
    return _extract_fields_from_text(text)


def _extract_result_text(obj: dict[str, Any]) -> str:
    """Extract text content from a JSONL result object."""
    if "result" in obj:
        return obj["result"]
    if "content" in obj:
        content = obj["content"]
        if isinstance(content, list):
            parts = []
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    parts.append(block.get("text", ""))
            return "".join(parts)
        if isinstance(content, str):
            return content
    return ""


def _extract_fields_from_text(text: str) -> RalphStatusBlock | None:
    """Extract RALPH_STATUS fields from text via regex.

    Mirrors agent.py _extract_ralph_status() but returns RalphStatusBlock.
    """
    field_patterns = {
        "work_type": r"WORK_TYPE:\s*(.+?)(?:\n|$)",
        "progress_summary": r"PROGRESS_SUMMARY:\s*(.+?)(?:\n|$)",
        "exit_signal": r"EXIT_SIGNAL:\s*(.+?)(?:\n|$)",
        "tasks_completed": r"TASKS_COMPLETED(?:_THIS_LOOP)?:\s*(\d+)",
        "files_modified": r"FILES_MODIFIED:\s*(\d+)",
        "tests_status": r"TESTS_STATUS:\s*(.+?)(?:\n|$)",
    }

    extracted: dict[str, Any] = {}
    for field_name, pattern in field_patterns.items():
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            value = match.group(1).strip()
            if field_name == "exit_signal":
                extracted[field_name] = _coerce_bool(value)
            elif field_name in ("tasks_completed", "files_modified"):
                try:
                    extracted[field_name] = int(value)
                except ValueError:
                    pass
            else:
                extracted[field_name] = value

    if not extracted:
        return None

    # Build with defaults for missing fields
    try:
        return RalphStatusBlock.model_validate(extracted)
    except ValidationError:
        # If validation fails (e.g. bad enum value), return None
        return None


def _coerce_bool(value: str) -> bool:
    """Coerce string to bool, handling all common representations."""
    return value.strip().lower() in ("true", "yes", "1")
```

### Change 2: `sdk/ralph_sdk/__init__.py` — Export new module

```python
# BEFORE:
from ralph_sdk.status import RalphStatus, CircuitBreakerState

# AFTER:
from ralph_sdk.status import RalphStatus, CircuitBreakerState, RalphStatusBlock
from ralph_sdk.parsing import parse_ralph_status
```

## Acceptance Criteria

- [ ] `parse_ralph_status()` exists in `sdk/ralph_sdk/parsing.py`
- [ ] Strategy 1 (JSON code block): parses ` ```json\n{"version":1,...}\n``` ` correctly
- [ ] Strategy 2 (JSONL result): parses `{"type":"result","result":"..."}` correctly
- [ ] Strategy 3 (text fallback): regex extraction works for `WORK_TYPE: IMPLEMENTATION\n...` format
- [ ] Strategies tried in order: JSON block -> JSONL result -> text fallback
- [ ] Returns `RalphStatusBlock` (validated Pydantic model)
- [ ] Raises `ValidationError` when all strategies fail on empty/garbage input
- [ ] Strategy used is logged at INFO level
- [ ] `_extract_result_text()` handles both `result` and `content` (list of blocks) formats
- [ ] JSON-escaped `\\n` auto-unescaped in text fallback path

## Test Plan

```python
import pytest
from pydantic import ValidationError
from ralph_sdk.parsing import parse_ralph_status, _try_json_code_block, _try_text_fallback

def test_json_code_block_strategy():
    raw = '''Here is the status:

```json
{
  "version": 1,
  "status": "COMPLETED",
  "exit_signal": true,
  "tasks_completed": 3,
  "files_modified": 5,
  "progress_summary": "All tasks done",
  "work_type": "IMPLEMENTATION",
  "tests_status": "PASSING"
}
```

Done.'''
    block = parse_ralph_status(raw)
    assert block.version == 1
    assert block.exit_signal is True
    assert block.tasks_completed == 3
    assert block.work_type.value == "IMPLEMENTATION"

def test_jsonl_result_strategy():
    raw = '{"type":"system","text":"init"}\n{"type":"result","result":"WORK_TYPE: TESTING\\nEXIT_SIGNAL: false\\nPROGRESS_SUMMARY: Running tests"}'
    block = parse_ralph_status(raw)
    assert block.work_type.value == "TESTING"
    assert block.exit_signal is False

def test_jsonl_result_with_embedded_json():
    raw = '{"type":"result","result":"```json\\n{\\"version\\":1,\\"status\\":\\"COMPLETED\\",\\"exit_signal\\":true,\\"tasks_completed\\":2,\\"files_modified\\":4,\\"progress_summary\\":\\"Done\\",\\"work_type\\":\\"IMPLEMENTATION\\",\\"tests_status\\":\\"PASSING\\"}\\n```"}'
    block = parse_ralph_status(raw)
    assert block.status.value == "COMPLETED"

def test_text_fallback_strategy():
    raw = """Some output here...
WORK_TYPE: REFACTORING
PROGRESS_SUMMARY: Cleaned up module
EXIT_SIGNAL: false
TASKS_COMPLETED: 1
FILES_MODIFIED: 3
TESTS_STATUS: PASSING
"""
    block = parse_ralph_status(raw)
    assert block.work_type.value == "REFACTORING"
    assert block.tasks_completed == 1

def test_text_fallback_with_escaped_newlines():
    raw = "WORK_TYPE: IMPLEMENTATION\\nEXIT_SIGNAL: true\\nPROGRESS_SUMMARY: Done"
    block = parse_ralph_status(raw)
    assert block.work_type.value == "IMPLEMENTATION"
    assert block.exit_signal is True

def test_all_strategies_fail():
    with pytest.raises(ValidationError):
        parse_ralph_status("no status information here at all")

def test_empty_input():
    with pytest.raises(ValidationError):
        parse_ralph_status("")

def test_json_block_preferred_over_text():
    """JSON block strategy should win even if text fields also present."""
    raw = '''WORK_TYPE: TESTING

```json
{"version": 1, "status": "COMPLETED", "work_type": "IMPLEMENTATION", "tests_status": "PASSING"}
```
'''
    block = parse_ralph_status(raw)
    # JSON block should win — work_type is IMPLEMENTATION, not TESTING
    assert block.work_type.value == "IMPLEMENTATION"

def test_content_list_extraction():
    raw = '{"type":"result","content":[{"type":"text","text":"WORK_TYPE: DOCUMENTATION\\nEXIT_SIGNAL: false"}]}'
    block = parse_ralph_status(raw)
    assert block.work_type.value == "DOCUMENTATION"
```
