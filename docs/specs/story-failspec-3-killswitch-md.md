# Story FAILSPEC-3: Implement KILLSWITCH.md Emergency Stop

**Epic:** [Failure Protocol Compliance](epic-failure-protocol.md)
**Priority:** Critical
**Status:** Open
**Effort:** Small
**Component:** new `KILLSWITCH.md` (project root), `ralph_loop.sh`

---

## Problem

Ralph has SIGINT/SIGTERM handling and circuit breaker halts, but no documented **emergency stop** protocol. In production scenarios (especially TheStudio fleet), operators need a standardized way to immediately halt Ralph with guaranteed cleanup.

## Solution

Create a `KILLSWITCH.md` that documents emergency stop triggers, procedures, and guarantees. Validate that Ralph's existing signal handling meets the specification.

## Implementation

### KILLSWITCH.md Content

```markdown
---
schema: killswitch-protocol/v1
agent: ralph
version: 2.0.0
---

# Ralph Emergency Stop Protocol

## Triggers

| Trigger | Method | Latency | Cleanup |
|---------|--------|---------|---------|
| Ctrl+C (SIGINT) | Terminal | <2s | Full cleanup |
| SIGTERM | Signal | <2s | Full cleanup |
| `ralph --stop` | CLI | <5s | Full cleanup |
| `touch .ralph/.killswitch` | File sentinel | <30s (next loop check) | Full cleanup |
| SIGKILL | Signal | Immediate | NO cleanup |
| Circuit breaker OPEN | Automatic | <1s | Partial cleanup |

## Cleanup Guarantees

On any non-SIGKILL stop:
1. Current Claude CLI process receives SIGTERM, then SIGKILL after 5s
2. All child processes (sub-agents, hooks) terminated
3. `.ralph/status.json` updated with final state
4. `ralph.log` flushed and closed
5. tmux panes preserved for post-mortem
6. Instance lock (flock) released
7. Temp files cleaned up

## File Sentinel

For headless/fleet operation, Ralph checks for `.ralph/.killswitch` at the start of each iteration:

```bash
if [[ -f "${RALPH_DIR}/.killswitch" ]]; then
    log "CRITICAL" "Killswitch file detected — emergency halt"
    rm -f "${RALPH_DIR}/.killswitch"
    ralph_cleanup
    exit 1
fi
```

## Post-Mortem Data

After emergency stop, these files contain diagnostic data:
- `ralph.log` — Full loop history
- `.ralph/status.json` — Last known state
- `.ralph/.circuit_breaker_state` — CB state at halt
- `claude_output_*.log` — Last Claude CLI output
```

## Implementation Changes

### Add killswitch file sentinel to main loop

```bash
# At top of main loop iteration:
ralph_check_killswitch() {
    if [[ -f "${RALPH_DIR}/.killswitch" ]]; then
        local reason
        reason=$(cat "${RALPH_DIR}/.killswitch" 2>/dev/null || echo "no reason given")
        log "CRITICAL" "KILLSWITCH activated: $reason"
        rm -f "${RALPH_DIR}/.killswitch"
        return 1
    fi
    return 0
}
```

## Acceptance Criteria

- [ ] KILLSWITCH.md created in Ralph project root
- [ ] All stop triggers documented with latency and cleanup guarantees
- [ ] File sentinel (`.ralph/.killswitch`) checked at each loop iteration
- [ ] Killswitch file can contain a reason string
- [ ] Existing SIGINT/SIGTERM behavior validated against spec
- [ ] `ralph --stop` command documented

## References

- [KILLSWITCH.md Specification](https://killswitch.md/)
