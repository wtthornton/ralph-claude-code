# RFC: Ralph v1.0 — Claude Code 2026 Native Feature Integration

**Status:** Draft
**Author:** TheStudio / tappt
**Date:** 2026-03-21
**Ralph Version:** v0.11.5 (baseline)
**Target Version:** v1.0.0
**Claude Code Baseline:** CLI v2.x (2026 feature set)

---

## 1. Executive Summary

Ralph v0.11.5 is a 5,870-line bash harness that wraps `claude -p <prompt>` in an
autonomous loop with rate limiting, circuit breaking, and response analysis. It was
designed for Claude Code circa late 2025 and uses none of the major 2026 platform
features: sub-agents, agent teams, hooks, custom agent definitions, skills, or
worktrees.

This spec defines how to integrate those features to:

1. **Replace fragile bash parsing** with deterministic Claude Code hooks
2. **Enable parallelism** via sub-agents and worktrees
3. **Formalize Ralph as a custom agent** with native memory and tool restrictions
4. **Create reusable skills** for common loop operations
5. **Support agent teams** for large fix plans

The result is a thinner bash orchestrator (~500 lines) backed by Claude Code's
native agent infrastructure, with higher reliability and parallel execution.

---

## 2. Problem Statement

### 2.1 Current Pain Points

