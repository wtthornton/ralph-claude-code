"""Session lifecycle mixin for RalphAgent (TAP-2772).

SDK-CONTEXT-3: session metadata, rotation (Continue-As-New), and expiry,
plus session-id / token extraction and the API call counter. Extracted
verbatim from agent.py to keep the god-module's MI in check.
"""

from __future__ import annotations

import json
import logging
import time

from ralph_sdk.agent_base import _AgentBase
from ralph_sdk.agent_models import ContinueAsNewState
from ralph_sdk.context import PromptCacheStats
from ralph_sdk.status import RalphStatus

logger = logging.getLogger("ralph.sdk")


class _SessionMixin(_AgentBase):
    """Session id, call counting, metadata, rotation, and expiry."""

    def _extract_session_id(self, stdout: str) -> None:
        """Extract session_id and token counts from JSONL result objects."""
        self._last_tokens_in = 0
        self._last_tokens_out = 0
        self._tokens_extracted = False
        for line in reversed(stdout.strip().splitlines()):
            line = line.strip()
            if not line:
                continue
            try:
                obj = json.loads(line)
                if obj.get("type") == "result":
                    if "session_id" in obj:
                        self.session_id = obj["session_id"]
                    # Claude Code emits token counts nested under "usage".
                    usage = obj.get("usage") or {}
                    self._last_tokens_in += usage.get("input_tokens", 0)
                    self._last_tokens_out += usage.get("output_tokens", 0)
                    self._tokens_extracted = True
                    return
            except json.JSONDecodeError:
                continue

    async def _load_session(self) -> None:
        """Load session ID via state backend."""
        self.session_id = await self.state_backend.read_session_id()

    async def _save_session(self) -> None:
        """Save session ID via state backend."""
        await self.state_backend.write_session_id(self.session_id)

    async def _increment_call_count(self) -> None:
        """Increment API call counter via state backend (matching bash rate limiting)."""
        now = int(time.time())
        last_reset = await self.state_backend.read_last_reset()

        if now - last_reset >= 3600:
            # Reset counter
            await self.state_backend.write_call_count(1)
            await self.state_backend.write_last_reset(now)
        else:
            # Increment
            count = await self.state_backend.read_call_count()
            await self.state_backend.write_call_count(count + 1)

    async def _initialize_session_metadata(self) -> None:
        """Initialize or load session metadata for lifecycle tracking."""
        metadata = await self.state_backend.read_session_metadata()
        if metadata and self.session_id:
            # Check session expiry
            created_at = metadata.get("created_at", 0)
            expiry_seconds = self.config.session_expiry_hours * 3600
            if created_at and (time.time() - created_at) > expiry_seconds:
                logger.info(
                    "Session expired (age=%.1fh, TTL=%dh) — rotating",
                    (time.time() - created_at) / 3600,
                    self.config.session_expiry_hours,
                )
                await self._expire_session()
                return

            # Resume existing session
            self._session_iteration_count = metadata.get("iteration_count", 0)
            self._session_start_time = metadata.get("created_at", time.time())
        else:
            # New session
            await self.state_backend.write_session_metadata({
                "session_id": self.session_id,
                "created_at": time.time(),
                "iteration_count": 0,
                "correlation_id": self.correlation_id,
            })

    async def _should_rotate_session(self) -> bool:
        """Check if the current session should be rotated (continue-as-new).

        SDK-CONTEXT-3: Returns True if max iterations or max age exceeded.
        """
        if not self.config.continue_as_new_enabled:
            return False

        # Check iteration count
        if self._session_iteration_count >= self.config.max_session_iterations:
            logger.debug(
                "Session rotation: iteration limit reached (%d >= %d)",
                self._session_iteration_count,
                self.config.max_session_iterations,
            )
            return True

        # Check session age
        session_age_minutes = (time.time() - self._session_start_time) / 60
        if session_age_minutes >= self.config.max_session_age_minutes:
            logger.debug(
                "Session rotation: age limit reached (%.1f >= %d minutes)",
                session_age_minutes,
                self.config.max_session_age_minutes,
            )
            return True

        return False

    async def _rotate_session(self, last_status: RalphStatus) -> None:
        """Perform session rotation: save essential state, clear session, start fresh.

        SDK-CONTEXT-3: Continue-As-New pattern — preserves progress while
        starting a fresh context window.

        TAP-671: When the circuit breaker is non-CLOSED at rotation time,
        the session is being reset because Claude's side is unhealthy.
        Carrying the old session_id through continue-as-new would mislead
        any downstream consumer into thinking --continue is still viable.
        Blank it out so the next iteration uses a truly fresh session.
        """
        old_session_id = self.session_id

        # Check CB state so we can decide whether to carry session_id forward
        cb_data = await self.state_backend.read_circuit_breaker()
        cb_state = (cb_data or {}).get("state", "CLOSED")
        carry_session_id = cb_state == "CLOSED"

        # Build continue-as-new state
        continue_state = ContinueAsNewState(
            current_task=last_status.next_task or last_status.completed_task,
            progress=last_status.progress_summary,
            key_findings=[],
            continued_from_loop=self.loop_count,
            previous_session_id=old_session_id if carry_session_id else "",
        )
        await self.state_backend.write_continue_as_new_state(continue_state.to_dict())

        # Record old session in history — tag the reason when rotation was
        # triggered with a tripped CB so post-mortem queries can find these.
        history_reason = (
            "continue_as_new_cb_open" if not carry_session_id else "continue_as_new"
        )
        await self.state_backend.append_session_history({
            "session_id": old_session_id,
            "started_at": self._session_start_time,
            "ended_at": time.time(),
            "iteration_count": self._session_iteration_count,
            "loop_count_at_end": self.loop_count,
            "reason": history_reason,
            "cb_state_at_rotation": cb_state,
            "correlation_id": self.correlation_id,
        })

        # Clear session to force a new one on next iteration
        self.session_id = ""
        await self.state_backend.write_session_id("")

        # Reset session-level counters
        self._session_iteration_count = 0
        self._session_start_time = time.time()

        # Write fresh metadata
        await self.state_backend.write_session_metadata({
            "session_id": "",
            "created_at": time.time(),
            "iteration_count": 0,
            "correlation_id": self.correlation_id,
            "continued_from": old_session_id,
        })

        # Reset prompt cache (new session = new prefix)
        self._prompt_cache_stats = PromptCacheStats()

        logger.info(
            "Session rotated: %s -> (new) after %d session iterations",
            old_session_id[:12] + "..." if old_session_id else "(none)",
            continue_state.continued_from_loop,
        )

    async def _expire_session(self) -> None:
        """Handle session expiry: archive and clear.

        SDK-CONTEXT-3: Called when session exceeds session_expiry_hours TTL.
        """
        old_session_id = self.session_id

        # Record in history
        if old_session_id:
            await self.state_backend.append_session_history({
                "session_id": old_session_id,
                "started_at": self._session_start_time,
                "ended_at": time.time(),
                "iteration_count": self._session_iteration_count,
                "reason": "expired",
                "correlation_id": self.correlation_id,
            })

        # Clear session
        self.session_id = ""
        await self.state_backend.write_session_id("")
        self._session_iteration_count = 0
        self._session_start_time = time.time()

        # Write fresh metadata
        await self.state_backend.write_session_metadata({
            "session_id": "",
            "created_at": time.time(),
            "iteration_count": 0,
            "correlation_id": self.correlation_id,
            "expired_from": old_session_id,
        })

        logger.info(
            "Session expired and cleared: %s",
            old_session_id[:12] + "..." if old_session_id else "(none)",
        )

    async def _update_session_metadata(self) -> None:
        """Update session metadata after each iteration."""
        await self.state_backend.write_session_metadata({
            "session_id": self.session_id,
            "created_at": self._session_start_time,
            "iteration_count": self._session_iteration_count,
            "correlation_id": self.correlation_id,
            "last_updated": time.time(),
        })
