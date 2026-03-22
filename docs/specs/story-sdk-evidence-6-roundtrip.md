# Story RALPH-SDK-EVIDENCE-6: JSON Round-Trip Verification

**Epic:** [EvidenceBundle Output](epic-sdk-evidence-bundle.md)
**Priority:** High
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/evidence.py`

---

## Problem

The `EvidenceBundle` will be serialized to JSON and sent from Ralph to TheStudio
(via task queue, HTTP, or file). If the model cannot survive a JSON round-trip
(serialize then deserialize), data will be lost or corrupted in transit. UUID fields,
datetime fields, and nested lists are common sources of serialization failures in
Pydantic models if not configured correctly.

## Solution

Write explicit tests verifying that `EvidenceBundle` survives
`model_dump_json()` -> `model_validate_json()` with all fields intact. This ensures
the Pydantic model configuration handles UUID serialization, datetime ISO 8601 format,
and list/string fields correctly.

## Implementation

No production code changes — this story is purely verification tests. The tests ensure
the model defined in Story 1 is correctly configured for JSON serialization.

**Test scenarios:**

1. **Full bundle round-trip**: All fields populated, serialize, deserialize, compare.
2. **Minimal bundle round-trip**: Only required fields, verify defaults survive.
3. **UUID preservation**: `taskpacket_id` survives as the same UUID value.
4. **Datetime preservation**: `created_at` survives with timezone info intact.
5. **Special characters**: `agent_summary` with newlines, unicode, and special chars.

### Key Notes

- `model_dump_json()` is the Pydantic v2 method for JSON serialization.
- `model_validate_json()` is the Pydantic v2 method for JSON deserialization.
- These are different from `model_dump()` / `model_validate()` which work with Python dicts.
- UUID serialization must produce a string in JSON and parse back to a UUID object.
- Datetime must serialize as ISO 8601 string and parse back to a timezone-aware datetime.

## Acceptance Criteria

- [ ] `model_dump_json()` produces valid JSON for a fully populated `EvidenceBundle`
- [ ] `model_validate_json()` reconstructs the bundle from the JSON output
- [ ] Round-tripped `taskpacket_id` matches the original UUID
- [ ] Round-tripped `created_at` matches the original datetime (including timezone)
- [ ] Round-tripped `files_changed` list preserves all entries in order
- [ ] Round-tripped `test_results`, `lint_results`, `agent_summary` preserve exact strings
- [ ] Round-trip works with minimal (defaults-only) bundle
- [ ] Round-trip works with special characters (newlines, unicode, quotes)

## Test Plan

```python
from datetime import datetime, UTC
from uuid import uuid4
from ralph_sdk.evidence import EvidenceBundle


def test_full_bundle_roundtrip():
    tid = uuid4()
    original = EvidenceBundle(
        taskpacket_id=tid,
        intent_version=2,
        files_changed=["src/main.py", "tests/test_main.py", "README.md"],
        test_results="====== 5 passed in 3.45s ======",
        lint_results="All checks passed!",
        agent_summary="Implemented feature X with full test coverage.",
        loopback_attempt=1,
    )
    json_str = original.model_dump_json()
    restored = EvidenceBundle.model_validate_json(json_str)

    assert restored.taskpacket_id == tid
    assert restored.intent_version == 2
    assert restored.files_changed == ["src/main.py", "tests/test_main.py", "README.md"]
    assert restored.test_results == "====== 5 passed in 3.45s ======"
    assert restored.lint_results == "All checks passed!"
    assert restored.agent_summary == "Implemented feature X with full test coverage."
    assert restored.loopback_attempt == 1


def test_minimal_bundle_roundtrip():
    original = EvidenceBundle(taskpacket_id=uuid4(), intent_version=1)
    json_str = original.model_dump_json()
    restored = EvidenceBundle.model_validate_json(json_str)

    assert restored.files_changed == []
    assert restored.test_results == ""
    assert restored.lint_results == ""
    assert restored.agent_summary == ""
    assert restored.loopback_attempt == 0


def test_uuid_preservation():
    tid = uuid4()
    original = EvidenceBundle(taskpacket_id=tid, intent_version=1)
    json_str = original.model_dump_json()
    restored = EvidenceBundle.model_validate_json(json_str)
    assert restored.taskpacket_id == tid
    assert isinstance(restored.taskpacket_id, type(tid))


def test_datetime_preservation():
    original = EvidenceBundle(taskpacket_id=uuid4(), intent_version=1)
    json_str = original.model_dump_json()
    restored = EvidenceBundle.model_validate_json(json_str)
    # Datetime should survive with timezone info
    assert restored.created_at.tzinfo is not None
    # Should be within a second of the original
    delta = abs((restored.created_at - original.created_at).total_seconds())
    assert delta < 1.0


def test_special_characters_roundtrip():
    original = EvidenceBundle(
        taskpacket_id=uuid4(),
        intent_version=1,
        agent_summary='Line 1\nLine 2\n"quoted"\ttab\nunicode: \u2603\u2764',
        test_results="PASSED tests/test_\u00e9ncoding.py::test_utf8",
    )
    json_str = original.model_dump_json()
    restored = EvidenceBundle.model_validate_json(json_str)
    assert restored.agent_summary == original.agent_summary
    assert restored.test_results == original.test_results
```
