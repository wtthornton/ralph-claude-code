# Story RALPH-TEAMS-3: Create ralph-bg-tester.md Background Agent

**Epic:** [Agent Teams + Parallelism](epic-agent-teams-parallelism.md)
**Priority:** Nice-to-have
**Status:** Done
**Effort:** Small
**Component:** `.claude/agents/ralph-bg-tester.md`

---

## Problem

In sequential mode, Ralph blocks while waiting for test results after each task.
A background test runner can validate changes asynchronously while Ralph starts
the next task, improving wall-clock time.

## Solution

Create `.claude/agents/ralph-bg-tester.md` — a background agent that runs tests
concurrently with Ralph's main loop. Results arrive asynchronously and Ralph checks
them before committing the next task.

## Implementation

```yaml
# .claude/agents/ralph-bg-tester.md
---
name: ralph-bg-tester
description: >
  Background test runner. Validates changes while Ralph continues
  implementing the next task. Returns results asynchronously.
  Runs in background mode — does not block the main agent.
tools:
  - Read
  - Glob
  - Grep
  - Bash
model: sonnet
maxTurns: 10
background: true
effort: medium
---

You are a background test runner. Run the test suite for the specified scope
and report results. Do NOT fix failures — only report them.

## Steps

1. Run the tests specified in the task description.
2. Run lint/type checks on the specified files.
3. Report results in structured format.

## Output Format

```
## Background Test Results
- **Scope:** <what was tested>
- **Status:** PASS | FAIL
- **Passed:** N
- **Failed:** N
- **Duration:** Ns

## Failures (if any)
1. `test_name` — error summary

## Recommendation
<fix suggestion or "all clear">
```

Be concise. The main agent needs quick, actionable results.
```

### Key Design Decisions

1. **`background: true`** — Runs concurrently with the main agent. Does not block
   Ralph from starting the next task.

2. **No `isolation: worktree`** — Background agents read the current working directory.
   Adding worktree isolation would be ideal but may introduce complexity. The tester
   only reads and runs commands, so conflicts are unlikely.

3. **`model: sonnet`** — Same as the foreground tester. Needs reasoning to interpret
   test output.

4. **`maxTurns: 10`** — Background tests should complete quickly. 10 turns is
   sufficient for run + report.

5. **Report-only** — Does not fix code. Reports findings for Ralph to act on.

6. **Permissions pre-approved:** Background agents have permissions pre-approved at
   launch. Unapproved tools are auto-denied. This means the tool list must include
   everything the tester needs.

## Usage Pattern

Ralph spawns the background tester after completing a task:

```
Agent(ralph-bg-tester, background: true, "Run pytest tests/auth/ — just committed auth middleware changes")
```

Ralph immediately starts the next fix_plan task. When the background tester finishes,
Ralph receives the results and checks them before committing the next task.

## Testing

```bash
@test "ralph-bg-tester.md has valid frontmatter" {
  local agent_file=".claude/agents/ralph-bg-tester.md"
  [[ -f "$agent_file" ]]

  grep -q "name: ralph-bg-tester" "$agent_file"
  grep -q "background: true" "$agent_file"
  grep -q "model: sonnet" "$agent_file"
}

@test "ralph-bg-tester.md has Bash tool" {
  grep -q "Bash" ".claude/agents/ralph-bg-tester.md"
}
```

## Acceptance Criteria

- [ ] `.claude/agents/ralph-bg-tester.md` exists with valid YAML frontmatter
- [ ] Agent has `background: true` for concurrent execution
- [ ] Agent uses `model: sonnet`
- [ ] Agent has `Bash` tool for running tests
- [ ] Agent prompt is report-only (no code fixes)
- [ ] Agent has `maxTurns: 10` bound
- [ ] Agent specifies structured output format
