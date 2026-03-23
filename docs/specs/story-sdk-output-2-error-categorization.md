# Story SDK-OUTPUT-2: Error Categorization

**Epic:** [SDK Structured Output & Observability](epic-sdk-structured-output.md)
**Priority:** P2
**Status:** Pending
**Effort:** 1 day
**Component:** `ralph_sdk/parsing.py`, `ralph_sdk/status.py`

---

## Problem

The CLI categorizes errors into expected-scope (permission denials for built-in tools) vs system errors (crashes, hangs). The SDK treats all errors generically — every failure gets the same `is_error: true` flag.

TheStudio's loopback logic needs to know whether a failure is:
- **Retryable** (permission denial → adjust tools, parse failure → retry with cleaner prompt)
- **Terminal** (system crash → circuit break, tool unavailable → escalate)

Generic error handling causes:
- Unnecessary retries on terminal failures (wasting budget)
- Premature circuit breaks on fixable issues (blocking progress)

## Solution

Add an `ErrorCategory` enum and return it alongside `RalphStatus` in the parsing output.

## Implementation

```python
# In ralph_sdk/status.py:

from enum import Enum


class ErrorCategory(str, Enum):
    """Categorized error types for intelligent retry/circuit-break decisions."""
    PERMISSION_DENIED = "permission_denied"    # Tool access denied (retryable: adjust tools)
    TIMEOUT = "timeout"                        # Iteration timed out (retryable: extend timeout or decompose)
    PARSE_FAILURE = "parse_failure"            # Response couldn't be parsed (retryable: retry)
    TOOL_UNAVAILABLE = "tool_unavailable"      # Required tool missing (terminal: escalate)
    SYSTEM_CRASH = "system_crash"              # Unexpected crash/hang (terminal: circuit break)
    RATE_LIMITED = "rate_limited"              # API rate limit hit (retryable: wait and retry)
    UNKNOWN = "unknown"                        # Unclassified error


class CategorizedError(BaseModel):
    """Error with category and retryability information."""
    category: ErrorCategory
    message: str
    retryable: bool
    suggestion: str = ""

    @classmethod
    def from_category(cls, category: ErrorCategory, message: str) -> "CategorizedError":
        retryable = category in {
            ErrorCategory.PERMISSION_DENIED,
            ErrorCategory.TIMEOUT,
            ErrorCategory.PARSE_FAILURE,
            ErrorCategory.RATE_LIMITED,
        }
        suggestions = {
            ErrorCategory.PERMISSION_DENIED: "Check ALLOWED_TOOLS configuration",
            ErrorCategory.TIMEOUT: "Consider extending timeout or decomposing the task",
            ErrorCategory.PARSE_FAILURE: "Retry; if persistent, check prompt format",
            ErrorCategory.TOOL_UNAVAILABLE: "Install required tool or update configuration",
            ErrorCategory.SYSTEM_CRASH: "Check system resources and Claude CLI health",
            ErrorCategory.RATE_LIMITED: "Wait for rate limit window to reset",
            ErrorCategory.UNKNOWN: "Investigate error output for details",
        }
        return cls(
            category=category,
            message=message,
            retryable=retryable,
            suggestion=suggestions.get(category, ""),
        )
```

### Error categorization in parsing

```python
# In ralph_sdk/parsing.py:

import re

PERMISSION_PATTERNS = [
    re.compile(r"permission denied", re.IGNORECASE),
    re.compile(r"not allowed", re.IGNORECASE),
    re.compile(r"tool.*blocked", re.IGNORECASE),
    re.compile(r"ALLOWED_TOOLS", re.IGNORECASE),
]

RATE_LIMIT_PATTERNS = [
    re.compile(r"rate.?limit", re.IGNORECASE),
    re.compile(r"too many requests", re.IGNORECASE),
    re.compile(r"429", re.IGNORECASE),
    re.compile(r"quota.*exceeded", re.IGNORECASE),
]

TOOL_UNAVAILABLE_PATTERNS = [
    re.compile(r"tool.*not found", re.IGNORECASE),
    re.compile(r"command not found", re.IGNORECASE),
    re.compile(r"FileNotFoundError", re.IGNORECASE),
]


def categorize_error(
    exit_code: int,
    error_output: str,
    is_error: bool = True,
) -> CategorizedError | None:
    """Categorize an error from iteration output.

    Args:
        exit_code: Process exit code (124 = timeout)
        error_output: Stderr or error text from the iteration
        is_error: Whether the iteration was flagged as an error

    Returns:
        CategorizedError if an error was detected, None otherwise.
    """
    if not is_error and exit_code == 0:
        return None

    # Timeout (exit code 124 from `timeout` command)
    if exit_code == 124:
        return CategorizedError.from_category(
            ErrorCategory.TIMEOUT,
            f"Iteration timed out (exit code 124)"
        )

    # System crash (signal-based exits)
    if exit_code > 128:
        signal_num = exit_code - 128
        return CategorizedError.from_category(
            ErrorCategory.SYSTEM_CRASH,
            f"Process killed by signal {signal_num} (exit code {exit_code})"
        )

    # Pattern-based categorization
    for pattern in PERMISSION_PATTERNS:
        if pattern.search(error_output):
            return CategorizedError.from_category(
                ErrorCategory.PERMISSION_DENIED,
                f"Permission denied: {pattern.pattern}"
            )

    for pattern in RATE_LIMIT_PATTERNS:
        if pattern.search(error_output):
            return CategorizedError.from_category(
                ErrorCategory.RATE_LIMITED,
                f"Rate limited: {pattern.pattern}"
            )

    for pattern in TOOL_UNAVAILABLE_PATTERNS:
        if pattern.search(error_output):
            return CategorizedError.from_category(
                ErrorCategory.TOOL_UNAVAILABLE,
                f"Tool unavailable: {pattern.pattern}"
            )

    # Unknown error
    return CategorizedError.from_category(
        ErrorCategory.UNKNOWN,
        error_output[:200] if error_output else f"Exit code {exit_code}"
    )
```

