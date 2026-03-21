# Story RALPH-SKILLS-1: Create ralph-loop Skill

**Epic:** [Skills + Bash Reduction](epic-skills-bash-reduction.md)
**Priority:** Important
**Status:** Done
**Effort:** Small
**Component:** `.claude/skills/ralph-loop/SKILL.md`

---

## Problem

Ralph's per-loop execution contract is currently embedded in the agent prompt and
PROMPT.md. There's no way to invoke a single loop iteration as a standalone operation
from the CLI. The execution contract is also not reusable — it can't be applied to
non-Ralph agents or different loop configurations.

## Solution

Create `.claude/skills/ralph-loop/SKILL.md` — a user-invocable skill that encapsulates
one Ralph loop iteration. This enables `/ralph-loop` from the CLI and makes the
execution contract reusable.

## Implementation

```yaml
# .claude/skills/ralph-loop/SKILL.md
---
name: ralph-loop
description: >
  Execute one Ralph development loop iteration. Reads fix_plan.md,
  implements the first unchecked task, verifies, and commits.
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Write
  - Edit
  - Glob
  - Grep
  - Bash
  - Agent
argument-hint: "[task description override]"
---

## Current Status

!`bash -c 'RALPH_DIR=".ralph"; total=$(grep -c "^\- \[" "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo 0); done=$(grep -c "^\- \[x\]" "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo 0); echo "Tasks: $done/$total complete, $((total - done)) remaining"'`

## Execution Contract

1. Read `.ralph/fix_plan.md` — find the FIRST unchecked `- [ ]` item.
   If `$ARGUMENTS` is provided, use that as the task override instead.
2. Search the codebase for existing implementations (use ralph-explorer agent if available).
3. If the task uses an external library API, look up docs first.
4. Implement the smallest complete change.
5. Run targeted verification (lint/type/test for touched scope).
6. Update fix_plan.md: `- [ ]` to `- [x]`.
7. Commit with descriptive message.
8. Report status in RALPH_STATUS block.
9. **STOP immediately after the status block.**

## Constraints

- ONE task only. Stop after completing it.
- LIMIT testing to ~20% of effort.
- NEVER modify .ralph/ files except fix_plan.md checkboxes.
- Use ralph-explorer for codebase search, ralph-tester for verification (if available).

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
```

### Key Design Decisions

1. **Dynamic context injection:** The `` !`bash ...` `` syntax runs at skill load time,
   injecting current fix_plan progress into the prompt. Claude sees real-time status
   without the skill needing to instruct a file read.

2. **`user-invocable: true`** — Operators can run `/ralph-loop` from the CLI to
   manually trigger a single iteration. Useful for testing and debugging.

3. **`disable-model-invocation: false`** — Claude can also invoke this skill
   programmatically. Enables automated loop orchestration.

4. **`$ARGUMENTS` override** — Passing an argument overrides the fix_plan task.
   Example: `/ralph-loop "Fix the authentication bug in middleware.py"`

5. **`allowed-tools`** — Auto-approves these tools when the skill is active.
   Reduces permission prompts during execution.

## Testing

```bash
@test "ralph-loop SKILL.md exists with valid frontmatter" {
  local skill_file=".claude/skills/ralph-loop/SKILL.md"
  [[ -f "$skill_file" ]]

  grep -q "name: ralph-loop" "$skill_file"
  grep -q "user-invocable: true" "$skill_file"
}

@test "ralph-loop SKILL.md has dynamic context injection" {
  grep -q '!`bash' ".claude/skills/ralph-loop/SKILL.md"
}

@test "ralph-loop SKILL.md has RALPH_STATUS template" {
  grep -q "RALPH_STATUS" ".claude/skills/ralph-loop/SKILL.md"
  grep -q "EXIT_SIGNAL" ".claude/skills/ralph-loop/SKILL.md"
}

@test "ralph-loop SKILL.md supports argument override" {
  grep -q '\$ARGUMENTS' ".claude/skills/ralph-loop/SKILL.md"
}
```

## Acceptance Criteria

- [ ] `.claude/skills/ralph-loop/SKILL.md` exists with valid YAML frontmatter
- [ ] Skill is user-invocable (`/ralph-loop` works from CLI)
- [ ] Skill uses dynamic context injection for fix_plan status
- [ ] Skill supports `$ARGUMENTS` task override
- [ ] Skill includes full RALPH_STATUS template
- [ ] Skill includes explicit STOP instruction
- [ ] `allowed-tools` auto-approves core tools
