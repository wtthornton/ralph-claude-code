"""Ralph SDK Agent — Agent SDK proof of concept replicating ralph_loop.sh core loop.

Dual-mode: standalone CLI + TheStudio embedded.
"""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

from ralph_sdk.config import RalphConfig
from ralph_sdk.status import CircuitBreakerState, RalphStatus
from ralph_sdk.tools import (
    RALPH_TOOLS,
    ralph_circuit_state_tool,
    ralph_rate_check_tool,
    ralph_status_tool,
    ralph_task_update_tool,
)

logger = logging.getLogger("ralph.sdk")


# =============================================================================
# Abstract Interface (SDK-3: Hybrid Architecture)
# =============================================================================

class RalphAgentInterface(Protocol):
    """Abstract interface for Ralph agent implementations (CLI and SDK)."""

    def run_iteration(self, prompt: str, context: dict[str, Any]) -> RalphStatus:
        """Execute a single loop iteration."""
        ...

    def should_exit(self, status: RalphStatus, loop_count: int) -> bool:
        """Evaluate exit conditions (dual-condition gate)."""
        ...

    def check_rate_limit(self) -> bool:
        """Check if within rate limits. Returns True if OK to proceed."""
        ...

    def check_circuit_breaker(self) -> bool:
        """Check circuit breaker state. Returns True if OK to proceed."""
        ...


# =============================================================================
# Task Input/Output (SDK-3: TheStudio compatibility)
# =============================================================================

@dataclass
class TaskInput:
    """Union type for task input — handles fix_plan.md and TheStudio TaskPackets.

    In standalone mode: reads from fix_plan.md + PROMPT.md
    In TheStudio mode: receives TaskPacket with structured fields
    """
    prompt: str = ""
    fix_plan: str = ""
    agent_instructions: str = ""
    # TheStudio fields (populated when embedded)
    task_packet_id: str = ""
    task_packet_type: str = ""
    task_packet_payload: dict[str, Any] = field(default_factory=dict)

    @classmethod
    def from_ralph_dir(cls, ralph_dir: str | Path = ".ralph") -> TaskInput:
        """Load task input from .ralph/ directory (standalone mode)."""
        ralph_path = Path(ralph_dir)
        prompt = ""
        fix_plan = ""
        agent_instructions = ""

        prompt_file = ralph_path / "PROMPT.md"
        if prompt_file.exists():
            prompt = prompt_file.read_text(encoding="utf-8")

        fix_plan_file = ralph_path / "fix_plan.md"
        if fix_plan_file.exists():
            fix_plan = fix_plan_file.read_text(encoding="utf-8")

        agent_file = ralph_path / "AGENT.md"
        if agent_file.exists():
            agent_instructions = agent_file.read_text(encoding="utf-8")

        return cls(
            prompt=prompt,
            fix_plan=fix_plan,
            agent_instructions=agent_instructions,
        )

    @classmethod
    def from_task_packet(cls, packet: dict[str, Any]) -> TaskInput:
        """Load task input from TheStudio TaskPacket."""
        return cls(
            prompt=packet.get("prompt", ""),
            fix_plan=packet.get("fix_plan", ""),
            agent_instructions=packet.get("agent_instructions", ""),
            task_packet_id=packet.get("id", ""),
            task_packet_type=packet.get("type", ""),
            task_packet_payload=packet,
        )


@dataclass
class TaskResult:
    """Output compatible with status.json and TheStudio signals."""
    status: RalphStatus = field(default_factory=RalphStatus)
    exit_code: int = 0
    output: str = ""
    error: str = ""
    loop_count: int = 0
    duration_seconds: float = 0.0

    def to_signal(self) -> dict[str, Any]:
        """Convert to TheStudio-compatible signal format."""
        return {
            "type": "ralph_result",
            "task_result": self.status.to_dict(),
            "exit_code": self.exit_code,
            "output": self.output,
            "error": self.error,
            "loop_count": self.loop_count,
            "duration_seconds": self.duration_seconds,
        }


# =============================================================================
# SDK Agent Implementation (SDK-1: Proof of Concept)
# =============================================================================

