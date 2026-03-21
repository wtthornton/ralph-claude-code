# Story RALPH-TEAMS-4: Add TeammateIdle and TaskCompleted Hooks

**Epic:** [Agent Teams + Parallelism](epic-agent-teams-parallelism.md)
**Priority:** Important
**Status:** Done
**Effort:** Small
**Component:** `.claude/settings.json`, `.ralph/hooks/on-teammate-idle.sh`
**Depends on:** RALPH-TEAMS-1

---

## Problem

When agent teams are enabled, teammates can go idle (waiting for work) or complete
tasks prematurely. Without hooks, these events are invisible to Ralph's monitoring
system and can't be controlled.

## Solution

Add `TeammateIdle` and `TaskCompleted` hooks to the settings.json configuration.
Implement hook scripts that log team events and optionally control teammate behavior.

## Implementation

### Add to .claude/settings.json

```jsonc
{
  "hooks": {
    // ... existing hooks ...

    "TeammateIdle": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/on-teammate-idle.sh",
            "statusMessage": "Checking teammate work queue..."
          }
        ]
      }
    ],

    "TaskCompleted": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/on-task-completed.sh",
            "statusMessage": "Validating task completion..."
          }
        ]
      }
    ]
  }
}
```

### on-teammate-idle.sh

```bash
#!/bin/bash
# .ralph/hooks/on-teammate-idle.sh
# TeammateIdle hook. Fires when a teammate is about to go idle.
#
# Exit 0 = allow idle (teammate stops)
# Exit 2 = keep working (teammate continues — e.g., assign more tasks)

set -euo pipefail

RALPH_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"
[[ -d "$RALPH_DIR" ]] || exit 0

INPUT=$(cat)
teammate_name=$(echo "$INPUT" | jq -r '.teammate_name // "unknown"' 2>/dev/null || echo "unknown")

# Check if there are remaining tasks in fix_plan
remaining=0
if [[ -f "$RALPH_DIR/fix_plan.md" ]]; then
  total=$(grep -c '^\- \[' "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "0")
  done=$(grep -c '^\- \[x\]' "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "0")
  remaining=$((total - done))
fi

# Log the event
echo "[$(date '+%H:%M:%S')] TEAMMATE IDLE: $teammate_name (${remaining} tasks remaining)" \
  >> "$RALPH_DIR/live.log"

# If tasks remain, could potentially reassign — but for now, allow idle
# Future enhancement: check if any remaining tasks match this teammate's scope
exit 0
```

### on-task-completed.sh

```bash
#!/bin/bash
# .ralph/hooks/on-task-completed.sh
# TaskCompleted hook. Fires when a task is marked complete.
#
# Exit 0 = allow completion
# Exit 2 = prevent completion (e.g., validation failed)

set -euo pipefail

RALPH_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"
[[ -d "$RALPH_DIR" ]] || exit 0

INPUT=$(cat)
task_description=$(echo "$INPUT" | jq -r '.task_description // "unknown"' 2>/dev/null || echo "unknown")

# Log the completion
echo "[$(date '+%H:%M:%S')] TASK COMPLETED: $task_description" \
  >> "$RALPH_DIR/live.log"

# Allow completion
exit 0
```

### Key Design Decisions

1. **TeammateIdle exits 0 (allow idle):** For the initial implementation, teammates
   are allowed to go idle when done. Future enhancement: check remaining tasks and
   reassign work.

2. **TaskCompleted exits 0 (allow completion):** No validation blocking for now.
   Could be enhanced to run tests before allowing task completion.

3. **Logging to live.log:** Both hooks log to the same monitoring file. Operators
   can see team activity in the tmux dashboard.

4. **Remaining tasks check:** TeammateIdle logs how many tasks are left. Useful for
   monitoring parallelism efficiency.

## Testing

```bash
@test "on-teammate-idle.sh logs idle event" {
  mkdir -p .ralph
  printf '- [x] task 1\n- [ ] task 2\n' > .ralph/fix_plan.md

  echo '{"teammate_name": "backend"}' | bash .ralph/hooks/on-teammate-idle.sh

  grep -q "TEAMMATE IDLE: backend" .ralph/live.log
  grep -q "1 tasks remaining" .ralph/live.log
}

@test "on-task-completed.sh logs completion" {
  mkdir -p .ralph
  echo '{"task_description": "Fix auth middleware"}' | bash .ralph/hooks/on-task-completed.sh

  grep -q "TASK COMPLETED: Fix auth middleware" .ralph/live.log
}

@test "on-teammate-idle.sh exits 0 in non-Ralph project" {
  CLAUDE_PROJECT_DIR="/nonexistent" bash .ralph/hooks/on-teammate-idle.sh <<< '{}'
}
```

## Acceptance Criteria

- [ ] `TeammateIdle` hook declared in `.claude/settings.json`
- [ ] `TaskCompleted` hook declared in `.claude/settings.json`
- [ ] `on-teammate-idle.sh` logs teammate name and remaining task count
- [ ] `on-task-completed.sh` logs task description
- [ ] Both hooks exit 0 in non-Ralph projects
- [ ] Both hooks log to `.ralph/live.log`
