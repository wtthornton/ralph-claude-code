---
title: Ralph Python SDK guide
description: Embed Ralph's autonomous loop in a Python application via the async SDK — modules, models, state backend, cost tracking.
audience: [integrator, contributor]
diataxis: reference
last_reviewed: 2026-04-23
---

# Ralph Python SDK guide

**Version:** v2.1.0 • **Requirements:** Python 3.12+, `pydantic>=2.0`, `aiofiles>=24.0`

## Overview

The Ralph SDK provides a Python-native async interface to Ralph's autonomous development loop. Built on Pydantic v2 models with a pluggable state backend, it supports:

- Async agent loop with `run_sync()` wrapper for CLI use
- Structured tool calls replacing RALPH_STATUS text blocks
- Active circuit breaker with stall detectors (FastTrip, DeferredTest, ConsecutiveTimeout)
- Dynamic model routing via 5-level complexity classification (TRIVIAL→ARCHITECTURAL)
- Cost tracking with per-model pricing, budget alerts, and token rate limiting
- Cross-session episodic + semantic memory with age decay
- AST-based file dependency graph and automatic `fix_plan.md` task reordering
- Continue-As-New session lifecycle (Temporal-inspired)
- Prompt cache optimization (stable prefix / dynamic suffix split)
- TaskPacket conversion and EvidenceBundle output for TheStudio embedding
- Pluggable `RalphStateBackend` (FileStateBackend, NullStateBackend)
- Correlation ID threading and OpenTelemetry-compatible tracing

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

# With dev dependencies (for running tests)
pip install -e ".[dev]"
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

# Run autonomous loop (sync wrapper around async loop)
result = agent.run_sync()
print(f"Completed in {result.loop_count} loops ({result.duration_seconds:.1f}s)")
```

### Async Usage

```python
import asyncio
from ralph_sdk import RalphAgent, RalphConfig

async def main():
    config = RalphConfig.load(".")
    agent = RalphAgent(config=config)
    result = await agent.run()
    return result

result = asyncio.run(main())
```

## Configuration

The SDK reads the same configuration as the bash CLI:

```python
from ralph_sdk import RalphConfig

# Auto-loads .ralphrc → ralph.config.json → environment
config = RalphConfig.load(".")

# Override programmatically
config.max_calls_per_hour = 50
config.dry_run = True

# Export as JSON
print(config.model_dump_json(indent=2))
```

### Configuration Precedence

1. Programmatic overrides (Python code)
2. Environment variables
3. `ralph.config.json`
4. `.ralphrc`
5. Built-in defaults

## Module Reference

### ralph_sdk.agent — Core Loop

`RalphAgent` is the main entry point. The agent loop is fully async; use `run_sync()` for synchronous CLI execution.

**Key classes**: `RalphAgent`, `TaskInput` (frozen), `TaskResult`, `ProgressSnapshot`, `CancelResult`, `DecompositionHint`, `ContinueAsNewState`

```python
from ralph_sdk.agent import RalphAgent, TaskInput

agent = RalphAgent(config=config)

# Single iteration
task = TaskInput(prompt="Fix the auth bug", project_dir=".")
status = await agent.run_iteration(task)

# Full loop (exits on dual-condition gate)
result = await agent.run()
```

**Dual-condition exit gate**: Both must be true before the loop exits:
1. `completion_indicators >= 2` (NLP heuristics on Claude's text)
2. `EXIT_SIGNAL: true` (explicit field from Claude's RALPH_STATUS or ralph_status tool)

**Completion indicator decay** (SDK-SAFETY-3): When files are modified or tasks completed AND `exit_signal` is false, completion indicators reset to `[]`. Stale "done" signals cannot combine with later legitimate ones.

### ralph_sdk.circuit_breaker — Active Circuit Breaker

Three-state machine (CLOSED → OPEN → HALF_OPEN → CLOSED) with sliding window failure detection.

```python
from ralph_sdk.circuit_breaker import CircuitBreaker

cb = CircuitBreaker(config=config)

if not await cb.can_proceed():
    # OPEN — in cooldown
    raise RuntimeError("Circuit breaker open")

try:
    result = await run_claude()
    await cb.record_success()
except Exception as e:
    await cb.record_failure(str(e))