| Problem | Root Cause | Impact |
|---------|-----------|--------|
| Fragile exit detection | 935-line `response_analyzer.sh` parses `---RALPH_STATUS---` blocks via regex/jq | False exits, missed completion |
| Single-threaded execution | One `claude -p` call per loop; no parallelism | Large fix plans (60+ tasks) take hours |
| Session drift | Session continuity via `--resume <id>` with manual ID tracking | Session hijacking risk (Issue #151) |
| Tool permission parsing | Bash string splitting of `ALLOWED_TOOLS` comma list | Shell injection surface, validation gaps |
| No persistent memory | Each loop starts fresh; context via `--append-system-prompt` only | Repeated codebase exploration |
| Circuit breaker fragility | Bash state files + jq parsing of `.circuit_breaker_state` | Race conditions, stale state |
| Timeout as only guard | `portable_timeout ${timeout_seconds}s` wraps entire CLI call | No per-tool or per-turn limits |

### 2.2 Available Claude Code 2026 Features (Unused)

| Feature | Available Since | Ralph Usage |
|---------|----------------|-------------|
| Custom agents (`.claude/agents/*.md`) | Early 2026 | None |
| Lifecycle hooks (30+ events) | Early 2026 | None |
| Skills (`.claude/skills/`) | Early 2026 | None |
| Sub-agent spawning (`Agent` tool) | Early 2026 | None |
| Agent teams (`CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`) | Mid 2026 | None |
| Git worktree isolation (`isolation: worktree`) | Early 2026 | None |
| Background agents (`background: true`) | Early 2026 | None |
| Inter-agent messaging (`SendMessage`) | Mid 2026 | None |
| Agent SDK (Python/TypeScript) | Early 2026 | None |
| `--agent <name>` CLI flag | Early 2026 | None |
| `maxTurns` per agent | Early 2026 | None |
| Agent-scoped MCP servers | Mid 2026 | None |
| Plan mode (`--permission-mode plan`) | Early 2026 | None |
| Persistent agent memory (`memory: project`) | Mid 2026 | None |

---

## 3. Proposed Architecture

### 3.1 High-Level Design

```
ralph (bash, ~500 lines)          Claude Code Native
================================  ====================================
Rate limiting (hourly counter)    .claude/agents/ralph.md (main agent)
tmux layout & monitoring          .claude/agents/ralph-explorer.md
Process lifecycle (start/stop)    .claude/agents/ralph-tester.md
.ralphrc config loading           .claude/agents/ralph-reviewer.md
CLI argument parsing              .claude/skills/ralph-loop/SKILL.md
                                  .claude/settings.json (hooks)
                                  Agent memory (project-scoped)
```

### 3.2 What Stays in Bash

The bash layer becomes a **thin orchestrator** responsible only for:

1. **Process lifecycle** — starting/stopping `claude --agent ralph`
2. **Rate limiting** — hourly call counter (`.call_count`, `.last_reset`)
3. **tmux layout** — 3-pane monitoring (loop, live output, status)
4. **CLI parsing** — `--calls`, `--monitor`, `--live`, `--timeout`, etc.
5. **Config loading** — `.ralphrc` sourcing and env var precedence

### 3.3 What Moves to Claude Code Native

| Current Bash Component | Lines | Replacement | Mechanism |
|------------------------|-------|-------------|-----------|
| `response_analyzer.sh` (exit detection) | 935 | `Stop` hook + `PostToolUse` hook | Deterministic shell hook |
| `circuit_breaker.sh` (stuck detection) | 475 | `Stop` hook + agent `maxTurns` | Hook + agent config |
| `file_protection.sh` (integrity check) | 58 | `PreToolUse` hook | Hook blocks destructive edits |
| Tool permission validation | ~80 | Agent `tools` field | Agent definition |
| Session continuity | ~60 | Agent `memory: project` | Native persistence |
| PROMPT.md injection | ~30 | Agent system prompt | Agent definition |
| Loop context (`--append-system-prompt`) | ~40 | Hook-injected context | `SessionStart` hook |
| Timeout management | 145 | `maxTurns` + hook timeout | Agent config |

**Estimated reduction:** ~1,800 lines of bash replaced by ~200 lines of agent/hook config.

---

## 4. Detailed Design

### 4.1 Custom Agent Definitions

#### 4.1.1 Main Agent: `ralph.md`

```yaml
# .claude/agents/ralph.md
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
---

You are Ralph, an autonomous AI development agent. Your execution contract:

1. Read .ralph/fix_plan.md — identify the FIRST unchecked `- [ ]` item.
2. Search the codebase for existing implementations before writing new code.
3. If the task uses an external library API, look up docs before writing code.
4. Implement the smallest complete change for that task only.
5. Run lint/type/test verification for touched scope.
6. Update fix_plan.md: change `- [ ]` to `- [x]` for the completed item.
7. Commit implementation + fix_plan update together.

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

**CLI invocation change:**

```bash
# Before (v0.11.5)
claude -p "$(cat .ralph/PROMPT.md)" \
  --output-format json \
  --allowedTools Write Read Edit Bash(git add *) ... \
  --resume "$session_id"

# After (v1.0)
claude --agent ralph \
  --output-format json
```

**Benefits:**
- Tool restrictions defined once in agent config, not parsed from `.ralphrc`
- `maxTurns: 50` replaces bash timeout logic
- `memory: project` gives Ralph persistent context across loops
- `model: opus` pinned at agent level
- `permissionMode: acceptEdits` eliminates permission prompts for file edits

#### 4.1.2 Explorer Agent: `ralph-explorer.md`

```yaml
# .claude/agents/ralph-explorer.md
---
name: ralph-explorer
description: >
  Fast, read-only codebase search. Use when Ralph needs to find files,
  understand existing implementations, or analyze code patterns.
  Spawned automatically when Ralph uses the Agent tool for exploration.
tools:
  - Read
  - Glob
  - Grep
model: haiku
maxTurns: 20
---

You are a fast codebase explorer. Your job:
1. Search for files, functions, classes, or patterns as requested.
2. Return concise, structured findings.
3. Do NOT modify any files. Read-only.
4. Summarize what you find — file paths, line numbers, key patterns.

Keep responses under 500 words. Lead with the answer.
```

**Usage pattern:** Ralph's main agent spawns this via the `Agent` tool when it needs
to search the codebase. Using `haiku` keeps it fast and cheap. Results return to
Ralph's main context without polluting it with intermediate search output.

#### 4.1.3 Tester Agent: `ralph-tester.md`

```yaml
# .claude/agents/ralph-tester.md
---
name: ralph-tester
description: >
  Run tests and validate changes. Use after Ralph implements a task
  to verify correctness. Can run pytest, npm test, ruff, mypy.
tools:
  - Read
  - Glob
  - Grep
  - Bash
model: sonnet
maxTurns: 15
isolation: worktree
---

You are a test runner. Your job:
1. Run the test suite for the scope specified (file, module, or full).
2. Run linting and type checking on changed files.
3. Report: pass/fail counts, specific failures, and recommended fixes.
4. Do NOT fix code yourself — only report findings.

Commands available:
- pytest (Python tests)
- ruff check . (Python lint)
- mypy src/ (Python types)
- cd frontend && npm test (Frontend tests)
- cd frontend && npm run typecheck (Frontend types)
```

**Usage pattern:** Spawned after each implementation task. `isolation: worktree`
ensures test runs don't interfere with Ralph's ongoing work.

#### 4.1.4 Reviewer Agent: `ralph-reviewer.md`

```yaml
# .claude/agents/ralph-reviewer.md
---
name: ralph-reviewer
description: >
  Code review specialist. Reviews Ralph's changes for quality, security,
  and correctness before commit. Read-only analysis.
tools:
  - Read
  - Glob
  - Grep
model: sonnet
maxTurns: 10
---

You are a code reviewer. Review the specified changes for:
1. Security vulnerabilities (OWASP top 10)
2. Code quality (naming, structure, complexity)
3. Correctness (logic errors, edge cases)
4. Style consistency with existing codebase

Output a structured review:
- PASS / FAIL (overall)
- Issues found (severity: critical/warning/info)
- Specific file:line references
```

### 4.2 Hooks Configuration

#### 4.2.1 Core Hooks

```jsonc
// .claude/settings.json (project-level, committed to repo)
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "startup",
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/on-session-start.sh"
          }
        ]
      }
    ],

    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/on-stop.sh"
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

    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/validate-command.sh"
          }
        ]
      },
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/protect-ralph-files.sh"
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
    ]
  }
}
```

#### 4.2.2 Hook Implementations

##### `on-session-start.sh` — Replace loop context injection

```bash
#!/bin/bash
# .ralph/hooks/on-session-start.sh
# Replaces: build_loop_context() in ralph_loop.sh (lines 850-920)
#
# Reads loop state and emits context for Claude's system prompt.
# Exit 0 = allow session, stderr = inject into context.

