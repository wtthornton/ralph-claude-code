---
schema: killswitch-protocol/v1
agent: ralph
version: 2.0.1
last_reviewed: 2026-04-23
audience: [operator, security-reviewer]
diataxis: reference
---

# Ralph Emergency Stop Protocol

This document defines emergency stop triggers and procedures following the [KILLSWITCH.md open specification](https://killswitch.md/). All stop methods guarantee safe cleanup except SIGKILL.

---

## Triggers

| Trigger | Method | Latency | Cleanup | Use Case |
|---------|--------|---------|---------|----------|
| Ctrl+C (SIGINT) | Terminal signal | <2s | Full | Interactive operator stop |
| SIGTERM | Process signal | <2s | Full | Graceful shutdown from process manager |
| `ralph --stop` | CLI command | <5s | Full | Remote/scripted stop |
| `touch .ralph/.killswitch` | File sentinel | <30s (next loop check) | Full | Headless/fleet operation |
| SIGKILL | Process signal | Immediate | **NONE** | Last resort only |
| Circuit breaker OPEN | Automatic | <1s | Partial | Stagnation/failure detection |

---

## Cleanup Guarantees

On any non-SIGKILL stop, Ralph performs these cleanup steps in order:

1. **Terminate Claude CLI** — Current Claude CLI process receives SIGTERM; if still running after 5s, receives SIGKILL
2. **Terminate child processes** — All sub-agents, hooks, and background processes terminated
3. **Update status** — `.ralph/status.json` updated with final state and stop reason
4. **Flush logs** — `ralph.log` flushed and closed with final entry
5. **Preserve tmux** — tmux panes preserved for post-mortem inspection
6. **Release lock** — Instance lock (flock on `.ralph/.ralph.lock`) released
7. **Clean temp files** — Atomic write temp files (`.*.XXXXXX`) removed

---

## File Sentinel

For headless or fleet operation where signal delivery is impractical, Ralph checks for a `.killswitch` file at the start of each loop iteration.

### Creating a killswitch

```bash
# Simple stop:
touch .ralph/.killswitch

# Stop with reason (file content is logged):
echo "Fleet maintenance window" > .ralph/.killswitch
```

### Behavior

- Ralph checks for `.ralph/.killswitch` at the top of each loop iteration
- If the file exists, Ralph reads its content as the stop reason
- The killswitch file is removed after reading
- Ralph performs full cleanup and exits with code 1
- Maximum latency is one full loop iteration (~30s worst case)

### Implementation

```bash
ralph_check_killswitch() {
    if [[ -f "${RALPH_DIR}/.killswitch" ]]; then
        local reason
        reason=$(cat "${RALPH_DIR}/.killswitch" 2>/dev/null || echo "no reason given")
        reason="${reason:-no reason given}"
        log_status "CRITICAL" "KILLSWITCH activated: $reason"
        rm -f "${RALPH_DIR}/.killswitch"
        return 1
    fi
    return 0
}
```

---

## Signal Handling

Ralph registers signal handlers at startup:

| Signal | Handler | Behavior |
|--------|---------|----------|
| SIGINT (2) | `cleanup()` | Graceful stop with full cleanup |
| SIGTERM (15) | `cleanup()` | Graceful stop with full cleanup |
| SIGPIPE (13) | Ignored | Prevents broken pipe crashes |
| EXIT | `cleanup()` | Final cleanup on any exit path |

The `cleanup()` function is reentrant-safe — multiple signals do not cause double-cleanup.

---

## Post-Mortem Data

After an emergency stop, these files contain diagnostic data:

| File | Content |
|------|---------|
| `.ralph/logs/ralph.log` | Full loop history with timestamps |
| `.ralph/status.json` | Last known state, stop reason, loop count |
| `.ralph/.circuit_breaker_state` | Circuit breaker state at halt |
| `.ralph/.circuit_breaker_events` | Sliding window failure log |
| `.ralph/logs/claude_output_*.log` | Last Claude CLI output (raw stream) |
| `.ralph/.claude_session_id` | Session ID for potential resume |

---

## Recovery After Emergency Stop

1. **Review logs**: `tail -50 .ralph/logs/ralph.log`
2. **Check last output**: `ls -lt .ralph/logs/claude_output_*.log | head -1`
3. **Check circuit breaker**: `ralph --circuit-status`
4. **Reset if needed**: `ralph --reset-circuit`
5. **Restart**: `ralph`

---

## References

- [KILLSWITCH.md Specification](https://killswitch.md/)
- [FAILURE.md](FAILURE.md) — Failure mode definitions
- [FAILSAFE.md](FAILSAFE.md) — Safe fallback behaviors
