# Story RALPH-SDK-EVIDENCE-3: Extract Test Results from Raw Output

**Epic:** [EvidenceBundle Output](epic-sdk-evidence-bundle.md)
**Priority:** High
**Status:** Done
**Effort:** Medium
**Component:** `sdk/ralph_sdk/evidence.py`

---

## Problem

Ralph's raw output from Claude contains test results mixed in with other text — code
changes, explanations, command output, and status blocks. TheStudio's Verification Gate
needs isolated test results to decide if the task passed. Manually parsing the full
output in TheStudio would duplicate logic and break whenever output format changes.

The extraction must handle multiple test frameworks (pytest, jest/npm test) and degrade
gracefully when no recognizable test output is found.

## Solution

Implement an `extract_test_results()` function in `evidence.py` that pattern-matches
against known test framework output formats. The function is best-effort — it returns
an empty string if no patterns match rather than raising an error.

## Implementation

**File:** `sdk/ralph_sdk/evidence.py`

```python
import re


def extract_test_results(raw_output: str) -> str:
    """Extract test results from raw Claude output.

    Best-effort pattern matching for common test frameworks.
    Returns empty string if no recognizable test output found.

    Supported patterns:
    - pytest: summary lines (X passed, Y failed, Z error)
    - jest/npm test: Test Suites/Tests summary lines
    - Generic: lines containing PASSED/FAILED/ERROR in test context
    """
    lines = raw_output.split("\n")
    results: list[str] = []

    # Pattern 1: pytest summary line
    # e.g., "====== 5 passed, 2 failed in 3.45s ======"
    pytest_summary = re.compile(
        r"=+\s+.*(?:passed|failed|error|warning).*\s+in\s+[\d.]+s\s*=+"
    )

    # Pattern 2: pytest individual results
    # e.g., "PASSED tests/test_foo.py::test_bar"
    # e.g., "FAILED tests/test_foo.py::test_bar - AssertionError"
    pytest_result = re.compile(r"^(PASSED|FAILED|ERROR)\s+\S+")

    # Pattern 3: jest/npm test summary
    # e.g., "Test Suites: 3 passed, 1 failed, 4 total"
    # e.g., "Tests:       12 passed, 2 failed, 14 total"
    jest_summary = re.compile(r"^(Test Suites|Tests):\s+.*\d+\s+(passed|failed|total)")

    # Pattern 4: Generic test summary
    # e.g., "5 tests passed, 0 failed"
    generic_summary = re.compile(r"\d+\s+tests?\s+(passed|failed)", re.IGNORECASE)

    for line in lines:
        stripped = line.strip()
        if (
            pytest_summary.search(stripped)
            or pytest_result.match(stripped)
            or jest_summary.match(stripped)
            or generic_summary.search(stripped)
        ):
            results.append(stripped)

    return "\n".join(results)
```

### Key Notes

- Extraction is best-effort. Empty string on no match, never raises.
- Patterns are ordered by specificity: framework-specific first, generic last.
- Only summary and result lines are extracted — not full test output (that's in `agent_summary`).
- The function is pure (no side effects, no file I/O) — easy to test.
- New patterns can be added later without changing the interface.

## Acceptance Criteria

- [ ] `extract_test_results()` function exists in `evidence.py`
- [ ] Matches pytest summary lines (e.g., `"====== 5 passed in 3.45s ======"`)
- [ ] Matches pytest PASSED/FAILED/ERROR lines with test paths
- [ ] Matches jest/npm test summary lines (Test Suites, Tests)
- [ ] Matches generic "N tests passed" patterns
- [ ] Returns empty string when no patterns match
- [ ] Returns empty string for empty input
- [ ] Does not raise exceptions on malformed input
- [ ] Function is pure — no side effects, no file I/O

## Test Plan

```python
from ralph_sdk.evidence import extract_test_results


def test_pytest_summary():
    output = """
Running tests...
====== 5 passed, 2 failed in 3.45s ======
"""
    result = extract_test_results(output)
    assert "5 passed" in result
    assert "2 failed" in result


def test_pytest_individual_results():
    output = """
PASSED tests/test_foo.py::test_bar
FAILED tests/test_foo.py::test_baz - AssertionError
PASSED tests/test_foo.py::test_qux
"""
    result = extract_test_results(output)
    assert "PASSED tests/test_foo.py::test_bar" in result
    assert "FAILED tests/test_foo.py::test_baz" in result


def test_jest_summary():
    output = """
Test Suites: 3 passed, 1 failed, 4 total
Tests:       12 passed, 2 failed, 14 total
"""
    result = extract_test_results(output)
    assert "Test Suites" in result
    assert "Tests:" in result


def test_generic_summary():
    output = "Ran 10 tests: 8 tests passed, 2 failed"
    result = extract_test_results(output)
    assert "tests passed" in result


def test_no_test_output():
    output = "Implemented the feature. Updated documentation."
    result = extract_test_results(output)
    assert result == ""


def test_empty_input():
    assert extract_test_results("") == ""


def test_malformed_input():
    """Should not raise on arbitrary input."""
    result = extract_test_results("random\x00binary\ngarbage\t\t\n")
    assert isinstance(result, str)
```
