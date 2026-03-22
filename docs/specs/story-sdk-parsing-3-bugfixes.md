# Story RALPH-SDK-PARSING-3: Fix EXIT_SIGNAL Coercion and Multi-Result Handling

**Epic:** [Structured Response Parsing](epic-sdk-structured-parsing.md)
**Priority:** High
**Status:** Pending
**Effort:** Small
**Component:** `sdk/ralph_sdk/parsing.py`, `sdk/ralph_sdk/agent.py`

---

## Problem

Two known bugs in the current parsing code:

### Bug 1: EXIT_SIGNAL case-sensitivity inconsistency

In `_extract_ralph_status()` (agent.py:483):

```python
status.exit_signal = value.lower() in ("true", "yes", "1")
```

This handles `True`/`true`/`TRUE` but the `lower()` call is only applied in the regex
extraction path. Other code paths (e.g., direct JSON parsing of a JSONL result object)
may receive a boolean `true` from JSON or a string `"True"` — these are handled
differently depending on how the value arrives. The coercion must be uniform: any of
`true/True/TRUE/yes/Yes/YES/1` should produce `True`, and `false/False/FALSE/no/No/NO/0`
should produce `False`.

### Bug 2: Multi-result JSONL — silent last-wins with no warning

In `_parse_response()` (agent.py:414-423):

```python
for line in reversed(stdout.strip().splitlines()):
    ...
    if obj.get("type") == "result":
        return self._parse_result_object(obj)
```

This iterates in reverse and returns the **first** (i.e., last in output) result object.
If there are multiple result objects (e.g., from subagent completions or multi-task loops),
earlier results are silently discarded. There is no log message indicating how many results
were found or that any were skipped.

## Solution

### Fix 1: Uniform bool coercion

Add a `_coerce_bool()` helper in `parsing.py` (already drafted in PARSING-2) that handles
all representations. Apply it in every code path where `exit_signal` is extracted:

