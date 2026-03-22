# Story FAILSPEC-1: Implement FAILURE.md Specification

**Epic:** [Failure Protocol Compliance](epic-failure-protocol.md)
**Priority:** Critical
**Status:** Open
**Effort:** Medium
**Component:** new `FAILURE.md` (project root)

---

## Problem

Ralph's failure modes are implemented across multiple bash modules but not documented in a standardized, machine-readable format. External tools, operators, and compliance auditors have no single source of truth for how Ralph behaves under failure conditions.

The FAILURE.md open specification (2026) provides a standard format for documenting AI agent failure modes.

## Solution

Create a `FAILURE.md` file in the Ralph project root that documents all known failure modes with detection signals, response procedures, notification rules, and escalation targets.

## Implementation

### FAILURE.md Structure

```markdown
---
schema: failure-protocol/v1
agent: ralph
version: 2.0.0
last_reviewed: 2026-03-22
---

# Ralph Failure Mode Protocol

## Failure Modes

### FM-001: API Rate Limit
- **Severity:** Medium
- **Detection:** Exit code 124 (timeout), `rate_limit_event` in JSONL stream, quota text in last 30 lines
- **Response:** Exponential backoff with jitter (base: 5min, max: 30min)
- **Fallback:** After 3 retries → circuit breaker OPEN
- **Notification:** WARN to log, webhook if configured
- **Recovery:** Automatic after cooldown period

### FM-002: Circuit Breaker Trip
- **Severity:** High
- **Detection:** CB state transitions to OPEN
- **Response:** Halt loop execution, log failure count and window stats
- **Fallback:** Wait for CB_COOLDOWN_MINUTES → HALF_OPEN → test iteration
- **Notification:** ERROR to log, webhook, OS notification
- **Recovery:** Auto-reset if CB_AUTO_RESET=true, else manual --reset-circuit

### FM-003: Consecutive Timeout (No Progress)
- **Severity:** Critical
- **Detection:** N consecutive timeouts with no git diff changes (GUARD-1 baseline comparison)
- **Response:** Open circuit breaker immediately
- **Fallback:** None — halt is the safe behavior
- **Notification:** CRITICAL to log, webhook
- **Recovery:** Manual investigation required

### FM-004: Session Corruption
- **Severity:** High
- **Detection:** Empty session_id, missing status.json, malformed JSON
- **Response:** Reset session, reinitialize state files
- **Fallback:** Fresh session (lose continuity, keep task progress)
- **Notification:** WARN to log
- **Recovery:** Automatic — next iteration starts fresh

### FM-005: Hook Execution Failure
- **Severity:** Medium
- **Detection:** Hook returns non-zero exit code
- **Response:** Log error, continue loop (hooks are advisory, not blocking)
- **Fallback:** Skip hook, use last known good status
- **Notification:** WARN to log
- **Recovery:** Automatic

### FM-006: Sub-Agent Failure
- **Severity:** Medium
- **Detection:** Sub-agent timeout or error result
- **Response:** Log failure, continue without sub-agent result
- **Fallback:** Main agent handles task without delegation
- **Notification:** WARN to log
- **Recovery:** Automatic — next iteration may re-attempt delegation

### FM-007: File System Full
- **Severity:** Critical
- **Detection:** Write failure to .ralph/ state files or log rotation failure
- **Response:** Halt loop, preserve current state
- **Fallback:** None — cannot operate without write access
- **Notification:** CRITICAL to log (if possible)
- **Recovery:** Manual — free disk space, restart

### FM-008: Claude CLI Missing/Broken
- **Severity:** Critical
- **Detection:** `command -v claude` fails, or CLI returns unexpected error on version check
- **Response:** Halt loop at startup
- **Fallback:** None — Ralph requires Claude CLI
- **Notification:** ERROR to stderr
- **Recovery:** Install/update Claude CLI, restart

### FM-009: Git Repository Corruption
- **Severity:** High
- **Detection:** `git status` returns error, `git rev-parse HEAD` fails
- **Response:** Halt loop, preserve logs
- **Fallback:** None — progress detection requires git
- **Notification:** ERROR to log
- **Recovery:** Manual — `git fsck`, restore from backup

### FM-010: Token Budget Exceeded
- **Severity:** Low
- **Detection:** Per-iteration token count exceeds complexity tier budget
- **Response:** Log warning, continue execution
- **Fallback:** None (advisory)
- **Notification:** WARN to log
- **Recovery:** Automatic — next iteration may use less
```

## Design Notes

- **Schema version**: `failure-protocol/v1` follows the FAILURE.md open specification.
- **Machine-readable frontmatter**: YAML frontmatter enables automated parsing by compliance tools.
- **Maps to existing code**: Every failure mode listed corresponds to existing Ralph behavior. This story documents, not implements.
- **Severity levels**: Critical (halt), High (degrade/retry), Medium (warn/continue), Low (advisory).

## Acceptance Criteria

- [ ] FAILURE.md created in Ralph project root
- [ ] All known failure modes documented (FM-001 through FM-010 minimum)
- [ ] Each failure mode has: severity, detection, response, fallback, notification, recovery
- [ ] YAML frontmatter with schema version, agent name, review date
- [ ] All documented behaviors match actual Ralph implementation
- [ ] File is valid markdown with machine-readable structure

## Test Plan

```bash
@test "FAILURE.md exists and has valid frontmatter" {
    assert [ -f "$RALPH_DIR/FAILURE.md" ]
    head -1 "$RALPH_DIR/FAILURE.md" | grep -q "^---$"
    grep -q "schema: failure-protocol/v1" "$RALPH_DIR/FAILURE.md"
}

@test "FAILURE.md documents all critical failure modes" {
    for fm in FM-001 FM-002 FM-003 FM-007 FM-008; do
        grep -q "$fm" "$RALPH_DIR/FAILURE.md"
    done
}
```

## References

- [FAILURE.md Specification](https://failure.md/)
- [AWS — Building Resilient Generative AI Agents](https://aws.amazon.com/blogs/architecture/build-resilient-generative-ai-agents/)
