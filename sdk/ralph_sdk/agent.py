"""Ralph SDK Agent — Agent SDK proof of concept replicating ralph_loop.sh core loop.

Dual-mode: standalone CLI + TheStudio embedded.
All agent methods are async. Use run_sync() for CLI synchronous execution.

SDK-SAFETY-2: Task decomposition detection via 4-factor heuristic.
SDK-SAFETY-3: Completion indicator decay — reset stale done signals
              when productive work occurs without exit_signal.

TAP-2772: The RalphAgent class is composed from cohesive mixins
(_SessionMixin, _InvocationMixin, _ReportingMixin, _LoopMixin) over a shared
_AgentBase type surface. The public API and every `self.*` call are unchanged;
the standalone models below are re-exported from agent_models.py.
"""

from __future__ import annotations

import asyncio
import logging
import signal
import sys
import uuid
from pathlib import Path

from ralph_sdk.agent_base import _AgentBase
from ralph_sdk.agent_guards import _GuardMixin
from ralph_sdk.agent_invocation import _InvocationMixin
from ralph_sdk.agent_loop import _LoopMixin
from ralph_sdk.agent_models import (
    CancelResult,
    ContinueAsNewState,
    DecompositionHint,
    IterationRecord,
    ProgressSnapshot,
    RalphAgentInterface,
    TaskInput,
    TaskResult,
    TracerProtocol,
    compute_adaptive_timeout,
    detect_decomposition_needed,
)
from ralph_sdk.agent_reporting import _ReportingMixin
from ralph_sdk.agent_session import _SessionMixin
from ralph_sdk.config import RalphConfig
from ralph_sdk.context import ContextManager, PromptCacheStats
from ralph_sdk.cost import CostTracker, TokenRateLimiter
from ralph_sdk.metrics import MetricsCollector, NullMetricsCollector
from ralph_sdk.state import FileStateBackend, RalphStateBackend

logger = logging.getLogger("ralph.sdk")

__all__ = [
    "CancelResult",
    "ContinueAsNewState",
    "DecompositionHint",
    "IterationRecord",
    "ProgressSnapshot",
    "RalphAgent",
    "RalphAgentInterface",
    "TaskInput",
    "TaskResult",
    "TracerProtocol",
    "compute_adaptive_timeout",
    "detect_decomposition_needed",
]


# Standalone models / helpers live in agent_models.py and are re-exported above.
# RalphAgent class follows.


# =============================================================================
# SDK Agent Implementation (SDK-1: Proof of Concept)
# =============================================================================

