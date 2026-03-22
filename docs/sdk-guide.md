# Ralph SDK Guide

**Version**: v2.0.0 | **Requirements**: Python 3.12+, pydantic>=2.0, aiofiles>=24.0

## Overview

The Ralph SDK provides a Python-native async interface to Ralph's autonomous development loop. Built on Pydantic v2 models with a pluggable state backend, it supports structured tool calls, active circuit breaking, correlation ID threading, TaskPacket conversion, and EvidenceBundle output for TheStudio embedding.

## Installation

```bash
# Via ralph installer (recommended)
./install.sh          # Automatically sets up SDK if Python 3.12+ available
ralph-doctor          # Verify installation

# Manual
cd sdk/
python3 -m venv .venv
source .venv/bin/activate  # or .venv/Scripts/activate on Windows
pip install -e .
```

## Quick Start

### CLI Usage

```bash
# Via ralph wrapper
ralph --sdk

# Direct entry point
ralph-sdk

# Module execution
python -m ralph_sdk --project-dir /path/to/project
```

### Python API

```python
from ralph_sdk import RalphAgent, RalphConfig

# Load config from project directory
config = RalphConfig.load("/path/to/project")

# Create agent
agent = RalphAgent(config=config, project_dir="/path/to/project")

# Run autonomous loop
result = agent.run()
print(f"Completed in {result.loop_count} loops ({result.duration_seconds:.1f}s)")
```

## Configuration

The SDK reads the same configuration as the bash CLI:

```python
from ralph_sdk import RalphConfig

# Auto-loads .ralphrc → ralph.config.json → environment
config = RalphConfig.load(".")

# Override programmatically
config.max_calls_per_hour = 50
config.model = "claude-opus-4-20250514"
config.dry_run = True

# Export as JSON
print(config.to_json())
```

### Configuration Precedence

1. Programmatic overrides (Python code)
2. Environment variables
3. `ralph.config.json`
4. `.ralphrc`
5. Built-in defaults

## Custom Tools

The SDK exposes Ralph's reliability features as structured tools:

### ralph_status

Report status at end of each iteration (replaces RALPH_STATUS text block):

```python
from ralph_sdk.tools import ralph_status_tool

result = ralph_status_tool(
    work_type="IMPLEMENTATION",
    completed_task="Added login form",
    next_task="Add form validation",
    progress_summary="2/5 tasks complete",
    exit_signal=False,
)
```

### ralph_rate_check

Check API rate limit status:

```python
from ralph_sdk.tools import ralph_rate_check_tool

result = ralph_rate_check_tool(max_calls_per_hour=100)
# {"calls_remaining": 85, "rate_limited": false, ...}
```

### ralph_circuit_state

Check circuit breaker:

```python
from ralph_sdk.tools import ralph_circuit_state_tool

result = ralph_circuit_state_tool()
# {"state": "CLOSED", "can_proceed": true, ...}
```

### ralph_task_update

Mark tasks complete in fix_plan.md:

```python
from ralph_sdk.tools import ralph_task_update_tool

result = ralph_task_update_tool(
    task_description="Add login form",
    completed=True,
)
```

## Agent Lifecycle

### Single Iteration

```python
from ralph_sdk.agent import TaskInput

agent = RalphAgent(config=config)
task = TaskInput.from_ralph_dir(".ralph")
status = agent.run_iteration(task)
```

### Full Loop

```python
result = agent.run()
# Loop runs until dual-condition exit gate is satisfied:
# 1. completion_indicators >= 2 (NLP heuristics)
# 2. EXIT_SIGNAL: true (explicit from Claude)
```

### Dry Run

```python
config.dry_run = True
agent = RalphAgent(config=config)
result = agent.run()  # No API calls, writes DRY_RUN status
```

## TheStudio Embedding

```python
from ralph_sdk import RalphAgent, RalphConfig

# Initialize with TheStudio config
config = RalphConfig.load()
agent = RalphAgent(config=config)

# Process a TaskPacket from TheStudio
signal = agent.process_task_packet({
    "id": "task-123",
    "type": "implementation",
    "prompt": "Build feature X",
    "fix_plan": "- [ ] Step 1\n- [ ] Step 2",
})

# signal is TheStudio-compatible
# {"type": "ralph_result", "task_result": {...}, "loop_count": 3, ...}
```

## Sub-agent Spawning

In SDK mode, sub-agents are spawned via the Claude Code CLI's Agent tool, just like in CLI mode. The agent definitions in `.claude/agents/` are used.

```python
# The SDK agent automatically uses --agent ralph which has access to:
# - ralph-explorer (haiku, read-only search)
# - ralph-tester (sonnet, worktree-isolated testing)
# - ralph-reviewer (sonnet, read-only review)
```

## Status and Circuit Breaker

```python
from ralph_sdk.status import RalphStatus, CircuitBreakerState

# Read current status
status = RalphStatus.load(".ralph")
print(f"Work type: {status.work_type}")
print(f"Exit signal: {status.exit_signal}")

# Read circuit breaker
cb = CircuitBreakerState.load(".ralph")
print(f"State: {cb.state}")

# Reset circuit breaker
cb.reset("Manual reset")
cb.save(".ralph")
```

## Testing

```bash
cd sdk/
pip install -e ".[dev]"
pytest tests/ -v
```

## File Compatibility

All state files are shared between CLI and SDK modes:

| File | Purpose |
|------|---------|
| `.ralph/status.json` | Current iteration status |
| `.ralph/.circuit_breaker_state` | Circuit breaker state |
| `.ralph/.claude_session_id` | Session continuity |
| `.ralph/.call_count` | Rate limit counter |
| `.ralph/.last_reset` | Rate limit reset timestamp |
| `.ralph/fix_plan.md` | Task checklist |
| `.ralph/PROMPT.md` | Development instructions |
