# Story CTXMGMT-3: Continue-As-New Pattern for Long Sessions

**Epic:** [Context Window Management](epic-context-management.md)
**Priority:** Medium
**Status:** Open
**Effort:** Medium
**Component:** `ralph_loop.sh`

---

## Problem

Long-running sessions accumulate stale context. After 20+ loop iterations, the conversation history contains exploration results, failed attempts, and completed task context that is no longer relevant. Session continuity (`--resume`) preserves everything, including noise.

Temporal's "Continue-As-New" pattern solves this: when state grows too large, atomically end the current execution and start a fresh one carrying forward only essential state.

## Solution

After N consecutive iterations in the same session, or when the session exceeds a configurable age, reset the session while preserving essential state.

## Implementation

```bash
RALPH_CONTINUE_AS_NEW_ENABLED=${RALPH_CONTINUE_AS_NEW_ENABLED:-true}
RALPH_MAX_SESSION_ITERATIONS=${RALPH_MAX_SESSION_ITERATIONS:-20}
RALPH_MAX_SESSION_AGE_MINUTES=${RALPH_MAX_SESSION_AGE_MINUTES:-120}

ralph_should_continue_as_new() {
    local session_iterations="$1" session_start_epoch="$2"
    local now
    now=$(date +%s)

    # Check iteration count
    if [[ "$session_iterations" -ge "$RALPH_MAX_SESSION_ITERATIONS" ]]; then
        log "INFO" "Session reached $session_iterations iterations — triggering Continue-As-New"
        return 0
    fi

    # Check session age
    local age_minutes=$(( (now - session_start_epoch) / 60 ))
    if [[ "$age_minutes" -ge "$RALPH_MAX_SESSION_AGE_MINUTES" ]]; then
        log "INFO" "Session age ${age_minutes}m exceeds ${RALPH_MAX_SESSION_AGE_MINUTES}m — triggering Continue-As-New"
        return 0
    fi

    return 1
}

ralph_continue_as_new() {
    # Step 1: Save essential state
    local state_file="${RALPH_DIR}/.continue_state.json"
    jq -n \
        --arg task "$(ralph_get_current_task)" \
        --arg progress "$(ralph_get_task_progress)" \
        --arg findings "$(ralph_get_key_findings)" \
        --argjson loop "$LOOP_COUNT" \
        '{
            current_task: $task,
            progress: $progress,
            key_findings: $findings,
            continued_from_loop: $loop
        }' > "$state_file"

    # Step 2: Reset session (clear session ID, forcing new session)
    rm -f "${RALPH_DIR}/.claude_session_id"

    # Step 3: Next iteration will start fresh with state injected via on-session-start.sh
    log "INFO" "Continue-As-New: saved state, cleared session, next iteration starts fresh"
}
```

### State injection on new session

```bash
# In on-session-start.sh:
if [[ -f "${RALPH_DIR}/.continue_state.json" ]]; then
    echo "## Continued Session"
    echo "This session continues from a previous session that was reset for context freshness."
    jq -r '"Previous task: \(.current_task)\nProgress: \(.progress)\nKey findings: \(.key_findings)"' \
        "${RALPH_DIR}/.continue_state.json"
    # Clean up after injection
    rm -f "${RALPH_DIR}/.continue_state.json"
fi
```

## Design Notes

- **20 iterations / 2 hours**: Based on research that success rate drops after ~35 minutes. At typical cadence (5-10 min per iteration), 20 iterations = ~100-200 minutes.
- **Essential state only**: Only current task, progress summary, and key findings carry forward. Full conversation history is intentionally dropped.
- **Automatic**: No user intervention required. The session resets transparently.
- **Compatible with session continuity**: This doesn't conflict with `--resume` — it simply clears the session ID, causing the next iteration to start a new session naturally.

## Acceptance Criteria

- [ ] Session reset triggered after N iterations or M minutes
- [ ] Essential state saved before reset (task, progress, findings)
- [ ] State injected into new session via on-session-start.sh
- [ ] State file cleaned up after injection
- [ ] Thresholds configurable via `.ralphrc`
- [ ] `RALPH_CONTINUE_AS_NEW_ENABLED=false` disables the feature

## References

- [Temporal — Continue-As-New](https://docs.temporal.io/workflows#continue-as-new)
- [Zylos — AI Agent Workflow Checkpointing](https://zylos.ai/research/2026-03-04-ai-agent-workflow-checkpointing-resumability)
- [LangChain — Durable Execution](https://docs.langchain.com/oss/python/langgraph/durable-execution)
