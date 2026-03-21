# Story RALPH-HOOKS-5: Implement File Protection PreToolUse Hooks

**Epic:** [Hooks + Agent Definition](epic-hooks-agent-definition.md)
**Priority:** Important
**Status:** Done
**Effort:** Small
**Component:** `.ralph/hooks/validate-command.sh`, `.ralph/hooks/protect-ralph-files.sh`

---

## Problem

Ralph v0.11.x uses three layers for file protection:
1. `ALLOWED_TOOLS` restrictions (bash string splitting, ~80 lines)
2. PROMPT.md warnings (instruction-level, not enforced)
3. `validate_ralph_integrity()` in `lib/file_protection.sh` (58 lines, pre-loop check)

These are all reactive or advisory. Claude Code's `PreToolUse` hooks provide
**preventive** enforcement — blocking destructive operations before they execute.

## Solution

Implement two PreToolUse hook scripts:
1. `validate-command.sh` — Blocks destructive bash commands
2. `protect-ralph-files.sh` — Blocks edits to `.ralph/` infrastructure files

### Hook Protocol (PreToolUse)

- **stdin:** JSON with `{ "type": "PreToolUse", "tool_name": "Bash|Edit|Write", "tool_input": { ... } }`
- **stdout:** JSON with `permissionDecision` (optional, exit 0 allows by default)
- **stderr:** Reason text shown to Claude when blocking
- **Exit 0:** Allow tool execution
- **Exit 2:** Block tool execution (stderr fed back to Claude)

## Implementation

### validate-command.sh

```bash
#!/bin/bash
# .ralph/hooks/validate-command.sh
# Replaces: ALLOWED_TOOLS validation in ralph_loop.sh (lines 73-91)
#
# PreToolUse hook for Bash commands.
# Reads command from stdin JSON, blocks destructive operations.

set -euo pipefail

RALPH_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"
[[ -d "$RALPH_DIR" ]] || exit 0

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Block destructive git commands
case "$COMMAND" in
  *"git clean"*|*"git rm"*|*"git reset --hard"*|*"git push --force"*|*"git push -f"*)
    echo "BLOCKED: Destructive git command not allowed: $COMMAND" >&2
    exit 2
    ;;
esac

# Block destructive file operations
case "$COMMAND" in
  *"rm -rf"*|*"rm -r "*|*"rm -fr"*)
    echo "BLOCKED: Recursive delete not allowed: $COMMAND" >&2
    exit 2
    ;;
esac

# Block modification of .ralph/ infrastructure via shell
if echo "$COMMAND" | grep -qE '(rm|mv|cp\s.*>|>)\s+(\./)?\.ralph/'; then
  echo "BLOCKED: Cannot modify .ralph/ infrastructure via shell: $COMMAND" >&2
  exit 2
fi

# Block modification of .claude/ config via shell
if echo "$COMMAND" | grep -qE '(rm|mv|cp\s.*>|>)\s+(\./)?\.claude/'; then
  echo "BLOCKED: Cannot modify .claude/ config via shell: $COMMAND" >&2
  exit 2
fi

exit 0
```

### protect-ralph-files.sh

```bash
#!/bin/bash
# .ralph/hooks/protect-ralph-files.sh
# Replaces: lib/file_protection.sh (58 lines) + validate_ralph_integrity()
#
# PreToolUse hook for Edit/Write. Blocks edits to .ralph/ except fix_plan.md.

set -euo pipefail

RALPH_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"
[[ -d "$RALPH_DIR" ]] || exit 0

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

# Normalize path (remove leading ./ if present)
FILE_PATH="${FILE_PATH#./}"

# Allow fix_plan.md edits (Ralph checks off tasks)
if [[ "$FILE_PATH" == *".ralph/fix_plan.md" ]]; then
  exit 0
fi

# Allow status.json updates (hooks write this)
if [[ "$FILE_PATH" == *".ralph/status.json" ]]; then
  exit 0
fi

# Block all other .ralph/ modifications
if [[ "$FILE_PATH" == *".ralph/"* ]]; then
  echo "BLOCKED: Cannot modify Ralph infrastructure file: $FILE_PATH" >&2
  echo "Only .ralph/fix_plan.md checkboxes may be updated by the agent." >&2
  exit 2
fi

# Block .ralphrc modifications
if [[ "$FILE_PATH" == *".ralphrc"* ]]; then
  echo "BLOCKED: Cannot modify Ralph configuration: $FILE_PATH" >&2
  exit 2
fi

exit 0
```

