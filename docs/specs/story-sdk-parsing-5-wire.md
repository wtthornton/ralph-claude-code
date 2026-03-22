# Story RALPH-SDK-PARSING-5: Wire New Parser into _parse_response()

**Epic:** [Structured Response Parsing](epic-sdk-structured-parsing.md)
**Priority:** High
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/agent.py`

---

## Problem

After PARSING-1 through PARSING-4 are implemented, the new `parse_ralph_status()` function
and `RalphStatusBlock` model exist but are not used. The agent still calls the old
`_extract_ralph_status()` regex method in two places:

1. `_parse_result_object()` (agent.py:452) — after extracting text from a JSONL result object
2. `_parse_text_status()` (agent.py:487-490) — fallback when JSONL parsing fails

The old methods must be replaced with calls to `parse_ralph_status()` while preserving
the existing fallback chain and error handling behavior.

## Solution

Replace both `_parse_result_object()` and `_parse_text_status()` internals to delegate
to `parse_ralph_status()`. Convert the returned `RalphStatusBlock` to `RalphStatus` via
`to_ralph_status()`. Keep the session ID extraction in `_parse_result_object()` since
that is outside the scope of the status parser.

If `parse_ralph_status()` raises `ValidationError`, fall back to a default `RalphStatus`
(current behavior on parse failure) and log a warning.

## Implementation

### Change 1: `sdk/ralph_sdk/agent.py` — Update imports

```python
# BEFORE:
from ralph_sdk.status import CircuitBreakerState, RalphStatus

