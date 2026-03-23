# Story SDK-LIFECYCLE-3: Permission Denial Detection

**Epic:** [SDK Lifecycle & Resilience](epic-sdk-lifecycle.md)
**Priority:** P3
**Status:** Pending
**Effort:** 1 day
**Component:** `ralph_sdk/parsing.py`, `ralph_sdk/status.py`

---

## Problem

The CLI distinguishes between:
- **Bash command denials**: Fixable by adding the command to `ALLOWED_TOOLS`
- **Built-in tool denials**: Filesystem scope boundaries that can't be adjusted

When Claude loses access to tools mid-run (sandboxed mode, permission revocation), the SDK doesn't detect this and continues looping uselessly. Each loop attempts the same blocked tool, fails, and retries — burning budget without making progress.

## Solution

Parse Claude output for permission denial patterns and expose them as `PermissionDenialEvent` on the status. Distinguish between user-fixable (add to allowed tools) and scope-locked (filesystem boundaries).

## Implementation

```python
# In ralph_sdk/status.py:

from enum import Enum
from pydantic import BaseModel


class PermissionDenialType(str, Enum):
    USER_FIXABLE = "user_fixable"      # Can be resolved by adjusting ALLOWED_TOOLS
    SCOPE_LOCKED = "scope_locked"      # Filesystem boundaries, can't be changed at runtime


class PermissionDenialEvent(BaseModel):
    """A detected permission denial during an iteration."""
    denial_type: PermissionDenialType
    tool_name: str
    detail: str
    suggestion: str
```

```python
# In ralph_sdk/parsing.py:

import re

# Patterns for permission denial detection
BASH_DENIAL_PATTERNS = [
    re.compile(r"Bash tool.*not allowed", re.IGNORECASE),
    re.compile(r"command.*not in.*ALLOWED_TOOLS", re.IGNORECASE),
    re.compile(r"bash.*permission denied.*ALLOWED_TOOLS", re.IGNORECASE),
]

SCOPE_DENIAL_PATTERNS = [
    re.compile(r"outside.*allowed.*directory", re.IGNORECASE),
    re.compile(r"path.*not.*within.*scope", re.IGNORECASE),
    re.compile(r"filesystem.*boundary", re.IGNORECASE),
    re.compile(r"Write.*denied.*outside", re.IGNORECASE),
]

TOOL_NAME_PATTERN = re.compile(r"(?:tool|command)[:\s]+['\"]?(\w+)['\"]?", re.IGNORECASE)


def detect_permission_denials(output: str) -> list[PermissionDenialEvent]:
    """Parse Claude output for permission denial patterns.

    Returns a list of detected denials with type and suggestions.
    """
    denials: list[PermissionDenialEvent] = []

    # Check for bash command denials (user-fixable)
    for pattern in BASH_DENIAL_PATTERNS:
        match = pattern.search(output)
        if match:
            tool_match = TOOL_NAME_PATTERN.search(output[max(0, match.start()-100):match.end()+100])
            tool_name = tool_match.group(1) if tool_match else "Bash"
            denials.append(PermissionDenialEvent(
                denial_type=PermissionDenialType.USER_FIXABLE,
                tool_name=tool_name,
                detail=match.group(0)[:200],
                suggestion=f"Add the command to ALLOWED_TOOLS in .ralphrc or RalphConfig.allowed_tools",
            ))

    # Check for scope denials (not user-fixable at runtime)
    for pattern in SCOPE_DENIAL_PATTERNS:
        match = pattern.search(output)
        if match:
            tool_match = TOOL_NAME_PATTERN.search(output[max(0, match.start()-100):match.end()+100])
            tool_name = tool_match.group(1) if tool_match else "Unknown"
            denials.append(PermissionDenialEvent(
                denial_type=PermissionDenialType.SCOPE_LOCKED,
                tool_name=tool_name,
                detail=match.group(0)[:200],
                suggestion="This operation is outside the allowed filesystem scope. Adjust the working directory or file protection rules.",
            ))

    return denials
```

