"""Prompt / command / parse mixin for RalphAgent (TAP-2772).

Builds the per-iteration prompt (progressive context + cache split), the
Claude CLI command (agent mode + per-task model routing), and the 3-strategy
response parser. Extracted verbatim from agent.py.
"""

from __future__ import annotations

import asyncio
import logging
import re

from ralph_sdk.agent_base import _AgentBase
from ralph_sdk.agent_models import TaskInput
from ralph_sdk.complexity import classify_complexity
from ralph_sdk.config import RalphConfigError
from ralph_sdk.context import estimate_tokens, split_prompt
from ralph_sdk.cost import CostComplexityBand, select_model
from ralph_sdk.parsing import parse_ralph_status
from ralph_sdk.status import RalphStatus

logger = logging.getLogger("ralph.sdk")


class _InvocationMixin(_AgentBase):
    """Prompt construction, CLI command building, model routing, and parsing."""

    def _build_iteration_prompt(self, task_input: TaskInput) -> str:
        """Build the prompt for one iteration with progressive context loading.

        SDK-CONTEXT-1: Trims fix_plan.md to the active section to reduce tokens.
        SDK-CONTEXT-2: Splits into stable/dynamic parts and tracks cache stats.
        """
        parts = []
        if task_input.prompt:
            parts.append(task_input.prompt)
        if task_input.fix_plan:
            # SDK-CONTEXT-1: Progressive context loading — trim fix_plan
            trimmed_plan = self._context_manager.trim_fix_plan(task_input.fix_plan)
            token_estimate = estimate_tokens(trimmed_plan)
            logger.debug(
                "Fix plan trimmed: %d -> %d chars (~%d tokens)",
                len(task_input.fix_plan),
                len(trimmed_plan),
                token_estimate,
            )
            parts.append(f"\n\n## Current Fix Plan\n\n{trimmed_plan}")
        if task_input.agent_instructions:
            parts.append(f"\n\n## Build/Run Instructions\n\n{task_input.agent_instructions}")

        full_prompt = "\n".join(parts)

        # SDK-CONTEXT-2: Prompt cache optimization — split and track
        loop_context = {
            "loop_count": self.loop_count,
            "session_id": self.session_id,
            "session_iteration": self._session_iteration_count,
        }
        prompt_parts = split_prompt(full_prompt, loop_context)
        is_hit = self._prompt_cache_stats.record(prompt_parts.prefix_hash)
        logger.debug(
            "Prompt cache %s (hit_rate=%.1f%%, prefix_hash=%s)",
            "HIT" if is_hit else "MISS",
            self._prompt_cache_stats.hit_rate * 100,
            prompt_parts.prefix_hash[:8],
        )

        return prompt_parts.full_prompt()

    async def _preflight_claude_version(self) -> None:
        """Verify Claude CLI >= config.claude_min_version, else raise.

        TAP-1104: SDK only supports agent mode. The `--agent` flag landed in
        Claude CLI 2.1.0; older binaries will silently ignore it and fall
        back to legacy `-p` mode, which is the failure the bash side already
        deleted via ADR-0006. We detect at startup and refuse to proceed.

        Network/exec errors degrade to a WARN log (matches bash behavior at
        ralph_loop.sh:1649-1652) — never raise on "could not detect".
        """
        try:
            proc = await asyncio.create_subprocess_exec(
                self.config.claude_code_cmd, "--version",
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )
            stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=5.0)
        except (TimeoutError, FileNotFoundError, OSError) as e:
            logger.warning("Cannot detect Claude CLI version (%s); assuming compatible", e)
            return

        match = re.search(rb"(\d+)\.(\d+)\.(\d+)", stdout)
        if not match:
            logger.warning("Cannot parse Claude CLI version from %r; assuming compatible", stdout[:80])
            return

        installed = tuple(int(g) for g in match.groups())
        required = tuple(
            int(g) for g in (self.config.claude_min_version.split(".") + ["0", "0", "0"])[:3]
        )
        if installed < required:
            raise RalphConfigError(
                f"Claude CLI version {'.'.join(map(str, installed))} is older than "
                f"required {self.config.claude_min_version}. Agent mode (--agent) "
                f"requires CLI >= 2.1.0. Upgrade with: "
                f"npm update -g @anthropic-ai/claude-code"
            )

    def _build_claude_command(
        self,
        prompt: str,
        system_prompt: str | None = None,
        task_text: str = "",
    ) -> list[str]:
        """Build Claude CLI command (matching bash build_claude_command())."""
        cmd = [self.config.claude_code_cmd]

        # TAP-1104: agent mode is the only execution path. The
        # `--allowedTools` flag is incompatible with `--agent` and is
        # therefore intentionally not emitted; tool surface is set by the
        # agent file's `tools:` allowlist + `disallowedTools:` blocklist.
        cmd.extend(["--agent", self.config.agent_name])

        # System prompt (for TheStudio DeveloperRoleConfig injection)
        if system_prompt:
            cmd.extend(["--system-prompt", system_prompt])

        # Model: per-task complexity routing when enabled, else config.model.
        # Falls back to config.model when task_text is empty so behavior matches
        # the bash build_claude_command (lib/complexity.sh::ralph_select_model).
        effective_model = self._select_effective_model(task_text)
        if effective_model:
            cmd.extend(["--model", effective_model])

        # Prompt
        cmd.extend(["-p", prompt])

        # Output format
        cmd.extend(["--output-format", self.config.output_format])

        # Session continuity
        if self.config.session_continuity and self.session_id:
            cmd.extend(["--continue", self.session_id])

        # Max turns
        cmd.extend(["--max-turns", str(self.config.max_turns)])

        return cmd

    def _extract_next_task_text(self, task_input: TaskInput) -> str:
        """Pull the first unchecked fix_plan.md task line for model routing.

        Returns empty string when no plan/no unchecked tasks — caller treats
        empty as "no routing input" and falls back to config.model.
        """
        if not task_input.fix_plan:
            return ""
        for line in task_input.fix_plan.splitlines():
            stripped = line.lstrip()
            if stripped.startswith("- [ ]"):
                return stripped[5:].strip()[:300]
        return ""

    def _select_effective_model(self, task_text: str) -> str:
        """Route to a model based on task complexity, or fall back to config.model.

        Mirrors bash ralph_select_model: routing must be opted in
        (model_routing_enabled=true) AND task_text must be non-empty. The
        config.model_map_* fields determine the per-band targets.
        """
        if not self.config.model_routing_enabled or not task_text:
            return self.config.model
        try:
            band = classify_complexity(task_text)
            model_map = {
                CostComplexityBand.TRIVIAL: self.config.model_map_trivial,
                CostComplexityBand.SMALL: self.config.model_map_small,
                CostComplexityBand.MEDIUM: self.config.model_map_medium,
                CostComplexityBand.LARGE: self.config.model_map_large,
                CostComplexityBand.ARCHITECTURAL: self.config.model_map_architectural,
            }
            routed = select_model(band, retry_count=0, model_map=model_map)
        except Exception:
            return self.config.model
        if routed and routed != self.config.model:
            logger.info(
                "Model routed: %s (complexity=%s, override of %s)",
                routed, band.value, self.config.model,
            )
        return routed or self.config.model

    def _parse_response(self, stdout: str, return_code: int) -> RalphStatus:
        """Parse Claude CLI response using 3-strategy chain (JSON block -> JSONL -> text).

        Delegates to ralph_sdk.parsing.parse_ralph_status for the actual parsing,
        with session_id extraction handled here.
        """
        status = RalphStatus()

        if return_code != 0:
            status.status = "ERROR"
            status.error = f"Claude CLI exited with code {return_code}"
            return status

        # Extract session_id from JSONL before parsing status
        self._extract_session_id(stdout)

        # Use the 3-strategy parse chain
        return parse_ralph_status(stdout)
