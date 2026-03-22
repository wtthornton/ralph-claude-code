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

## FAQ

**Q: Do I need to rewrite my hooks for SDK mode?**
A: No. Hooks still execute as bash commands via `.claude/settings.json`. The SDK invokes the same Claude CLI, which triggers the same hooks.

**Q: Will my existing .ralph/ state work with SDK mode?**
A: Yes. status.json, circuit breaker state, session IDs, call counts — all formats are compatible.

**Q: Can I switch between CLI and SDK modes?**
A: Yes, freely. State files are shared and compatible.

**Q: Does SDK mode require an internet connection for setup?**
A: Only for the initial `pip install` of dependencies. After that, it works the same as CLI mode.