- Text regex extraction (`_extract_fields_from_text`)
- JSON parsing (Pydantic's validator handles `bool` type natively for JSON `true`/`false`)
- JSONL result object parsing

For the Pydantic model, add a field validator on `exit_signal` that coerces string inputs.

### Fix 2: Multi-result warning with last-valid selection

When scanning JSONL for result objects, count all results, use the last valid one, and
log a warning listing skipped results.

## Implementation

### Change 1: `sdk/ralph_sdk/status.py` — Add validator for exit_signal coercion

```python
# BEFORE (in RalphStatusBlock):
class RalphStatusBlock(BaseModel):
    exit_signal: bool = False

# AFTER:
from pydantic import field_validator

class RalphStatusBlock(BaseModel):
    exit_signal: bool = False

    @field_validator("exit_signal", mode="before")
    @classmethod
    def coerce_exit_signal(cls, v: Any) -> bool:
        """Uniform bool coercion for all input representations."""
        if isinstance(v, bool):
            return v
        if isinstance(v, (int, float)):
            return bool(v)
        if isinstance(v, str):
            return v.strip().lower() in ("true", "yes", "1")
        return False
```

### Change 2: `sdk/ralph_sdk/parsing.py` — Multi-result handling

```python
# BEFORE (in _try_jsonl_result):
def _try_jsonl_result(text: str) -> RalphStatusBlock | None:
    for line in reversed(text.strip().splitlines()):
        ...
        if obj.get("type") != "result":
            continue
        result_text = _extract_result_text(obj)
        ...

# AFTER:
def _try_jsonl_result(text: str) -> RalphStatusBlock | None:
    """Strategy 2: Find {"type": "result"} lines, use last valid, warn on multiples."""
    result_objects: list[dict] = []
    for line in text.strip().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
            if obj.get("type") == "result":
                result_objects.append(obj)
        except json.JSONDecodeError:
            continue

    if not result_objects:
        return None

    if len(result_objects) > 1:
        logger.warning(
            "Multiple result objects found in JSONL (%d total). "
            "Using last valid result; %d earlier results skipped.",
            len(result_objects), len(result_objects) - 1,
        )

    # Try results in reverse order (last first) until one validates
    for obj in reversed(result_objects):
        result_text = _extract_result_text(obj)
        if not result_text:
            continue
        # Try JSON block within result text
        block = _try_json_code_block(result_text)
        if block is not None:
            return block
        # Try regex extraction from result text
        block = _extract_fields_from_text(result_text)
        if block is not None:
            return block

    return None
```

### Change 3: `sdk/ralph_sdk/agent.py` — Align existing `_extract_ralph_status()` coercion

```python
# BEFORE (agent.py:483):
elif field_name == "EXIT_SIGNAL":
    status.exit_signal = value.lower() in ("true", "yes", "1")

# AFTER:
elif field_name == "EXIT_SIGNAL":
    status.exit_signal = value.strip().lower() in ("true", "yes", "1")
```

This is a minimal fix for the existing code path; the full coercion via Pydantic validator
takes over once PARSING-5 wires in the new parser.

## Acceptance Criteria

- [ ] `EXIT_SIGNAL: true` -> `True`
- [ ] `EXIT_SIGNAL: True` -> `True`
- [ ] `EXIT_SIGNAL: TRUE` -> `True`
- [ ] `EXIT_SIGNAL: yes` -> `True`
- [ ] `EXIT_SIGNAL: 1` -> `True`
- [ ] `EXIT_SIGNAL: false` -> `False`
- [ ] `EXIT_SIGNAL: False` -> `False`
- [ ] `EXIT_SIGNAL: FALSE` -> `False`
- [ ] `EXIT_SIGNAL: no` -> `False`
- [ ] `EXIT_SIGNAL: 0` -> `False`
- [ ] JSON boolean `true`/`false` handled natively by Pydantic
- [ ] Multi-result JSONL: last valid result used
- [ ] Multi-result JSONL: warning logged with count of total and skipped results
- [ ] Single-result JSONL: no warning logged
- [ ] If last result is invalid, earlier results tried in reverse order

## Test Plan

```python
import pytest
from ralph_sdk.status import RalphStatusBlock
from ralph_sdk.parsing import parse_ralph_status

# --- EXIT_SIGNAL coercion tests ---

@pytest.mark.parametrize("value,expected", [
    ("true", True), ("True", True), ("TRUE", True),
    ("yes", True), ("Yes", True), ("YES", True),
    ("1", True),
    ("false", False), ("False", False), ("FALSE", False),
    ("no", False), ("No", False), ("NO", False),
    ("0", False),
])
def test_exit_signal_string_coercion(value, expected):
    block = RalphStatusBlock(exit_signal=value)
    assert block.exit_signal is expected

def test_exit_signal_json_bool():
    block = RalphStatusBlock(exit_signal=True)
    assert block.exit_signal is True
    block = RalphStatusBlock(exit_signal=False)
    assert block.exit_signal is False

def test_exit_signal_int_coercion():
    block = RalphStatusBlock(exit_signal=1)
    assert block.exit_signal is True
    block = RalphStatusBlock(exit_signal=0)
    assert block.exit_signal is False

# --- Multi-result JSONL tests ---

def test_multi_result_uses_last_valid(caplog):
    raw = (
        '{"type":"result","result":"WORK_TYPE: TESTING\\nEXIT_SIGNAL: false"}\n'
        '{"type":"result","result":"WORK_TYPE: IMPLEMENTATION\\nEXIT_SIGNAL: true"}'
    )
    import logging
    with caplog.at_level(logging.WARNING, logger="ralph.sdk.parsing"):
        block = parse_ralph_status(raw)
    assert block.work_type.value == "IMPLEMENTATION"
    assert block.exit_signal is True
    assert "Multiple result objects" in caplog.text
    assert "2 total" in caplog.text

def test_single_result_no_warning(caplog):
    raw = '{"type":"result","result":"WORK_TYPE: TESTING\\nEXIT_SIGNAL: false"}'
    import logging
    with caplog.at_level(logging.WARNING, logger="ralph.sdk.parsing"):
        block = parse_ralph_status(raw)
    assert "Multiple result objects" not in caplog.text

def test_multi_result_fallback_to_earlier():
    """If last result has no extractable fields, try earlier ones."""
    raw = (
        '{"type":"result","result":"WORK_TYPE: IMPLEMENTATION\\nEXIT_SIGNAL: false"}\n'
        '{"type":"result","result":""}'
    )
    block = parse_ralph_status(raw)
    assert block.work_type.value == "IMPLEMENTATION"
```
