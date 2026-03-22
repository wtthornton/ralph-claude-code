"""Tests for Ralph SDK pluggable state backend (async)."""

import json
import pytest
from pathlib import Path

from ralph_sdk.state import FileStateBackend, NullStateBackend, RalphStateBackend
from ralph_sdk.status import CircuitBreakerState, RalphStatus


@pytest.fixture
def ralph_dir(tmp_path):
    d = tmp_path / ".ralph"
    d.mkdir()
    return d


class TestFileStateBackend:
    def test_implements_protocol(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        assert isinstance(backend, RalphStateBackend)

    @pytest.mark.asyncio
    async def test_status_round_trip(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        data = {"WORK_TYPE": "TESTING", "EXIT_SIGNAL": False}
        await backend.write_status(data)
        loaded = await backend.read_status()
        assert loaded["WORK_TYPE"] == "TESTING"

    @pytest.mark.asyncio
    async def test_circuit_breaker_round_trip(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        data = {"state": "OPEN", "no_progress_count": 3}
        await backend.write_circuit_breaker(data)
        loaded = await backend.read_circuit_breaker()
        assert loaded["state"] == "OPEN"
        assert loaded["no_progress_count"] == 3

    @pytest.mark.asyncio
    async def test_call_count_round_trip(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        await backend.write_call_count(42)
        assert await backend.read_call_count() == 42

    @pytest.mark.asyncio
    async def test_last_reset_round_trip(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        await backend.write_last_reset(1234567890)
        assert await backend.read_last_reset() == 1234567890

    @pytest.mark.asyncio
    async def test_session_id_round_trip(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        await backend.write_session_id("sess-abc-123")
        assert await backend.read_session_id() == "sess-abc-123"

    @pytest.mark.asyncio
    async def test_fix_plan_round_trip(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        content = "- [ ] Task 1\n- [x] Task 2\n"
        await backend.write_fix_plan(content)
        loaded = await backend.read_fix_plan()
        assert "Task 1" in loaded
        assert "Task 2" in loaded

    @pytest.mark.asyncio
    async def test_read_missing_returns_defaults(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        assert await backend.read_status() == {}
        assert await backend.read_circuit_breaker() == {}
        assert await backend.read_call_count() == 0
        assert await backend.read_last_reset() == 0
        assert await backend.read_session_id() == ""
        assert await backend.read_fix_plan() == ""

    @pytest.mark.asyncio
    async def test_atomic_write_no_tmp_files(self, ralph_dir):
        backend = FileStateBackend(ralph_dir)
        await backend.write_status({"test": True})
        tmp_files = list(ralph_dir.glob("*.tmp"))
        assert len(tmp_files) == 0


class TestNullStateBackend:
    def test_implements_protocol(self):
        backend = NullStateBackend()
        assert isinstance(backend, RalphStateBackend)

    @pytest.mark.asyncio
    async def test_status_round_trip(self):
        backend = NullStateBackend()
        data = {"WORK_TYPE": "TESTING", "EXIT_SIGNAL": False}
        await backend.write_status(data)
        loaded = await backend.read_status()
        assert loaded["WORK_TYPE"] == "TESTING"

    @pytest.mark.asyncio
    async def test_circuit_breaker_round_trip(self):
        backend = NullStateBackend()
        data = {"state": "OPEN", "no_progress_count": 3}
        await backend.write_circuit_breaker(data)
        loaded = await backend.read_circuit_breaker()
        assert loaded["state"] == "OPEN"

    @pytest.mark.asyncio
    async def test_call_count_round_trip(self):
        backend = NullStateBackend()
        await backend.write_call_count(42)
        assert await backend.read_call_count() == 42

    @pytest.mark.asyncio
    async def test_session_id_round_trip(self):
        backend = NullStateBackend()
        await backend.write_session_id("sess-xyz")
        assert await backend.read_session_id() == "sess-xyz"

    @pytest.mark.asyncio
    async def test_creates_no_files(self, tmp_path):
        """NullStateBackend must not create any files."""
        backend = NullStateBackend()
        await backend.write_status({"test": True})
        await backend.write_circuit_breaker({"state": "OPEN"})
        await backend.write_call_count(10)
        await backend.write_last_reset(12345)
        await backend.write_session_id("sess")
        await backend.write_fix_plan("plan")

        # No files should exist in tmp_path
        assert list(tmp_path.iterdir()) == []

    @pytest.mark.asyncio
    async def test_read_defaults(self):
        backend = NullStateBackend()
        assert await backend.read_status() == {}
        assert await backend.read_circuit_breaker() == {}
        assert await backend.read_call_count() == 0
        assert await backend.read_last_reset() == 0
        assert await backend.read_session_id() == ""
        assert await backend.read_fix_plan() == ""