RALPH_DIR=".ralph"

# Read current loop count
loop_count=$(jq -r '.loop_count // 0' "$RALPH_DIR/status.json" 2>/dev/null || echo "0")

# Read fix_plan completion status
total_tasks=$(grep -c '^\- \[' "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "0")
done_tasks=$(grep -c '^\- \[x\]' "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "0")
remaining=$((total_tasks - done_tasks))

# Read circuit breaker state
cb_state=$(jq -r '.state // "CLOSED"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "CLOSED")

cat >&2 <<EOF
Ralph loop #$((loop_count + 1)). Tasks: $done_tasks/$total_tasks complete, $remaining remaining.
Circuit breaker: $cb_state.
Read .ralph/fix_plan.md and do the FIRST unchecked item.
EOF

exit 0
```

##### `on-stop.sh` — Replace response_analyzer.sh

```bash
#!/bin/bash
# .ralph/hooks/on-stop.sh
# Replaces: analyze_response() in lib/response_analyzer.sh (lines 1-935)
#
# Runs after every Claude response. Reads the response from stdin (JSON).
# Updates .ralph state files deterministically.
# Exit 0 = allow stop. Exit 2 = block stop (keep working).

INPUT=$(cat)
RALPH_DIR=".ralph"

# Extract RALPH_STATUS block from the response text
response_text=$(echo "$INPUT" | jq -r '.result // .content // ""' 2>/dev/null)

# Parse EXIT_SIGNAL
exit_signal=$(echo "$response_text" | grep -oP 'EXIT_SIGNAL:\s*\K(true|false)' | tail -1)
status=$(echo "$response_text" | grep -oP 'STATUS:\s*\K\w+' | tail -1)
tasks_done=$(echo "$response_text" | grep -oP 'TASKS_COMPLETED_THIS_LOOP:\s*\K\d+' | tail -1)
files_modified=$(echo "$response_text" | grep -oP 'FILES_MODIFIED:\s*\K\d+' | tail -1)
work_type=$(echo "$response_text" | grep -oP 'WORK_TYPE:\s*\K\w+' | tail -1)

# Update status.json
loop_count=$(jq -r '.loop_count // 0' "$RALPH_DIR/status.json" 2>/dev/null || echo "0")
loop_count=$((loop_count + 1))

cat > "$RALPH_DIR/status.json" <<EOF
{
  "timestamp": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "loop_count": $loop_count,
  "status": "${status:-UNKNOWN}",
  "exit_signal": "${exit_signal:-false}",
  "tasks_completed": ${tasks_done:-0},
  "files_modified": ${files_modified:-0},
  "work_type": "${work_type:-UNKNOWN}"
}
EOF

# Update circuit breaker — check for progress
if [[ "${files_modified:-0}" -gt 0 || "${tasks_done:-0}" -gt 0 ]]; then
  # Progress detected — reset no-progress counter
  jq '.no_progress_count = 0 | .state = "CLOSED"' \
    "$RALPH_DIR/.circuit_breaker_state" > "$RALPH_DIR/.circuit_breaker_state.tmp" \
    && mv "$RALPH_DIR/.circuit_breaker_state.tmp" "$RALPH_DIR/.circuit_breaker_state"
else
  # No progress — increment counter
  current=$(jq -r '.no_progress_count // 0' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "0")
  threshold=$(jq -r '.threshold // 3' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "3")
  new_count=$((current + 1))

  if [[ $new_count -ge $threshold ]]; then
    echo "Circuit breaker OPEN: $new_count loops with no progress" >&2
    jq ".no_progress_count = $new_count | .state = \"OPEN\"" \
      "$RALPH_DIR/.circuit_breaker_state" > "$RALPH_DIR/.circuit_breaker_state.tmp" \
      && mv "$RALPH_DIR/.circuit_breaker_state.tmp" "$RALPH_DIR/.circuit_breaker_state"
  else
    jq ".no_progress_count = $new_count" \
      "$RALPH_DIR/.circuit_breaker_state" > "$RALPH_DIR/.circuit_breaker_state.tmp" \
      && mv "$RALPH_DIR/.circuit_breaker_state.tmp" "$RALPH_DIR/.circuit_breaker_state"
  fi
fi

# Log for monitoring
echo "[$(date '+%H:%M:%S')] Loop $loop_count: status=$status exit=$exit_signal tasks=$tasks_done files=$files_modified" \
  >> "$RALPH_DIR/live.log"

exit 0
```

##### `validate-command.sh` — Replace ALLOWED_TOOLS parsing

```bash
#!/bin/bash
# .ralph/hooks/validate-command.sh
# Replaces: ALLOWED_TOOLS validation in ralph_loop.sh (lines 73-91)
#
# PreToolUse hook for Bash commands.
# Reads command from stdin JSON, blocks destructive operations.
# Exit 0 = allow, Exit 2 = block (stderr = reason shown to Claude).

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // ""')

# Block destructive git commands
case "$COMMAND" in
  *"git clean"*|*"git rm"*|*"git reset --hard"*|*"rm -rf"*|*"rm -r "*|*"> /dev/null"*)
    echo "BLOCKED: Destructive command not allowed: $COMMAND" >&2
    exit 2
    ;;
esac

# Block modification of .ralph/ infrastructure
if echo "$COMMAND" | grep -qE '(rm|mv|cp.*>)\s+\.ralph/'; then
  echo "BLOCKED: Cannot modify .ralph/ infrastructure via shell" >&2
  exit 2
fi

exit 0
```

##### `protect-ralph-files.sh` — Replace file_protection.sh

```bash
#!/bin/bash
# .ralph/hooks/protect-ralph-files.sh
# Replaces: lib/file_protection.sh (58 lines) + validate_ralph_integrity()
#
# PreToolUse hook for Edit/Write. Blocks edits to .ralph/ except fix_plan.md.
# Exit 0 = allow, Exit 2 = block.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')

# Allow fix_plan.md edits (Ralph checks off tasks)
if [[ "$FILE_PATH" == *".ralph/fix_plan.md" ]]; then
  exit 0
fi

# Block all other .ralph/ modifications
if [[ "$FILE_PATH" == *".ralph/"* || "$FILE_PATH" == *".ralphrc"* ]]; then
  echo "BLOCKED: Cannot modify Ralph infrastructure file: $FILE_PATH" >&2
  exit 2
fi

exit 0
```

##### `on-file-change.sh` — Track file modifications

```bash
#!/bin/bash
# .ralph/hooks/on-file-change.sh
# NEW: PostToolUse hook for Edit/Write.
# Tracks which files were modified per loop for progress detection.

INPUT=$(cat)
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // ""')
RALPH_DIR=".ralph"

# Append to per-loop file tracking
echo "$FILE_PATH" >> "$RALPH_DIR/.files_modified_this_loop"

exit 0
```

### 4.3 Skills

#### 4.3.1 Ralph Loop Skill

```yaml
# .claude/skills/ralph-loop/SKILL.md
---
name: ralph-loop
description: >
  Execute one Ralph development loop iteration. Reads fix_plan.md,
  implements the first unchecked task, verifies, and commits.
user-invocable: true
disable-model-invocation: false
allowed-tools: Read, Write, Edit, Glob, Grep, Bash, Agent
argument-hint: "[task description override]"
---

## Execution Contract

1. Read `.ralph/fix_plan.md` — find the FIRST unchecked `- [ ]` item.
   If `$ARGUMENTS` is provided, use that as the task override.
2. Search the codebase for existing implementations (use ralph-explorer agent).
3. If the task uses an external library API, look up docs first.
4. Implement the smallest complete change.
5. Run targeted verification (lint/type/test for touched scope).
6. Update fix_plan.md: `- [ ]` to `- [x]`.
7. Commit with descriptive message.
8. Report status in RALPH_STATUS block.

## Constraints
- ONE task only. Stop after completing it.
- LIMIT testing to ~20% of effort.
- NEVER modify .ralph/ files except fix_plan.md checkboxes.
- Use ralph-explorer for codebase search, ralph-tester for verification.
```

#### 4.3.2 Ralph Research Skill

```yaml
# .claude/skills/ralph-research/SKILL.md
---
name: ralph-research
description: >
  Research the codebase before implementing a task. Spawns parallel
  explorer agents to find relevant files, patterns, and existing code.
user-invocable: false
disable-model-invocation: false
context: fork
agent: ralph-explorer
---

Search the codebase for:
1. Files related to: $ARGUMENTS
2. Existing implementations that might conflict or be reusable
3. Test files that will need updating
4. Import dependencies that might be affected

Return a structured summary:
- Related files (path + relevance)
- Existing code to reuse (function/class + file)
- Tests to update
- Dependencies to consider
```

### 4.4 Agent Teams (Phase 2)

For large fix plans with independent tasks, Ralph can coordinate a team:

#### 4.4.1 Configuration

```jsonc
// .claude/settings.local.json (not committed — experimental)
{
  "env": {
    "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1"
  }
}
```

#### 4.4.2 Team Strategy

```
Ralph Lead (coordinator)
├── Teammate 1: Backend tasks (worktree: backend-work)
│   └── Owns: src/**/*.py files
├── Teammate 2: Frontend tasks (worktree: frontend-work)
│   └── Owns: frontend/**/*.{ts,tsx} files
└── Teammate 3: Test runner (read-only)
    └── Validates both teammates' changes
```

**Spawn pattern in PROMPT.md:**

```markdown
## Parallelism (when fix_plan has independent backend + frontend tasks)

When the fix plan contains BOTH backend and frontend tasks that are independent:
1. Create a team with 2 implementation teammates + 1 test runner
2. Assign backend tasks to Teammate 1 (model: sonnet, worktree)
3. Assign frontend tasks to Teammate 2 (model: sonnet, worktree)
4. Teammate 3 runs tests on both worktrees
5. Merge results when all teammates complete
```

#### 4.4.3 Team Hooks

```jsonc
{
  "hooks": {
    "TeammateIdle": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash .ralph/hooks/on-teammate-idle.sh"
          }
        ]
      }
    ]
  }
}
```

### 4.5 Worktree Integration

#### 4.5.1 Per-Agent Isolation

Agents that modify files get isolated worktrees:

```yaml
# In agent definition
isolation: worktree
```

This creates a branch like `worktree-ralph-tester-<hash>` that is cleaned up
automatically if no changes were made, or merged back if changes were committed.

#### 4.5.2 `.gitignore` Addition

```
# Ralph worktrees
.claude/worktrees/
```

### 4.6 Background Agents

#### 4.6.1 Non-Blocking Test Runner

```yaml
# .claude/agents/ralph-bg-tester.md
---
name: ralph-bg-tester
description: >
  Background test runner. Validates changes while Ralph continues
  implementing the next task. Returns results asynchronously.