```

**Stall detectors** (SDK-SAFETY-1):
- `FastTripDetector` — consecutive 0-tool-use runs completing in <30s
- `DeferredTestDetector` — consecutive `TESTS_STATUS: DEFERRED` loops
- `ConsecutiveTimeoutDetector` — consecutive timeout runs

### ralph_sdk.complexity — Task Classifier

5-level heuristic classifier without LLM calls. Feeds into `cost.select_model()`.

```python
from ralph_sdk.complexity import classify_complexity

band = classify_complexity("Refactor the entire auth module [LARGE]")
# ComplexityBand.LARGE
```

Levels: TRIVIAL → SMALL → MEDIUM → LARGE → ARCHITECTURAL

Classification priority:
1. Explicit size annotations (`[TRIVIAL]`, `[SMALL]`, etc.)
2. Keyword scoring (architectural terms rank higher)
3. Referenced file count
4. Multi-step indicators (checklists, phases)
5. Retry escalation (repeated failures bump complexity)

### ralph_sdk.cost — Cost Tracking & Model Routing

```python
from ralph_sdk.cost import CostTracker, select_model
from ralph_sdk.complexity import ComplexityBand

# Dynamic model routing
model = select_model(ComplexityBand.LARGE, retry_count=0)
# "claude-opus-4-7" for LARGE/ARCH; "claude-sonnet-4-6" for others

# Cost tracking
tracker = CostTracker(budget_usd=5.0)
tracker.record_iteration(input_tokens=1000, output_tokens=500, model=model)
print(f"Session cost: ${tracker.session_cost.total_usd:.4f}")
```

### ralph_sdk.memory — Cross-Session Memory

Episodic (iteration outcomes) + semantic (project index) memory with Ebbinghaus-inspired age decay.

```python
from ralph_sdk.memory import MemoryManager, FileMemoryBackend

backend = FileMemoryBackend(ralph_dir=".ralph")
memory = MemoryManager(backend=backend)

# Store episode
await memory.record_episode(
    task="Fix auth bug",
    outcome="success",
    files_changed=["auth.py"],
    error_summary=None,
)

# Retrieve relevant episodes by keyword
episodes = await memory.retrieve_episodes(query="auth", limit=5)
```

### ralph_sdk.import_graph — File Dependency Graph

AST-based Python + regex JS/TS dependency graph with JSON caching.

```python
from ralph_sdk.import_graph import CachedImportGraph, build_import_graph

graph = build_import_graph(root=".", cache_path=".ralph/.import_graph.json")
deps = graph.get_dependencies("ralph_sdk/agent.py")
# ["ralph_sdk/config.py", "ralph_sdk/circuit_breaker.py", ...]
```

### ralph_sdk.plan_optimizer — Fix Plan Reordering

Reorders unchecked tasks in `fix_plan.md` by dependency order. Runs automatically in `RalphAgent.run()`.

```python
from ralph_sdk.plan_optimizer import optimize_plan

result = optimize_plan(
    fix_plan_path=".ralph/fix_plan.md",
    graph=import_graph,
    dry_run=False,
)
print(f"Reordered {result.tasks_reordered} tasks")
```

Three-layer dependency detection:
1. Import graph (highest confidence)
2. Explicit metadata (`<!-- id: ... -->`, `<!-- depends: ... -->`)
3. Phase convention (create → implement → test → document)

### ralph_sdk.context — Context Management

Progressive `fix_plan.md` loading + prompt cache optimization.

```python
from ralph_sdk.context import ContextManager, PromptParts

ctx = ContextManager(config=config)
parts = ctx.build_prompt_parts(fix_plan_path=".ralph/fix_plan.md")
# parts.stable_prefix — cached across iterations
# parts.dynamic_suffix — updated each iteration
```

### ralph_sdk.state — Pluggable State Backend

All state I/O goes through `RalphStateBackend`. Swap backends for testing or embedding.

```python
from ralph_sdk.state import FileStateBackend, NullStateBackend

# Production: reads/writes .ralph/ directory
backend = FileStateBackend(ralph_dir=".ralph")

# Testing: in-memory, no disk I/O
backend = NullStateBackend()

agent = RalphAgent(config=config, state_backend=backend)
```

**RalphStateBackend protocol** (18 async methods): `read_status`, `write_status`, `read_circuit_state`, `write_circuit_state`, `read_session_id`, `write_session_id`, `read_call_count`, `increment_call_count`, `reset_call_count`, `read_fix_plan`, `write_fix_plan`, `append_exit_signal`, `read_exit_signals`, `read_prompt`, `read_agent_md`, `read_history`, `append_history`, `clear_history`

### ralph_sdk.tools — Custom Tools

Replace RALPH_STATUS text blocks with structured tool calls in SDK mode.

```python
from ralph_sdk.tools import ralph_status_tool, ralph_rate_check_tool, ralph_circuit_state_tool, ralph_task_update_tool

