# Ralph SDK Migration Strategy

**Version**: v2.0.0 | **Status**: Active

## Overview

Ralph supports three operational modes. This guide explains each mode, helps you choose, and provides migration paths.

## Operational Modes

### Mode 1: Standalone CLI (Default)

The original Ralph experience — a bash loop that invokes the Claude Code CLI.

```bash
ralph                    # Standard loop
ralph --live             # With real-time output
ralph --monitor          # With tmux dashboard
```

**Best for**: Individual developers, simple projects, quick setup, CI/CD pipelines.

### Mode 2: Standalone SDK (v2.0.0+)

Python-native async agent using Pydantic v2 models, pluggable state backend, and structured tool calls.

```bash
ralph --sdk              # SDK mode via bash wrapper
ralph-sdk                # Direct Python entry point
python -m ralph_sdk      # Module execution
```

**Best for**: Python-native projects, custom tool integration, programmatic control.

### Mode 3: TheStudio Embedded (Premium)

Ralph as Primary Agent within TheStudio orchestration platform.

```python
from ralph_sdk import RalphAgent

agent = RalphAgent(config=config)
signal = agent.process_task_packet(task_packet)
```

**Best for**: Teams, multi-agent orchestration, advanced observability, quality gates.

## Decision Matrix

| Factor | CLI | SDK | TheStudio |
|--------|-----|-----|-----------|
| Setup complexity | Minimal | Low | Medium |
| Runtime dependency | Bash + Claude CLI | Python 3.12+ | TheStudio platform |
| Custom tools | No | Yes | Yes + expert routing |
| Programmatic API | No | Yes | Yes + signals |
| Observability | Logs + tmux | Logs + metrics JSONL | OTel + dashboards |
| Multi-agent | Experimental teams | Sub-agent spawning | Full orchestration |
| Sandbox | Docker only | Docker only | Multi-provider |
| Cost | Free | Free | Premium |

## Migration Paths

### CLI → SDK

1. **Install SDK dependencies**:
   ```bash
   ralph doctor           # Verify prerequisites
   cd your-project
   ralph --sdk --dry-run  # Verify SDK mode works
   ```

2. **Switch to SDK mode**:
   ```bash
   ralph --sdk            # That's it — same config, same .ralph/ dir
   ```

3. **What changes**:
   - RALPH_STATUS text block → `ralph_status` tool call
   - Bash parsing → Python JSON parsing
   - Session files remain compatible
   - status.json format unchanged

4. **What stays the same**:
   - `.ralphrc` / `ralph.config.json` configuration
   - `.ralph/` directory structure
   - fix_plan.md checkbox format
   - PROMPT.md instructions
   - Hook system (still bash, still works)
   - Circuit breaker behavior
   - Rate limiting

### SDK → TheStudio

1. **Install TheStudio** (separate product)
2. **Configure Ralph as Primary Agent**:
   ```python
   from thestudio import Studio
   from ralph_sdk import RalphAgent

   studio = Studio()
   ralph = RalphAgent(config=RalphConfig.load())
   studio.register_primary_agent(ralph)
   ```
3. **TaskPacket integration**: TheStudio sends TaskPackets, Ralph returns Signals
4. **Gradual migration**: Start with Ralph handling all tasks, add expert agents incrementally

## Feature Comparison

| Feature | CLI | SDK | TheStudio |
|---------|-----|-----|-----------|
| Core loop | bash | Python | Python (embedded) |
| Status reporting | RALPH_STATUS text | ralph_status tool | Signal protocol |
| Rate limiting | .call_count file | .call_count file | Platform-managed |
| Circuit breaker | .circuit_breaker_state | .circuit_breaker_state | Platform-managed |
| Exit detection | Dual-condition gate | Dual-condition gate | Verification Gate |
| Task input | fix_plan.md | fix_plan.md / TaskPacket | TaskPacket |
| Sub-agents | Agent definitions (.md) | Agent SDK spawning | Expert routing |
| Hooks | .claude/settings.json | .claude/settings.json | Platform hooks |
| Session management | .claude_session_id | .claude_session_id | Platform sessions |