tools:
  - Read
  - Glob
  - Grep
  - Bash
model: sonnet
maxTurns: 10
background: true
---

Run the test suite for the specified scope. Report results.
Do not fix failures — only report them.
```

**Usage in main loop:** Ralph spawns `ralph-bg-tester` after completing a task,
then immediately starts the next task. Test results arrive asynchronously and
Ralph checks them before committing the next task.

### 4.7 Inter-Agent Communication

#### 4.7.1 SendMessage Pattern

```
Ralph (main) ──spawn──> ralph-tester (subagent)
             <──result── "3/3 tests pass, lint clean"

Ralph (main) ──spawn──> ralph-explorer (subagent)
             <──result── "Found existing impl at src/context/enricher.py:42"

Ralph (main) ──SendMessage──> ralph-bg-tester (running)
             "Also check src/intent/builder.py — just modified it"
             <──result── "4/4 tests pass including new file"
```

### 4.8 Agent Memory

#### 4.8.1 Project-Scoped Memory

With `memory: project` in the agent definition, Ralph persists learnings:

```
Session 1: "src/verification uses signals.py for gate events"
Session 2: Ralph recalls this instead of re-exploring
```

**What to persist:**
- Codebase patterns discovered during exploration
- Build/test quirks (e.g., "mypy needs --ignore-missing-imports for NATS")
- Fix plan context (task dependencies, blockers)
- Previous loop outcomes

**What NOT to persist:**
- Ephemeral state (current task, loop count)
- Git history (use `git log`)
- File contents (read fresh each loop)

---

## 5. Migration Plan

### Phase 1: Hooks + Agent Definition (Low Risk)

**Goal:** Replace response parsing and file protection with hooks. Define Ralph as
a custom agent. No changes to loop control flow.

| Step | Change | Files | Risk |
|------|--------|-------|------|
| 1.1 | Create `.claude/agents/ralph.md` | New file | None |
| 1.2 | Create `.claude/settings.json` with hooks | New file | Low |
| 1.3 | Create `.ralph/hooks/` directory with hook scripts | New files | Low |
| 1.4 | Add `--agent ralph` to `build_claude_command()` | `ralph_loop.sh` ~5 lines | Low |
| 1.5 | Remove `--allowedTools` parsing (agent handles it) | `ralph_loop.sh` ~30 lines | Low |
| 1.6 | Keep `response_analyzer.sh` as fallback | No change | None |

**Verification:**
- All existing BATS tests pass
- Ralph completes a 3-task fix plan identically to v0.11.5
- Hook scripts fire (check `.ralph/live.log`)
- File protection blocks `.ralph/PROMPT.md` edits

**Rollback:** Remove `--agent ralph` flag; hooks are additive and don't break
existing flow.

### Phase 2: Sub-agents (Medium Risk)

**Goal:** Add explorer, tester, and reviewer sub-agents. Ralph spawns them via
the `Agent` tool during loops.

| Step | Change | Files | Risk |
|------|--------|-------|------|
| 2.1 | Create `ralph-explorer.md` agent | New file | None |
| 2.2 | Create `ralph-tester.md` agent | New file | None |
| 2.3 | Create `ralph-reviewer.md` agent | New file | None |
| 2.4 | Update `ralph.md` prompt to reference sub-agents | Edit agent | Low |
| 2.5 | Add `Agent` to ralph.md tools list | Edit agent | Low |

**Verification:**
- Ralph spawns explorer for codebase search (check logs)
- Tester runs in worktree without file conflicts
- Sub-agent results appear in Ralph's response

### Phase 3: Skills + Bash Reduction (Medium Risk)

**Goal:** Create reusable skills. Remove bash code that hooks now handle.

| Step | Change | Files | Risk |
|------|--------|-------|------|
| 3.1 | Create `ralph-loop` skill | New files | None |
| 3.2 | Create `ralph-research` skill | New files | None |
| 3.3 | Remove `response_analyzer.sh` (hooks handle it) | Delete 935 lines | Medium |
| 3.4 | Remove `file_protection.sh` (hooks handle it) | Delete 58 lines | Low |
| 3.5 | Simplify `circuit_breaker.sh` (hooks provide data) | Edit ~200 lines | Medium |

**Verification:**
- `npm test` — existing BATS tests adapted for new structure
- Ralph loop completes 5-task fix plan
- Circuit breaker triggers on stuck loop (test with empty fix plan)

### Phase 4: Agent Teams + Parallelism (Higher Risk, Experimental)

**Goal:** Enable parallel execution for large fix plans.

| Step | Change | Files | Risk |
|------|--------|-------|------|
| 4.1 | Add team env var to settings | `.claude/settings.local.json` | Low |
| 4.2 | Update `ralph.md` with team spawning instructions | Edit agent | Medium |
| 4.3 | Add `TeammateIdle` hook | `.claude/settings.json` | Low |
| 4.4 | Create `ralph-bg-tester.md` background agent | New file | Low |
| 4.5 | Add worktree support to `.gitignore` | Edit `.gitignore` | None |

**Verification:**
- 2-teammate run completes independent tasks in parallel
- No file conflicts between worktrees
- Merged results are correct
- Background tester returns results

---

## 6. File Manifest

### New Files

```
.claude/
  agents/
    ralph.md                    # Main agent definition
    ralph-explorer.md           # Fast codebase search (haiku)
    ralph-tester.md             # Test runner (sonnet, worktree)
    ralph-reviewer.md           # Code review (sonnet)
    ralph-bg-tester.md          # Background test runner (Phase 4)
  skills/
    ralph-loop/
      SKILL.md                  # Per-loop execution contract
    ralph-research/
      SKILL.md                  # Codebase research skill
  settings.json                 # Hooks configuration

