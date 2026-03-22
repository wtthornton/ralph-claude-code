# Story RALPH-SDK-EVIDENCE-4: Extract Lint Results from Raw Output

**Epic:** [EvidenceBundle Output](epic-sdk-evidence-bundle.md)
**Priority:** High
**Status:** Done
**Effort:** Small
**Component:** `sdk/ralph_sdk/evidence.py`

---

## Problem

Lint results from tools like `ruff` and `eslint` are embedded in Ralph's raw output
alongside code changes, test results, and explanations. TheStudio's Verification Gate
needs isolated lint results to assess code quality. Without extraction, the gate has
no structured way to determine if linting passed or what issues remain.

## Solution

Implement an `extract_lint_results()` function in `evidence.py` that pattern-matches
against known linter output formats. Like `extract_test_results()`, this is best-effort
and returns an empty string when no patterns match.

## Implementation

**File:** `sdk/ralph_sdk/evidence.py`

```python
def extract_lint_results(raw_output: str) -> str:
    """Extract lint results from raw Claude output.

    Best-effort pattern matching for common linters.
    Returns empty string if no recognizable lint output found.

    Supported patterns:
    - ruff: "Found N errors" or "All checks passed"
    - eslint: "N problems (N errors, N warnings)"
    - Generic: "N errors, N warnings" in lint context
    """
    lines = raw_output.split("\n")
    results: list[str] = []

    # Pattern 1: ruff summary
    # e.g., "Found 3 errors." or "Found 0 errors."
    # e.g., "All checks passed!"
    ruff_found = re.compile(r"Found\s+\d+\s+error", re.IGNORECASE)
    ruff_clean = re.compile(r"All checks passed", re.IGNORECASE)

    # Pattern 2: eslint summary
    # e.g., "✖ 5 problems (3 errors, 2 warnings)"
    eslint_summary = re.compile(r"\d+\s+problems?\s*\(\d+\s+errors?,\s*\d+\s+warnings?\)")

    # Pattern 3: Generic lint summary
    # e.g., "3 errors, 2 warnings found"
    generic_lint = re.compile(r"\d+\s+errors?,\s*\d+\s+warnings?", re.IGNORECASE)

    for line in lines:
        stripped = line.strip()
        if (
            ruff_found.search(stripped)
            or ruff_clean.search(stripped)
            or eslint_summary.search(stripped)
            or generic_lint.search(stripped)
        ):
            results.append(stripped)

    return "\n".join(results)
```

### Key Notes

- Same best-effort pattern as `extract_test_results()` — empty string on no match.
- Ruff has two success patterns: "Found 0 errors" and "All checks passed".
- ESLint summary typically starts with a unicode marker but the regex matches the numeric portion.
- The function is pure and side-effect-free.
- New linter patterns (e.g., mypy, pylint, flake8) can be added later.

## Acceptance Criteria

- [ ] `extract_lint_results()` function exists in `evidence.py`
- [ ] Matches ruff "Found N errors" lines
- [ ] Matches ruff "All checks passed" lines
- [ ] Matches eslint "N problems (N errors, N warnings)" lines
- [ ] Matches generic "N errors, N warnings" patterns
- [ ] Returns empty string when no patterns match
- [ ] Returns empty string for empty input
- [ ] Does not raise exceptions on malformed input
- [ ] Function is pure — no side effects, no file I/O

## Test Plan

```python
from ralph_sdk.evidence import extract_lint_results


def test_ruff_errors():
    output = """
Running ruff check...
Found 3 errors.
"""
    result = extract_lint_results(output)
    assert "Found 3 errors" in result


def test_ruff_clean():
    output = "All checks passed!"
    result = extract_lint_results(output)
    assert "All checks passed" in result


def test_eslint_summary():
    output = """
/src/app.js
  1:1  error  Unexpected var  no-var

✖ 5 problems (3 errors, 2 warnings)
"""
    result = extract_lint_results(output)
    assert "5 problems" in result


def test_generic_lint():
    output = "Linting complete: 2 errors, 1 warning found"
    result = extract_lint_results(output)
    assert "2 errors" in result
    assert "1 warning" in result


def test_no_lint_output():
    output = "Implemented the feature. Added documentation."
    result = extract_lint_results(output)
    assert result == ""


def test_empty_input():
    assert extract_lint_results("") == ""


def test_malformed_input():
    """Should not raise on arbitrary input."""
    result = extract_lint_results("random\x00binary\ngarbage\n")
    assert isinstance(result, str)
```