## CLI is NOT Deprecated

The CLI remains the primary, supported interface. SDK mode is an additional capability for users who need:
- Custom tool definitions
- Programmatic control
- Python ecosystem integration
- TheStudio embedding

Both modes are maintained and tested. Choose based on your needs, not because one is "newer."

## Configuration Compatibility

All configuration sources work in all modes:

```
.ralphrc          → sourced as bash (CLI) / parsed as text (SDK)
ralph.config.json → parsed via jq (CLI) / parsed natively (SDK)
Environment vars  → read directly (both)
```

Precedence is identical: Environment > ralph.config.json > .ralphrc > defaults.

### RFC Section 9 Open Question Resolutions

| # | Question | Decision | Rationale |
|---|----------|----------|-----------|
| 1 | Should Ralph SDK depend on TheStudio models? | **Own models** | Zero coupling. Ralph is free and independent. TheStudio writes a thin mapper (`TaskPacketRead` -> `TaskPacketInput`). |
| 2 | `anyio` vs `asyncio`? | **`asyncio` only** | TheStudio uses asyncio. No Trio requirement. Avoids the anyio dependency. |
| 3 | Include task queue ops in state backend? | **Exclude** | TheStudio manages tasks via TaskPacket lifecycle. Standalone Ralph reads `fix_plan.md` directly. Task queue is an orchestration concern, not a state concern. |
| 4 | Configurable system prompt template? | **Yes — `system_prompt` override** | `run_iteration()` accepts an optional `system_prompt: str` parameter. When provided, it replaces the default PROMPT.md content. Enables TheStudio's `DeveloperRoleConfig.system_prompt_template`. |

#### Q1: Own Models (Decision)

Ralph defines `TaskPacketInput`, `IntentSpecInput`, and `EvidenceBundle` in its own
codebase. These models mirror TheStudio's shapes but are independently versioned.
TheStudio maps from its internal models to Ralph's types. This means:

- Ralph can be used by any orchestration platform, not just TheStudio
- Ralph has zero dependency on TheStudio packages
- Model version drift is caught at TheStudio's mapper boundary, not at runtime

#### Q2: asyncio Only (Decision)

The SDK uses `asyncio` exclusively. The `FileStateBackend` uses `aiofiles` for async
file I/O. The `NullStateBackend` uses `asyncio.sleep(0)` for cooperative yielding.
There is no `anyio` or `trio` support.

For callers that need synchronous access, `run_iteration_sync()` wraps the async
method via `asyncio.run()`.

#### Q3: Exclude Task Queue (Decision)

`RalphStateBackend` Protocol covers: status, circuit breaker, rate limiting, session,
and metrics. It does NOT include task queue operations (create, claim, complete, fail).
Task lifecycle is managed by TheStudio's Temporal workflows, not by Ralph's state layer.

#### Q4: System Prompt Override (Decision)

`run_iteration(task_input, system_prompt="...")` replaces the default PROMPT.md content.
This enables TheStudio to inject its `DeveloperRoleConfig.system_prompt_template` which
includes role context, project conventions, and team-specific instructions.

## FAQ

**Q: Do I need to rewrite my hooks for SDK mode?**
A: No. Hooks still execute as bash commands via `.claude/settings.json`. The SDK invokes the same Claude CLI, which triggers the same hooks.

**Q: Will my existing .ralph/ state work with SDK mode?**
A: Yes. status.json, circuit breaker state, session IDs, call counts — all formats are compatible.

**Q: Can I switch between CLI and SDK modes?**
A: Yes, freely. State files are shared and compatible.

**Q: Does SDK mode require an internet connection for setup?**
A: Only for the initial `pip install` of dependencies. After that, it works the same as CLI mode.
