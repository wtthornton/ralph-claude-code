# Story RALPH-SKILLS-2: Create ralph-research Skill

**Epic:** [Skills + Bash Reduction](epic-skills-bash-reduction.md)
**Priority:** Nice-to-have
**Status:** Open
**Effort:** Small
**Component:** `.claude/skills/ralph-research/SKILL.md`

---

## Problem

Codebase research before implementation is a repeated pattern in Ralph's workflow.
Currently, research is either done in-context (expensive, noisy) or by manually
spawning the explorer sub-agent (requires knowing the right invocation). A skill
formalizes this as a reusable, one-command operation.

## Solution

Create `.claude/skills/ralph-research/SKILL.md` — a model-invocable skill that
spawns the ralph-explorer sub-agent in a forked context to research the codebase
before implementation.

## Implementation

```yaml
# .claude/skills/ralph-research/SKILL.md
---
name: ralph-research
description: >
  Research the codebase before implementing a task. Spawns ralph-explorer
  to find relevant files, patterns, existing code, and test files.
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

### Related Files
- `path/to/file:line` — relevance description

### Existing Code to Reuse
- `FunctionName` in `path/to/file:line` — what it does

### Tests to Update
- `path/to/test_file` — what it tests

### Dependencies to Consider
- `package/module` — how it's used and what might break
```

### Key Design Decisions

1. **`user-invocable: false`** — This skill is not meant for direct CLI invocation.
   It's used by Claude (the main Ralph agent) during the implementation workflow.

2. **`context: fork`** — Runs in a sub-agent context, keeping the main conversation
   clean. Research output doesn't pollute Ralph's primary context window.

3. **`agent: ralph-explorer`** — Delegates to the ralph-explorer sub-agent (Haiku,
   read-only). Fast and cheap.

4. **`$ARGUMENTS` as search query** — The main agent passes the task description
   as the search query. Example: the skill is invoked with "rate limiting middleware"
   and the explorer searches for related files.

## Testing

```bash
@test "ralph-research SKILL.md exists with valid frontmatter" {
  local skill_file=".claude/skills/ralph-research/SKILL.md"
  [[ -f "$skill_file" ]]

  grep -q "name: ralph-research" "$skill_file"
  grep -q "user-invocable: false" "$skill_file"
  grep -q "context: fork" "$skill_file"
  grep -q "agent: ralph-explorer" "$skill_file"
}

@test "ralph-research SKILL.md uses ARGUMENTS" {
  grep -q '\$ARGUMENTS' ".claude/skills/ralph-research/SKILL.md"
}
```

## Acceptance Criteria

- [ ] `.claude/skills/ralph-research/SKILL.md` exists with valid YAML frontmatter
- [ ] Skill is model-invocable only (`user-invocable: false`)
- [ ] Skill uses `context: fork` for isolated execution
- [ ] Skill delegates to `ralph-explorer` agent
- [ ] Skill uses `$ARGUMENTS` for dynamic search query
- [ ] Skill specifies structured output format