class RalphAgent(
    _SessionMixin,
    _InvocationMixin,
    _ReportingMixin,
    _GuardMixin,
    _LoopMixin,
    _AgentBase,
):
    """Ralph Agent SDK implementation — replicates ralph_loop.sh core loop in Python.

    Core loop: Read PROMPT.md + fix_plan.md -> invoke Claude -> parse response ->
    check exit conditions -> repeat.

    All loop methods are async. Use run_sync() for synchronous CLI execution.

    Supports three operational modes:
    - Standalone CLI: `ralph` (bash loop, unchanged)
    - Standalone SDK: `ralph --sdk` (this class)
    - TheStudio embedded: RalphAgent used as Primary Agent

    Cancel semantics (SDK-LIFECYCLE-1):
        Calling ``cancel()`` sets the ``_cancelled`` flag and, if a Claude
        subprocess is currently running, sends SIGTERM (or terminates on
        Windows), waits ``cancel_grace_seconds``, then sends SIGKILL if the
        process has not exited.  ``cancel()`` returns a ``CancelResult`` with
        any partial output captured, the iteration count, and whether a forced
        kill was needed.  It never raises.

    Adaptive timeout (SDK-LIFECYCLE-2):
        When ``adaptive_timeout_enabled`` is True in config, the agent tracks
        the wall-clock duration of each iteration.  Once
        ``adaptive_timeout_min_samples`` iterations have been recorded, the
        timeout for subsequent iterations is computed via
        ``compute_adaptive_timeout()`` using the P95 latency of the history
        window.  Until enough samples are collected, the static
        ``timeout_minutes`` from config is used.
    """

    def __init__(
        self,
        config: RalphConfig | None = None,
        project_dir: str | Path = ".",
        state_backend: RalphStateBackend | None = None,
        correlation_id: str | None = None,
        tracer: TracerProtocol | None = None,
        metrics_collector: MetricsCollector | None = None,
    ) -> None:
        self.config = config or RalphConfig.load(project_dir)
        self.project_dir = Path(project_dir).resolve()
        self.ralph_dir = self.project_dir / self.config.ralph_dir
        self.loop_count = 0
        self.start_time = 0.0
        self.session_id = ""
        self._completion_indicators = 0
        self._running = False
        self._last_tokens_in = 0
        self._last_tokens_out = 0

        # SDK-LIFECYCLE-1: Cancellation state
        self._cancelled = False
        self._current_proc: asyncio.subprocess.Process | None = None
        self._last_partial_output: str | None = None
        # TAP-675: Reference to the event loop running `self.run()`.
        # Captured at run() entry so `cancel()` can schedule work on the
        # correct loop from any thread, without calling deprecated
        # asyncio.get_event_loop() and without guessing via is_running().
        self._loop: asyncio.AbstractEventLoop | None = None

        # SDK-LIFECYCLE-2: Iteration duration history for adaptive timeout
        self._iteration_durations: list[float] = []

        # Correlation ID — auto-generated UUID if not provided
        self.correlation_id = correlation_id or str(uuid.uuid4())

        # Optional OpenTelemetry tracer (guarded import)
        self.tracer = tracer

        # SDK-OUTPUT-4: Metrics collector — NullMetricsCollector by default
        self.metrics_collector: MetricsCollector = metrics_collector or NullMetricsCollector()

        # SDK-OUTPUT-3: Progress snapshot — updated after each iteration
        self._progress: ProgressSnapshot = ProgressSnapshot()

        # SDK-OUTPUT-1: Files changed in the last iteration (populated by run_iteration)
        self._last_iteration_files: list[str] = []

        # SDK-SAFETY-2: Iteration history for decomposition detection
        self._iteration_history: list[IterationRecord] = []

        # SDK-SAFETY-3: Completion indicators stored as a list for decay support
        self._completion_indicator_list: list[str] = []

        # SDK-SAFETY-2: Pending decomposition hint to inject into next prompt
        self._pending_decomposition_hint: DecompositionHint | None = None

        # State backend — FileStateBackend by default
        self.state_backend: RalphStateBackend = state_backend or FileStateBackend(self.ralph_dir)

        # SDK-CONTEXT-1: Progressive context loading
        self._context_manager = ContextManager()

        # SDK-CONTEXT-2: Prompt cache optimization
        self._prompt_cache_stats = PromptCacheStats()

        # SDK-CONTEXT-3: Session lifecycle tracking
        self._session_iteration_count = 0
        self._session_start_time = 0.0

        # SDK-COST-1: Cost tracker with configurable thresholds
        self._cost_tracker = CostTracker(
            budget_warning_pct=self.config.budget_warning_pct,
            budget_critical_pct=self.config.budget_critical_pct,
        )

        # SDK-COST-3: Token-based rate limiter
        self._token_rate_limiter = TokenRateLimiter(
            max_tokens_per_hour=self.config.max_tokens_per_hour,
        )

        # Ensure .ralph directory exists
        self.ralph_dir.mkdir(parents=True, exist_ok=True)
        (self.ralph_dir / "logs").mkdir(exist_ok=True)

    # -------------------------------------------------------------------------
    # Sync wrapper for CLI mode
    # -------------------------------------------------------------------------

    def run_sync(self) -> TaskResult:
        """Synchronous wrapper around async run() for CLI mode.

        Uses asyncio.run() to execute the async loop. This is the entry point
        for `ralph --sdk` and `python -m ralph_sdk`.
        """
        return asyncio.run(self.run())

    # -------------------------------------------------------------------------
    # SDK-LIFECYCLE-1: Cancellation
    # -------------------------------------------------------------------------

    def _signal_terminate(self, proc: asyncio.subprocess.Process) -> None:
        """Send SIGTERM (Unix) or terminate() (Windows) to ``proc``.

        Never raises — cancel() is a cleanup path, not an error-discovery one.
        """
        try:
            if sys.platform != "win32":
                try:
                    proc.send_signal(signal.SIGTERM)
                except (ProcessLookupError, OSError):
                    pass
            else:
                try:
                    proc.terminate()
                except (ProcessLookupError, OSError):
                    pass
        except Exception:
            # Broad: cancel() must never propagate from a cleanup path —
            # the caller is asking us to stop, not to discover new errors.
            logger.exception("Failed to send termination signal")

    def _schedule_or_force_kill(self, proc: asyncio.subprocess.Process) -> bool:
        """Schedule a deferred grace-then-SIGKILL, or synchronously kill.

        Returns ``was_forced`` — True only on the synchronous kill fallback
        paths (no usable loop). The async deferred-kill path's forced-kill is
        not observable in the returned result, matching prior behavior.
        """
        grace = self.config.cancel_grace_seconds

        async def _deferred_kill() -> None:
            try:
                await asyncio.wait_for(proc.wait(), timeout=grace)
            except TimeoutError:
                try:
                    proc.kill()
                except (ProcessLookupError, OSError):
                    pass

        try:
            # Case A: we're being called from within the agent's own loop.
            # `asyncio.get_running_loop()` returns it; schedule directly.
            current_loop = asyncio.get_running_loop()
            if self._loop is not None and current_loop is self._loop:
                current_loop.create_task(_deferred_kill())
                return False
            # Running inside some other loop than the agent's.
            # Fall through to the cross-thread path below.
            raise RuntimeError("cancel called from a different loop")
        except RuntimeError:
            # Case B: no running loop in this thread (sync context or
            # supervisor thread). Use the agent's stored loop via
            # call_soon_threadsafe so scheduling is thread-safe.
            agent_loop = self._loop
            if agent_loop is not None and not agent_loop.is_closed():
                try:
                    agent_loop.call_soon_threadsafe(
                        lambda: agent_loop.create_task(_deferred_kill())
                    )
                    return False
                except RuntimeError:
                    # Loop is closed/stopping -- fall back to sync kill.
                    return self._sync_force_kill(proc)
            # No loop at all (agent never started) -- synchronous kill.
            return self._sync_force_kill(proc)

    @staticmethod
    def _sync_force_kill(proc: asyncio.subprocess.Process) -> bool:
        """Synchronously SIGKILL ``proc``; return True if the kill was issued."""
        try:
            proc.kill()
            return True
        except (ProcessLookupError, OSError):
            return False

    def _capture_partial_output(
        self, proc: asyncio.subprocess.Process
    ) -> str | None:
        """Best-effort read of the subprocess stdout buffer at cancel time."""
        try:
            if proc.stdout and hasattr(proc.stdout, "_buffer"):
                return bytes(proc.stdout._buffer).decode("utf-8", errors="replace")
        except (AttributeError, OSError, UnicodeDecodeError) as e:
            # Best-effort buffer read; failure here just means the
            # subprocess closed mid-decode. Surface at debug for triage.
            logger.debug("partial_output capture failed: %s", e)
        return None

    def cancel(self) -> CancelResult:
        """Request graceful cancellation of the running loop.

        SDK-LIFECYCLE-1: Hardened cancel semantics.

        Sets the ``_cancelled`` flag so the main loop exits after the current
        iteration.  If a Claude subprocess is currently running, sends SIGTERM
        (or ``terminate()`` on Windows), waits up to ``cancel_grace_seconds``
        for it to exit, then sends SIGKILL if necessary.

        Safe to call from another thread or an async timeout handler.
        Never raises -- always returns a ``CancelResult``.

        Returns:
            A ``CancelResult`` containing any partial output captured from the
            interrupted subprocess, the number of iterations completed, and
            whether a forced kill was required.
        """
        self._cancelled = True
        self._running = False

        was_forced = False
        partial_output: str | None = None
        proc = self._current_proc

        if proc is not None and proc.returncode is None:
            self._signal_terminate(proc)
            was_forced = self._schedule_or_force_kill(proc)
            partial_output = self._capture_partial_output(proc)

        # Fallback to last captured partial output
        if partial_output is None:
            partial_output = self._last_partial_output

        logger.info(
            "Cancel requested: iterations=%d, was_forced=%s",
            self.loop_count,
            was_forced,
        )

        return CancelResult(
            partial_output=partial_output,
            iterations_completed=self.loop_count,
            was_forced=was_forced,
        )

    # -------------------------------------------------------------------------
    # SDK-LIFECYCLE-2: Adaptive Timeout
    # -------------------------------------------------------------------------

    def _get_effective_timeout_seconds(self) -> float:
        """Return the timeout to use for the next iteration, in seconds.

        SDK-LIFECYCLE-2: If adaptive timeout is enabled and enough samples
        have been collected, uses ``compute_adaptive_timeout()`` with the
        configured multiplier and bounds.  Otherwise falls back to the static
        ``timeout_minutes`` from config.
        """
        cfg = self.config
        if (
            cfg.adaptive_timeout_enabled
            and len(self._iteration_durations) >= cfg.adaptive_timeout_min_samples
        ):
            adaptive_minutes = compute_adaptive_timeout(
                history=self._iteration_durations,
                multiplier=cfg.adaptive_timeout_multiplier,
                min_minutes=cfg.adaptive_timeout_min_minutes,
                max_minutes=cfg.adaptive_timeout_max_minutes,
            )
            logger.debug(
                "Adaptive timeout: %d min (from %d samples)",
                adaptive_minutes,
                len(self._iteration_durations),
            )
            return adaptive_minutes * 60.0

        return cfg.timeout_minutes * 60.0

    # -------------------------------------------------------------------------
    # SDK-COST: Cost and Token accessors
    # -------------------------------------------------------------------------

    @property
    def cost_tracker(self) -> CostTracker:
        """Return the cost tracker for external session cost / budget queries."""
        return self._cost_tracker

    @property
    def token_rate_limiter(self) -> TokenRateLimiter:
        """Return the token rate limiter for external usage queries."""
        return self._token_rate_limiter
