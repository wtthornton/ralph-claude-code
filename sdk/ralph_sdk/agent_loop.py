"""Core loop orchestration mixin for RalphAgent (TAP-2772).

The async main() equivalent: per-iteration runner, run-loop driver,
finalization, and the single-iteration Claude CLI invocation (run_iteration).
Pre-flight guards and the exit gate live in agent_guards.py. Extracted
verbatim from agent.py.
"""

from __future__ import annotations

import asyncio
import logging
import time

from ralph_sdk.agent_base import _AgentBase
from ralph_sdk.agent_models import (
    _ADAPTIVE_TIMEOUT_HISTORY_SIZE,
    TaskInput,
    TaskResult,
    detect_decomposition_needed,
)
from ralph_sdk.import_graph import CachedImportGraph
from ralph_sdk.parsing import detect_permission_denials, extract_files_changed
from ralph_sdk.plan_optimizer import optimize_plan
from ralph_sdk.status import (
    CircuitBreakerState,
    ErrorCategory,
    RalphStatus,
    classify_error,
)

logger = logging.getLogger("ralph.sdk")


class _LoopMixin(_AgentBase):
    """Run-loop driver, run_iteration, and per-iteration bookkeeping."""

    async def _run_dry_iteration(self, result: TaskResult) -> None:
        logger.info("Dry run mode — skipping API call")
        status = RalphStatus(
            status="DRY_RUN",
            work_type="DRY_RUN",
            loop_count=self.loop_count,
            correlation_id=self.correlation_id,
        )
        await self.state_backend.write_status(status.to_dict())
        result.status = status

    async def _maybe_optimize_plan(self) -> None:
        """Run plan optimizer before the first iteration if enabled."""
        if not self.config.optimize_plan:
            return
        try:
            fix_plan_path = self.ralph_dir / "fix_plan.md"
            if not fix_plan_path.exists():
                return
            graph = CachedImportGraph(
                self.project_dir,
                max_age_seconds=self.config.optimize_plan_cache_seconds,
                project_type=self.config.project_type or None,
            )
            opt_result = optimize_plan(
                fix_plan_path,
                project_root=self.project_dir,
                import_graph=graph,
            )
            if opt_result.changed:
                logger.info(
                    "Plan optimized: %s",
                    opt_result.reason,
                    extra={"correlation_id": self.correlation_id},
                )
        except Exception as exc:
            logger.debug("Plan optimization skipped: %s", exc)

    async def _initialize_run(self) -> None:
        """Pre-loop bookkeeping: preflight, session, CB reset, plan optimize."""
        await self._preflight_claude_version()
        logger.info(
            "Ralph SDK starting (v%s) [%s]",
            self.config.model,
            self.correlation_id,
            extra={"correlation_id": self.correlation_id},
        )
        logger.info(
            "Project: %s (%s)",
            self.config.project_name,
            self.config.project_type,
            extra={"correlation_id": self.correlation_id},
        )
        await self._load_session()
        self._session_iteration_count = 0
        self._session_start_time = time.time()
        await self._initialize_session_metadata()

        cb_data = await self.state_backend.read_circuit_breaker()
        cb = (
            CircuitBreakerState._from_state_dict(cb_data)
            if cb_data
            else CircuitBreakerState()
        )
        cb.no_progress_count = 0
        cb.same_error_count = 0
        await self.state_backend.write_circuit_breaker(cb._to_state_dict())

        await self._maybe_optimize_plan()

    def _post_iteration_decomposition_check(
        self, iteration_status: RalphStatus
    ) -> None:
        hint = detect_decomposition_needed(
            iteration_status, self._iteration_history, self.config
        )
        if hint.should_decompose:
            logger.warning(
                "SDK-SAFETY-2: %s (suggested_split=%d)",
                hint.reason,
                hint.suggested_split,
            )
            self._pending_decomposition_hint = hint

    async def _preflight_checks(self, result: TaskResult) -> bool:
        """Run rate-limit, budget, and circuit-breaker guards. Returns False to break."""
        if not await self._check_invocation_rate_limit(result):
            return False
        if not self._check_token_rate_limit(result):
            return False
        if not self._check_budget(result):
            return False
        if not await self.check_circuit_breaker():
            logger.warning("Circuit breaker OPEN, stopping")
            result.error = "Circuit breaker open"
            return False
        return True

    async def _execute_iteration(
        self,
        result: TaskResult,
        all_files_changed: dict[str, None],
    ) -> bool:
        """Run one loop iteration. Returns True to continue, False to break."""
        if not await self._preflight_checks(result):
            return False

        if self.config.dry_run:
            await self._run_dry_iteration(result)
            return False

        task_input = TaskInput.from_ralph_dir(str(self.ralph_dir))
        if not task_input.prompt and not task_input.fix_plan:
            logger.error("No PROMPT.md or fix_plan.md found")
            result.error = "No task input found"
            return False

        iteration_status = await self.run_iteration(task_input)

        self._session_iteration_count += 1
        if await self._should_rotate_session():
            logger.info(
                "Session rotation triggered at iteration %d (session iterations=%d)",
                self.loop_count,
                self._session_iteration_count,
            )
            await self._rotate_session(iteration_status)

        for fp in self._last_iteration_files:
            all_files_changed.setdefault(fp, None)

        self._record_iteration_history(iteration_status)
        self._post_iteration_decomposition_check(iteration_status)

        if await self.should_exit(iteration_status, self.loop_count):
            logger.info("Exit conditions met after %d loops", self.loop_count)
            result.status = iteration_status
            return False

        await asyncio.sleep(2)
        return True

    def _finalize_result(
        self, result: TaskResult, all_files_changed: dict[str, None]
    ) -> None:
        self._running = False
        result.loop_count = self.loop_count
        result.duration_seconds = time.time() - self.start_time
        result.tokens_in = self._last_tokens_in
        result.tokens_out = self._last_tokens_out
        result.files_changed = list(all_files_changed)
        session_cost = self._cost_tracker.get_session_cost()
        result.total_cost_usd = session_cost.total_usd

    async def run(self) -> TaskResult:
        """Execute the autonomous loop until exit conditions are met."""
        self.start_time = time.time()
        self._running = True
        self._cancelled = False
        # TAP-675: Capture the loop we're running on so cancel() from another
        # thread can schedule work safely via call_soon_threadsafe.
        self._loop = asyncio.get_running_loop()

        await self._initialize_run()

        result = TaskResult()
        all_files_changed: dict[str, None] = {}

        try:
            while self._running:
                self.loop_count += 1
                logger.info("Loop iteration %d", self.loop_count)
                if not await self._execute_iteration(result, all_files_changed):
                    break
        except KeyboardInterrupt:
            logger.info("Interrupted by user")
            result.error = "User interrupt"
        except Exception as e:
            logger.exception("Unexpected error in loop")
            result.error = str(e)
            result.status.error_category = classify_error(exception=e)
        finally:
            self._finalize_result(result, all_files_changed)

        return result

    async def run_iteration(
        self,
        task_input: TaskInput | None = None,
        system_prompt: str | None = None,
    ) -> RalphStatus:
        """Execute a single loop iteration via Claude Code CLI.

        Uses asyncio.create_subprocess_exec() with asyncio.wait_for() timeout.

        Args:
            task_input: Task input to process. Loads from .ralph/ if None.
            system_prompt: Optional system prompt passed through to Claude CLI
                via --system-prompt flag.
        """
        if task_input is None:
            task_input = TaskInput.from_ralph_dir(str(self.ralph_dir))

        cmd = self._build_iteration_command(task_input, system_prompt)
        logger.debug("Invoking: %s", " ".join(cmd[:5]) + "...")

        iteration_start = time.time()

        # SDK-LIFECYCLE-2: Compute effective timeout (adaptive or static)
        timeout_seconds = self._get_effective_timeout_seconds()

        # Execute Claude CLI asynchronously
        try:
            proc = await asyncio.create_subprocess_exec(
                *cmd,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.PIPE,
                cwd=str(self.project_dir),
            )

            # SDK-LIFECYCLE-1: Track current subprocess for cancel()
            self._current_proc = proc

            stdout_bytes, stderr_bytes = await asyncio.wait_for(
                proc.communicate(),
                timeout=timeout_seconds,
            )

            # SDK-LIFECYCLE-1: Clear subprocess reference
            self._current_proc = None

            stdout = stdout_bytes.decode("utf-8", errors="replace") if stdout_bytes else ""
            stderr = stderr_bytes.decode("utf-8", errors="replace") if stderr_bytes else ""
            returncode = proc.returncode or 0

            # SDK-LIFECYCLE-1: Stash partial output for cancel()
            self._last_partial_output = stdout if stdout else None

            self._record_iteration_duration(iteration_start)
            await self._increment_call_count()

            # Parse response (also extracts session_id and token counts)
            status = self._parse_response(stdout, returncode)
            status.loop_count = self.loop_count
            status.session_id = self.session_id
            status.correlation_id = self.correlation_id

            self._record_iteration_cost()
            return await self._process_iteration_output(
                status, stdout, stderr, returncode, iteration_start
            )

        except TimeoutError:
            return await self._handle_iteration_timeout(proc, timeout_seconds)

        except FileNotFoundError:
            self._current_proc = None
            logger.error("Claude CLI not found: %s", self.config.claude_code_cmd)
            return RalphStatus(
                status="ERROR",
                error=f"Claude CLI not found: {self.config.claude_code_cmd}",
                error_category=ErrorCategory.TOOL_UNAVAILABLE,
            )

    async def _handle_iteration_timeout(
        self,
        proc: asyncio.subprocess.Process,
        timeout_seconds: float,
    ) -> RalphStatus:
        """SDK-LIFECYCLE-1: kill the orphaned subprocess and build a TIMEOUT status."""
        timeout_minutes_used = timeout_seconds / 60.0
        logger.warning(
            "Claude CLI timed out after %.1f minutes", timeout_minutes_used,
        )
        # SDK-LIFECYCLE-1: Clear subprocess reference
        self._current_proc = None
        # Kill the orphaned subprocess to prevent resource leaks
        try:
            proc.kill()
            await proc.wait()
        except (ProcessLookupError, OSError) as e:
            # Process already dead or wait() race — both are benign on
            # the timeout path; everything else has already given up.
            logger.debug("post-timeout proc cleanup: %s", e)
        status = RalphStatus(
            status="TIMEOUT",
            work_type="UNKNOWN",
            error=f"Timeout after {timeout_minutes_used:.0f} minutes",
            loop_count=self.loop_count,
            error_category=ErrorCategory.TIMEOUT,
        )
        await self.state_backend.write_status(status.to_dict())
        self._update_progress(status, [])
        return status

    def _build_iteration_command(
        self,
        task_input: TaskInput,
        system_prompt: str | None,
    ) -> list[str]:
        """Build the prompt (+ decomposition hint) and the Claude CLI command."""
        prompt = self._build_iteration_prompt(task_input)

        # SDK-SAFETY-2: Inject decomposition hint into prompt if pending
        if self._pending_decomposition_hint and self._pending_decomposition_hint.should_decompose:
            hint = self._pending_decomposition_hint
            prompt += (
                f"\n\n## Decomposition Advisory\n\n"
                f"**{hint.reason}**\n\n"
                f"Consider splitting this work into ~{hint.suggested_split} smaller sub-tasks "
                f"before proceeding. Focus on one logical unit of change per iteration."
            )
            self._pending_decomposition_hint = None  # Consumed

        # Build Claude CLI command (task_text feeds per-task model routing)
        return self._build_claude_command(
            prompt,
            system_prompt=system_prompt,
            task_text=self._extract_next_task_text(task_input),
        )

    def _record_iteration_duration(self, iteration_start: float) -> None:
        """SDK-LIFECYCLE-2: append this iteration's wall-clock to the history."""
        self._iteration_durations.append(time.time() - iteration_start)
        if len(self._iteration_durations) > _ADAPTIVE_TIMEOUT_HISTORY_SIZE:
            self._iteration_durations = self._iteration_durations[
                -_ADAPTIVE_TIMEOUT_HISTORY_SIZE:
            ]

    def _record_iteration_cost(self) -> None:
        """SDK-COST-1/3: record cost + token usage for the just-parsed response."""
        if not self._tokens_extracted:
            # TAP-662: distinguish "no usage block" from "0 tokens used"
            logger.warning(
                "No token counts in CLI output; cost for this iteration not recorded"
            )
        elif self._last_tokens_in or self._last_tokens_out:
            self._cost_tracker.record_iteration(
                model=self.config.model,
                input_tokens=self._last_tokens_in,
                output_tokens=self._last_tokens_out,
            )

        # SDK-COST-3: Record tokens for rate limiting
        self._token_rate_limiter.record_tokens(
            self._last_tokens_in,
            self._last_tokens_out,
        )

    async def _process_iteration_output(
        self,
        status: RalphStatus,
        stdout: str,
        stderr: str,
        returncode: int,
        iteration_start: float,
    ) -> RalphStatus:
        """Classify errors, extract files/denials, persist state, log output.

        The tail of run_iteration's success path, extracted so run_iteration
        stays a thin orchestrator (TAP-2772).
        """
        # SDK-OUTPUT-2: Classify errors on non-zero exit codes
        if returncode != 0:
            status.error_category = classify_error(
                exit_code=returncode,
                output=stdout + stderr,
            )

        # SDK-OUTPUT-1: Extract files_changed from JSONL tool_use records
        iteration_files = extract_files_changed(stdout)

        # SDK-LIFECYCLE-3: Detect permission denials
        denials = detect_permission_denials(stdout)
        if denials:
            status.permission_denials = denials
            logger.info(
                "Detected %d permission denial(s): %s",
                len(denials),
                ", ".join(
                    f"{d.tool_name}({d.denied_pattern})"
                    for d in denials
                ),
            )

        await self.state_backend.write_status(status.to_dict())

        # Persist extracted session_id for continuity across restarts
        if self.session_id:
            await self._save_session()

        # SDK-CONTEXT-3: Update session metadata
        await self._update_session_metadata()

        # SDK-OUTPUT-3: Update progress snapshot
        self._update_progress(status, iteration_files)

        # SDK-OUTPUT-4: Record metrics
        iteration_duration = time.time() - iteration_start
        self._record_iteration_metrics(
            status=status,
            files_changed=iteration_files,
            duration_seconds=iteration_duration,
        )

        # Log output
        self._log_output(stdout, stderr, self.loop_count)

        # Stash iteration files on the result so callers of run() can access them
        self._last_iteration_files = iteration_files

        return status
