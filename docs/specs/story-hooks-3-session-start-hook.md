# Story RALPH-HOOKS-3: Implement on-session-start.sh Hook

**Epic:** [Hooks + Agent Definition](epic-hooks-agent-definition.md)
**Priority:** Important
**Status:** Done
**Effort:** Small
**Component:** `.ralph/hooks/on-session-start.sh`

---

## Problem

Ralph v0.11.x injects loop context via `--append-system-prompt` (~40 lines in
`ralph_loop.sh`, `build_loop_context()` function at lines 850-920). This context
includes loop count, task progress, and circuit breaker state. With Claude Code hooks,
the `SessionStart` event can inject this context automatically.

## Solution

Implement `.ralph/hooks/on-session-start.sh` to replace `build_loop_context()`. The
hook reads Ralph state files and emits context to stderr, which Claude Code injects
into the session's system prompt.

### Hook Protocol (SessionStart)

- **stdin:** JSON with `{ "type": "SessionStart", "trigger": "startup|resume|clear|compact" }`
- **stdout:** JSON or ignored
- **stderr:** Text injected into Claude's context
- **Exit 0:** Allow session to proceed
- **Environment:** `CLAUDE_PROJECT_DIR` and `CLAUDE_ENV_FILE` available

## Implementation

```bash
#!/bin/bash
# .ralph/hooks/on-session-start.sh
# Replaces: build_loop_context() in ralph_loop.sh (lines 850-920)
#
# SessionStart hook. Reads loop state and emits context for Claude's system prompt.
# Exit 0 = allow session. stderr = inject into context.

set -euo pipefail

RALPH_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"

# Guard: only run if this is a Ralph-managed project
if [[ ! -d "$RALPH_DIR" ]]; then
  exit 0
fi

# Read current loop count
loop_count=0
if [[ -f "$RALPH_DIR/status.json" ]]; then
  loop_count=$(jq -r '.loop_count // 0' "$RALPH_DIR/status.json" 2>/dev/null || echo "0")
fi

# Read fix_plan completion status
total_tasks=0
done_tasks=0
if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
  total_tasks=$(grep -c '^\- \[' "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "0")
  done_tasks=$(grep -c '^\- \[x\]' "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "0")
fi
remaining=$((total_tasks - done_tasks))

# Read circuit breaker state
cb_state="CLOSED"
if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
  cb_state=$(jq -r '.state // "CLOSED"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "CLOSED")
fi

# Read last loop outcome (if available)
last_status=""
if [[ -f "$RALPH_DIR/status.json" ]]; then
  last_status=$(jq -r '.status // ""' "$RALPH_DIR/status.json" 2>/dev/null || echo "")
fi

# Clear per-loop file tracking
: > "$RALPH_DIR/.files_modified_this_loop" 2>/dev/null || true

# Emit context to stderr (injected into Claude's system prompt)
cat >&2 <<EOF
Ralph loop #$((loop_count + 1)). Tasks: $done_tasks/$total_tasks complete, $remaining remaining.
Circuit breaker: $cb_state.$([ -n "$last_status" ] && echo " Last loop: $last_status.")
Read .ralph/fix_plan.md and do the FIRST unchecked item.
EOF

exit 0
```

### Key Design Decisions

1. **`CLAUDE_PROJECT_DIR` usage:** Uses the hook-provided environment variable for
   reliable path resolution, with `.` fallback.

2. **Guard clause:** Exits cleanly if `.ralph/` doesn't exist. Prevents errors when
   hooks fire in non-Ralph projects.

3. **Per-loop file tracking reset:** Clears `.files_modified_this_loop` at session start
   so the PostToolUse hook (on-file-change.sh) can track modifications for this loop only.

4. **`set -euo pipefail`:** Strict mode. All hook scripts should use this to prevent
   silent failures.

5. **No stdout JSON output:** SessionStart hooks use stderr for context injection.
   Stdout is reserved for structured responses (not needed here).

## Testing

```bash
@test "on-session-start.sh emits loop context" {
  mkdir -p .ralph
  echo '{"loop_count": 5}' > .ralph/status.json
  printf '- [x] task 1\n- [ ] task 2\n- [ ] task 3\n' > .ralph/fix_plan.md
  echo '{"state": "CLOSED"}' > .ralph/.circuit_breaker_state

  local stderr_output
  stderr_output=$(echo '{}' | bash .ralph/hooks/on-session-start.sh 2>&1 >/dev/null)

  [[ "$stderr_output" == *"Ralph loop #6"* ]]
  [[ "$stderr_output" == *"1/3 complete"* ]]
  [[ "$stderr_output" == *"2 remaining"* ]]
  [[ "$stderr_output" == *"CLOSED"* ]]
}

@test "on-session-start.sh exits 0 without .ralph dir" {
  CLAUDE_PROJECT_DIR="/nonexistent" bash .ralph/hooks/on-session-start.sh
}

@test "on-session-start.sh clears per-loop file tracking" {
  mkdir -p .ralph
  echo "src/foo.py" > .ralph/.files_modified_this_loop
  echo '{}' | bash .ralph/hooks/on-session-start.sh 2>/dev/null
  [[ ! -s .ralph/.files_modified_this_loop ]]
}
```

## Acceptance Criteria

- [ ] Hook emits loop count, task progress, and circuit breaker state to stderr
- [ ] Hook exits 0 when `.ralph/` doesn't exist (non-Ralph projects)
- [ ] Hook clears per-loop file tracking
- [ ] Hook uses `CLAUDE_PROJECT_DIR` for path resolution
- [ ] Hook uses `set -euo pipefail` strict mode
- [ ] Last loop status included when available
