# Story RALPH-TEAMS-2: Implement Team Spawning Strategy in ralph.md

**Epic:** [Agent Teams + Parallelism](epic-agent-teams-parallelism.md)
**Priority:** Important
**Status:** Done
**Effort:** Medium
**Component:** `.claude/agents/ralph.md`
**Depends on:** RALPH-TEAMS-1, RALPH-TEAMS-4, RALPH-TEAMS-5

---

## Problem

When agent teams are enabled, Ralph needs to know how to coordinate teammates for
parallel execution. The current agent prompt handles tasks sequentially (one per loop).
With teams, Ralph can assign independent tasks to teammates working in separate
worktrees.

## Solution

Add team spawning instructions to `ralph.md` that activate only when teams are enabled.
Define file ownership rules, teammate assignment strategy, and result merging.

## Implementation

### Add to ralph.md (conditional on teams being enabled)

```markdown
## Team Execution (when agent teams are enabled)

When the fix plan contains INDEPENDENT tasks that can be parallelized:

### Assessment
1. Read the entire fix_plan.md
2. Identify tasks that are independent (no shared file dependencies)
3. Group tasks by file ownership:
   - **Backend:** `src/**/*.py`, `lib/**/*.sh`, `tests/**`
   - **Frontend:** `frontend/**/*.{ts,tsx,js,jsx}`, `public/**`
   - **Config/Docs:** `*.md`, `*.json`, `*.yaml`, `.ralphrc`

### Teammate Assignment
- Create up to ${RALPH_MAX_TEAMMATES:-3} teammates
- Assign each teammate a file ownership scope
- Each teammate gets its own worktree (file isolation)
- Teammates should NOT modify files outside their scope

### Example

For a fix plan with:
- [ ] Fix auth middleware validation (src/auth/middleware.py)
- [ ] Add rate limit to API endpoint (src/api/routes.py)
- [ ] Update dashboard component (frontend/src/Dashboard.tsx)
- [ ] Fix CSS layout issue (frontend/src/styles/layout.css)

Assign:
1. Teammate "backend": tasks 1 + 2 (src/**/*.py)
2. Teammate "frontend": tasks 3 + 4 (frontend/**)
3. Test runner: validate both after completion

### Constraints
- Each teammate works in its own worktree — no file conflicts
- Lead (you) coordinates and merges results
- If a teammate fails, reassign their task to yourself
- Maximum ${RALPH_MAX_TEAMMATES:-3} teammates
- Only parallelize truly independent tasks — when in doubt, run sequentially

### Sequential Fallback
If tasks have dependencies (shared files, import chains), run them sequentially
as in normal mode. Team mode is an optimization, not a requirement.
```

### Key Design Decisions

1. **Independence assessment first:** Ralph must verify tasks are independent before
   parallelizing. Dependent tasks run sequentially.

2. **File ownership scopes:** Clear boundaries prevent worktree merge conflicts.
   Backend, frontend, and config are natural splits.

3. **Teammate failure handling:** Reassign to self (the lead). The lead always has
   full capability as a fallback.

4. **Conservative parallelization:** "When in doubt, run sequentially." Safety over
   speed.

5. **`RALPH_MAX_TEAMMATES` respected:** Environment variable controls the upper bound.

## Testing

```bash
@test "ralph.md includes team execution section" {
  grep -q "Team Execution" ".claude/agents/ralph.md"
}

@test "ralph.md includes file ownership scopes" {
  grep -q "Backend" ".claude/agents/ralph.md"
  grep -q "Frontend" ".claude/agents/ralph.md"
}

@test "ralph.md includes sequential fallback" {
  grep -q "Sequential Fallback" ".claude/agents/ralph.md"
}

@test "ralph.md references RALPH_MAX_TEAMMATES" {
  grep -q "RALPH_MAX_TEAMMATES" ".claude/agents/ralph.md"
}
```

## Acceptance Criteria

- [ ] ralph.md includes team execution section with assessment, assignment, and constraints
- [ ] File ownership scopes defined (backend, frontend, config)
- [ ] Teammate failure handling defined (reassign to self)
- [ ] Sequential fallback for dependent tasks
- [ ] `RALPH_MAX_TEAMMATES` respected in teammate limit
- [ ] Clear example showing task-to-teammate mapping