.ralph/
  hooks/
    on-session-start.sh         # SessionStart hook
    on-stop.sh                  # Stop hook (replaces response_analyzer)
    on-file-change.sh           # PostToolUse(Edit|Write) hook
    on-bash-command.sh          # PostToolUse(Bash) hook — logging
    validate-command.sh         # PreToolUse(Bash) hook — block destructive
    protect-ralph-files.sh      # PreToolUse(Edit|Write) hook
    on-subagent-done.sh         # SubagentStop hook
    on-teammate-idle.sh         # TeammateIdle hook (Phase 4)
```

### Modified Files

```
ralph_loop.sh                   # Add --agent ralph, remove tool parsing
lib/response_analyzer.sh        # Deprecate (Phase 3 removal)
lib/file_protection.sh          # Deprecate (Phase 3 removal)
lib/circuit_breaker.sh          # Simplify (hooks provide state)
.gitignore                      # Add .claude/worktrees/
```

### Deleted Files (Phase 3)

```
lib/response_analyzer.sh        # -935 lines (replaced by on-stop.sh hook)
lib/file_protection.sh          # -58 lines (replaced by protect-ralph-files.sh hook)
```

---

## 7. Configuration Changes

### 7.1 `.ralphrc` Updates

New fields for v1.0:

```bash
# .ralphrc additions for v1.0