### Key Design Decisions

1. **Two separate hooks:** Split by concern. `validate-command.sh` handles Bash commands;
   `protect-ralph-files.sh` handles Edit/Write. This matches the `PreToolUse` matcher
   pattern (`Bash` vs `Edit|Write`).

2. **`.claude/` protection added:** The RFC only protected `.ralph/`. Research shows
   `.claude/settings.json` and agent definitions should also be protected from
   accidental modification by the agent.

3. **`git push --force` blocked:** Not in the original RFC but a critical safety measure.
   Defense-in-depth with `disallowedTools` in the agent definition.

4. **`status.json` allowed:** The `on-stop.sh` hook writes this. Must not be blocked.

5. **Path normalization:** Strips leading `./` to handle both `./ralph/fix_plan.md`
   and `.ralph/fix_plan.md` consistently.

## Testing

```bash
@test "validate-command.sh blocks git clean" {
  echo '{"tool_input": {"command": "git clean -fd"}}' | \
    run bash .ralph/hooks/validate-command.sh
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "validate-command.sh allows git add" {
  echo '{"tool_input": {"command": "git add src/main.py"}}' | \
    run bash .ralph/hooks/validate-command.sh
  [[ "$status" -eq 0 ]]
}

@test "validate-command.sh blocks rm -rf" {
  echo '{"tool_input": {"command": "rm -rf src/"}}' | \
    run bash .ralph/hooks/validate-command.sh
  [[ "$status" -eq 2 ]]
}

@test "protect-ralph-files.sh allows fix_plan.md edits" {
  echo '{"tool_input": {"file_path": ".ralph/fix_plan.md"}}' | \
    run bash .ralph/hooks/protect-ralph-files.sh
  [[ "$status" -eq 0 ]]
}

@test "protect-ralph-files.sh blocks PROMPT.md edits" {
  echo '{"tool_input": {"file_path": ".ralph/PROMPT.md"}}' | \
    run bash .ralph/hooks/protect-ralph-files.sh
  [[ "$status" -eq 2 ]]
  [[ "$output" == *"BLOCKED"* ]]
}

@test "protect-ralph-files.sh blocks .ralphrc edits" {
  echo '{"tool_input": {"file_path": ".ralphrc"}}' | \
    run bash .ralph/hooks/protect-ralph-files.sh
  [[ "$status" -eq 2 ]]
}

@test "protect-ralph-files.sh allows normal file edits" {
  echo '{"tool_input": {"file_path": "src/main.py"}}' | \
    run bash .ralph/hooks/protect-ralph-files.sh
  [[ "$status" -eq 0 ]]
}
```

## Acceptance Criteria

- [ ] `validate-command.sh` blocks `git clean`, `git rm`, `git reset --hard`, `rm -rf`, `git push --force`
- [ ] `validate-command.sh` allows normal git/bash commands
- [ ] `validate-command.sh` blocks shell modification of `.ralph/` and `.claude/`
- [ ] `protect-ralph-files.sh` allows `.ralph/fix_plan.md` edits
- [ ] `protect-ralph-files.sh` blocks all other `.ralph/` file edits
- [ ] `protect-ralph-files.sh` blocks `.ralphrc` edits
- [ ] Both hooks exit 0 in non-Ralph projects
- [ ] Both hooks use `set -euo pipefail` strict mode
- [ ] Error messages are descriptive (shown to Claude as feedback)
