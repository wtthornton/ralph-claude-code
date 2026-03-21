# Story RALPH-HOOKS-1: Create ralph.md Custom Agent Definition

**Epic:** [Hooks + Agent Definition](epic-hooks-agent-definition.md)
**Priority:** Critical
**Status:** Done
**Effort:** Small
**Component:** `.claude/agents/ralph.md`

---

## Problem

Ralph v0.11.x uses `claude -p "$(cat PROMPT.md)"` with inline `--allowedTools` parsing.
Tool restrictions, model selection, and permission modes are all managed via bash string
manipulation in `ralph_loop.sh` (~80 lines for tool validation alone). This is fragile,
hard to test, and diverges from Claude Code's native agent model.

## Solution

Create `.claude/agents/ralph.md` — a custom agent definition that formalizes Ralph as
a first-class Claude Code agent. This replaces:
- `--allowedTools` parsing (~30 lines in `ralph_loop.sh`)
- Model pinning via CLI flags
- Permission mode via CLI flags
- `--append-system-prompt` context injection

## Implementation

Create `.claude/agents/ralph.md`:

```yaml
---
name: ralph
description: >
  Autonomous development agent. Works through fix_plan.md tasks one at a time.
  Reads instructions from .ralph/PROMPT.md. Reports status after each task.
tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash
  - Agent
  - TodoWrite
  - WebFetch
disallowedTools:
  - Bash(git clean *)
  - Bash(git rm *)
  - Bash(git reset --hard *)
  - Bash(rm -rf *)
model: opus
permissionMode: acceptEdits
maxTurns: 50
memory: project
effort: high
---

You are Ralph, an autonomous AI development agent. Your execution contract:

1. Read .ralph/fix_plan.md — identify the FIRST unchecked `- [ ]` item.
2. Search the codebase for existing implementations before writing new code.
3. If the task uses an external library API, look up docs before writing code.
4. Implement the smallest complete change for that task only.
5. Run lint/type/test verification for touched scope.
6. Update fix_plan.md: change `- [ ]` to `- [x]` for the completed item.
7. Commit implementation + fix_plan update together.
8. Output your RALPH_STATUS block.
9. **STOP. End your response immediately after the status block.**

## Rules
- ONE task per invocation. Do not batch.
- NEVER modify files in .ralph/ except fix_plan.md checkboxes.
- LIMIT testing to ~20% of effort. Prioritize implementation.
- Keep commits descriptive and focused.

## Status Reporting
At the end of your response, include:
---RALPH_STATUS---
STATUS: IN_PROGRESS | COMPLETE | BLOCKED
TASKS_COMPLETED_THIS_LOOP: <number>
FILES_MODIFIED: <number>
TESTS_STATUS: PASSING | FAILING | NOT_RUN
WORK_TYPE: IMPLEMENTATION | TESTING | DOCUMENTATION | REFACTORING
EXIT_SIGNAL: false | true
RECOMMENDATION: <one line summary>
---END_RALPH_STATUS---

EXIT_SIGNAL: true ONLY when every item in fix_plan.md is checked [x].
STATUS: COMPLETE ONLY when EXIT_SIGNAL is also true.
```

### Key Design Decisions

1. **`model: opus`** — Pinned at agent level. Overridable via `RALPH_AGENT_MODEL` env var
   or `.ralphrc` if the agent definition supports model override via CLI.

2. **`maxTurns: 50`** — Replaces bash timeout logic. Prevents runaway loops at the
   platform level.

3. **`memory: project`** — Gives Ralph persistent context across loop iterations.
   Memories stored in `.claude/agent-memory/ralph/`.

4. **`effort: high`** — Ensures thorough implementation without `max` cost overhead.

5. **`permissionMode: acceptEdits`** — Eliminates permission prompts for file edits.
   Bash commands still require tool-level approval via `tools` list.

6. **`disallowedTools`** — Blocks destructive git/rm commands at the agent level.
   Defense-in-depth with PreToolUse hooks (RALPH-HOOKS-5).

## Testing

```bash
# Validate agent YAML frontmatter is parseable
@test "ralph.md agent definition has valid frontmatter" {
  local agent_file=".claude/agents/ralph.md"
  [[ -f "$agent_file" ]]

  # Extract frontmatter (between --- delimiters)
  local frontmatter
  frontmatter=$(sed -n '/^---$/,/^---$/p' "$agent_file" | head -n -1 | tail -n +2)

  # Verify required fields
  echo "$frontmatter" | grep -q "name: ralph"
  echo "$frontmatter" | grep -q "model: opus"
  echo "$frontmatter" | grep -q "maxTurns:"
}

@test "ralph.md includes RALPH_STATUS template" {
  grep -q "RALPH_STATUS" ".claude/agents/ralph.md"
  grep -q "EXIT_SIGNAL" ".claude/agents/ralph.md"
}

@test "ralph.md disallows destructive commands" {
  grep -q "git clean" ".claude/agents/ralph.md"
  grep -q "git reset --hard" ".claude/agents/ralph.md"
  grep -q "rm -rf" ".claude/agents/ralph.md"
}
```

## Acceptance Criteria

- [ ] `.claude/agents/ralph.md` exists with valid YAML frontmatter
- [ ] `claude --agent ralph` launches successfully
- [ ] Tool restrictions match current `ALLOWED_TOOLS` defaults
- [ ] `disallowedTools` blocks destructive commands
- [ ] Agent prompt includes RALPH_STATUS template
- [ ] Agent prompt includes explicit STOP instruction