# =============================================================================
# AGENT CONFIGURATION (v1.0)
# =============================================================================

# Use custom agent definition instead of raw -p prompt
RALPH_USE_AGENT=true
RALPH_AGENT_NAME="ralph"

# Sub-agent model overrides (default: defined in agent .md files)
# RALPH_EXPLORER_MODEL="haiku"
# RALPH_TESTER_MODEL="sonnet"
# RALPH_REVIEWER_MODEL="sonnet"

# =============================================================================
# PARALLELISM (v1.0 Phase 4)
# =============================================================================

# Enable agent teams for parallel execution
RALPH_ENABLE_TEAMS=false
RALPH_MAX_TEAMMATES=3

# Background testing
RALPH_BG_TESTING=false
```

### 7.2 Environment Variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `RALPH_USE_AGENT` | `true` | Use `--agent ralph` instead of `-p` |
| `RALPH_AGENT_NAME` | `ralph` | Agent definition to use |
| `RALPH_ENABLE_TEAMS` | `false` | Enable agent teams |
| `RALPH_MAX_TEAMMATES` | `3` | Max parallel teammates |
| `RALPH_BG_TESTING` | `false` | Background test runner |
| `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS` | unset | Claude Code team feature flag |

---

## 8. Testing Strategy

### 8.1 Existing Test Adaptation

All 566 existing BATS tests should continue to pass. Tests that validate
`response_analyzer.sh` output can be retained as regression tests for the
`on-stop.sh` hook (same output format, different trigger mechanism).

### 8.2 New Tests

| Test File | Tests | Coverage |
|-----------|-------|----------|
| `test_hooks.bats` | 15 | Hook scripts: input parsing, exit codes, state updates |
| `test_agent_definition.bats` | 8 | Agent YAML validation, tool lists, model config |
| `test_file_protection_hook.bats` | 10 | PreToolUse blocking for .ralph/ files |
| `test_command_validation_hook.bats` | 12 | PreToolUse blocking for destructive commands |
| `test_stop_hook.bats` | 15 | Status parsing, circuit breaker updates |
| `test_agent_mode_cli.bats` | 8 | `--agent ralph` flag in build_claude_command |
| `test_subagent_integration.bats` | 6 | Explorer/tester spawn and result handling |

**Total new tests:** ~74
**Target total:** 640+

### 8.3 Integration Test Scenarios

```bash
# Scenario 1: Hook-based exit detection
# Setup: 1-task fix_plan, agent completes task
# Verify: on-stop.sh writes status.json with EXIT_SIGNAL=true