# Report iteration status
result = ralph_status_tool(
    work_type="IMPLEMENTATION",
    completed_task="Add login form",
    next_task="Add form validation",
    progress_summary="2/5 tasks",
    exit_signal=False,
)

# Check rate limit
status = ralph_rate_check_tool(max_calls_per_hour=100)

# Check circuit breaker
cb = ralph_circuit_state_tool()

# Mark task complete
ralph_task_update_tool(task_description="Add login form", completed=True)
```

### ralph_sdk.parsing — Response Parser

3-strategy parse chain: JSON fenced block → JSONL stream result → text fallback.

```python
from ralph_sdk.parsing import parse_ralph_status, detect_permission_denials

status = parse_ralph_status(raw_output)
denials = detect_permission_denials(raw_output)
```

### ralph_sdk.evidence — EvidenceBundle Output

Converts `TaskResult` to a TheStudio-compatible evidence bundle.

```python
from ralph_sdk.evidence import EvidenceBundle

bundle = EvidenceBundle.from_task_result(result)
# Extracts test results from pytest/jest/BATS output
# Extracts lint results from ruff/eslint output
```

## Session Lifecycle

### Continue-As-New (CTXMGMT-3)

Temporal-inspired pattern: after `RALPH_MAX_SESSION_ITERATIONS` (default 20) or `RALPH_MAX_SESSION_AGE_MINUTES` (default 120), the session resets while carrying forward essential state.

```python
# Controlled by config
config.max_session_iterations = 20
config.max_session_age_minutes = 120
config.continue_as_new_enabled = True  # default True
```

When triggered, `ContinueAsNewState` is written to state, carrying:
- Current task description
- Progress summary
- Recommendation for next iteration

### Adaptive Timeout

Percentile-based timeout tracking adjusts per-iteration timeouts based on observed completion times.

## TheStudio Embedding

```python
from ralph_sdk import RalphAgent, RalphConfig
from ralph_sdk.converters import TaskPacketInput

config = RalphConfig.load()
agent = RalphAgent(config=config, state_backend=NullStateBackend())

# Convert TheStudio TaskPacket to TaskInput
task_packet = TaskPacketInput(
    goal="Build feature X",
    constraints=["No external dependencies"],
    acceptance_criteria=["All tests pass"],
)
task_input = task_packet.to_task_input()

# Run and get EvidenceBundle
result = await agent.run_iteration(task_input)
bundle = EvidenceBundle.from_task_result(result)
# bundle is TheStudio-compatible JSON
```

## Status and Circuit Breaker (Shared with CLI)

```python
from ralph_sdk.status import RalphStatus, CircuitBreakerStateEnum

# Read current status (reads .ralph/status.json written by on-stop.sh hook)
status = await state_backend.read_status()
print(f"Work type: {status.work_type}")
print(f"Exit signal: {status.exit_signal}")

# Read circuit breaker
cb_state = await state_backend.read_circuit_state()
print(f"State: {cb_state.state}")  # CLOSED / HALF_OPEN / OPEN
```

## Testing

```bash
cd sdk/
pip install -e ".[dev]"
pytest tests/ -v

# Specific test files
pytest tests/test_agent.py tests/test_circuit_breaker.py -v
```

## File Compatibility

All state files are shared between CLI and SDK modes:

| File | Purpose |
|------|---------|
| `.ralph/status.json` | Current iteration status (written by on-stop.sh hook) |
| `.ralph/.circuit_breaker_state` | Circuit breaker state (JSON) |
| `.ralph/.claude_session_id` | Session continuity (24h expiry) |
| `.ralph/.call_count` | Rate limit counter (hourly reset) |
| `.ralph/.last_reset` | Rate limit reset timestamp |
| `.ralph/.import_graph.json` | Cached file dependency graph |
| `.ralph/fix_plan.md` | Task checklist |
| `.ralph/PROMPT.md` | Development instructions |
| `.ralph/metrics/` | Monthly JSONL metrics (JsonlMetricsCollector) |

## Version Information

```python
from ralph_sdk.versions import get_versions

versions = get_versions()
print(versions.ralph_sdk)   # "2.1.0"
print(versions.ralph_loop)  # "2.8.3"
```
