# Story SDK-3: Implement Hybrid CLI/SDK Architecture

**Epic:** [RALPH-SDK](epic-sdk-integration.md)
**Priority:** Critical
**Status:** Open
**Effort:** Large
**Component:** `sdk/ralph_agent.py`, `ralph_loop.sh`, new `sdk/interface.py`

---

## Problem

Ralph needs to operate in three modes:
1. **Standalone CLI** — Current bash loop, invokes Claude Code CLI directly
2. **Standalone SDK** — Python Agent SDK loop, runs independently
3. **Embedded in TheStudio** — Receives TaskPackets from TheStudio pipeline, emits signals back

These modes must share the same reliability infrastructure (circuit breaker, rate limiting, exit detection) without duplicating logic.

## Solution

Define a **Ralph Agent Interface** that abstracts the execution contract. Both CLI and SDK implementations conform to this interface. TheStudio embeds Ralph by instantiating the SDK implementation with a TaskPacket adapter.

```
┌─────────────────────────────────────────────────────┐
│                Ralph Agent Interface                 │
│  input: TaskInput (fix_plan | TaskPacket)            │
│  output: TaskResult (status.json | Signal)           │
│  hooks: on_start, on_stop, on_tool_use               │
│  safety: rate_limit, circuit_breaker, exit_gate      │
└──────────────┬──────────────────┬────────────────────┘
               │                  │
    ┌──────────▼──────┐  ┌───────▼─────────┐
    │   CLI Runner    │  │   SDK Runner     │
    │  ralph_loop.sh  │  │ ralph_agent.py   │
    │  (bash, proven) │  │ (python, new)    │
    └─────────────────┘  └───────┬──────────┘
                                 │
                      ┌──────────▼──────────┐
                      │  TheStudio Adapter  │
                      │  TaskPacket → input  │
                      │  output → Signal     │
                      └─────────────────────┘
```

## Implementation

1. Define `sdk/interface.py` — Abstract base class for Ralph execution:
   ```python
   class RalphAgentInterface:
       def start(self, input: TaskInput) -> None
       def stop(self) -> TaskResult
       def on_iteration(self, response: ClaudeResponse) -> LoopAction
       def get_status(self) -> Status
       def get_circuit_state(self) -> CircuitState
   ```

2. Define `sdk/models.py` — Shared data models:
   ```python
   class TaskInput:
       """Union of fix_plan.md content or TheStudio TaskPacket"""
       source: Literal["fix_plan", "task_packet"]
       tasks: list[Task]
       context: str  # PROMPT.md content or TaskPacket.intent

   class TaskResult:
       """Output compatible with status.json and TheStudio signals"""
       work_type: str
       completed_tasks: list[str]
       exit_signal: bool
       metrics: LoopMetrics
   ```

3. Implement `sdk/runner.py` — SDK runner conforming to interface:
   - Full loop with rate limiting, circuit breaker, exit detection
   - Uses SDK custom tools (from SDK-2) instead of text parsing
   - Spawns sub-agents using Agent SDK native spawning

4. Create `sdk/adapters/thestudio.py` — TheStudio adapter:
   - Converts TaskPacket to TaskInput
   - Converts TaskResult to TheStudio Signal format
   - Implements TheStudio's Primary Agent contract

5. Update `ralph_loop.sh` — Add SDK dispatch:
   - `ralph --sdk` flag invokes SDK runner instead of CLI loop
   - `ralph` (no flag) continues to use bash CLI loop
   - Both modes read same `.ralphrc` / `ralph.config.json`

### Key Design Decisions

1. **Interface, not migration:** The CLI runner is NOT being replaced. The interface allows both to coexist and share safety logic. CLI remains the default for standalone users.
2. **TaskInput union type:** A single input model handles both fix_plan.md and TaskPackets. The source field determines parsing strategy. This is the key to dual-mode operation.
3. **Adapter pattern for TheStudio:** TheStudio doesn't need to know Ralph's internals. It instantiates a RalphAgent, passes a TaskPacket, and receives Signals. The adapter handles translation.
4. **Sub-agent spawning:** SDK runner uses Agent SDK's native agent spawning rather than the CLI's `--agent` flag approach. This enables deeper integration with TheStudio's execution planes.

## Testing

```bash
@test "SDK runner completes same tasks as CLI runner" {
  # Run CLI on reference project
  ralph --project "$REF_PROJECT" --dry-run --output-format json > cli_result.json
  # Run SDK on same project
  ralph --sdk --project "$REF_PROJECT" --dry-run --output-format json > sdk_result.json
  # Compare task completion
  diff <(jq '.completed_tasks' cli_result.json) <(jq '.completed_tasks' sdk_result.json)
}

@test "TheStudio adapter converts TaskPacket to TaskInput" {
  run python -c "
from sdk.adapters.thestudio import taskpacket_to_input
inp = taskpacket_to_input({'intent': {'goal': 'fix bug'}, 'tasks': [{'title': 'task1'}]})
assert inp.source == 'task_packet'
print('OK')
"
  [[ "$output" == "OK" ]]
}

@test "SDK runner respects circuit breaker" {
  # Set circuit breaker to OPEN
  echo '{"state": "OPEN", "timestamp": "2026-01-01T00:00:00Z"}' > .ralph/.circuit_breaker_state
  run ralph --sdk --project "$REF_PROJECT"
  [[ "$output" == *"circuit breaker is OPEN"* ]]
}
```

## Acceptance Criteria

- [ ] `ralph --sdk` runs the SDK runner with identical safety guarantees as CLI
- [ ] `ralph` (default) continues to run bash CLI loop unchanged
- [ ] RalphAgentInterface is implemented by both CLI and SDK runners
- [ ] TaskInput handles both fix_plan.md and TaskPacket sources
- [ ] TaskResult is compatible with status.json format
- [ ] TheStudio adapter converts TaskPacket ↔ TaskInput and TaskResult ↔ Signal
- [ ] Sub-agents spawn via Agent SDK in SDK mode
- [ ] Circuit breaker, rate limiting, and exit detection work in SDK mode
- [ ] All existing 736+ tests continue to pass (CLI mode unaffected)