# Scenario 2: File protection
# Setup: Agent attempts to edit .ralph/PROMPT.md
# Verify: PreToolUse hook blocks with exit 2, agent receives error

# Scenario 3: Circuit breaker via hooks
# Setup: Empty fix_plan, agent produces no file changes for 3 loops
# Verify: on-stop.sh increments no_progress_count, circuit opens

# Scenario 4: Sub-agent exploration
# Setup: Task requires finding existing implementation
# Verify: ralph-explorer spawned, results returned to main agent

# Scenario 5: Parallel execution (Phase 4)
# Setup: 4-task fix_plan with 2 backend + 2 frontend tasks
# Verify: 2 teammates complete tasks in parallel, no conflicts
```

---

## 9. Compatibility & Backwards Compatibility

### 9.1 Fallback Mode

If `RALPH_USE_AGENT=false` in `.ralphrc`, Ralph v1.0 falls back to v0.11.5
behavior: `-p "$(cat PROMPT.md)"` with `--allowedTools` parsing.

### 9.2 Claude Code Version Requirements

| Feature | Min CLI Version | Graceful Degradation |
|---------|----------------|---------------------|
| `--agent` flag | 2.1+ | Fall back to `-p` |
| Hooks | 2.1+ | Skip hooks, use response_analyzer |
| Sub-agents | 2.1+ | Skip, run single-threaded |
| Agent teams | 2.2+ (experimental) | Disabled by default |
| Worktrees | 2.1+ | Skip isolation |
| Agent memory | 2.2+ | Use session continuity |

### 9.3 Version Detection

```bash
# In ralph_loop.sh
check_agent_support() {
  local version
  version=$(claude --version 2>/dev/null | grep -oP '\d+\.\d+' | head -1)
  if [[ $(echo "$version >= 2.1" | bc -l 2>/dev/null) == "1" ]]; then
    return 0  # Agent mode supported
  fi
  return 1  # Fall back to legacy mode
}
```

---

## 10. Cost & Performance Impact

### 10.1 Token Usage

| Component | v0.11.5 (current) | v1.0 (proposed) | Delta |
|-----------|-------------------|-----------------|-------|
| Main agent prompt | ~2,000 tokens | ~1,500 tokens | -25% (cleaner prompt) |
| Codebase search | In-context (expensive) | Sub-agent (isolated) | -40% main context |
| Test output | In-context | Sub-agent (worktree) | -30% main context |
| Loop context injection | ~200 tokens/loop | Hook-injected | ~Same |
| Total per loop | ~15,000 tokens | ~12,000 tokens | -20% estimated |

### 10.2 API Calls

| Mode | Calls per Fix Plan Task | Notes |
|------|------------------------|-------|
| v0.11.5 (single-threaded) | 1 main call | Everything in one context |
| v1.0 (with sub-agents) | 1 main + 1-2 sub-agents | More calls, but smaller/cheaper |
| v1.0 (with teams, Phase 4) | 2-3 parallel calls | Faster wall-clock time |

### 10.3 Wall-Clock Time (Estimated)

| Fix Plan Size | v0.11.5 | v1.0 (sub-agents) | v1.0 (teams) |
|---------------|---------|-------------------|--------------|
| 5 tasks | 25 min | 20 min | 15 min |
| 15 tasks | 75 min | 55 min | 30 min |
| 60 tasks | 300 min | 220 min | 90 min |

---

## 11. Risks & Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Hook scripts fail silently | Medium | High | Log all hook invocations, test in CI |
| Agent memory grows unbounded | Low | Medium | Periodic pruning, memory TTL |
| Sub-agent context too narrow | Medium | Medium | Tune system prompts iteratively |
| Team file conflicts | Medium | High | Strict file ownership per teammate |
| Claude Code CLI changes break hooks | Low | High | Version detection + fallback mode |
| Worktree merge conflicts | Low | Medium | Independent file sets per teammate |
| `--agent` flag not in installed CLI | Low | High | `check_agent_support()` fallback |

---

## 12. Success Criteria

### Phase 1 (Hooks + Agent)
- [ ] Ralph completes a 5-task fix plan using `--agent ralph`
- [ ] All 566 existing BATS tests pass
- [ ] Hook scripts fire on every Stop/PreToolUse/PostToolUse event
- [ ] File protection hook blocks `.ralph/PROMPT.md` modification
- [ ] `on-stop.sh` writes correct `status.json` after every loop
- [ ] Fallback to `-p` mode works when `RALPH_USE_AGENT=false`

### Phase 2 (Sub-agents)
- [ ] `ralph-explorer` spawns and returns codebase search results
- [ ] `ralph-tester` runs in worktree without file conflicts
- [ ] `ralph-reviewer` produces structured code review
- [ ] Main agent context reduced by 30%+ (measured via `/cost`)
- [ ] Sub-agent failures don't crash the main loop

### Phase 3 (Skills + Reduction)
- [ ] `ralph_loop.sh` reduced to <600 lines
- [ ] `response_analyzer.sh` removed (hooks handle all parsing)
- [ ] `file_protection.sh` removed (hooks handle protection)
- [ ] 640+ BATS tests pass (74 new)
- [ ] No regressions in exit detection accuracy

### Phase 4 (Teams + Parallelism)
- [ ] 2-teammate run completes 4 independent tasks
- [ ] Wall-clock time reduced by 40%+ vs single-threaded
- [ ] No file conflicts between worktrees
- [ ] Background tester reports results while main agent works
- [ ] Team gracefully handles teammate failure

---

## 13. Open Questions

1. **Hook stdin format:** Does the `Stop` hook receive the full Claude response
   JSON on stdin, or only metadata? Need to verify with Claude Code docs.

2. **Agent memory scope:** Does `memory: project` persist across `--agent ralph`
   invocations, or only within a single `claude` process lifetime?

3. **Worktree branch naming:** Can we control the branch name for teammate
   worktrees, or is it always `worktree-<agent>-<hash>`?

4. **Rate limiting interaction:** Do sub-agent calls count against the same
   Anthropic API rate limit as the main agent, or are they independent?

5. **Hook execution order:** When multiple hooks match the same event (e.g.,
   two `PreToolUse` hooks for `Bash`), do they run sequentially or can one
   short-circuit?

6. **Agent SDK alternative:** Should Ralph v2.0 be rewritten as a Python/TypeScript
   Agent SDK application instead of a bash wrapper? This would give programmatic
   control over agent spawning, messaging, and result handling.

---

## 14. References

- [Claude Code Agents Documentation](https://docs.anthropic.com/en/docs/claude-code/agents)
- [Claude Code Hooks Documentation](https://docs.anthropic.com/en/docs/claude-code/hooks)
- [Claude Code Skills Documentation](https://docs.anthropic.com/en/docs/claude-code/skills)
- [Agent SDK Documentation](https://docs.anthropic.com/en/docs/claude-code/agent-sdk)
- [Ralph v0.11.5 README](https://github.com/frankbria/ralph-claude-code/blob/main/README.md)
- [Ralph CLAUDE.md](https://github.com/frankbria/ralph-claude-code/blob/main/CLAUDE.md)
- [Ralph Implementation Status](https://github.com/frankbria/ralph-claude-code/blob/main/IMPLEMENTATION_STATUS.md)
