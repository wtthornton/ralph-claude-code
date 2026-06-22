"""Ralph SDK pluggable state backend — Protocol + File + Null implementations.

All state I/O goes through a RalphStateBackend implementation, making the agent
testable (NullStateBackend) and embeddable (custom backends like Postgres).

Methods are async for use with the async agent loop. Sync wrappers are provided
for tool handlers and backward compatibility.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import aiofiles
import aiofiles.os

from ralph_sdk.state_null import NullStateBackend
from ralph_sdk.state_protocol import RalphStateBackend

__all__ = [
    "FileStateBackend",
    "NullStateBackend",
    "RalphStateBackend",
]


class FileStateBackend(RalphStateBackend):
    """File-based state backend wrapping current .ralph/ file I/O.

    This is the default backend, maintaining full compatibility with the
    bash loop's state files. All methods are async using aiofiles.
    """

    def __init__(self, ralph_dir: str | Path = ".ralph") -> None:
        self.ralph_dir = Path(ralph_dir)
        self.ralph_dir.mkdir(parents=True, exist_ok=True)

    async def _atomic_write(self, path: Path, content: str) -> None:
        """Write file atomically using tmp+replace pattern (WSL/NTFS safe)."""
        tmp_file = path.with_suffix(f".{os.getpid()}.tmp")
        try:
            async with aiofiles.open(tmp_file, "w", encoding="utf-8") as f:
                await f.write(content)
            # Use async os.replace for atomic rename (non-blocking)
            await aiofiles.os.replace(str(tmp_file), str(path))
        finally:
            try:
                await aiofiles.os.remove(str(tmp_file))
            except FileNotFoundError:
                pass

    async def _read_json(self, path: Path) -> dict[str, Any]:
        """Read a JSON file, returning empty dict on missing/corrupt."""
        if not path.exists():
            return {}
        try:
            async with aiofiles.open(path, encoding="utf-8") as f:
                content = await f.read()
            return json.loads(content)
        except (json.JSONDecodeError, OSError):
            return {}

    async def _read_text(self, path: Path) -> str:
        """Read a text file, returning empty string on missing."""
        if not path.exists():
            return ""
        try:
            async with aiofiles.open(path, encoding="utf-8") as f:
                content = await f.read()
            return content.strip()
        except OSError:
            return ""

    async def _read_int(self, path: Path) -> int:
        """Read an integer from a text file, returning 0 on missing/invalid."""
        text = await self._read_text(path)
        if not text:
            return 0
        try:
            return int(text)
        except ValueError:
            return 0

    # NOTE: _write_text removed in TAP-625 — every text writer now uses
    # _atomic_write so a SIGTERM between truncate and write can no longer
    # leave a zero-byte counter that silently reads back as 0 (rate-limit
    # bypass). Mirrors the bash atomic_write helper from TAP-535.

    # --- Status ---

    async def read_status(self) -> dict[str, Any]:
        return await self._read_json(self.ralph_dir / "status.json")

    async def write_status(self, data: dict[str, Any]) -> None:
        await self._atomic_write(
            self.ralph_dir / "status.json",
            json.dumps(data, indent=2) + "\n",
        )

    # --- Circuit Breaker ---

    async def read_circuit_breaker(self) -> dict[str, Any]:
        return await self._read_json(self.ralph_dir / ".circuit_breaker_state")

    async def write_circuit_breaker(self, data: dict[str, Any]) -> None:
        await self._atomic_write(
            self.ralph_dir / ".circuit_breaker_state",
            json.dumps(data, indent=2) + "\n",
        )

    # --- Rate Limiting ---

    async def read_call_count(self) -> int:
        return await self._read_int(self.ralph_dir / ".call_count")

    async def write_call_count(self, count: int) -> None:
        await self._atomic_write(self.ralph_dir / ".call_count", f"{count}\n")

    async def read_last_reset(self) -> int:
        return await self._read_int(self.ralph_dir / ".last_reset")

    async def write_last_reset(self, timestamp: int) -> None:
        await self._atomic_write(self.ralph_dir / ".last_reset", f"{timestamp}\n")

    # --- Session ---

    async def read_session_id(self) -> str:
        return await self._read_text(self.ralph_dir / ".claude_session_id")

    async def write_session_id(self, session_id: str) -> None:
        await self._atomic_write(self.ralph_dir / ".claude_session_id", session_id + "\n")

    # --- Task Plan ---

    async def read_fix_plan(self) -> str:
        return await self._read_text(self.ralph_dir / "fix_plan.md")

    async def write_fix_plan(self, content: str) -> None:
        await self._atomic_write(self.ralph_dir / "fix_plan.md", content)

    # --- Session Lifecycle (SDK-CONTEXT-3) ---

    async def read_session_metadata(self) -> dict[str, Any]:
        return await self._read_json(self.ralph_dir / ".session_metadata.json")

    async def write_session_metadata(self, data: dict[str, Any]) -> None:
        await self._atomic_write(
            self.ralph_dir / ".session_metadata.json",
            json.dumps(data, indent=2) + "\n",
        )

    async def read_session_history(self) -> list[dict[str, Any]]:
        data = await self._read_json(self.ralph_dir / ".session_history.json")
        return data.get("sessions", [])

    async def append_session_history(self, entry: dict[str, Any]) -> None:
        history = await self.read_session_history()
        history.append(entry)
        await self._atomic_write(
            self.ralph_dir / ".session_history.json",
            json.dumps({"sessions": history}, indent=2) + "\n",
        )

    async def read_continue_as_new_state(self) -> dict[str, Any]:
        return await self._read_json(self.ralph_dir / ".continue_as_new.json")

    async def write_continue_as_new_state(self, data: dict[str, Any]) -> None:
        await self._atomic_write(
            self.ralph_dir / ".continue_as_new.json",
            json.dumps(data, indent=2) + "\n",
        )
