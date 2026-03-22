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
from typing import Any, Protocol, runtime_checkable

import aiofiles
import aiofiles.os


@runtime_checkable
class RalphStateBackend(Protocol):
    """Protocol defining the 12 async state operations."""

    # --- Status ---

    async def read_status(self) -> dict[str, Any]:
        """Read current status (status.json equivalent)."""
        ...

    async def write_status(self, data: dict[str, Any]) -> None:
        """Write status atomically."""
        ...

    # --- Circuit Breaker ---

    async def read_circuit_breaker(self) -> dict[str, Any]:
        """Read circuit breaker state."""
        ...

    async def write_circuit_breaker(self, data: dict[str, Any]) -> None:
        """Write circuit breaker state atomically."""
        ...

    # --- Rate Limiting ---

    async def read_call_count(self) -> int:
        """Read current API call count."""
        ...

    async def write_call_count(self, count: int) -> None:
        """Write API call count."""
        ...

    async def read_last_reset(self) -> int:
        """Read last rate limit reset timestamp."""
        ...

    async def write_last_reset(self, timestamp: int) -> None:
        """Write rate limit reset timestamp."""
        ...

    # --- Session ---

    async def read_session_id(self) -> str:
        """Read Claude session ID."""
        ...

    async def write_session_id(self, session_id: str) -> None:
        """Write Claude session ID."""
        ...

    # --- Task Plan ---

    async def read_fix_plan(self) -> str:
        """Read fix_plan.md content."""
        ...

    async def write_fix_plan(self, content: str) -> None:
        """Write fix_plan.md content."""
        ...


class FileStateBackend:
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
            # aiofiles.os.replace for atomic rename
            tmp_path = str(tmp_file)
            target_path = str(path)
            os.replace(tmp_path, target_path)
        finally:
            try:
                os.unlink(str(tmp_file))
            except FileNotFoundError:
                pass

    async def _read_json(self, path: Path) -> dict[str, Any]:
        """Read a JSON file, returning empty dict on missing/corrupt."""
        if not path.exists():
            return {}
        try:
            async with aiofiles.open(path, "r", encoding="utf-8") as f:
                content = await f.read()
            return json.loads(content)
        except (json.JSONDecodeError, OSError):
            return {}

    async def _read_text(self, path: Path) -> str:
        """Read a text file, returning empty string on missing."""
        if not path.exists():
            return ""
        try:
            async with aiofiles.open(path, "r", encoding="utf-8") as f:
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

    async def _write_text(self, path: Path, content: str) -> None:
        """Write text to a file."""
        async with aiofiles.open(path, "w", encoding="utf-8") as f:
            await f.write(content)

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
        await self._write_text(self.ralph_dir / ".call_count", f"{count}\n")

    async def read_last_reset(self) -> int:
        return await self._read_int(self.ralph_dir / ".last_reset")

    async def write_last_reset(self, timestamp: int) -> None:
        await self._write_text(self.ralph_dir / ".last_reset", f"{timestamp}\n")

    # --- Session ---

    async def read_session_id(self) -> str:
        return await self._read_text(self.ralph_dir / ".claude_session_id")

    async def write_session_id(self, session_id: str) -> None:
        await self._write_text(self.ralph_dir / ".claude_session_id", session_id + "\n")

    # --- Task Plan ---

    async def read_fix_plan(self) -> str:
        return await self._read_text(self.ralph_dir / "fix_plan.md")

    async def write_fix_plan(self, content: str) -> None:
        await self._write_text(self.ralph_dir / "fix_plan.md", content)


class NullStateBackend:
    """In-memory state backend — creates no files on disk.

    Used for testing and for TheStudio embedded mode where state
    is managed by the orchestrator.
    """

    def __init__(self) -> None:
        self._status: dict[str, Any] = {}
        self._circuit_breaker: dict[str, Any] = {}
        self._call_count: int = 0
        self._last_reset: int = 0
        self._session_id: str = ""
        self._fix_plan: str = ""

    # --- Status ---

    async def read_status(self) -> dict[str, Any]:
        return dict(self._status)

    async def write_status(self, data: dict[str, Any]) -> None:
        self._status = dict(data)

    # --- Circuit Breaker ---

    async def read_circuit_breaker(self) -> dict[str, Any]:
        return dict(self._circuit_breaker)

    async def write_circuit_breaker(self, data: dict[str, Any]) -> None:
        self._circuit_breaker = dict(data)

    # --- Rate Limiting ---

    async def read_call_count(self) -> int:
        return self._call_count

    async def write_call_count(self, count: int) -> None:
        self._call_count = count

    async def read_last_reset(self) -> int:
        return self._last_reset

    async def write_last_reset(self, timestamp: int) -> None:
        self._last_reset = timestamp

    # --- Session ---

    async def read_session_id(self) -> str:
        return self._session_id

    async def write_session_id(self, session_id: str) -> None:
        self._session_id = session_id

    # --- Task Plan ---

    async def read_fix_plan(self) -> str:
        return self._fix_plan

    async def write_fix_plan(self, content: str) -> None:
        self._fix_plan = content
