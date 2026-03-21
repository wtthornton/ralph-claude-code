# Story RALPH-SUBAGENTS-2: Create ralph-tester.md Agent with Worktree Isolation

**Epic:** [Sub-agents](epic-subagents.md)
**Priority:** Important
**Status:** Open
**Effort:** Small
**Component:** `.claude/agents/ralph-tester.md`

---

## Problem

Ralph v0.11.x runs tests in the same context and working directory as the main loop.
Test output (often verbose) consumes main context tokens. Long-running test suites block
Ralph from starting the next task. Test processes can also interfere with files Ralph
is actively modifying.

## Solution

Create `.claude/agents/ralph-tester.md` — a test runner agent that executes in an
isolated git worktree. This prevents file conflicts with Ralph's ongoing work and
keeps test output out of the main context window.

## Implementation

```yaml
# .claude/agents/ralph-tester.md
---
name: ralph-tester
description: >
  Run tests and validate changes after Ralph implements a task.
  Reports pass/fail counts, specific failures, and recommended fixes.
  Runs in an isolated worktree to avoid file conflicts.
tools:
  - Read
  - Glob
  - Grep
  - Bash
model: sonnet
maxTurns: 15
isolation: worktree
effort: medium
---

You are a test runner validating Ralph's changes. Your job:

1. Run the test suite for the scope specified (file, module, or full).
2. Run linting and type checking on changed files.
3. Report results in structured format.
4. Do NOT fix code yourself — only report findings.

## Available Commands

Detect project type and use appropriate commands:

### Python
- `pytest <path>` — run tests
- `ruff check .` — lint
- `mypy src/` — type check

### Node.js/TypeScript
- `npm test` — run tests
- `npm run lint` — lint
- `npm run typecheck` — type check

### Bash (Ralph itself)
- `bats tests/unit/` — unit tests
- `bats tests/integration/` — integration tests
- `npm test` — all tests via npm

## Output Format

```
## Test Results
- **Suite:** <test command>
- **Status:** PASS | FAIL
- **Passed:** N
- **Failed:** N
- **Skipped:** N

## Failures (if any)
1. `test_name` in `file:line` — error message
2. ...

## Lint/Type Issues (if any)
1. `file:line` — issue description
2. ...

## Recommendation
<one sentence: what to fix, or "all clear">
```

Keep output focused. Don't include passing test details — only failures and issues.
```

### Key Design Decisions

1. **`isolation: worktree`** — Tests run in a separate git worktree. This is critical:
   - Prevents test processes from modifying files Ralph is editing
   - Worktree auto-cleans if no changes are committed
   - Test-generated artifacts don't pollute the main working directory

2. **`model: sonnet`** — Tests need some reasoning (interpreting errors, suggesting
   fixes) but not full Opus capability. Sonnet balances cost and quality.

3. **`maxTurns: 15`** — Test suites should complete quickly. 15 turns prevents
   runaway test debugging loops.

4. **Report-only** — The tester does NOT fix code. It reports findings to Ralph,
   who decides how to act.

5. **No Agent tool** — Subagents can't spawn subagents. The tester is a leaf task.

6. **Project type detection** — Prompt includes commands for multiple project types.
   The tester should detect the project type and use appropriate commands.

## Usage Pattern

Ralph spawns the tester after completing a task:

```
Agent(ralph-tester, "Run tests for the authentication module: pytest tests/auth/ and ruff check src/auth/")
```

The tester runs in its own worktree, executes tests, and returns a structured report.
Ralph reads the report and decides whether to commit or fix issues.

## Testing

```bash
@test "ralph-tester.md has valid frontmatter" {
  local agent_file=".claude/agents/ralph-tester.md"
  [[ -f "$agent_file" ]]

  grep -q "name: ralph-tester" "$agent_file"
  grep -q "model: sonnet" "$agent_file"
  grep -q "isolation: worktree" "$agent_file"
  grep -q "maxTurns:" "$agent_file"
}

@test "ralph-tester.md has Bash tool for running tests" {
  grep -q "Bash" ".claude/agents/ralph-tester.md"
}

@test "ralph-tester.md specifies structured output format" {
  grep -q "Test Results" ".claude/agents/ralph-tester.md"
  grep -q "Failures" ".claude/agents/ralph-tester.md"
  grep -q "Recommendation" ".claude/agents/ralph-tester.md"
}
```

## Acceptance Criteria

- [ ] `.claude/agents/ralph-tester.md` exists with valid YAML frontmatter
- [ ] Agent uses `isolation: worktree` for file safety
- [ ] Agent uses `model: sonnet` for cost-effective test analysis
- [ ] Agent has `Bash` tool for running test commands
- [ ] Agent prompt is report-only (no code fixes)
- [ ] Agent prompt includes commands for Python, Node.js, and Bash project types
- [ ] Agent specifies structured output format
- [ ] Agent has `maxTurns: 15` bound
