# Story RALPH-SUBAGENTS-3: Create ralph-reviewer.md Agent Definition

**Epic:** [Sub-agents](epic-subagents.md)
**Priority:** Nice-to-have
**Status:** Open
**Effort:** Small
**Component:** `.claude/agents/ralph-reviewer.md`

---

## Problem

Ralph v0.11.x has no automated code review step. Changes are committed immediately
after implementation and testing. Code quality, security vulnerabilities, and style
consistency are only caught by manual review or CI pipelines after the fact.

## Solution

Create `.claude/agents/ralph-reviewer.md` — a read-only code review agent that
analyzes Ralph's changes before commit. Provides structured feedback on security,
quality, correctness, and style.

## Implementation

```yaml
# .claude/agents/ralph-reviewer.md
---
name: ralph-reviewer
description: >
  Code review specialist. Reviews Ralph's changes for quality, security,
  and correctness before commit. Read-only analysis — does not modify files.
tools:
  - Read
  - Glob
  - Grep
model: sonnet
maxTurns: 10
effort: medium
---

You are a code reviewer analyzing changes made by Ralph. Review for:

1. **Security** — OWASP top 10 vulnerabilities (injection, XSS, auth issues)
2. **Correctness** — Logic errors, edge cases, off-by-one, null handling
3. **Quality** — Naming, structure, complexity, DRY violations
4. **Style** — Consistency with existing codebase patterns

## Input

You will be given a description of changed files. Read the current state of those
files and review the changes.

## Output Format

```
## Review: PASS | FAIL

### Critical Issues (must fix before commit)
- `file:line` — [SECURITY|CORRECTNESS] description

### Warnings (should fix)
- `file:line` — [QUALITY|STYLE] description

### Info (optional improvements)
- `file:line` — description

### Summary
<1-2 sentences: overall assessment>
```

Rules:
- FAIL only for Critical issues (security vulnerabilities, logic errors)
- Keep review focused on the changed files, not the entire codebase
- Reference specific file:line locations
- Don't suggest refactors beyond the scope of the change
- If everything looks good, say PASS and move on quickly
```

### Key Design Decisions

1. **`model: sonnet`** — Code review needs reasoning capability but not Opus-level.
   Sonnet catches most security and correctness issues.

2. **Read-only** — No Write/Edit/Bash tools. The reviewer cannot modify code.
   This is a safety constraint — reviews should inform, not act.

3. **`maxTurns: 10`** — Reviews should be quick. Reading changed files and
   producing output shouldn't take many turns.

4. **PASS/FAIL binary** — Clear signal for Ralph to act on. FAIL = fix before commit.
   PASS = safe to commit.

5. **Scope limitation** — Prompt explicitly says "don't suggest refactors beyond
   the scope of the change." Prevents review scope creep.

## Usage Pattern

Ralph spawns the reviewer after implementation and testing:

```
Agent(ralph-reviewer, "Review changes in src/auth/middleware.py and src/auth/tokens.py for the session token migration task")
```

If review returns FAIL with critical issues, Ralph fixes them before committing.
If PASS, Ralph proceeds to commit.

## Testing

```bash
@test "ralph-reviewer.md has valid frontmatter" {
  local agent_file=".claude/agents/ralph-reviewer.md"
  [[ -f "$agent_file" ]]

  grep -q "name: ralph-reviewer" "$agent_file"
  grep -q "model: sonnet" "$agent_file"
  grep -q "maxTurns:" "$agent_file"
}

@test "ralph-reviewer.md is read-only" {
  local tools_section
  tools_section=$(sed -n '/^tools:/,/^[a-z]/p' ".claude/agents/ralph-reviewer.md" | head -n -1)

  [[ "$tools_section" != *"Write"* ]]
  [[ "$tools_section" != *"Edit"* ]]
  [[ "$tools_section" != *"Bash"* ]]
}

@test "ralph-reviewer.md has PASS/FAIL output format" {
  grep -q "PASS | FAIL" ".claude/agents/ralph-reviewer.md"
  grep -q "Critical Issues" ".claude/agents/ralph-reviewer.md"
}
```

## Acceptance Criteria

- [ ] `.claude/agents/ralph-reviewer.md` exists with valid YAML frontmatter
- [ ] Agent is read-only (only Read, Glob, Grep tools)
- [ ] Agent uses `model: sonnet`
- [ ] Agent prompt specifies PASS/FAIL output format
- [ ] Agent prompt covers security, correctness, quality, and style
- [ ] Agent has `maxTurns: 10` bound
- [ ] Agent prompt limits scope to changed files only
