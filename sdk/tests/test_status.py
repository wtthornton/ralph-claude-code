"""Tests for Ralph SDK status and circuit breaker."""

import json
import pytest
from pathlib import Path

from ralph_sdk.status import RalphStatus, CircuitBreakerState


@pytest.fixture
def ralph_dir(tmp_path):
    d = tmp_path / ".ralph"
    d.mkdir()
    return str(d)


class TestRalphStatus:
    def test_defaults(self):
        s = RalphStatus()
        assert s.work_type == "UNKNOWN"
        assert s.exit_signal is False
        assert s.status == "IN_PROGRESS"

    def test_to_dict(self):
        s = RalphStatus(work_type="TESTING", exit_signal=True)
        d = s.to_dict()
        assert d["WORK_TYPE"] == "TESTING"
        assert d["EXIT_SIGNAL"] is True

    def test_from_dict(self):
        s = RalphStatus.from_dict({
            "WORK_TYPE": "ANALYSIS",
            "EXIT_SIGNAL": True,
            "COMPLETED_TASK": "Reviewed code",
        })
        assert s.work_type == "ANALYSIS"
        assert s.exit_signal is True
        assert s.completed_task == "Reviewed code"

    def test_save_and_load(self, ralph_dir):
        s = RalphStatus(work_type="IMPL", completed_task="Did stuff", loop_count=5)
        s.save(ralph_dir)

        loaded = RalphStatus.load(ralph_dir)
        assert loaded.work_type == "IMPL"
        assert loaded.completed_task == "Did stuff"
        assert loaded.loop_count == 5

    def test_load_missing(self, ralph_dir):
        loaded = RalphStatus.load(ralph_dir)
        assert loaded.work_type == "UNKNOWN"

    def test_atomic_write(self, ralph_dir):
        """Temp file should be cleaned up after save."""
        s = RalphStatus(work_type="TEST")
        s.save(ralph_dir)
        # No .tmp files should remain
        tmp_files = list(Path(ralph_dir).glob("*.tmp"))
        assert len(tmp_files) == 0


class TestCircuitBreakerState:
    def test_defaults(self):
        cb = CircuitBreakerState()
        assert cb.state == "CLOSED"
        assert cb.no_progress_count == 0

    def test_trip(self):
        cb = CircuitBreakerState()
        cb.trip("No progress detected")
        assert cb.state == "OPEN"
        assert cb.last_error == "No progress detected"
        assert cb.opened_at != ""

    def test_half_open(self):
        cb = CircuitBreakerState(state="OPEN")
        cb.half_open()
        assert cb.state == "HALF_OPEN"

    def test_close(self):
        cb = CircuitBreakerState(state="HALF_OPEN", no_progress_count=3)
        cb.close()
        assert cb.state == "CLOSED"
        assert cb.no_progress_count == 0

    def test_reset(self):
        cb = CircuitBreakerState(state="OPEN", no_progress_count=5)
        cb.reset("manual")
        assert cb.state == "CLOSED"
        assert cb.no_progress_count == 0

    def test_save_and_load(self, ralph_dir):
        cb = CircuitBreakerState(state="OPEN", no_progress_count=3)
        cb.trip("test error")
        cb.save(ralph_dir)

        loaded = CircuitBreakerState.load(ralph_dir)
        assert loaded.state == "OPEN"
        assert loaded.no_progress_count == 3

    def test_load_missing(self, ralph_dir):
        loaded = CircuitBreakerState.load(ralph_dir)
        assert loaded.state == "CLOSED"
