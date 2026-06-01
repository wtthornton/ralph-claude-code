"""Shared type surface for RalphAgent mixins (TAP-2772).

Annotation-only attribute declarations (PEP 563 strings under
``from __future__ import annotations``, no runtime assignment) so they do NOT
shadow the real instance attributes set in ``RalphAgent.__init__``. Cross-mixin
method signatures live under ``TYPE_CHECKING`` so they don't exist at runtime
(no MRO shadowing) but mypy can still resolve them.

The decomposition keeps ONE ``RalphAgent`` class inheriting from cohesive
mixins; the public API and every ``self.*`` call are unchanged.
"""

from __future__ import annotations

import asyncio
from pathlib import Path
from typing import TYPE_CHECKING

from ralph_sdk.agent_models import (
    DecompositionHint,
    IterationRecord,
    ProgressSnapshot,
)
from ralph_sdk.config import RalphConfig
from ralph_sdk.context import ContextManager, PromptCacheStats
from ralph_sdk.cost import CostTracker, TokenRateLimiter
from ralph_sdk.metrics import MetricsCollector
from ralph_sdk.state import RalphStateBackend

if TYPE_CHECKING:
    from ralph_sdk.agent_models import TaskInput, TaskResult, TracerProtocol
    from ralph_sdk.status import RalphStatus


class _AgentBase:
    """Type surface shared across the RalphAgent mixins.

    Only annotations and ``TYPE_CHECKING`` method stubs live here; the real
    attributes are assigned in ``RalphAgent.__init__`` and the real methods are
    defined on the concrete mixins / ``RalphAgent``.
    """

    # --- instance attributes (declarations only; set in RalphAgent.__init__) ---
    config: RalphConfig
    project_dir: Path
    ralph_dir: Path
    loop_count: int
    start_time: float
    session_id: str
    correlation_id: str
    state_backend: RalphStateBackend
    metrics_collector: MetricsCollector
    tracer: TracerProtocol | None

    _completion_indicators: int
    _running: bool
    _last_tokens_in: int
    _last_tokens_out: int
    _tokens_extracted: bool

    _cancelled: bool
    _current_proc: asyncio.subprocess.Process | None
    _last_partial_output: str | None
    _loop: asyncio.AbstractEventLoop | None

    _iteration_durations: list[float]
    _progress: ProgressSnapshot
    _last_iteration_files: list[str]
    _iteration_history: list[IterationRecord]
    _completion_indicator_list: list[str]
    _pending_decomposition_hint: DecompositionHint | None

    _context_manager: ContextManager
    _prompt_cache_stats: PromptCacheStats
    _session_iteration_count: int
    _session_start_time: float

    _cost_tracker: CostTracker
    _token_rate_limiter: TokenRateLimiter

    if TYPE_CHECKING:
        # --- methods called ACROSS mixin boundaries (signatures only) ---
        # Defined on a different mixin / RalphAgent than the caller.

        # RalphAgent (agent.py) methods called from the loop mixin
        def _get_effective_timeout_seconds(self) -> float: ...

        # _GuardMixin pre-flight checks (called from _LoopMixin._execute_iteration)
        async def _check_invocation_rate_limit(self, result: TaskResult) -> bool: ...
        def _check_token_rate_limit(self, result: TaskResult) -> bool: ...
        def _check_budget(self, result: TaskResult) -> bool: ...

        # _GuardMixin / _LoopMixin methods (called across mixins / RalphAgent)
        async def check_rate_limit(self) -> bool: ...
        async def check_circuit_breaker(self) -> bool: ...
        async def should_exit(
            self, status: RalphStatus, loop_count: int
        ) -> bool: ...
        async def run_iteration(
            self,
            task_input: TaskInput | None = ...,
            system_prompt: str | None = ...,
        ) -> RalphStatus: ...

        # _SessionMixin methods called from RalphAgent / other mixins
        def _extract_session_id(self, stdout: str) -> None: ...
        async def _load_session(self) -> None: ...
        async def _save_session(self) -> None: ...
        async def _increment_call_count(self) -> None: ...
        async def _initialize_session_metadata(self) -> None: ...
        async def _should_rotate_session(self) -> bool: ...
        async def _rotate_session(self, last_status: RalphStatus) -> None: ...
        async def _expire_session(self) -> None: ...
        async def _update_session_metadata(self) -> None: ...

        # _InvocationMixin methods called from RalphAgent
        def _build_iteration_prompt(self, task_input: TaskInput) -> str: ...
        async def _preflight_claude_version(self) -> None: ...
        def _build_claude_command(
            self,
            prompt: str,
            system_prompt: str | None = ...,
            task_text: str = ...,
        ) -> list[str]: ...
        def _extract_next_task_text(self, task_input: TaskInput) -> str: ...
        def _select_effective_model(self, task_text: str) -> str: ...
        def _parse_response(self, stdout: str, return_code: int) -> RalphStatus: ...

        # _ReportingMixin methods called from RalphAgent
        def _log_output(self, stdout: str, stderr: str, loop_count: int) -> None: ...
        def _record_iteration_history(self, status: RalphStatus) -> None: ...
        def _update_progress(
            self, status: RalphStatus, files_modified: list[str]
        ) -> None: ...
        def _record_iteration_metrics(
            self,
            status: RalphStatus,
            files_changed: list[str],
            duration_seconds: float,
        ) -> None: ...
