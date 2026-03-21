# Story RALPH-SUBAGENTS-4: Update ralph.md to Reference and Spawn Sub-agents

**Epic:** [Sub-agents](epic-subagents.md)
**Priority:** Important
**Status:** Open
**Effort:** Small
**Component:** `.claude/agents/ralph.md`
**Depends on:** RALPH-SUBAGENTS-1, RALPH-SUBAGENTS-2, RALPH-SUBAGENTS-3

---

## Problem

The initial ralph.md agent definition (RALPH-HOOKS-1) includes the `Agent` tool but
doesn't instruct Ralph on when and how to spawn sub-agents. Without explicit guidance,
Ralph may continue doing everything in-context or may spawn sub-agents inappropriately.

## Solution

Update the ralph.md agent prompt to include sub-agent spawning instructions. Define
when to use each sub-agent and restrict which sub-agents Ralph can spawn.

## Implementation

### Update ralph.md tools field

Add `Agent(ralph-explorer, ralph-tester, ralph-reviewer)` to restrict spawning:

```yaml
tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash
  - Agent(ralph-explorer, ralph-tester, ralph-reviewer)
  - TodoWrite
  - WebFetch
```

### Add sub-agent instructions to ralph.md prompt

Append after the existing Rules section:

```markdown
## Sub-agents

You have access to specialized sub-agents. Use them instead of doing everything yourself:

### ralph-explorer (fast codebase search)
- **When:** Before implementing ANY task. Search for existing code, patterns, tests.
- **Model:** Haiku (fast, cheap)
- **Example:** `Agent(ralph-explorer, "Find all files related to rate limiting and their tests")`
- **Benefit:** Keeps search output out of your main context.

### ralph-tester (isolated test runner)
- **When:** After implementing a task. Run tests, lint, and type checks.
- **Model:** Sonnet (worktree-isolated)
- **Example:** `Agent(ralph-tester, "Run bats tests/unit/test_circuit_breaker.bats and check for lint issues")`
- **Benefit:** Tests run in separate worktree — no file conflicts.

### ralph-reviewer (code review)
- **When:** Before committing, especially for security-sensitive changes.
- **Model:** Sonnet (read-only)
- **Example:** `Agent(ralph-reviewer, "Review changes in lib/response_analyzer.sh for the JSONL fix")`
- **Benefit:** Catches security and correctness issues before commit.

### Workflow
1. **Explore** → Spawn ralph-explorer to understand the codebase
2. **Implement** → Make changes yourself (you have Write/Edit/Bash)
3. **Test** → Spawn ralph-tester to verify
4. **Review** → Spawn ralph-reviewer for security-sensitive changes (optional)
5. **Commit** → If tests pass and review is clean
```

### Key Design Decisions

1. **`Agent(ralph-explorer, ralph-tester, ralph-reviewer)` allowlist:** Prevents Ralph
   from spawning arbitrary sub-agents. Only the three defined sub-agents are allowed.

2. **Explicit "When" guidance:** Each sub-agent has clear trigger conditions. Prevents
   both over-spawning and under-spawning.

3. **Workflow section:** Defines the expected execution order. Exploration before
   implementation, testing after, review optional.

4. **Explorer is mandatory:** "Before implementing ANY task" ensures Ralph always
   checks for existing code first. This was a common issue in v0.11.x.

5. **Reviewer is optional:** "Especially for security-sensitive changes" — not every
   task needs review. Keeps the loop efficient for simple tasks.

## Testing

```bash
@test "ralph.md uses Agent allowlist syntax" {
  grep -q "Agent(ralph-explorer, ralph-tester, ralph-reviewer)" ".claude/agents/ralph.md"
}

@test "ralph.md includes sub-agent workflow" {
  grep -q "ralph-explorer" ".claude/agents/ralph.md"
  grep -q "ralph-tester" ".claude/agents/ralph.md"
  grep -q "ralph-reviewer" ".claude/agents/ralph.md"
  grep -q "Workflow" ".claude/agents/ralph.md"
}

@test "ralph.md has exploration-first instruction" {
  grep -q "Before implementing ANY task" ".claude/agents/ralph.md"
}
```

## Acceptance Criteria

- [ ] ralph.md `tools` field uses `Agent(ralph-explorer, ralph-tester, ralph-reviewer)` syntax
- [ ] ralph.md prompt includes sub-agent instructions with When/Model/Example for each
- [ ] ralph.md prompt defines workflow order (explore → implement → test → review → commit)
- [ ] Explorer is positioned as mandatory ("before ANY task")
- [ ] Reviewer is positioned as optional ("especially for security-sensitive changes")
- [ ] No references to sub-agents spawning other sub-agents
