# Story RALPH-SUBAGENTS-1: Create ralph-explorer.md Agent Definition

**Epic:** [Sub-agents](epic-subagents.md)
**Priority:** Important
**Status:** Done
**Effort:** Small
**Component:** `.claude/agents/ralph-explorer.md`

---

## Problem

Ralph v0.11.x performs codebase exploration in the main agent context. Every `grep`,
`find`, and file read consumes tokens in the primary context window, leading to context
bloat and higher costs. Intermediate search results pollute the main conversation.

Claude Code has a built-in `Explore` subagent (Haiku, read-only), but it uses a generic
prompt. A custom `ralph-explorer` can be tuned for Ralph's specific search patterns
(fix_plan.md tasks, existing implementations, test files, import dependencies).

## Solution

Create `.claude/agents/ralph-explorer.md` — a fast, read-only codebase search agent
optimized for Ralph's workflow.

### Decision: Custom vs Built-in Explore

| Factor | Built-in Explore | Custom ralph-explorer |
|--------|-----------------|----------------------|
| Model | Haiku | Haiku (same) |
| Tools | Read, Glob, Grep | Read, Glob, Grep (same) |
| Prompt | Generic "explore codebase" | Ralph-specific search patterns |
| Output | Unstructured | Structured (files, functions, tests) |
| Recommendation | | **Use custom** for structured output |

## Implementation

```yaml
# .claude/agents/ralph-explorer.md
---
name: ralph-explorer
description: >
  Fast, read-only codebase search for Ralph. Use when you need to find files,
  understand existing implementations, analyze code patterns, or locate test files.
  Returns structured findings — file paths, line numbers, and key patterns.
tools:
  - Read
  - Glob
  - Grep
model: haiku
maxTurns: 20
effort: low
---

You are a fast codebase explorer working for Ralph. Your job:

1. Search for files, functions, classes, or patterns as requested.
2. Return concise, structured findings.
3. Do NOT modify any files. Read-only.
4. Summarize what you find — file paths, line numbers, key patterns.

## Output Format

Return your findings in this structure:

### Related Files
- `path/to/file.py:42` — brief relevance description

### Existing Code to Reuse
- `FunctionName` in `path/to/file.py:100` — what it does

### Tests to Update
- `path/to/test_file.py` — what it tests

### Dependencies
- `package_name` — how it's used

Keep responses under 500 words. Lead with the answer.
If you find nothing relevant, say so immediately — don't keep searching.
```

### Key Design Decisions

1. **`model: haiku`** — Fastest and cheapest model. Codebase search doesn't need
   complex reasoning, just pattern matching and file reading.

2. **`maxTurns: 20`** — Generous for exploration but bounded. Prevents runaway
   search loops.

3. **`effort: low`** — Matches the simple search task. Minimizes token usage.

4. **Structured output format** — The main agent (Ralph) gets clean, parseable
   findings instead of verbose search narratives.

5. **No Agent tool** — Subagents cannot spawn other subagents (Claude Code limitation).
   This is fine since exploration is a leaf task.

## Usage Pattern

Ralph's main agent spawns this via the `Agent` tool:

```
Agent(ralph-explorer, "Find all files related to authentication middleware and their test files")
```

Results return to Ralph's main context as a structured summary without intermediate
search output polluting the conversation.

## Testing

```bash
@test "ralph-explorer.md has valid frontmatter" {
  local agent_file=".claude/agents/ralph-explorer.md"
  [[ -f "$agent_file" ]]

  # Verify key fields
  grep -q "name: ralph-explorer" "$agent_file"
  grep -q "model: haiku" "$agent_file"
  grep -q "maxTurns:" "$agent_file"
}

@test "ralph-explorer.md is read-only (no Write/Edit tools)" {
  local agent_file=".claude/agents/ralph-explorer.md"

  # Extract tools list
  local tools_section
  tools_section=$(sed -n '/^tools:/,/^[a-z]/p' "$agent_file" | head -n -1)

  [[ "$tools_section" != *"Write"* ]]
  [[ "$tools_section" != *"Edit"* ]]
  [[ "$tools_section" != *"Bash"* ]]
}

@test "ralph-explorer.md has structured output format" {
  grep -q "Related Files" ".claude/agents/ralph-explorer.md"
  grep -q "Existing Code" ".claude/agents/ralph-explorer.md"
  grep -q "Tests to Update" ".claude/agents/ralph-explorer.md"
}
```

## Acceptance Criteria

- [ ] `.claude/agents/ralph-explorer.md` exists with valid YAML frontmatter
- [ ] Agent uses `model: haiku` for speed/cost
- [ ] Agent is read-only (only Read, Glob, Grep tools)
- [ ] Agent prompt specifies structured output format
- [ ] Agent has `maxTurns: 20` bound
- [ ] Agent does not include `Agent` tool (subagents can't spawn subagents)
