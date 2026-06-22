"""Telemetry + task-packet surface mixin for RalphAgent (TAP-2772).

Progress snapshots, output logging, iteration history (decomposition input),
metrics events, prompt-cache stats accessor, the TheStudio TaskPacket adapter,
and the Agent SDK tool handlers. Extracted verbatim from agent.py.
"""

from __future__ import annotations

import logging
import time
from typing import Any

from ralph_sdk.agent_base import _AgentBase
from ralph_sdk.agent_models import (
    IterationRecord,
    ProgressSnapshot,
    TaskInput,
    TaskResult,
)
from ralph_sdk.context import PromptCacheStats
from ralph_sdk.decomposition import (
    _estimate_complexity,
    _estimate_file_count,
)
from ralph_sdk.metrics import MetricEvent
from ralph_sdk.status import RalphStatus
from ralph_sdk.tools import (
    RALPH_TOOLS,
    ralph_circuit_state_tool,
    ralph_rate_check_tool,
    ralph_status_tool,
    ralph_task_update_tool,
)

logger = logging.getLogger("ralph.sdk")


class _ReportingMixin(_AgentBase):
    """Progress, logging, history, metrics, and the TaskPacket / tool surface."""

    def get_progress(self) -> ProgressSnapshot:
        """Return a point-in-time snapshot of agent progress.

        SDK-OUTPUT-3: Updated after each iteration.  Safe to call from any
        thread while the loop is running.
        """
        return self._progress.model_copy()

    def _log_output(self, stdout: str, stderr: str, loop_count: int) -> None:
        """Log Claude output to .ralph/logs/."""
        log_dir = self.ralph_dir / "logs"
        log_dir.mkdir(exist_ok=True)
        timestamp = time.strftime("%Y%m%d_%H%M%S")
        log_file = log_dir / f"claude_output_{loop_count:04d}_{timestamp}.log"
        try:
            with open(log_file, "w", encoding="utf-8") as f:
                f.write(f"=== Loop {loop_count} — {timestamp} ===\n")
                f.write(f"=== STDOUT ===\n{stdout}\n")
                if stderr:
                    f.write(f"=== STDERR ===\n{stderr}\n")
        except OSError:
            pass

    def _record_iteration_history(self, status: RalphStatus) -> None:
        """Record an IterationRecord for decomposition detection.

        SDK-SAFETY-2: Builds up iteration_history so that
        detect_decomposition_needed() can evaluate the 4-factor heuristic.
        """
        files_modified = len(self._last_iteration_files)
        tasks_completed = 1 if status.completed_task else 0
        had_progress = files_modified > 0 or tasks_completed > 0
        timed_out = str(status.status).upper() == "TIMEOUT"

        record = IterationRecord(
            loop_count=self.loop_count,
            files_modified=files_modified,
            tasks_completed=tasks_completed,
            timed_out=timed_out,
            complexity=_estimate_complexity(status),
            file_count=_estimate_file_count(status),
            had_progress=had_progress,
        )
        self._iteration_history.append(record)

        # Keep only last 20 records to bound memory
        if len(self._iteration_history) > 20:
            self._iteration_history = self._iteration_history[-20:]

    def _update_progress(
        self,
        status: RalphStatus,
        files_modified: list[str],
    ) -> None:
        """Update the internal progress snapshot after an iteration.

        SDK-OUTPUT-3: Called at the end of each run_iteration() so that
        ``get_progress()`` always reflects the latest state.
        """
        self._progress = ProgressSnapshot(
            loop_count=self.loop_count,
            work_type=status.work_type.value if hasattr(status.work_type, "value") else str(status.work_type),
            current_task=status.next_task or status.completed_task,
            elapsed_seconds=time.time() - self.start_time if self.start_time else 0.0,
            circuit_breaker_state=status.circuit_breaker_state,
            session_id=self.session_id,
            files_modified_this_loop=files_modified,
        )

    def _record_iteration_metrics(
        self,
        status: RalphStatus,
        files_changed: list[str],
        duration_seconds: float,
    ) -> None:
        """Record a MetricEvent for the completed iteration.

        SDK-OUTPUT-4: Delegates to the configured MetricsCollector.
        """
        event = MetricEvent(
            event_type="iteration_complete",
            loop_count=self.loop_count,
            duration_seconds=round(duration_seconds, 3),
            work_type=status.work_type.value if hasattr(status.work_type, "value") else str(status.work_type),
            files_changed=files_changed,
            tokens_in=self._last_tokens_in,
            tokens_out=self._last_tokens_out,
            model=self.config.model,
        )
        try:
            self.metrics_collector.record(event)
        except Exception:
            # Broad: metrics is observability — a backend bug must never
            # crash the agent loop. Surface stack at debug for triage.
            logger.exception("Failed to record metrics")

    def get_prompt_cache_stats(self) -> PromptCacheStats:
        """Return current prompt cache statistics.

        SDK-CONTEXT-2: Useful for observability and debugging cache behavior.
        """
        return self._prompt_cache_stats.model_copy()

    # -------------------------------------------------------------------------
    # TheStudio Adapter (SDK-3)
    # -------------------------------------------------------------------------

    async def process_task_packet(self, packet: dict[str, Any]) -> dict[str, Any]:
        """Process a TheStudio TaskPacket and return a Signal.

        Converts TaskPacket -> TaskInput, runs iteration, returns TaskResult as Signal.
        """
        task_input = TaskInput.from_task_packet(packet)
        status = await self.run_iteration(task_input)
        result = TaskResult(
            status=status,
            loop_count=self.loop_count,
            duration_seconds=time.time() - self.start_time if self.start_time else 0,
        )
        return result.to_signal()

    # -------------------------------------------------------------------------
    # Tool handlers (for Agent SDK tool registration)
    # -------------------------------------------------------------------------

    async def handle_tool_call(self, tool_name: str, tool_input: dict[str, Any]) -> dict[str, Any]:
        """Dispatch tool calls to appropriate async handlers."""
        if tool_name == "ralph_status":
            return await ralph_status_tool(
                ralph_dir=str(self.ralph_dir), **tool_input
            )
        elif tool_name == "ralph_rate_check":
            return await ralph_rate_check_tool(
                ralph_dir=str(self.ralph_dir),
                max_calls_per_hour=self.config.max_calls_per_hour,
            )
        elif tool_name == "ralph_circuit_state":
            return await ralph_circuit_state_tool(
                ralph_dir=str(self.ralph_dir),
            )
        elif tool_name == "ralph_task_update":
            return await ralph_task_update_tool(
                ralph_dir=str(self.ralph_dir), **tool_input
            )
        return {"ok": False, "error": f"Unknown tool: {tool_name}"}

    def get_tool_definitions(self) -> list[dict[str, Any]]:
        """Return tool definitions for Agent SDK registration."""
        return [
            {k: v for k, v in tool.items() if k != "handler"}
            for tool in RALPH_TOOLS
        ]
