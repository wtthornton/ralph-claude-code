# Story RALPH-HOOKS-2: Create Hooks Configuration in settings.json

**Epic:** [Hooks + Agent Definition](epic-hooks-agent-definition.md)
**Priority:** Critical
**Status:** Done
**Effort:** Medium
**Component:** `.claude/settings.json`

---

## Problem

Ralph v0.11.x has no integration with Claude Code's hook system. Response analysis,
file protection, and session context injection are all handled by bash code that runs
outside the Claude Code lifecycle. This means Ralph must parse raw CLI output after
the fact, rather than reacting to events as they occur.

## Solution

Create `.claude/settings.json` with hook declarations for all relevant lifecycle events.
Hook scripts live in `.ralph/hooks/` and are implemented in subsequent stories.

## Implementation

Create `.claude/settings.json`:

```jsonc
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/on-session-start.sh",
            "statusMessage": "Injecting Ralph loop context..."
          }
        ]
      }
    ],

    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/on-stop.sh",
            "statusMessage": "Analyzing Ralph response..."
          }
        ]
      }
    ],

    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/validate-command.sh",
            "statusMessage": "Validating command..."
          }
        ]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/protect-ralph-files.sh",
            "statusMessage": "Checking file protection..."
          }
        ]
      }
    ],

    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/on-file-change.sh"
          }
        ]
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/on-bash-command.sh"
          }
        ]
      }
    ],

    "SubagentStop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/on-subagent-done.sh"
          }
        ]
      }
    ],

    "StopFailure": [
      {
        "matcher": "rate_limit|server_error",
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/on-stop-failure.sh",
            "statusMessage": "Handling API error..."
          }
        ]
      }
    ]
  }
}
```

### Key Design Decisions

1. **`StopFailure` hook added:** The RFC only listed 6 hook events. Research shows
   `StopFailure` fires on rate limits and server errors — replacing Ralph's four-layer
   API limit detection with a single deterministic hook.

2. **`statusMessage` fields:** Provide UI feedback during hook execution. Helpful for
   debugging and monitoring.

3. **No `PermissionRequest` hooks:** These don't fire in non-interactive mode (`-p`),
   which Ralph uses. `PreToolUse` is the correct enforcement point.

4. **`matcher` patterns:** Use `|` for OR matching (e.g., `Edit|Write`). No regex needed.

5. **Hook scripts in `.ralph/hooks/`:** Keeps them with Ralph's managed project files.
   They are NOT in `.claude/` to avoid mixing platform config with hook implementations.

## Directory Structure

```
.ralph/
  hooks/
    on-session-start.sh      # SessionStart hook (RALPH-HOOKS-3)
    on-stop.sh               # Stop hook (RALPH-HOOKS-4)
    on-file-change.sh        # PostToolUse(Edit|Write)
    on-bash-command.sh       # PostToolUse(Bash) — logging
    validate-command.sh      # PreToolUse(Bash) (RALPH-HOOKS-5)
    protect-ralph-files.sh   # PreToolUse(Edit|Write) (RALPH-HOOKS-5)
    on-subagent-done.sh      # SubagentStop (RALPH-SUBAGENTS-5)
    on-stop-failure.sh       # StopFailure — API error handling
```

## Testing

```bash
@test "settings.json is valid JSON" {
  jq empty ".claude/settings.json"
}

@test "settings.json declares SessionStart hook" {
  jq -e '.hooks.SessionStart' ".claude/settings.json" >/dev/null
}

@test "settings.json declares Stop hook" {
  jq -e '.hooks.Stop' ".claude/settings.json" >/dev/null
}

@test "settings.json declares PreToolUse hooks" {
  local count
  count=$(jq '.hooks.PreToolUse | length' ".claude/settings.json")
  [[ "$count" -ge 2 ]]
}

@test "settings.json declares StopFailure hook" {
  jq -e '.hooks.StopFailure' ".claude/settings.json" >/dev/null
}

@test "all referenced hook scripts exist" {
  local scripts
  scripts=$(jq -r '.. | .command? // empty' ".claude/settings.json" | sed 's/^bash //')
  for script in $scripts; do
    [[ -f "$script" ]] || echo "MISSING: $script"
  done
}
```

## Acceptance Criteria

- [ ] `.claude/settings.json` exists with valid JSON
- [ ] All 7 hook events are declared (SessionStart, Stop, PreToolUse x2, PostToolUse x2, SubagentStop, StopFailure)
- [ ] All referenced hook script paths point to `.ralph/hooks/` directory
- [ ] `.ralph/hooks/` directory exists with placeholder scripts
- [ ] `statusMessage` fields set for user-facing hooks
- [ ] No JSONC comments in committed file (strip before commit)