### Status integration

```python
# In ralph_sdk/status.py, add to RalphStatus:
permission_denials: list[PermissionDenialEvent] = Field(default_factory=list)
```

### Agent integration

```python
# In ralph_sdk/agent.py, after parsing iteration output:
denials = detect_permission_denials(raw_output)
if denials:
    status.permission_denials = denials
    user_fixable = [d for d in denials if d.denial_type == PermissionDenialType.USER_FIXABLE]
    scope_locked = [d for d in denials if d.denial_type == PermissionDenialType.SCOPE_LOCKED]

    if scope_locked:
        self._log(f"Scope-locked permission denial detected: {scope_locked[0].detail}")
        # Scope-locked denials are terminal for the denied operation
```

## Design Notes

- **Detection, not resolution**: The SDK detects and reports denials. The embedder decides how to respond (add to allowed tools, adjust scope, circuit break).
- **Two categories**: User-fixable denials have a clear fix path (adjust ALLOWED_TOOLS). Scope-locked denials require infrastructure changes.
- **Pattern-based**: Uses regex patterns against Claude's output. These patterns are based on known Claude Code permission denial message formats.
- **Additive to error categorization**: Works alongside SDK-OUTPUT-2 (Error Categorization). Permission denials are a specific sub-type of errors with actionable remediation.
- **List, not single**: Multiple denials can occur in one iteration (e.g., both a bash command and a file write are denied).

## Acceptance Criteria

- [ ] `detect_permission_denials()` detects bash command denials
- [ ] `detect_permission_denials()` detects filesystem scope denials
- [ ] `PermissionDenialEvent` includes `denial_type`, `tool_name`, `detail`, `suggestion`
- [ ] `USER_FIXABLE` denials suggest adjusting ALLOWED_TOOLS
- [ ] `SCOPE_LOCKED` denials explain the filesystem boundary constraint
- [ ] `RalphStatus.permission_denials` is a list of events
- [ ] Empty list when no denials detected
- [ ] Multiple denials in one iteration handled correctly

## Test Plan

```python
import pytest
from ralph_sdk.parsing import detect_permission_denials
from ralph_sdk.status import PermissionDenialType

class TestPermissionDenialDetection:
    def test_detect_bash_denial(self):
        output = 'Error: Bash tool "npm test" not allowed. Add to ALLOWED_TOOLS.'
        denials = detect_permission_denials(output)
        assert len(denials) == 1
        assert denials[0].denial_type == PermissionDenialType.USER_FIXABLE
        assert "ALLOWED_TOOLS" in denials[0].suggestion

    def test_detect_scope_denial(self):
        output = "Write denied: path /etc/config is outside allowed directory /home/user/project"
        denials = detect_permission_denials(output)
        assert len(denials) == 1
        assert denials[0].denial_type == PermissionDenialType.SCOPE_LOCKED

    def test_no_denials(self):
        output = "Successfully wrote src/main.py. All tests passing."
        denials = detect_permission_denials(output)
        assert denials == []

    def test_multiple_denials(self):
        output = (
            'Bash tool "rm -rf" not allowed.\n'
            'Write denied: path outside allowed directory.\n'
        )
        denials = detect_permission_denials(output)
        assert len(denials) == 2
        types = {d.denial_type for d in denials}
        assert PermissionDenialType.USER_FIXABLE in types
        assert PermissionDenialType.SCOPE_LOCKED in types

    def test_detail_truncated(self):
        output = "Bash tool not allowed: " + "x" * 500
        denials = detect_permission_denials(output)
        assert len(denials[0].detail) <= 200
```

## References

- CLI: Distinguishes bash command denials from built-in tool denials
- Claude Code permission model: `ALLOWED_TOOLS`, filesystem scope
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §1.12