### Integration with status

```python
# In ralph_sdk/status.py, add to RalphStatus:
error: CategorizedError | None = None
```

## Design Notes

- **Retryable vs terminal**: Clear classification helps embedders decide: retry (with adjustments) or circuit break.
- **Exit code first**: Exit code 124 (timeout) and > 128 (signal) are unambiguous. Pattern matching is only for non-obvious cases.
- **Additive**: `RATE_LIMITED` is added beyond what the evaluation requested — it's a common failure mode the SDK should distinguish.
- **Message truncation**: Error messages truncated to 200 chars to prevent large error outputs from bloating the status.
- **Optional field**: `error` on `RalphStatus` is `None` for successful iterations.

## Acceptance Criteria

- [ ] `ErrorCategory` enum with 7 categories: PERMISSION_DENIED, TIMEOUT, PARSE_FAILURE, TOOL_UNAVAILABLE, SYSTEM_CRASH, RATE_LIMITED, UNKNOWN
- [ ] `CategorizedError` includes `category`, `message`, `retryable: bool`, `suggestion: str`
- [ ] Exit code 124 → TIMEOUT
- [ ] Exit code > 128 → SYSTEM_CRASH
- [ ] Permission denial patterns → PERMISSION_DENIED
- [ ] Rate limit patterns → RATE_LIMITED
- [ ] Tool not found patterns → TOOL_UNAVAILABLE
- [ ] `RalphStatus.error` is `CategorizedError | None`
- [ ] `retryable` is True for PERMISSION_DENIED, TIMEOUT, PARSE_FAILURE, RATE_LIMITED
- [ ] `retryable` is False for TOOL_UNAVAILABLE, SYSTEM_CRASH, UNKNOWN

## Test Plan

```python
import pytest
from ralph_sdk.parsing import categorize_error
from ralph_sdk.status import ErrorCategory

class TestErrorCategorization:
    def test_timeout(self):
        err = categorize_error(exit_code=124, error_output="", is_error=True)
        assert err.category == ErrorCategory.TIMEOUT
        assert err.retryable is True

    def test_system_crash_signal(self):
        err = categorize_error(exit_code=137, error_output="", is_error=True)
        assert err.category == ErrorCategory.SYSTEM_CRASH
        assert err.retryable is False

    def test_permission_denied(self):
        err = categorize_error(
            exit_code=1,
            error_output="Error: Bash tool not allowed. Check ALLOWED_TOOLS.",
            is_error=True,
        )
        assert err.category == ErrorCategory.PERMISSION_DENIED
        assert err.retryable is True

    def test_rate_limited(self):
        err = categorize_error(
            exit_code=1,
            error_output="429 Too Many Requests - rate limit exceeded",
            is_error=True,
        )
        assert err.category == ErrorCategory.RATE_LIMITED
        assert err.retryable is True

    def test_tool_unavailable(self):
        err = categorize_error(
            exit_code=1,
            error_output="FileNotFoundError: claude binary not found",
            is_error=True,
        )
        assert err.category == ErrorCategory.TOOL_UNAVAILABLE
        assert err.retryable is False

    def test_unknown_error(self):
        err = categorize_error(exit_code=1, error_output="Something went wrong", is_error=True)
        assert err.category == ErrorCategory.UNKNOWN

    def test_no_error(self):
        err = categorize_error(exit_code=0, error_output="", is_error=False)
        assert err is None

    def test_suggestion_populated(self):
        err = categorize_error(exit_code=124, error_output="", is_error=True)
        assert "timeout" in err.suggestion.lower() or "decomposing" in err.suggestion.lower()
```

## References

- CLI error categorization: Expected-scope vs system errors
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.7
