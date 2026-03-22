---
schema: failure-protocol/v1
agent: ralph
version: 2.0.0
last_reviewed: 2026-03-22
---

# Ralph Failure Mode Protocol

This document defines all known failure modes for the Ralph autonomous development loop, following the [FAILURE.md open specification](https://failure.md/). Each failure mode describes detection signals, response procedures, fallback behaviors, notification rules, and recovery steps.

**Severity Levels:**
- **Critical** — Halt execution immediately; manual intervention likely required
- **High** — Degrade or retry; automatic recovery possible but not guaranteed
- **Medium** — Warn and continue; self-healing expected
- **Low** — Advisory only; no operational impact

---

## Failure Modes

### FM-001: API Rate Limit
- **Severity:** Medium
- **Detection:**
  - Exit code 124 (timeout guard)
  - `rate_limit_event` object in JSONL stream
  - Quota-exceeded text in last 30 lines of output (filtered to exclude echoed project content)
  - Extra Usage quota detection
- **Response:** Exponential backoff with jitter (base: 5min, max: 30min, managed by loop sleep)
- **Fallback:** After 3 consecutive rate limits within the sliding window → circuit breaker transitions to OPEN (FM-002)
- **Notification:** WARN to `ralph.log`, webhook POST if configured
- **Recovery:** Automatic — hourly rate counter resets via `.call_count` / `.last_reset`

### FM-002: Circuit Breaker Trip
- **Severity:** High
- **Detection:**
  - Circuit breaker state transitions to OPEN in `.circuit_breaker_state`
  - Sliding window failure count reaches `CB_FAILURE_THRESHOLD` (default: 5) within `CB_FAILURE_DECAY_MINUTES` (default: 30)
- **Response:** Halt loop execution, log failure count and window statistics
- **Fallback:** Wait for `CB_COOLDOWN_MINUTES` (default: 30) → transition to HALF_OPEN → execute test iteration → if progress detected, transition to CLOSED
- **Notification:** ERROR to `ralph.log`, webhook POST, OS notification (terminal bell / native)
- **Recovery:**
  - Automatic if `CB_AUTO_RESET=true` (bypasses cooldown on next startup)
  - Manual via `ralph --reset-circuit`

### FM-003: Consecutive Timeout (No Progress)
- **Severity:** Critical
- **Detection:**
  - N consecutive iterations produce exit code 124 (timeout)
  - Git diff baseline comparison (GUARD-1) shows zero file changes between iterations
  - No `EXIT_SIGNAL: true` or progress indicators in RALPH_STATUS
- **Response:** Open circuit breaker immediately (bypass sliding window threshold)
- **Fallback:** None — halt is the safe behavior; loop cannot make progress
- **Notification:** CRITICAL to `ralph.log`, webhook POST
- **Recovery:** Manual investigation required — review `claude_output_*.log`, update `fix_plan.md` or `PROMPT.md`, then `ralph --reset-circuit`

### FM-004: Session Corruption
- **Severity:** High
- **Detection:**
  - Empty or missing `.claude_session_id`
  - Missing or malformed `status.json` (invalid JSON)
  - Session ID older than 24-hour expiration window
- **Response:** Reset session state, reinitialize state files
- **Fallback:** Start fresh session (lose conversation continuity, preserve task progress in `fix_plan.md`)
- **Notification:** WARN to `ralph.log`
- **Recovery:** Automatic — next iteration starts with a new session

### FM-005: Hook Execution Failure
- **Severity:** Medium
- **Detection:**
  - Hook script returns non-zero exit code
  - Hook output contains error indicators
- **Response:** Log error details, continue loop execution (hooks are advisory, not blocking for loop progress)
- **Fallback:** Skip hook result, use last known good `status.json` for response analysis
- **Notification:** WARN to `ralph.log`
- **Recovery:** Automatic — hooks re-execute on next iteration

### FM-006: Sub-Agent Failure
- **Severity:** Medium
- **Detection:**
  - Sub-agent invocation times out (exceeds deadline budget from ADAPTIVE-2)
  - Sub-agent returns error result
  - SubagentStop hook fires with error context
- **Response:** Log failure, continue main loop without sub-agent result
- **Fallback:** Main agent (ralph) handles the task directly without delegation
- **Notification:** WARN to `ralph.log`
- **Recovery:** Automatic — next iteration may re-attempt delegation or main agent handles it

### FM-007: File System Full
- **Severity:** Critical
- **Detection:**
  - Write failure to `.ralph/` state files (status.json, circuit breaker state, session ID)
  - Log rotation failure in `rotate_ralph_log()`
  - Atomic write temp file creation fails
- **Response:** Halt loop, preserve current state as-is
- **Fallback:** None — Ralph cannot operate without write access to `.ralph/`
- **Notification:** CRITICAL to stderr (log file writes may also fail)
- **Recovery:** Manual — free disk space, then restart Ralph

### FM-008: Claude CLI Missing or Broken
- **Severity:** Critical
- **Detection:**
  - `command -v claude` (or configured `CLAUDE_CODE_CMD`) returns non-zero
  - CLI version check returns unexpected error or empty output
  - `npx @anthropic-ai/claude-code` fallback also fails
- **Response:** Halt loop at startup before any iteration
- **Fallback:** None — Ralph requires the Claude Code CLI to function
- **Notification:** ERROR to stderr with installation instructions
- **Recovery:** Install or update Claude CLI (`npm install -g @anthropic-ai/claude-code`), then restart

### FM-009: Git Repository Corruption
- **Severity:** High
- **Detection:**
  - `git status` returns non-zero exit code
  - `git rev-parse HEAD` fails
  - `git diff` commands used for baseline snapshotting (GUARD-1) fail
- **Response:** Halt loop, preserve all logs
- **Fallback:** None — progress detection (git diff baseline), commit tracking, and guard rails all require a functional git repository
- **Notification:** ERROR to `ralph.log`
- **Recovery:** Manual — run `git fsck`, restore from backup if needed, then restart

### FM-010: Token Budget Exceeded
- **Severity:** Low
- **Detection:**
  - Per-iteration token count (from JSONL stream `usage` fields) exceeds expected budget for the task's complexity tier
  - Aggregate session tokens approach model context window limit
- **Response:** Log warning with token counts and task details, continue execution
- **Fallback:** None — advisory metric; loop continues normally
- **Notification:** WARN to `ralph.log`
- **Recovery:** Automatic — next iteration may consume less; cost-aware routing (COSTROUTE epic) will address optimization

### FM-011: Concurrent Instance Conflict
- **Severity:** High
- **Detection:**
  - `flock` on `.ralph/.ralph.lock` fails (LOCK-1)
  - Another Ralph process holds the lock file
- **Response:** Refuse to start, exit immediately with error message
- **Fallback:** None — concurrent execution would cause state corruption
- **Notification:** ERROR to stderr with PID of existing process
- **Recovery:** Wait for existing instance to complete, or kill it manually, then restart

### FM-012: MCP Server Failure
- **Severity:** Medium
- **Detection:**
  - MCP server initialization fails during pre-flight check (MULTI-6)
  - MCP tool calls return errors during execution
- **Response:** Log failure, suppress repeated MCP errors (UPKEEP-2), continue without MCP tools
- **Fallback:** Claude operates without MCP-provided tools; core functionality unaffected
- **Notification:** WARN to `ralph.log` (first occurrence only, subsequent suppressed)
- **Recovery:** Automatic — MCP re-initializes on next session start

---

## Failure Mode Matrix

| ID | Name | Severity | Auto-Recovery | Halts Loop |
|----|------|----------|---------------|------------|
| FM-001 | API Rate Limit | Medium | Yes | No |
| FM-002 | Circuit Breaker Trip | High | Conditional | Yes |
| FM-003 | Consecutive Timeout | Critical | No | Yes |
| FM-004 | Session Corruption | High | Yes | No |
| FM-005 | Hook Execution Failure | Medium | Yes | No |
| FM-006 | Sub-Agent Failure | Medium | Yes | No |
| FM-007 | File System Full | Critical | No | Yes |
| FM-008 | Claude CLI Missing | Critical | No | Yes (startup) |
| FM-009 | Git Repository Corruption | High | No | Yes |
| FM-010 | Token Budget Exceeded | Low | Yes | No |
| FM-011 | Concurrent Instance | High | No | Yes (startup) |
| FM-012 | MCP Server Failure | Medium | Yes | No |

---

## Escalation Chain

```
Individual failure
    → Detection signal matched
        → Response action executed
            → If fallback needed → activate fallback
                → If fallback fails → escalate severity
    → Notification sent (level matches severity)
    → If repeated → sliding window evaluation (CBDECAY-1)
        → If threshold breached → FM-002 (Circuit Breaker Trip)
            → If CB_AUTO_RESET → auto-recover on next startup
            → Else → manual intervention required
```

## References

- [FAILURE.md Specification](https://failure.md/)
- [AWS — Building Resilient Generative AI Agents](https://aws.amazon.com/blogs/architecture/build-resilient-generative-ai-agents/)
- Ralph Phase 13 epics: guard rails, circuit breaker decay, adaptive timeout, stream capture
