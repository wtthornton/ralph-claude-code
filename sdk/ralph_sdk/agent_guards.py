"""Pre-flight guard + exit-gate mixin for RalphAgent (TAP-2772).

The pre-Claude safety checks (hourly invocation cap, token rate limit, budget,
circuit breaker) and the dual-condition exit gate with SDK-SAFETY-3 completion
indicator decay. Extracted verbatim from agent.py / agent_loop.py.
"""

from __future__ import annotations

import logging
import time

from ralph_sdk.agent_base import _AgentBase
from ralph_sdk.agent_models import TaskResult
from ralph_sdk.cost import AlertLevel
from ralph_sdk.status import ErrorCategory, RalphStatus

logger = logging.getLogger("ralph.sdk")


class _GuardMixin(_AgentBase):
    """Rate/token/budget/circuit-breaker pre-flight checks and the exit gate."""

    async def _check_invocation_rate_limit(self, result: TaskResult) -> bool:
        """Return False (caller breaks) if the hourly invocation cap is hit."""
        if not await self.check_rate_limit():
            logger.warning("Rate limit reached, waiting for reset")
            result.error = "Rate limit reached"
            result.status.error_category = ErrorCategory.RATE_LIMITED
            return False
        return True

    def _check_token_rate_limit(self, result: TaskResult) -> bool:
        if self._token_rate_limiter.can_proceed():
            return True
        usage = self._token_rate_limiter.get_usage()
        logger.warning(
            "Token rate limit reached: %d/%d tokens this hour",
            usage.tokens_used_this_hour,
            usage.limit,
        )
        result.error = "Token rate limit reached"
        return False

    def _check_budget(self, result: TaskResult) -> bool:
        """Return False on EXHAUSTED budget. Logs CRITICAL/WARNING but does not stop."""
        if self.config.max_budget_usd <= 0:
            return True
        budget = self._cost_tracker.check_budget(self.config.max_budget_usd)
        msg = "Budget %s: $%.4f / $%.2f (%.1f%%)"
        args = (
            budget.total_spent_usd,
            budget.max_budget_usd,
            budget.percentage_used,
        )
        if budget.alert_level == AlertLevel.EXHAUSTED:
            logger.warning(msg, "exhausted", *args)
            result.error = "Budget exhausted"
            return False
        if budget.alert_level == AlertLevel.CRITICAL:
            logger.warning(msg, "CRITICAL", *args)
        elif budget.alert_level == AlertLevel.WARNING:
            logger.info(msg, "WARNING", *args)
        return True

    async def check_rate_limit(self) -> bool:
        """Check if within rate limits via state backend."""
        call_count = await self.state_backend.read_call_count()
        last_reset = await self.state_backend.read_last_reset()
        now = int(time.time())
        elapsed = now - last_reset if last_reset > 0 else 3600
        remaining = max(0, self.config.max_calls_per_hour - call_count)
        # If the hour has elapsed, we're not rate limited
        if elapsed >= 3600:
            return True
        return remaining > 0

    async def check_circuit_breaker(self) -> bool:
        """Check circuit breaker via state backend — returns True if OK to proceed."""
        cb_data = await self.state_backend.read_circuit_breaker()
        state = cb_data.get("state", "CLOSED")
        return state in ("CLOSED", "HALF_OPEN")

    async def should_exit(self, status: RalphStatus, loop_count: int) -> bool:
        """Dual-condition exit gate (matching bash implementation).

        Requires BOTH:
        1. completion_indicators >= 2 (NLP heuristics)
        2. EXIT_SIGNAL: true (explicit from Claude)

        SDK-SAFETY-3: Completion indicator decay -- when productive work
        occurs (files_modified > 0 or tasks_completed > 0) AND exit_signal
        is False, reset completion_indicators to prevent stale done signals
        from combining with later signals for premature exit.
        """
        # SDK-SAFETY-3: Decay stale completion indicators on productive work
        # without exit signal. This prevents premature exit when Claude said
        # "done" earlier but then continued making real progress.
        files_modified = len(self._last_iteration_files)
        tasks_completed = 1 if status.completed_task else 0

        if (files_modified > 0 or tasks_completed > 0) and not status.exit_signal:
            if self._completion_indicators > 0:
                logger.debug(
                    "SDK-SAFETY-3: Resetting %d completion indicators "
                    "(productive work without exit_signal: %d files, %d tasks)",
                    self._completion_indicators,
                    files_modified,
                    tasks_completed,
                )
                self._completion_indicators = 0
                self._completion_indicator_list.clear()

        if status.exit_signal:
            self._completion_indicators += 1
            self._completion_indicator_list.append("exit_signal")

        # Check for completion phrases in progress summary
        completion_phrases = [
            "all tasks complete",
            "all tasks done",
            "nothing left",
            "no remaining tasks",
            "work is complete",
            "all items checked",
        ]
        summary_lower = status.progress_summary.lower()
        if any(phrase in summary_lower for phrase in completion_phrases):
            self._completion_indicators += 1
            self._completion_indicator_list.append("completion_phrase")

        # Dual condition: need both indicators and explicit exit signal
        return self._completion_indicators >= 2 and status.exit_signal
