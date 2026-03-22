# Story CTXMGMT-2: Task Decomposition Signals

**Epic:** [Context Window Management](epic-context-management.md)
**Priority:** High
**Status:** Open
**Effort:** Small
**Component:** `ralph_loop.sh`, `.claude/agents/ralph.md`

---

## Problem

Research shows agent success rate decreases after 35 minutes and doubling duration quadruples failure rate. Some tasks are inherently too large for a single iteration but Ralph doesn't detect this before execution.

## Solution

Detect "too-large" tasks before they begin and emit a decomposition signal. The signal can be: (a) a log warning, (b) an instruction in the agent prompt to split the task, or (c) a hard block requiring manual decomposition.

## Implementation

```bash
RALPH_DECOMPOSE_THRESHOLD_FILES=${RALPH_DECOMPOSE_THRESHOLD_FILES:-5}
RALPH_DECOMPOSE_THRESHOLD_WORDS=${RALPH_DECOMPOSE_THRESHOLD_WORDS:-500}
RALPH_DECOMPOSE_THRESHOLD_RETRIES=${RALPH_DECOMPOSE_THRESHOLD_RETRIES:-2}

ralph_should_decompose() {
    local task_text="$1" retry_count="${2:-0}"

    # Signal 1: Too many files mentioned
    local file_count
    file_count=$(echo "$task_text" | grep -oE '[a-zA-Z0-9_/]+\.[a-z]{1,4}' | sort -u | wc -l)
    [[ "$file_count" -ge "$RALPH_DECOMPOSE_THRESHOLD_FILES" ]] && return 0

    # Signal 2: Task description too long
    local word_count
    word_count=$(echo "$task_text" | wc -w)
    [[ "$word_count" -ge "$RALPH_DECOMPOSE_THRESHOLD_WORDS" ]] && return 0

    # Signal 3: Repeated failures
    [[ "$retry_count" -ge "$RALPH_DECOMPOSE_THRESHOLD_RETRIES" ]] && return 0

    # Signal 4: Historical data (if available)
    local avg_duration
    avg_duration=$(ralph_get_avg_duration_for_similar_tasks "$task_text" 2>/dev/null || echo "0")
    [[ "$avg_duration" -gt 2100 ]] && return 0  # >35 min average

    return 1  # No decomposition needed
}
```

### Decomposition instruction injection

```bash
# Before Claude invocation, if decomposition signaled:
if ralph_should_decompose "$task_text" "$retry_count"; then
    log "WARN" "Task may be too large — injecting decomposition guidance"
    DECOMPOSE_CONTEXT="IMPORTANT: This task appears complex. Break it into 2-3 smaller sub-tasks.
Complete one sub-task fully, then mark it done and move to the next.
Do NOT attempt all changes in a single pass."
fi
```

## Acceptance Criteria

- [ ] Tasks with 5+ files, 500+ words, or 2+ retries flagged for decomposition
- [ ] Decomposition guidance injected into agent context when flagged
- [ ] Historical duration data used when available
- [ ] Thresholds configurable via `.ralphrc`
- [ ] Warning logged for visibility

## Test Plan

```bash
@test "ralph_should_decompose detects multi-file tasks" {
    source "$RALPH_DIR/lib/context.sh"
    run ralph_should_decompose "Refactor auth.py, middleware.py, views.py, models.py, tests/test_auth.py, tests/test_views.py"
    assert_success  # Should decompose
}

@test "ralph_should_decompose passes simple tasks" {
    source "$RALPH_DIR/lib/context.sh"
    run ralph_should_decompose "Fix typo in README.md"
    assert_failure  # No decomposition needed
}
```

## References

- [Zylos — Long-Running AI Agents 2026](https://zylos.ai/research/2026-01-16-long-running-ai-agents)
- [Addy Osmani — Self-Improving Coding Agents](https://addyosmani.com/blog/self-improving-agents/)
