---
schema: failsafe-protocol/v1
agent: ralph
version: 2.0.1
last_reviewed: 2026-04-23
audience: [operator, security-reviewer]
diataxis: reference
---

# Ralph Safe Fallback Behaviors

This document defines Ralph's safe default behaviors following the [FAILSAFE.md open specification](https://failsafe.md/). When Ralph cannot determine the correct action, when components are missing, or when it operates in a degraded state, these defaults ensure safe, predictable behavior.

---

## Degradation Hierarchy

When components fail, Ralph degrades gracefully in this order:

1. **Full operation** — All systems nominal: hooks, sub-agents, metrics, session continuity, file protection
2. **No sub-agents** — Main agent handles all work directly (skip explorer/tester/reviewer delegation)
3. **No hooks** — Loop continues without response analysis hooks; uses last known good `status.json`
4. **No session continuity** — Each iteration starts fresh without `--resume` (no conversation history)
5. **No metrics/tracing** — Loop continues without observability; metrics JSONL not written
6. **No file protection** — Loop continues with warning; operator assumes risk of `.ralph/` modification
7. **HALT** — Cannot safely continue; operator intervention required

Each level includes all degradations from levels above it. Level 7 (HALT) is reached when core requirements (Claude CLI, git, `.ralph/` directory) are unavailable.

---

## Safe Defaults

| Condition | Safe Default | Rationale |
|-----------|-------------|-----------|
| Unknown task complexity | ROUTINE (Sonnet) | Over-provisioning is safer than under-provisioning |
| Missing `status.json` | Assume no completion | Prevents false exit when response analysis unavailable |
| Missing `.ralphrc` | Use hardcoded defaults | Ralph should work out-of-the-box with sensible defaults |
| Unknown exit code | Treat as failure | Prevents masking real errors; circuit breaker records it |
| Git not available | Halt loop | Progress detection (git diff baseline) requires git |
| Docker not available | Run on host with warning | Sandbox is opt-in via `--sandbox`; host execution is the default |
| Missing `fix_plan.md` | Halt loop | No tasks = nothing to execute; operator must create tasks |
| Missing `PROMPT.md` | Halt loop | No instructions = no context for Claude |
| API key invalid | Halt immediately | Cannot recover without valid API credentials |
| Circuit breaker state corrupt | Reset to CLOSED | Fresh start is safer than being stuck in OPEN state |
| Hook returns garbage | Ignore hook output | Loop should not depend on hook correctness for core operation |
| Session ID expired (>24h) | Start fresh session | Stale sessions may have corrupted context |
| MCP server unreachable | Continue without MCP tools | Core functionality does not depend on MCP servers |
| Rate limit counter corrupt | Reset to zero | Under-counting is safer than blocking the loop |
| Log rotation failure | Continue without rotation | Logs growing large is less harmful than halting |

---

## Minimum Viable Operation

Ralph can operate with ONLY these components:

| Component | Required | Purpose |
|-----------|----------|---------|
| `ralph_loop.sh` | Yes | Core autonomous loop |
| `lib/circuit_breaker.sh` | Yes | Failure detection and halt mechanism |
| `lib/date_utils.sh` | Yes | Cross-platform timestamp handling |
| Claude CLI (`claude` command) | Yes | AI execution engine |
| `.ralph/fix_plan.md` | Yes | Task list driving each iteration |
| `.ralph/PROMPT.md` | Yes | Development instructions for Claude |
| Git repository | Yes | Progress detection via diff baseline |
| `jq` | Yes | JSON parsing for state files |

Everything else is an optional enhancement:

| Optional Component | Degrades To |
|-------------------|-------------|
| Hooks (`.claude/hooks/`) | No response analysis; raw output only |
| Sub-agents (`ralph-explorer`, `ralph-tester`, etc.) | Main agent handles all tasks |
| Skills (`.claude/skills/`) | No skill shortcuts |
| Metrics (`lib/metrics.sh`) | No usage analytics |
| Notifications (`lib/notifications.sh`) | No alerts beyond log output |
| Sandbox (`lib/sandbox.sh`) | Host execution |
| SDK (`sdk/`) | CLI-only mode |
| State backup (`lib/backup.sh`) | No rollback capability |

---

## Recovery Priority

When multiple failures occur simultaneously, recover in this order:

1. **Restore write access** — If `.ralph/` is unwritable, nothing else can recover
2. **Validate Claude CLI** — The execution engine must be functional
3. **Reset circuit breaker** — Clear OPEN state to allow iteration attempts
4. **Reinitialize session** — Fresh session clears corrupted state
5. **Restore hooks** — Response analysis feeds circuit breaker decisions
6. **Re-enable sub-agents** — Delegation improves quality but is not required

---

## References

- [FAILSAFE.md Specification](https://failsafe.md/)
- [FAILURE.md](FAILURE.md) — Ralph's failure mode definitions
