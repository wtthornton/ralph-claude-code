"""Status enums and error classification helpers split out of status.py.

Holds the loop/work/circuit-breaker enums and the deterministic
``classify_error`` helper (SDK-OUTPUT-2). These names are re-exported from
``ralph_sdk.status`` so the public import surface is unchanged.
"""

from __future__ import annotations

import asyncio
import json
from enum import Enum


class RalphLoopStatus(str, Enum):
    """Status of the Ralph loop iteration."""
    IN_PROGRESS = "IN_PROGRESS"
    COMPLETED = "COMPLETED"
    ERROR = "ERROR"
    TIMEOUT = "TIMEOUT"
    DRY_RUN = "DRY_RUN"


class WorkType(str, Enum):
    """Type of work performed in a loop iteration."""
    UNKNOWN = "UNKNOWN"
    IMPLEMENTATION = "IMPLEMENTATION"
    TESTING = "TESTING"
    ANALYSIS = "ANALYSIS"
    PLANNING = "PLANNING"
    DEBUGGING = "DEBUGGING"
    DRY_RUN = "DRY_RUN"


class CircuitBreakerStateEnum(str, Enum):
    """Circuit breaker state values."""
    CLOSED = "CLOSED"
    HALF_OPEN = "HALF_OPEN"
    OPEN = "OPEN"


class ErrorCategory(str, Enum):
    """Categorization of errors encountered during loop execution.

    SDK-OUTPUT-2: Structured error categories for programmatic error handling.
    """
    PERMISSION_DENIED = "PERMISSION_DENIED"
    TIMEOUT = "TIMEOUT"
    PARSE_FAILURE = "PARSE_FAILURE"
    TOOL_UNAVAILABLE = "TOOL_UNAVAILABLE"
    SYSTEM_CRASH = "SYSTEM_CRASH"
    RATE_LIMITED = "RATE_LIMITED"
    UNKNOWN = "UNKNOWN"


_EXCEPTION_CATEGORIES: tuple[tuple[type[BaseException], ErrorCategory], ...] = (
    (TimeoutError, ErrorCategory.TIMEOUT),
    (asyncio.TimeoutError, ErrorCategory.TIMEOUT),
    (PermissionError, ErrorCategory.PERMISSION_DENIED),
    (FileNotFoundError, ErrorCategory.TOOL_UNAVAILABLE),
    (json.JSONDecodeError, ErrorCategory.PARSE_FAILURE),
    (ValueError, ErrorCategory.PARSE_FAILURE),
)

_EXIT_CODE_CATEGORIES: dict[int, ErrorCategory] = {
    124: ErrorCategory.TIMEOUT,            # Standard Unix timeout
    126: ErrorCategory.PERMISSION_DENIED,  # Cannot execute
    127: ErrorCategory.TOOL_UNAVAILABLE,   # Command not found
    137: ErrorCategory.SYSTEM_CRASH,       # SIGKILL
    139: ErrorCategory.SYSTEM_CRASH,       # SIGSEGV
}

_OUTPUT_SENTINELS: tuple[tuple[ErrorCategory, tuple[str, ...]], ...] = (
    (ErrorCategory.RATE_LIMITED, ("rate limit", "rate_limit", "429", "too many requests")),
    (ErrorCategory.PERMISSION_DENIED, ("permission denied", "access denied", "eacces")),
    (ErrorCategory.TIMEOUT, ("timeout", "timed out", "deadline exceeded")),
    (ErrorCategory.TOOL_UNAVAILABLE, ("tool not available", "tool_unavailable", "unknown tool")),
    (ErrorCategory.SYSTEM_CRASH, ("segfault", "core dumped", "fatal error", "panic")),
    (ErrorCategory.PARSE_FAILURE, ("json", "parse error", "unexpected token", "decode")),
)


def _classify_exception(exception: BaseException) -> ErrorCategory | None:
    for exc_type, category in _EXCEPTION_CATEGORIES:
        if isinstance(exception, exc_type):
            return category
    return None


def _classify_exit_code(exit_code: int) -> ErrorCategory | None:
    return _EXIT_CODE_CATEGORIES.get(exit_code)


def _classify_output(output: str) -> ErrorCategory | None:
    output_lower = output.lower()
    for category, sentinels in _OUTPUT_SENTINELS:
        if any(s in output_lower for s in sentinels):
            return category
    return None


def classify_error(
    exit_code: int | None = None,
    output: str = "",
    exception: BaseException | None = None,
) -> ErrorCategory:
    """Classify an error into an ErrorCategory based on exit code, output, and exception type.

    SDK-OUTPUT-2: Deterministic classification helper — no ML, no heuristics on
    freeform text beyond known sentinel strings from the CLI.
    """
    if exception is not None and (cat := _classify_exception(exception)) is not None:
        return cat
    if exit_code is not None and (cat := _classify_exit_code(exit_code)) is not None:
        return cat
    if (cat := _classify_output(output)) is not None:
        return cat
    if (exit_code is not None and exit_code != 0) or exception is not None:
        return ErrorCategory.UNKNOWN
    return ErrorCategory.UNKNOWN