# AFTER:
from ralph_sdk.status import CircuitBreakerState, RalphStatus, RalphStatusBlock
from ralph_sdk.parsing import parse_ralph_status
```

### Change 2: `sdk/ralph_sdk/agent.py` — Replace `_parse_response()`

```python
# BEFORE (agent.py:401-426):
def _parse_response(self, stdout: str, return_code: int) -> RalphStatus:
    """Parse Claude CLI response (JSONL or text)."""
    status = RalphStatus()

    if return_code != 0:
        status.status = "ERROR"
        status.error = f"Claude CLI exited with code {return_code}"
        return status

    # Try JSONL parsing first (primary path since v1.2.0)
    for line in reversed(stdout.strip().splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if obj.get("type") == "result":
                return self._parse_result_object(obj)
        except json.JSONDecodeError:
            continue

    # Fallback: extract RALPH_STATUS from text
    return self._parse_text_status(stdout)

# AFTER:
def _parse_response(self, stdout: str, return_code: int) -> RalphStatus:
    """Parse Claude CLI response using multi-strategy parser.

    Delegates to parse_ralph_status() which tries JSON block, JSONL, and
    text fallback strategies in order.
    """
    status = RalphStatus()

    if return_code != 0:
        status.status = "ERROR"
        status.error = f"Claude CLI exited with code {return_code}"
        return status

    # Extract session ID from JSONL before status parsing
    self._extract_session_id(stdout)

    # Multi-strategy parsing (PARSING-2)
    try:
        block = parse_ralph_status(stdout)
        return block.to_ralph_status()
    except Exception as e:
        logger.warning("parse_ralph_status() failed, using default status: %s", e)
        return self._legacy_parse_response(stdout)
```

### Change 3: `sdk/ralph_sdk/agent.py` — Extract session ID handling

```python
# NEW METHOD (extracted from _parse_result_object):
def _extract_session_id(self, stdout: str) -> None:
    """Extract and save session ID from JSONL result objects."""
    for line in reversed(stdout.strip().splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if obj.get("type") == "result" and "session_id" in obj:
                self.session_id = obj["session_id"]
                self._save_session()
                return
        except json.JSONDecodeError:
            continue
```

### Change 4: `sdk/ralph_sdk/agent.py` — Rename old methods as legacy fallback

```python
# BEFORE:
def _parse_result_object(self, obj: dict[str, Any]) -> RalphStatus:
    ...
def _extract_ralph_status(self, text: str, status: RalphStatus) -> RalphStatus:
    ...
def _parse_text_status(self, text: str) -> RalphStatus:
    ...

# AFTER:
def _legacy_parse_response(self, stdout: str) -> RalphStatus:
    """Legacy fallback: original JSONL + regex parsing.

    Kept as safety net if parse_ralph_status() fails unexpectedly.
    Will be removed once the new parser is battle-tested.
    """
    for line in reversed(stdout.strip().splitlines()):
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if obj.get("type") == "result":
                return self._legacy_parse_result_object(obj)
        except json.JSONDecodeError:
            continue
    return self._legacy_extract_ralph_status(stdout, RalphStatus())

def _legacy_parse_result_object(self, obj: dict[str, Any]) -> RalphStatus:
    """Legacy: Parse a JSONL result object into RalphStatus."""
    status = RalphStatus()
    result_text = ""
    if "result" in obj:
        result_text = obj["result"]
    elif "content" in obj:
        content = obj["content"]
        if isinstance(content, list):
            for block in content:
                if isinstance(block, dict) and block.get("type") == "text":
                    result_text += block.get("text", "")
        elif isinstance(content, str):
            result_text = content
    if "session_id" in obj:
        self.session_id = obj["session_id"]
        self._save_session()
    return self._legacy_extract_ralph_status(result_text, status)

def _legacy_extract_ralph_status(self, text: str, status: RalphStatus) -> RalphStatus:
    """Legacy: Extract RALPH_STATUS fields from response text via regex."""
    text = text.replace("\\n", "\n")
    field_patterns = {
        "WORK_TYPE": r"WORK_TYPE:\s*(.+?)(?:\n|$)",
        "COMPLETED_TASK": r"COMPLETED_TASK:\s*(.+?)(?:\n|$)",
        "NEXT_TASK": r"NEXT_TASK:\s*(.+?)(?:\n|$)",
        "PROGRESS_SUMMARY": r"PROGRESS_SUMMARY:\s*(.+?)(?:\n|$)",
        "EXIT_SIGNAL": r"EXIT_SIGNAL:\s*(.+?)(?:\n|$)",
    }
    for field_name, pattern in field_patterns.items():
        match = re.search(pattern, text, re.IGNORECASE)
        if match:
            value = match.group(1).strip()
            if field_name == "WORK_TYPE":
                status.work_type = value
            elif field_name == "COMPLETED_TASK":
                status.completed_task = value
            elif field_name == "NEXT_TASK":
                status.next_task = value
            elif field_name == "PROGRESS_SUMMARY":
                status.progress_summary = value
            elif field_name == "EXIT_SIGNAL":
                status.exit_signal = value.strip().lower() in ("true", "yes", "1")
    return status
```

## Acceptance Criteria

- [ ] `_parse_response()` calls `parse_ralph_status()` as primary path
- [ ] On `parse_ralph_status()` success, returns `block.to_ralph_status()`
- [ ] On `parse_ralph_status()` failure, falls back to `_legacy_parse_response()`
- [ ] Fallback logs a warning with the exception message
- [ ] Session ID extraction still works (moved to `_extract_session_id()`)
- [ ] Non-zero return code still returns ERROR status immediately (no parsing attempted)
- [ ] Old methods renamed with `_legacy_` prefix, not deleted
- [ ] All existing unit tests pass without modification
- [ ] All existing integration tests pass without modification
- [ ] `import ralph_sdk` still works (no import errors)

## Test Plan

```python
import json
import pytest
from unittest.mock import patch, MagicMock
from ralph_sdk.agent import RalphAgent
from ralph_sdk.status import RalphStatus

def _make_agent():
    """Create an agent instance without full initialization."""
    agent = RalphAgent.__new__(RalphAgent)
    agent.session_id = ""
    agent.ralph_dir = "/tmp/test_ralph"
    agent.config = MagicMock()
    return agent

def test_parse_response_nonzero_return_code():
    agent = _make_agent()
    status = agent._parse_response("some output", return_code=1)
    assert status.status == "ERROR"
    assert "exit code 1" in status.error

def test_parse_response_json_block():
    agent = _make_agent()
    stdout = '''{"type":"system","text":"init"}
{"type":"result","session_id":"sess-123","result":"```json\\n{\\"version\\":1,\\"status\\":\\"COMPLETED\\",\\"exit_signal\\":true,\\"tasks_completed\\":2,\\"files_modified\\":3,\\"progress_summary\\":\\"Done\\",\\"work_type\\":\\"IMPLEMENTATION\\",\\"tests_status\\":\\"PASSING\\"}\\n```"}'''
    with patch.object(agent, "_save_session"):
        status = agent._parse_response(stdout, return_code=0)
    assert status.status == "COMPLETED"
    assert status.exit_signal is True
    assert status.work_type == "IMPLEMENTATION"

def test_parse_response_text_fallback():
    agent = _make_agent()
    stdout = "WORK_TYPE: TESTING\nEXIT_SIGNAL: false\nPROGRESS_SUMMARY: Running tests"
    status = agent._parse_response(stdout, return_code=0)
    assert status.work_type == "TESTING"
    assert status.exit_signal is False

def test_parse_response_falls_back_to_legacy_on_failure():
    agent = _make_agent()
    stdout = "WORK_TYPE: TESTING\nEXIT_SIGNAL: false"
    with patch("ralph_sdk.agent.parse_ralph_status", side_effect=Exception("boom")):
        status = agent._parse_response(stdout, return_code=0)
    # Legacy parser should handle it
    assert status.work_type == "TESTING"

def test_session_id_extracted():
    agent = _make_agent()
    stdout = '{"type":"result","session_id":"sess-abc","result":"WORK_TYPE: TESTING\\nEXIT_SIGNAL: false"}'
    with patch.object(agent, "_save_session"):
        agent._parse_response(stdout, return_code=0)
    assert agent.session_id == "sess-abc"

def test_legacy_methods_still_exist():
    """Legacy methods kept as fallback."""
    agent = _make_agent()
    assert hasattr(agent, "_legacy_parse_response")
    assert hasattr(agent, "_legacy_parse_result_object")
    assert hasattr(agent, "_legacy_extract_ralph_status")

def test_existing_tests_pass():
    """Meta-test: run existing test suite to verify no regressions.

    Execute: pytest tests/sdk/ -v
    All tests must pass without modification.
    """
    pass  # This is a manual verification step
```
