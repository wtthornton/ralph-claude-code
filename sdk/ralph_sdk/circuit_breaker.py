"""Ralph SDK active circuit breaker — state machine with sliding window failure detection.

Replaces the passive check_circuit_breaker() with active state management:
- record_success() — HALF_OPEN -> CLOSED
- record_failure(reason) — sliding window detection, trip when threshold hit
- record_no_progress() — consecutive zero-work detection
- can_proceed() — OPEN -> HALF_OPEN after cooldown

State transitions:
  CLOSED -> OPEN (threshold failures or no-progress reached)
  OPEN -> HALF_OPEN (cooldown elapsed)
  HALF_OPEN -> CLOSED (success recorded)
  HALF_OPEN -> OPEN (failure recorded)
"""

from __future__ import annotations

import time
from typing import Any

from ralph_sdk.state import RalphStateBackend
from ralph_sdk.status import CircuitBreakerState, CircuitBreakerStateEnum


class CircuitBreaker:
    """Active circuit breaker with sliding window failure detection.

    Matches lib/circuit_breaker.sh behavior for common scenarios while
    providing programmatic state management via the state backend.
    """

    def __init__(
        self,
        state_backend: RalphStateBackend,
        *,
        no_progress_threshold: int = 3,
        same_error_threshold: int = 5,
        cooldown_minutes: int = 30,
        auto_reset: bool = False,
        failure_window_minutes: int = 60,
    ) -> None:
        self.state_backend = state_backend
        self.no_progress_threshold = no_progress_threshold
        self.same_error_threshold = same_error_threshold
        self.cooldown_minutes = cooldown_minutes
        self.auto_reset = auto_reset
        self.failure_window_minutes = failure_window_minutes

        # Sliding window: list of (timestamp, reason) tuples
        self._failure_window: list[tuple[float, str]] = []

    async def _load_state(self) -> CircuitBreakerState:
        """Load current state from backend."""
        data = await self.state_backend.read_circuit_breaker()
        if data:
            return CircuitBreakerState._from_state_dict(data)
        return CircuitBreakerState()

    async def _save_state(self, cb: CircuitBreakerState) -> None:
        """Save state to backend."""
        await self.state_backend.write_circuit_breaker(cb._to_state_dict())

    async def can_proceed(self) -> bool:
        """Check if the loop can proceed.

        Returns True if CLOSED or HALF_OPEN.
        If OPEN and cooldown has elapsed, transitions to HALF_OPEN.
        If auto_reset is True, bypasses cooldown.
        """
        cb = await self._load_state()

        if cb.state == CircuitBreakerStateEnum.CLOSED:
            return True

        if cb.state == CircuitBreakerStateEnum.HALF_OPEN:
            return True

        # OPEN state — check cooldown
        if cb.state == CircuitBreakerStateEnum.OPEN:
            if self.auto_reset:
                cb.half_open()
                await self._save_state(cb)
                return True

            if cb.opened_at:
                try:
                    opened_time = time.mktime(time.strptime(cb.opened_at, "%Y-%m-%dT%H:%M:%S%z"))
                except (ValueError, OverflowError):
                    # Can't parse timestamp, allow transition
                    opened_time = 0.0

                elapsed_minutes = (time.time() - opened_time) / 60
                if elapsed_minutes >= self.cooldown_minutes:
                    cb.half_open()
                    await self._save_state(cb)
                    return True

        return False

    async def record_success(self) -> None:
        """Record a successful iteration.

        HALF_OPEN -> CLOSED with counter reset.
        CLOSED -> stays CLOSED with counters reset.
        """
        cb = await self._load_state()

        if cb.state == CircuitBreakerStateEnum.HALF_OPEN:
            cb.close()
        elif cb.state == CircuitBreakerStateEnum.CLOSED:
            # Reset progressive counters on success
            cb.no_progress_count = 0
            cb.same_error_count = 0
            cb.last_error = ""
            cb.last_transition = "CLOSED: success"

        # Clear sliding window on success
        self._failure_window.clear()

        await self._save_state(cb)

    async def record_failure(self, reason: str = "") -> None:
        """Record a failure.

        Uses sliding window: only failures within the window period count.
        If same_error_threshold reached, trips to OPEN.
        HALF_OPEN -> OPEN immediately on any failure.
        """
        cb = await self._load_state()
        now = time.time()

        # HALF_OPEN fails immediately back to OPEN
        if cb.state == CircuitBreakerStateEnum.HALF_OPEN:
            cb.trip(reason)
            await self._save_state(cb)
            return

        # Add to sliding window
        self._failure_window.append((now, reason))

        # Prune old entries outside the window
        cutoff = now - (self.failure_window_minutes * 60)
        self._failure_window = [
            (ts, r) for ts, r in self._failure_window if ts >= cutoff
        ]

        # Count same errors in window
        if reason:
            same_count = sum(1 for _, r in self._failure_window if r == reason)
            cb.same_error_count = same_count

            if same_count >= self.same_error_threshold:
                cb.trip(f"Same error threshold ({self.same_error_threshold}): {reason}")
                await self._save_state(cb)
                return

        cb.last_error = reason
        cb.last_transition = f"CLOSED: failure recorded ({reason})"
        await self._save_state(cb)

    async def record_no_progress(self) -> None:
        """Record a zero-work iteration (no files changed, no tasks completed).

        Increments no_progress_count. Trips to OPEN when threshold reached.
        """
        cb = await self._load_state()
        cb.no_progress_count += 1

        if cb.no_progress_count >= self.no_progress_threshold:
            cb.trip(f"No progress threshold ({self.no_progress_threshold}) reached")
        else:
            cb.last_transition = f"CLOSED: no progress ({cb.no_progress_count}/{self.no_progress_threshold})"

        await self._save_state(cb)

    async def reset(self, reason: str = "manual") -> None:
        """Reset circuit breaker to CLOSED state."""
        cb = CircuitBreakerState()
        cb.last_transition = f"RESET: {reason}"
        self._failure_window.clear()
        await self._save_state(cb)

    async def get_state(self) -> dict[str, Any]:
        """Get current state as a dictionary."""
        cb = await self._load_state()
        return {
            "state": cb.state.value,
            "no_progress_count": cb.no_progress_count,
            "same_error_count": cb.same_error_count,
            "last_error": cb.last_error,
            "opened_at": cb.opened_at,
            "last_transition": cb.last_transition,
            "can_proceed": cb.state in (CircuitBreakerStateEnum.CLOSED, CircuitBreakerStateEnum.HALF_OPEN),
        }
