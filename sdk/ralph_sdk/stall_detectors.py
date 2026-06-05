"""Stall detectors for the active circuit breaker (SDK-SAFETY-1).

Three independent consecutive-event detectors that can trip the circuit
breaker on patterns the sliding-window failure logic alone would miss:

- FastTripDetector — consecutive 0-tool-use runs completing in <threshold s
- DeferredTestDetector — consecutive TESTS_STATUS: DEFERRED loops
- ConsecutiveTimeoutDetector — consecutive timeout runs

Each ``record(...)`` call returns a :class:`StallDetectorResult` carrying the
trip / warn decision plus the current count and threshold.
"""

from __future__ import annotations

import logging
from dataclasses import dataclass

logger = logging.getLogger("ralph.sdk")


@dataclass
class StallDetectorResult:
    """Result from a stall detector check."""

    should_trip: bool = False
    should_warn: bool = False
    reason: str = ""
    count: int = 0
    threshold: int = 0


class FastTripDetector:
    """Detect consecutive 0-tool-use runs completing in <threshold seconds.

    When Claude completes a run very quickly without using any tools, it
    typically indicates a stall — the model is producing text-only responses
    without making progress. Trip the circuit breaker after
    MAX_CONSECUTIVE_FAST_FAILURES consecutive such runs.
    """

    def __init__(
        self,
        max_consecutive: int = 3,
        threshold_seconds: float = 30.0,
    ) -> None:
        self.max_consecutive = max_consecutive
        self.threshold_seconds = threshold_seconds
        self._consecutive_count: int = 0

    def record(self, duration_seconds: float, tool_use_count: int) -> StallDetectorResult:
        """Record an iteration and check for fast-trip condition.

        Args:
            duration_seconds: Wall-clock duration of the iteration.
            tool_use_count: Number of tool calls made during the iteration.

        Returns:
            StallDetectorResult with should_trip=True if threshold reached.
        """
        if tool_use_count == 0 and duration_seconds < self.threshold_seconds:
            self._consecutive_count += 1
            logger.debug(
                "FastTripDetector: fast failure %d/%d (%.1fs, 0 tools)",
                self._consecutive_count,
                self.max_consecutive,
                duration_seconds,
            )
            if self._consecutive_count >= self.max_consecutive:
                return StallDetectorResult(
                    should_trip=True,
                    reason=(
                        f"Fast trip: {self._consecutive_count} consecutive 0-tool-use "
                        f"runs completing in <{self.threshold_seconds}s"
                    ),
                    count=self._consecutive_count,
                    threshold=self.max_consecutive,
                )
            return StallDetectorResult(
                count=self._consecutive_count,
                threshold=self.max_consecutive,
            )
        else:
            self._consecutive_count = 0
            return StallDetectorResult()

    def reset(self) -> None:
        """Reset the consecutive counter."""
        self._consecutive_count = 0

    @property
    def consecutive_count(self) -> int:
        """Current consecutive fast failure count."""
        return self._consecutive_count


class DeferredTestDetector:
    """Detect consecutive TESTS_STATUS: DEFERRED loops.

    When tests are deferred too many times in a row, the agent may be stuck
    in a loop where it never actually runs tests. Warn early and trip the
    circuit breaker if the pattern continues.
    """

    def __init__(
        self,
        warn_at: int = 5,
        max_consecutive: int = 10,
    ) -> None:
        self.warn_at = warn_at
        self.max_consecutive = max_consecutive
        self._consecutive_count: int = 0

    def record(self, tests_deferred: bool) -> StallDetectorResult:
        """Record whether tests were deferred this iteration.

        Args:
            tests_deferred: True if TESTS_STATUS was DEFERRED this iteration.

        Returns:
            StallDetectorResult with should_warn or should_trip set.
        """
        if tests_deferred:
            self._consecutive_count += 1
            logger.debug(
                "DeferredTestDetector: deferred %d/%d",
                self._consecutive_count,
                self.max_consecutive,
            )
            if self._consecutive_count >= self.max_consecutive:
                return StallDetectorResult(
                    should_trip=True,
                    reason=(
                        f"Deferred tests: {self._consecutive_count} consecutive "
                        f"TESTS_STATUS: DEFERRED loops (threshold: {self.max_consecutive})"
                    ),
                    count=self._consecutive_count,
                    threshold=self.max_consecutive,
                )
            if self._consecutive_count >= self.warn_at:
                return StallDetectorResult(
                    should_warn=True,
                    reason=(
                        f"Deferred tests warning: {self._consecutive_count} consecutive "
                        f"TESTS_STATUS: DEFERRED loops (trip at {self.max_consecutive})"
                    ),
                    count=self._consecutive_count,
                    threshold=self.max_consecutive,
                )
            return StallDetectorResult(
                count=self._consecutive_count,
                threshold=self.max_consecutive,
            )
        else:
            self._consecutive_count = 0
            return StallDetectorResult()

    def reset(self) -> None:
        """Reset the consecutive counter."""
        self._consecutive_count = 0

    @property
    def consecutive_count(self) -> int:
        """Current consecutive deferred test count."""
        return self._consecutive_count


class ConsecutiveTimeoutDetector:
    """Detect consecutive timeout iterations.

    Multiple consecutive timeouts indicate the task may be too large or the
    agent is stuck in an unbounded operation. Trip the circuit breaker after
    MAX_CONSECUTIVE_TIMEOUTS.
    """

    def __init__(self, max_consecutive: int = 5) -> None:
        self.max_consecutive = max_consecutive
        self._consecutive_count: int = 0

    def record(self, timed_out: bool) -> StallDetectorResult:
        """Record whether this iteration timed out.

        Args:
            timed_out: True if the iteration ended due to timeout.

        Returns:
            StallDetectorResult with should_trip=True if threshold reached.
        """
        if timed_out:
            self._consecutive_count += 1
            logger.debug(
                "ConsecutiveTimeoutDetector: timeout %d/%d",
                self._consecutive_count,
                self.max_consecutive,
            )
            if self._consecutive_count >= self.max_consecutive:
                return StallDetectorResult(
                    should_trip=True,
                    reason=(
                        f"Consecutive timeouts: {self._consecutive_count} in a row "
                        f"(threshold: {self.max_consecutive})"
                    ),
                    count=self._consecutive_count,
                    threshold=self.max_consecutive,
                )
            return StallDetectorResult(
                count=self._consecutive_count,
                threshold=self.max_consecutive,
            )
        else:
            self._consecutive_count = 0
            return StallDetectorResult()

    def reset(self) -> None:
        """Reset the consecutive counter."""
        self._consecutive_count = 0

    @property
    def consecutive_count(self) -> int:
        """Current consecutive timeout count."""
        return self._consecutive_count
