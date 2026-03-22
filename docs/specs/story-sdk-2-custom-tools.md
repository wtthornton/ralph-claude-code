# Story SDK-2: Define Custom Tools for Agent SDK

**Epic:** [RALPH-SDK](epic-sdk-integration.md)
**Priority:** High
**Status:** Open
**Effort:** Medium
**Component:** `sdk/tools/`

---

## Problem

Ralph's reliability features (rate limiting, circuit breaking, status reporting) are implemented as bash functions in `ralph_loop.sh` and `lib/circuit_breaker.sh`. These cannot be exposed as callable tools in an SDK agent. For the SDK to match CLI reliability, these capabilities must be expressed as SDK-native tools.

## Solution

Define custom tools that Claude can call during SDK execution to interact with Ralph's safety infrastructure:

1. **ralph_status** — Report current work status (replaces RALPH_STATUS block parsing)
2. **ralph_rate_check** — Query remaining API calls in current window
3. **ralph_circuit_state** — Query or update circuit breaker state
4. **ralph_task_update** — Mark fix_plan.md tasks as complete

## Implementation

1. Create `sdk/tools/` directory
2. Implement each tool as a Python function with JSON schema definition:

```python
# sdk/tools/ralph_status.py
def ralph_status(
    work_type: str,
    completed_task: str,
    next_task: str,
    progress_summary: str,
    exit_signal: bool = False
) -> dict:
    """Report current work status to Ralph loop controller."""
    status = {
        "WORK_TYPE": work_type,
        "COMPLETED_TASK": completed_task,
        "NEXT_TASK": next_task,
        "PROGRESS_SUMMARY": progress_summary,
        "EXIT_SIGNAL": exit_signal,
        "timestamp": datetime.utcnow().isoformat()
    }
    write_status_json(status)
    return {"acknowledged": True, "exit": exit_signal}
```

3. Register tools with Agent SDK tool registry
4. Ensure tool output format is compatible with existing status.json schema

### Key Design Decisions

1. **ralph_status replaces RALPH_STATUS block:** Instead of parsing freeform text for a status block, Claude calls a structured tool. This eliminates parsing fragility (the root cause of many Phase 0 bugs).
2. **Tools are opt-in:** CLI mode continues to use text-based RALPH_STATUS. SDK mode uses tools. Both write the same status.json.
3. **Circuit breaker as queryable tool:** Claude can check circuit breaker state before attempting expensive operations, enabling self-regulation.

## Testing

```bash
@test "ralph_status tool writes valid status.json" {
  run python -c "from sdk.tools.ralph_status import ralph_status; ralph_status('IMPLEMENTATION', 'task 1', 'task 2', 'progress', False)"
  [ -f ".ralph/status.json" ]
  jq -e '.WORK_TYPE == "IMPLEMENTATION"' .ralph/status.json
}

@test "ralph_rate_check returns remaining calls" {
  run python -c "from sdk.tools.ralph_rate_check import ralph_rate_check; print(ralph_rate_check())"
  [[ "$output" == *"remaining"* ]]
}

@test "ralph_circuit_state reports current state" {
  run python -c "from sdk.tools.ralph_circuit_state import ralph_circuit_state; print(ralph_circuit_state())"
  [[ "$output" == *"CLOSED"* ]]
}
```

## Acceptance Criteria

- [ ] `ralph_status` tool writes status.json in existing format
- [ ] `ralph_rate_check` tool returns remaining calls and window expiry
- [ ] `ralph_circuit_state` tool returns current CB state (CLOSED/HALF_OPEN/OPEN)
- [ ] `ralph_task_update` tool marks fix_plan.md checkboxes as complete
- [ ] All tools have JSON schema definitions compatible with Agent SDK
- [ ] Tools work in both standalone SDK and TheStudio embedded contexts
- [ ] Tool outputs match existing status.json / .circuit_breaker_state formats
