# Story SDK-COST-3: Token-Based Rate Limiting

**Epic:** [SDK Cost Intelligence](epic-sdk-cost-intelligence.md)
**Priority:** P2
**Status:** Pending
**Effort:** 1 day
**Component:** `ralph_sdk/agent.py`, `ralph_sdk/config.py`

---

## Problem

Ralph issue #223: The rate limiter tracks calls per hour, not token consumption. A single high-token call (100K tokens for an architectural review) counts the same as a trivial call (1K tokens for a typo fix). This makes TheStudio's budget enforcement inaccurate.

Anthropic's API rate limits are based on both requests per minute (RPM) and tokens per minute (TPM). The SDK should track both dimensions.

## Solution

Add optional token-based rate limiting alongside the existing invocation-based limiter. Accept `max_tokens_per_hour` in config and track cumulative input + output tokens per hour.

## Implementation

```python
# In ralph_sdk/agent.py or ralph_sdk/rate_limiter.py:

import time


class TokenRateLimiter:
    """Token-based rate limiter that tracks cumulative tokens per hour.

    Complements the existing invocation-based rate limiter.
    """

    def __init__(self, max_tokens_per_hour: int = 0):
        """Initialize token rate limiter.

        Args:
            max_tokens_per_hour: Max tokens per hour (0 = unlimited)
        """
        self._max_tokens = max_tokens_per_hour
        self._tokens_used: int = 0
        self._window_start: float = time.monotonic()
        self._window_duration: float = 3600.0  # 1 hour in seconds

    def record(self, input_tokens: int, output_tokens: int) -> None:
        """Record token usage for an iteration."""
        self._maybe_reset_window()
        self._tokens_used += input_tokens + output_tokens

    def check(self) -> bool:
        """Check if token limit has been reached.

        Returns:
            True if within limit (OK to proceed), False if limit reached.
        """
        if self._max_tokens <= 0:
            return True  # No limit

        self._maybe_reset_window()
        return self._tokens_used < self._max_tokens

    @property
    def tokens_used(self) -> int:
        """Tokens consumed in current window."""
        self._maybe_reset_window()
        return self._tokens_used

    @property
    def tokens_remaining(self) -> int | None:
        """Tokens remaining in current window. None if unlimited."""
        if self._max_tokens <= 0:
            return None
        self._maybe_reset_window()
        return max(0, self._max_tokens - self._tokens_used)

    @property
    def window_resets_in_seconds(self) -> float:
        """Seconds until the current window resets."""
        elapsed = time.monotonic() - self._window_start
        return max(0.0, self._window_duration - elapsed)

    def _maybe_reset_window(self) -> None:
        """Reset token counter if the hour window has elapsed."""
        elapsed = time.monotonic() - self._window_start
        if elapsed >= self._window_duration:
            self._tokens_used = 0
            self._window_start = time.monotonic()
```

### Config field

```python
# In ralph_sdk/config.py:
max_tokens_per_hour: int = Field(
    default=0, ge=0,
    description="Max total tokens (input + output) per hour (0 = unlimited)"
)
```

### Agent integration

```python
# In ralph_sdk/agent.py:
self._token_limiter = TokenRateLimiter(
    max_tokens_per_hour=config.max_tokens_per_hour,
)

# After each iteration (alongside cost tracking):
self._token_limiter.record(
    input_tokens=result_input_tokens,
    output_tokens=result_output_tokens,
)

# Before each iteration:
if not self._token_limiter.check():
    wait_seconds = self._token_limiter.window_resets_in_seconds
    self._log(f"Token rate limit reached ({self._token_limiter.tokens_used} tokens). "
              f"Waiting {wait_seconds:.0f}s for window reset.")
    await asyncio.sleep(min(wait_seconds, 300))  # Cap wait at 5 minutes
```

## Design Notes

- **Complementary, not replacement**: Token limiter works alongside the existing invocation-based limiter. Both must pass for an iteration to proceed.
- **Hourly window**: Matches the existing invocation limiter's hourly window.
- **0 = unlimited**: Consistent with the SDK's convention for optional limits.
- **Monotonic clock**: Uses `time.monotonic()` to avoid issues with system clock changes.
- **Wait cap**: If the window resets in > 5 minutes, the agent waits at most 5 minutes then rechecks. This prevents indefinite sleeps.
- **Input + output**: Both input and output tokens count toward the limit, since both contribute to API costs and rate limits.

## Acceptance Criteria

- [ ] `TokenRateLimiter` tracks cumulative input + output tokens per hour
- [ ] `max_tokens_per_hour` configurable in `RalphConfig` (default 0 = unlimited)
- [ ] Agent pauses when token limit reached, waits for window reset
- [ ] Hourly window resets automatically
- [ ] Works alongside existing invocation-based rate limiter
- [ ] `tokens_remaining` property available for monitoring
- [ ] Wait time capped at 5 minutes per check

## Test Plan

```python
import pytest
import time
from unittest.mock import patch
from ralph_sdk.rate_limiter import TokenRateLimiter

class TestTokenRateLimiter:
    def test_unlimited_always_ok(self):
        limiter = TokenRateLimiter(max_tokens_per_hour=0)
        limiter.record(input_tokens=1000000, output_tokens=500000)
        assert limiter.check() is True

    def test_within_limit(self):
        limiter = TokenRateLimiter(max_tokens_per_hour=100000)
        limiter.record(input_tokens=10000, output_tokens=5000)
        assert limiter.check() is True
        assert limiter.tokens_remaining == 85000

    def test_exceeds_limit(self):
        limiter = TokenRateLimiter(max_tokens_per_hour=10000)
        limiter.record(input_tokens=8000, output_tokens=5000)
        assert limiter.check() is False
        assert limiter.tokens_remaining == 0

    def test_window_reset(self):
        limiter = TokenRateLimiter(max_tokens_per_hour=10000)
        limiter._window_duration = 0.01  # Very short window for testing
        limiter.record(input_tokens=8000, output_tokens=5000)
        assert limiter.check() is False
        time.sleep(0.02)  # Wait for window reset
        assert limiter.check() is True
        assert limiter.tokens_used == 0

    def test_accumulation_across_records(self):
        limiter = TokenRateLimiter(max_tokens_per_hour=50000)
        limiter.record(input_tokens=10000, output_tokens=5000)
        limiter.record(input_tokens=10000, output_tokens=5000)
        limiter.record(input_tokens=10000, output_tokens=5000)
        assert limiter.tokens_used == 45000
        assert limiter.check() is True
        limiter.record(input_tokens=5000, output_tokens=5000)
        assert limiter.check() is False

    def test_tokens_remaining_unlimited(self):
        limiter = TokenRateLimiter(max_tokens_per_hour=0)
        assert limiter.tokens_remaining is None
```

## References

- Ralph issue #223: Rate limiter counts invocations, not tokens
- Anthropic API rate limits: RPM and TPM based
- [ralph-sdk-upgrade-evaluation.md](../../../TheStudio/docs/ralph-sdk-upgrade-evaluation.md) §2.4