class RalphAgent:
    """Ralph Agent SDK implementation — replicates ralph_loop.sh core loop in Python.

    Core loop: Read PROMPT.md + fix_plan.md → invoke Claude → parse response →
    check exit conditions → repeat.

    Supports three operational modes:
    - Standalone CLI: `ralph` (bash loop, unchanged)
    - Standalone SDK: `ralph --sdk` (this class)
    - TheStudio embedded: RalphAgent used as Primary Agent
    """

    def __init__(
        self,
        config: RalphConfig | None = None,
        project_dir: str | Path = ".",
    ) -> None:
        self.config = config or RalphConfig.load(project_dir)
        self.project_dir = Path(project_dir).resolve()
        self.ralph_dir = self.project_dir / self.config.ralph_dir
        self.loop_count = 0
        self.start_time = 0.0
        self.session_id = ""
        self._completion_indicators = 0
        self._running = False

        # Ensure .ralph directory exists
        self.ralph_dir.mkdir(parents=True, exist_ok=True)
        (self.ralph_dir / "logs").mkdir(exist_ok=True)

    # -------------------------------------------------------------------------
    # Core Loop (replicates ralph_loop.sh main())
    # -------------------------------------------------------------------------

    def run(self) -> TaskResult:
        """Execute the autonomous loop until exit conditions are met.

        Replicates ralph_loop.sh main() function:
        1. Load config
        2. Validate prerequisites
        3. Loop: invoke → parse → check exit → repeat
        """
        self.start_time = time.time()
        self._running = True

        logger.info("Ralph SDK starting (v%s)", self.config.model)
        logger.info("Project: %s (%s)", self.config.project_name, self.config.project_type)

        # Load session
        self._load_session()

        # Reset circuit breaker counters (matching bash behavior)
        cb = CircuitBreakerState.load(str(self.ralph_dir))
        cb.no_progress_count = 0
        cb.same_error_count = 0
        cb.save(str(self.ralph_dir))

        result = TaskResult()

        try:
            while self._running:
                self.loop_count += 1
                logger.info("Loop iteration %d", self.loop_count)

                # Rate limit check
                if not self.check_rate_limit():
                    logger.warning("Rate limit reached, waiting for reset")
                    result.error = "Rate limit reached"
                    break

                # Circuit breaker check
                if not self.check_circuit_breaker():
                    logger.warning("Circuit breaker OPEN, stopping")
                    result.error = "Circuit breaker open"
                    break

                # Dry run check
                if self.config.dry_run:
                    logger.info("Dry run mode — skipping API call")
                    status = RalphStatus(
                        status="DRY_RUN",
                        work_type="DRY_RUN",
                        loop_count=self.loop_count,
                    )
                    status.save(str(self.ralph_dir))
                    result.status = status
                    break

                # Load task input
                task_input = TaskInput.from_ralph_dir(str(self.ralph_dir))
                if not task_input.prompt and not task_input.fix_plan:
                    logger.error("No PROMPT.md or fix_plan.md found")
                    result.error = "No task input found"
                    break

                # Execute one iteration
                iteration_status = self.run_iteration(task_input)

                # Check exit conditions (dual-condition gate)
                if self.should_exit(iteration_status, self.loop_count):
                    logger.info("Exit conditions met after %d loops", self.loop_count)
                    result.status = iteration_status
                    break

                # Brief pause between iterations
                time.sleep(2)

        except KeyboardInterrupt:
            logger.info("Interrupted by user")
            result.error = "User interrupt"
        except Exception as e:
            logger.exception("Unexpected error in loop")
            result.error = str(e)
        finally:
            self._running = False
            result.loop_count = self.loop_count
            result.duration_seconds = time.time() - self.start_time

        return result

    def run_iteration(self, task_input: TaskInput | None = None) -> RalphStatus:
        """Execute a single loop iteration via Claude Code CLI.

        Matches ralph_loop.sh behavior: builds command, invokes CLI,
        parses JSONL response, extracts status.
        """
        if task_input is None:
            task_input = TaskInput.from_ralph_dir(str(self.ralph_dir))

        # Build the prompt for this iteration
        prompt = self._build_iteration_prompt(task_input)

        # Build Claude CLI command
        cmd = self._build_claude_command(prompt)

        logger.debug("Invoking: %s", " ".join(cmd[:5]) + "...")

        # Execute Claude CLI
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=self.config.timeout_minutes * 60,
                cwd=str(self.project_dir),
            )

            # Increment call count
            self._increment_call_count()

            # Parse response
            status = self._parse_response(result.stdout, result.returncode)
            status.loop_count = self.loop_count
            status.session_id = self.session_id
            status.save(str(self.ralph_dir))

            # Log output
            self._log_output(result.stdout, result.stderr, self.loop_count)

            return status

        except subprocess.TimeoutExpired:
            logger.warning("Claude CLI timed out after %d minutes", self.config.timeout_minutes)
            status = RalphStatus(
                status="TIMEOUT",
                work_type="UNKNOWN",
                error=f"Timeout after {self.config.timeout_minutes} minutes",
                loop_count=self.loop_count,
            )
            status.save(str(self.ralph_dir))
            return status

        except FileNotFoundError:
            logger.error("Claude CLI not found: %s", self.config.claude_code_cmd)
            return RalphStatus(
                status="ERROR",
                error=f"Claude CLI not found: {self.config.claude_code_cmd}",
            )

    def should_exit(self, status: RalphStatus, loop_count: int) -> bool:
        """Dual-condition exit gate (matching bash implementation).

        Requires BOTH:
        1. completion_indicators >= 2 (NLP heuristics)
        2. EXIT_SIGNAL: true (explicit from Claude)
        """
        if status.exit_signal:
            self._completion_indicators += 1

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

        # Dual condition: need both indicators and explicit exit signal
        return self._completion_indicators >= 2 and status.exit_signal

    def check_rate_limit(self) -> bool:
        """Check if within rate limits."""
        result = ralph_rate_check_tool(
            ralph_dir=str(self.ralph_dir),
            max_calls_per_hour=self.config.max_calls_per_hour,
        )
        return not result["rate_limited"]

    def check_circuit_breaker(self) -> bool:
        """Check circuit breaker — returns True if OK to proceed."""
        result = ralph_circuit_state_tool(ralph_dir=str(self.ralph_dir))
        return result["can_proceed"]

    # -------------------------------------------------------------------------
    # Private helpers
    # -------------------------------------------------------------------------

    def _build_iteration_prompt(self, task_input: TaskInput) -> str:
        """Build the prompt for one iteration (matching bash PROMPT+fix_plan injection)."""
        parts = []
        if task_input.prompt:
            parts.append(task_input.prompt)
        if task_input.fix_plan:
            parts.append(f"\n\n## Current Fix Plan\n\n{task_input.fix_plan}")
        if task_input.agent_instructions:
            parts.append(f"\n\n## Build/Run Instructions\n\n{task_input.agent_instructions}")
        return "\n".join(parts)

    def _build_claude_command(self, prompt: str) -> list[str]:
        """Build Claude CLI command (matching bash build_claude_command())."""
        cmd = [self.config.claude_code_cmd]

        # Agent mode (v1.0+)
        if self.config.use_agent:
            cmd.extend(["--agent", self.config.agent_name])

        # Prompt
        cmd.extend(["-p", prompt])

        # Output format
        cmd.extend(["--output-format", self.config.output_format])

        # Allowed tools
        if self.config.allowed_tools:
            cmd.extend(["--allowedTools", ",".join(self.config.allowed_tools)])

        # Session continuity
        if self.config.session_continuity and self.session_id:
            cmd.extend(["--continue", self.session_id])

        # Max turns
        cmd.extend(["--max-turns", str(self.config.max_turns)])

        return cmd

    def _parse_response(self, stdout: str, return_code: int) -> RalphStatus:
        """Parse Claude CLI response (JSONL or text).

        Mirrors ralph_extract_result_from_stream + on-stop.sh RALPH_STATUS extraction.
        """
        status = RalphStatus()

        if return_code != 0:
            status.status = "ERROR"
            status.error = f"Claude CLI exited with code {return_code}"
            return status

        # Try JSONL parsing first (primary path since v1.2.0)
        for line in reversed(stdout.strip().splitlines()):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if obj.get("type") == "result":
                    return self._parse_result_object(obj)
            except json.JSONDecodeError:
                continue

        # Fallback: extract RALPH_STATUS from text
        return self._parse_text_status(stdout)

    def _parse_result_object(self, obj: dict[str, Any]) -> RalphStatus:
        """Parse a JSONL result object into RalphStatus."""
        status = RalphStatus()

        # Extract result text
        result_text = ""
        if "result" in obj:
            result_text = obj["result"]
        elif "content" in obj:
            # Content may be a list of blocks
            content = obj["content"]
            if isinstance(content, list):
                for block in content:
                    if isinstance(block, dict) and block.get("type") == "text":
                        result_text += block.get("text", "")
            elif isinstance(content, str):
                result_text = content

        # Extract session ID
        if "session_id" in obj:
            self.session_id = obj["session_id"]
            self._save_session()

        # Extract RALPH_STATUS fields from result text
        return self._extract_ralph_status(result_text, status)

    def _extract_ralph_status(self, text: str, status: RalphStatus) -> RalphStatus:
        """Extract RALPH_STATUS fields from response text.

        Matches on-stop.sh field extraction with auto-unescape.
        """
        # Auto-unescape JSON-encoded \n (matching STREAM-3)
        text = text.replace("\\n", "\n")

        field_patterns = {
            "WORK_TYPE": r"WORK_TYPE:\s*(.+?)(?:\n|$)",
            "COMPLETED_TASK": r"COMPLETED_TASK:\s*(.+?)(?:\n|$)",
            "NEXT_TASK": r"NEXT_TASK:\s*(.+?)(?:\n|$)",
            "PROGRESS_SUMMARY": r"PROGRESS_SUMMARY:\s*(.+?)(?:\n|$)",
            "EXIT_SIGNAL": r"EXIT_SIGNAL:\s*(.+?)(?:\n|$)",
        }

        for field_name, pattern in field_patterns.items():
            match = re.search(pattern, text, re.IGNORECASE)
            if match:
                value = match.group(1).strip()
                if field_name == "WORK_TYPE":
                    status.work_type = value
                elif field_name == "COMPLETED_TASK":
                    status.completed_task = value
                elif field_name == "NEXT_TASK":
                    status.next_task = value
                elif field_name == "PROGRESS_SUMMARY":
                    status.progress_summary = value
                elif field_name == "EXIT_SIGNAL":
                    status.exit_signal = value.lower() in ("true", "yes", "1")

        return status

    def _parse_text_status(self, text: str) -> RalphStatus:
        """Fallback text parsing when JSONL not available."""
        status = RalphStatus()
        return self._extract_ralph_status(text, status)

    def _load_session(self) -> None:
        """Load session ID from .ralph/.claude_session_id."""
        session_file = self.ralph_dir / ".claude_session_id"
        if session_file.exists():
            try:
                self.session_id = session_file.read_text().strip()
            except OSError:
                pass

    def _save_session(self) -> None:
        """Save session ID to .ralph/.claude_session_id."""
        session_file = self.ralph_dir / ".claude_session_id"
        try:
            session_file.write_text(self.session_id + "\n")
        except OSError:
            pass

    def _increment_call_count(self) -> None:
        """Increment API call counter (matching bash rate limiting)."""
        call_count_file = self.ralph_dir / ".call_count"
        last_reset_file = self.ralph_dir / ".last_reset"

        # Check if hour has elapsed
        now = int(time.time())
        last_reset = 0
        if last_reset_file.exists():
            try:
                last_reset = int(last_reset_file.read_text().strip())
            except (ValueError, OSError):
                pass

        if now - last_reset >= 3600:
            # Reset counter
            call_count_file.write_text("1\n")
            last_reset_file.write_text(f"{now}\n")
        else:
            # Increment
            count = 0
            if call_count_file.exists():
                try:
                    count = int(call_count_file.read_text().strip())
                except (ValueError, OSError):
                    pass
            call_count_file.write_text(f"{count + 1}\n")

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

    # -------------------------------------------------------------------------
    # TheStudio Adapter (SDK-3)
    # -------------------------------------------------------------------------

    def process_task_packet(self, packet: dict[str, Any]) -> dict[str, Any]:
        """Process a TheStudio TaskPacket and return a Signal.

        Converts TaskPacket → TaskInput, runs iteration, returns TaskResult as Signal.
        """
        task_input = TaskInput.from_task_packet(packet)
        status = self.run_iteration(task_input)
        result = TaskResult(
            status=status,
            loop_count=self.loop_count,
            duration_seconds=time.time() - self.start_time if self.start_time else 0,
        )
        return result.to_signal()

    # -------------------------------------------------------------------------
    # Tool handlers (for Agent SDK tool registration)
    # -------------------------------------------------------------------------

    def handle_tool_call(self, tool_name: str, tool_input: dict[str, Any]) -> dict[str, Any]:
        """Dispatch tool calls to appropriate handlers."""
        handlers = {
            "ralph_status": lambda inp: ralph_status_tool(
                ralph_dir=str(self.ralph_dir), **inp
            ),
            "ralph_rate_check": lambda inp: ralph_rate_check_tool(
                ralph_dir=str(self.ralph_dir),
                max_calls_per_hour=self.config.max_calls_per_hour,
            ),
            "ralph_circuit_state": lambda inp: ralph_circuit_state_tool(
                ralph_dir=str(self.ralph_dir),
            ),
            "ralph_task_update": lambda inp: ralph_task_update_tool(
                ralph_dir=str(self.ralph_dir), **inp
            ),
        }

        handler = handlers.get(tool_name)
        if handler:
            return handler(tool_input)
        return {"ok": False, "error": f"Unknown tool: {tool_name}"}

    def get_tool_definitions(self) -> list[dict[str, Any]]:
        """Return tool definitions for Agent SDK registration."""
        return [
            {k: v for k, v in tool.items() if k != "handler"}
            for tool in RALPH_TOOLS
        ]
