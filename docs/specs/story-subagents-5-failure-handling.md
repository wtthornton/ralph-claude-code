# Story RALPH-SUBAGENTS-5: Add Sub-agent Failure Handling and SubagentStop Hook

**Epic:** [Sub-agents](epic-subagents.md)
**Priority:** Important
**Status:** Open
**Effort:** Medium
**Component:** `.ralph/hooks/on-subagent-done.sh`, `.claude/agents/ralph.md`
**Depends on:** RALPH-SUBAGENTS-4, RALPH-HOOKS-2

---

## Problem

Sub-agents can fail for various reasons: API rate limits, context overflow, tool errors,
or exceeding `maxTurns`. If Ralph doesn't handle sub-agent failures gracefully, the
entire loop can stall or produce incomplete results.

Additionally, sub-agent completion events need to be logged for monitoring and debugging.
Sub-agent transcripts are stored at `~/.claude/projects/{project}/{sessionId}/subagents/`
but are not surfaced to Ralph's monitoring dashboard.

## Solution

1. Implement `.ralph/hooks/on-subagent-done.sh` (`SubagentStop` hook) to log sub-agent
   completion and detect failures.
2. Add failure handling instructions to ralph.md so the main agent degrades gracefully
   when sub-agents fail.

## Implementation

### on-subagent-done.sh

```bash
#!/bin/bash
# .ralph/hooks/on-subagent-done.sh
# SubagentStop hook. Logs sub-agent completion for monitoring.
#
# stdin: JSON with sub-agent result data
# Exit 0 = allow (normal)

set -euo pipefail

RALPH_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"
[[ -d "$RALPH_DIR" ]] || exit 0

INPUT=$(cat)

# Extract sub-agent info
agent_name=$(echo "$INPUT" | jq -r '.agent_name // .subagent_type // "unknown"' 2>/dev/null || echo "unknown")
agent_id=$(echo "$INPUT" | jq -r '.agent_id // "unknown"' 2>/dev/null || echo "unknown")
duration_ms=$(echo "$INPUT" | jq -r '.duration_ms // 0' 2>/dev/null || echo "0")
error=$(echo "$INPUT" | jq -r '.error // empty' 2>/dev/null || true)

# Calculate duration in seconds
duration_s=0
if [[ "$duration_ms" -gt 0 ]]; then
  duration_s=$((duration_ms / 1000))
fi

# Log completion
if [[ -n "$error" ]]; then
  echo "[$(date '+%H:%M:%S')] SUBAGENT FAILED: $agent_name (id=$agent_id) after ${duration_s}s — $error" \
    >> "$RALPH_DIR/live.log"
else
  echo "[$(date '+%H:%M:%S')] SUBAGENT DONE: $agent_name (id=$agent_id) in ${duration_s}s" \
    >> "$RALPH_DIR/live.log"
fi

exit 0
```

### Add failure handling to ralph.md

Append to the Sub-agents section:

```markdown
## Sub-agent Failure Handling

If a sub-agent fails or returns an error:

1. **ralph-explorer fails:** Fall back to in-context exploration using Glob/Grep/Read
   directly. Do not skip the search step — just do it yourself.

2. **ralph-tester fails:** Run tests yourself using Bash directly in the main context.
   Log the failure but don't block the task.

3. **ralph-reviewer fails:** Skip the review and proceed to commit. Log the failure.
   Code review is an optional quality gate, not a blocker.

**Never let a sub-agent failure stop the loop.** Degrade gracefully and continue.
```

### Key Design Decisions

1. **Logging to live.log:** Sub-agent events are visible in Ralph's monitoring dashboard
   (tmux pane). Operators can see which sub-agents ran, how long they took, and whether
   they failed.

2. **Graceful degradation:** Each sub-agent has an explicit fallback. Explorer falls
   back to in-context search. Tester falls back to in-context testing. Reviewer is
   skipped entirely.

3. **No exit 2 (blocking):** The SubagentStop hook should never block. Sub-agent
   completion is informational. The main agent handles failure logic.

4. **Duration tracking:** Logs how long each sub-agent took. Useful for identifying
   slow sub-agents or rate limit delays.

5. **Transcript location note:** Sub-agent transcripts at `~/.claude/projects/
   {project}/{sessionId}/subagents/agent-{agentId}.jsonl` can be inspected for
   post-mortem debugging. Not surfaced in the hook but available.

## Testing

```bash
@test "on-subagent-done.sh logs successful completion" {
  mkdir -p .ralph
  local input='{"agent_name": "ralph-tester", "agent_id": "abc123", "duration_ms": 15000}'
  echo "$input" | bash .ralph/hooks/on-subagent-done.sh

  grep -q "SUBAGENT DONE: ralph-tester" .ralph/live.log
  grep -q "15s" .ralph/live.log
}

@test "on-subagent-done.sh logs failure" {
  mkdir -p .ralph
  local input='{"agent_name": "ralph-explorer", "agent_id": "def456", "duration_ms": 5000, "error": "Rate limit exceeded"}'
  echo "$input" | bash .ralph/hooks/on-subagent-done.sh

  grep -q "SUBAGENT FAILED: ralph-explorer" .ralph/live.log
  grep -q "Rate limit exceeded" .ralph/live.log
}

@test "on-subagent-done.sh exits 0 in non-Ralph project" {
  CLAUDE_PROJECT_DIR="/nonexistent" bash .ralph/hooks/on-subagent-done.sh <<< '{}'
}
```

## Acceptance Criteria

- [ ] `on-subagent-done.sh` logs sub-agent name, ID, duration, and error (if any)
- [ ] Hook logs to `.ralph/live.log` for monitoring visibility
- [ ] Hook exits 0 in non-Ralph projects
- [ ] Hook exits 0 always (never blocks)
- [ ] ralph.md includes failure handling instructions for each sub-agent type
- [ ] Each sub-agent has an explicit fallback strategy
- [ ] Instructions emphasize "never let sub-agent failure stop the loop"
