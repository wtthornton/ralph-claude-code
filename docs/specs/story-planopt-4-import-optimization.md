# Story RALPH-PLANOPT-4: Import-Time Optimization

**Epic:** [Plan Optimization on Startup](epic-plan-optimization.md)
**Priority:** Normal
**Status:** Not Started
**Effort:** Small
**Component:** `ralph_import.sh`

---

## Problem

`ralph_import.sh` converts PRD documents into fix_plan.md using Claude, but gives Claude
minimal guidance on task ordering. The import prompt says "convert requirements into a
prioritized task list" with High/Medium/Low buckets but nothing about:

- Grouping tasks by module/file
- Ordering dependencies correctly
- Clustering by task size for batching efficiency

The result is a plan ordered by how the human wrote the PRD, not by execution efficiency.
While PLANOPT-3 fixes this on every startup, running optimization at import time means
the **first loop** also gets an optimized plan — and the import prompt can generate
better initial structure.

## Solution

Two changes:

### 1. Enhance the Claude import prompt

Add optimization instructions to the PRD→fix_plan conversion prompt in `ralph_import.sh`:

```
### Task Ordering Rules (CRITICAL for execution efficiency)

Within each priority section (## High Priority, etc.), order tasks for optimal
autonomous execution:

1. **Dependencies first** — If task B requires output from task A, list A before B.
   "Create schema" must come before "Add endpoint using schema".

2. **Group by module** — Tasks touching the same files or directories should be
   adjacent. This minimizes context switching between loops.
   Example: all `src/api/` tasks together, all `src/db/` tasks together.

3. **Cluster by size** — Group small tasks (renames, config changes, typo fixes)
   together so they can be batched in a single loop. Keep large tasks isolated.

4. **Setup before implementation** — Within a module group:
   setup/init/create → implement/add → test → document
```

### 2. Run optimizer after import

After Claude generates fix_plan.md, run the plan optimizer (from PLANOPT-1/2) as a
post-processing step:

```bash
# In ralph_import.sh, after fix_plan.md is written:
if [[ -f "$PROJECT_ROOT/lib/plan_optimizer.sh" ]]; then
    source "$PROJECT_ROOT/lib/plan_optimizer.sh"
    plan_optimize "$RALPH_DIR/fix_plan.md" "$PROJECT_ROOT"
    echo "  ✓ Fix plan optimized for execution efficiency"
fi
```

This catches anything Claude's prompt-based ordering missed.

## Implementation

### Prompt changes in ralph_import.sh

Locate the heredoc that builds the Claude import prompt (around line 316-410) and add
the ordering rules after the fix_plan.md format section.

### Post-import optimization call

Add after the "Files created successfully" section (around line 600), before the
"Next steps" output.

### Graceful degradation

If `lib/plan_optimizer.sh` doesn't exist (older Ralph installation), skip the
post-processing step silently. The enhanced prompt still provides some ordering benefit.

## Test Plan

```bash
# tests/unit/test_import_optimization.bats

@test "PLANOPT-4: import prompt includes ordering rules" {
    # Extract the prompt template from ralph_import.sh
    grep -q "Dependencies first" ralph_import.sh
    grep -q "Group by module" ralph_import.sh
    grep -q "Cluster by size" ralph_import.sh
}

@test "PLANOPT-4: post-import optimization runs when optimizer exists" {
    setup_ralph_project
    # Create a minimal fix_plan.md
    echo -e "## Tasks\n- [ ] B (src/api)\n- [ ] A (src/db)\n- [ ] C (src/api)" > .ralph/fix_plan.md

    # Source and run optimizer
    source lib/plan_optimizer.sh
    plan_optimize .ralph/fix_plan.md .

    # Verify API tasks are grouped
    # (specific assertions depend on PLANOPT-2 implementation)
}

@test "PLANOPT-4: import works without optimizer present" {
    # Remove optimizer
    rm -f lib/plan_optimizer.sh

    # Import should still succeed (graceful skip)
    # (Would need a mock PRD and Claude response for full test)
}
```

## Acceptance Criteria

- [ ] Import prompt includes task ordering rules (dependencies, module grouping, size clustering)
- [ ] Post-import runs plan_optimize on generated fix_plan.md
- [ ] Graceful skip when lib/plan_optimizer.sh doesn't exist
- [ ] First loop after import gets an optimized plan (no manual intervention)
