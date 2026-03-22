"""Tests for Ralph SDK Agent."""

import json
import pytest
from pathlib import Path
from unittest.mock import patch, MagicMock

from ralph_sdk.agent import RalphAgent, TaskInput, TaskResult
from ralph_sdk.config import RalphConfig
from ralph_sdk.status import RalphStatus, CircuitBreakerState


@pytest.fixture
def project_dir(tmp_path):
    """Create a minimal Ralph project."""
    ralph_dir = tmp_path / ".ralph"
    ralph_dir.mkdir()
    (ralph_dir / "logs").mkdir()
    (ralph_dir / "PROMPT.md").write_text("Build a login form")
    (ralph_dir / "fix_plan.md").write_text("- [ ] Add login form\n- [ ] Add validation\n")
    (ralph_dir / "AGENT.md").write_text("Run: npm test")
    return tmp_path


@pytest.fixture
def config():
    return RalphConfig(dry_run=True, project_name="test-project")


class TestTaskInput:
    def test_from_ralph_dir(self, project_dir):
        task = TaskInput.from_ralph_dir(str(project_dir / ".ralph"))
        assert "login form" in task.prompt
        assert "Add login form" in task.fix_plan
        assert "npm test" in task.agent_instructions

    def test_from_ralph_dir_missing(self, tmp_path):
        ralph_dir = tmp_path / ".ralph"
        ralph_dir.mkdir()
        task = TaskInput.from_ralph_dir(str(ralph_dir))
        assert task.prompt == ""
        assert task.fix_plan == ""

    def test_from_task_packet(self):
        packet = {
            "id": "task-123",
            "type": "implementation",
            "prompt": "Build feature X",
            "fix_plan": "- [ ] Step 1",
        }
        task = TaskInput.from_task_packet(packet)
        assert task.task_packet_id == "task-123"
        assert task.prompt == "Build feature X"


class TestTaskResult:
    def test_to_signal(self):
        status = RalphStatus(work_type="IMPLEMENTATION", exit_signal=True)
        result = TaskResult(status=status, loop_count=5, duration_seconds=120.5)
        signal = result.to_signal()
        assert signal["type"] == "ralph_result"
        assert signal["loop_count"] == 5
        assert signal["task_result"]["EXIT_SIGNAL"] is True


class TestRalphAgent:
    def test_init(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        assert agent.loop_count == 0
        assert agent.ralph_dir == project_dir / ".ralph"

    def test_dry_run(self, project_dir, config):
        config.dry_run = True
        agent = RalphAgent(config=config, project_dir=project_dir)
        result = agent.run()
        assert result.status.status == "DRY_RUN"
        assert result.loop_count == 1

    def test_should_exit_requires_dual_condition(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)

        # EXIT_SIGNAL alone is not enough
        status = RalphStatus(exit_signal=True, progress_summary="Still working")
        assert agent.should_exit(status, 1) is False

        # EXIT_SIGNAL + completion phrase = exit
        status2 = RalphStatus(exit_signal=True, progress_summary="All tasks complete")
        assert agent.should_exit(status2, 2) is True

    def test_check_rate_limit_ok(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        assert agent.check_rate_limit() is True

    def test_check_circuit_breaker_ok(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        assert agent.check_circuit_breaker() is True

    def test_check_circuit_breaker_open(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        cb = CircuitBreakerState(state="OPEN")
        cb.save(str(project_dir / ".ralph"))
        assert agent.check_circuit_breaker() is False

    def test_parse_jsonl_response(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        jsonl = json.dumps({
            "type": "result",
            "result": "WORK_TYPE: IMPLEMENTATION\nCOMPLETED_TASK: Added form\nPROGRESS_SUMMARY: 50% done\nEXIT_SIGNAL: false",
            "session_id": "sess-123",
        })
        status = agent._parse_response(jsonl, 0)
        assert status.work_type == "IMPLEMENTATION"
        assert status.completed_task == "Added form"
        assert status.exit_signal is False
        assert agent.session_id == "sess-123"

    def test_parse_text_fallback(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        text = "Some output...\nWORK_TYPE: TESTING\nEXIT_SIGNAL: true\n"
        status = agent._parse_response(text, 0)
        assert status.work_type == "TESTING"
        assert status.exit_signal is True

    def test_parse_error_return_code(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        status = agent._parse_response("", 1)
        assert status.status == "ERROR"

    def test_handle_tool_call(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        result = agent.handle_tool_call("ralph_circuit_state", {})
        assert result["ok"] is True
        assert result["state"] == "CLOSED"

    def test_handle_unknown_tool(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        result = agent.handle_tool_call("nonexistent", {})
        assert result["ok"] is False

    def test_get_tool_definitions(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        tools = agent.get_tool_definitions()
        assert len(tools) == 4
        # No handler in output (SDK registration doesn't need it)
        for tool in tools:
            assert "handler" not in tool

    def test_process_task_packet(self, project_dir, config):
        config.dry_run = False
        agent = RalphAgent(config=config, project_dir=project_dir)
        agent.start_time = 1000.0

        with patch.object(agent, 'run_iteration') as mock_iter:
            mock_iter.return_value = RalphStatus(work_type="IMPLEMENTATION")
            signal = agent.process_task_packet({
                "id": "task-1",
                "prompt": "Do something",
            })
            assert signal["type"] == "ralph_result"

    def test_build_claude_command(self, project_dir, config):
        agent = RalphAgent(config=config, project_dir=project_dir)
        cmd = agent._build_claude_command("test prompt")
        assert cmd[0] == "claude"
        assert "--agent" in cmd
        assert "ralph" in cmd
        assert "-p" in cmd
        assert "--output-format" in cmd
        assert "--max-turns" in cmd
