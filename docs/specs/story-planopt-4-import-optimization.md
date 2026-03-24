# Story RALPH-PLANOPT-4: Import-Time Optimization

**Epic:** [Plan Optimization on Startup](epic-plan-optimization.md)
**Priority:** Normal
**Status:** Not Started
**Effort:** Small
**Component:** `ralph_import.sh`
**Research basis:** Anthropic prompt caching, SWE-Agent structured planning

---

## Problem

`ralph_import.sh` converts PRD documents into fix_plan.md using Claude, but gives Claude
minimal guidance on task ordering. The import prompt says "convert requirements into a
prioritized task list" with High/Medium/Low buckets but nothing about module grouping,
dependency ordering, or size clustering.

While PLANOPT-3 fixes this on every startup, running optimization at import time means
the **first loop** also gets an optimized plan.

## Solution

Four changes:

### 1. Enhance the Claude import prompt

Add optimization instructions to the PRD→fix_plan conversion prompt. This leverages
Claude's understanding of the requirements (which the post-processing optimizer cannot
access) to produce better initial ordering.

### 2. Run optimizer as post-processing

After Claude generates fix_plan.md, run the plan optimizer (PLANOPT-1/2) as a safety net.
This catches anything Claude's prompt-based ordering missed and ensures consistent output.

### 3. ralph-explorer for PRD→file mapping

During `ralph_import`, the PRD is converted to tasks by Claude. But Claude generates
task descriptions based on the PRD, which often don't reference specific files. Before
running the post-processing optimizer, spawn **ralph-explorer** to map vague tasks to
actual codebase files. This gives the first optimization run better data than regex alone.

```bash
# After Claude generates fix_plan.md, before post-processing optimization:
if command -v claude &>/dev/null && [[ -d "$PROJECT_ROOT/src" || -d "$PROJECT_ROOT/lib" ]]; then
    # Spawn explorer to map vague tasks to files
    local vague_count
    vague_count=$(grep -c '^\- \[ \]' "$RALPH_DIR/fix_plan.md" | head -1)

    if [[ $vague_count -gt 0 ]]; then
        echo "  Resolving task file references via ralph-explorer..."
        # The optimizer's plan_resolve_vague_tasks (PLANOPT-2) handles this
        # It spawns ralph-explorer (Haiku) per vague task and caches results
        source "$_lib_dir/plan_optimizer.sh" 2>/dev/null
        if declare -f plan_resolve_vague_tasks &>/dev/null; then
            local tasks_json
            tasks_json=$(plan_parse_tasks "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "[]")
            plan_resolve_vague_tasks "$tasks_json" "$RALPH_DIR/fix_plan.md" "$PROJECT_ROOT" 2>/dev/null || true
        fi
    fi
fi
```

### 4. Skill for manual optimization (`/optimize`)

Add a `ralph-optimize` skill so users can manually trigger optimization on demand:

```markdown
# .claude/skills/ralph-optimize/SKILL.md
---
name: ralph-optimize
description: >
  Manually re-optimize fix_plan.md task ordering. Rebuilds the import graph,
  resolves vague tasks via ralph-explorer, and reorders for dependency order,
  module locality, and phase ordering.
---

Run the plan optimization pipeline manually:

1. Source `~/.ralph/lib/import_graph.sh` and rebuild the import graph
2. Source `~/.ralph/lib/plan_optimizer.sh`
3. Run `plan_resolve_vague_tasks` to resolve any tasks without file references
4. Run `plan_optimize_section` on .ralph/fix_plan.md
5. Report what changed (read .ralph/.plan_optimize_diff)
```

### 5. Document prompt caching invariant

The optimizer must never modify content that falls in the stable prompt prefix
(identity, build instructions, tool permissions). Fix_plan lives in the dynamic suffix
per `PromptParts.split_prompt()` in `sdk/ralph_sdk/context.py`, so reordering tasks
does not bust the prompt cache.

## Implementation

### Prompt changes in ralph_import.sh

Add after the fix_plan.md format section in the Claude import prompt (around line 316-410):

```markdown
### Task Ordering Rules (CRITICAL for execution efficiency)

Within each priority section (## High Priority, etc.), order tasks for optimal
autonomous AI execution:

1. **Dependencies first** — If task B requires output from task A, list A before B.
   "Create schema" must come before "Add endpoint using schema".

2. **Group by module** — Tasks touching the same files or directories should be
   adjacent. This minimizes context switching between loops.
   Example: all `src/api/` tasks together, all `src/db/` tasks together.

3. **Phase ordering within groups** — Within each module group, follow this order:
   setup/create/define → implement/add → modify/refactor → test → document

4. **Cluster by size** — Group small tasks (renames, config changes, typo fixes)
   together so they can be batched in a single loop. Keep large tasks (new features,
   cross-module refactors) isolated.

5. **Explicit dependencies** — When a dependency isn't obvious from the task text,
   add a metadata comment: `<!-- depends: task-id -->` with a corresponding
   `<!-- id: task-id -->` on the prerequisite task.
```

### Post-import optimization call

Add after the "Files created successfully" section (around line 600):

```bash
# Post-import plan optimization
_optimizer_ran=false
for _lib_dir in "$HOME/.ralph/lib" "${RALPH_INSTALL_DIR:-/nonexistent}/lib"; do
    if [[ -f "$_lib_dir/plan_optimizer.sh" ]]; then
        source "$_lib_dir/plan_optimizer.sh"

        # Build import graph if available
        if [[ -f "$_lib_dir/import_graph.sh" ]]; then
            source "$_lib_dir/import_graph.sh"
            import_graph_ensure "$PROJECT_ROOT" "$RALPH_DIR/.import_graph.json" 2>/dev/null || true
        fi

        if plan_optimize_section "$RALPH_DIR/fix_plan.md" "$PROJECT_ROOT" \
            "$RALPH_DIR/.import_graph.json" 2>/dev/null; then
            echo "  Fix plan optimized for execution efficiency"
            _optimizer_ran=true
        fi
        break
    fi
done

if [[ "$_optimizer_ran" != "true" ]]; then
    # Optimizer not available — prompt-based ordering is the only optimization
    echo "  (Plan optimizer not installed — using prompt-based ordering only)"
fi
```

### Graceful degradation

If `lib/plan_optimizer.sh` doesn't exist (older Ralph installation), skip the
post-processing step silently. The enhanced prompt still provides some ordering benefit.

### Prompt cache documentation

Add as a comment in `lib/plan_optimizer.sh`:

```bash
# INVARIANT: The plan optimizer modifies ONLY fix_plan.md content, which
# falls in the dynamic suffix of the prompt (per sdk/ralph_sdk/context.py
# PromptParts.split_prompt). The stable prefix (identity, build instructions,
# tool permissions) is NEVER modified. This preserves Anthropic prompt cache
# hit rate across loop iterations.
```

## Test Plan

```bash
# tests/unit/test_import_optimization.bats

@test "PLANOPT-4: import prompt includes dependency ordering rules" {
    grep -q "Dependencies first" ralph_import.sh
}

@test "PLANOPT-4: import prompt includes module grouping rules" {
    grep -q "Group by module" ralph_import.sh
}

@test "PLANOPT-4: import prompt includes phase ordering rules" {
    grep -q "Phase ordering" ralph_import.sh ||
    grep -q "setup/create/define" ralph_import.sh
}

@test "PLANOPT-4: import prompt includes size clustering rules" {
    grep -q "Cluster by size" ralph_import.sh
}

@test "PLANOPT-4: import prompt mentions explicit dependency metadata" {
    grep -q '<!-- depends:' ralph_import.sh
    grep -q '<!-- id:' ralph_import.sh
}

@test "PLANOPT-4: post-import optimization runs when optimizer exists" {
    setup_ralph_project
    echo -e "## Tasks\n- [ ] B (src/api)\n- [ ] A (src/db)\n- [ ] C (src/api)" > .ralph/fix_plan.md
    source "$HOME/.ralph/lib/plan_optimizer.sh" 2>/dev/null || skip "optimizer not installed"
    plan_optimize_section .ralph/fix_plan.md . /dev/null
    # API tasks should be grouped
    local b_line=$(grep -n "B (src/api)" .ralph/fix_plan.md | cut -d: -f1)
    local c_line=$(grep -n "C (src/api)" .ralph/fix_plan.md | cut -d: -f1)
    local diff=$(( c_line - b_line ))
    [[ $diff -eq 1 ]]  # Adjacent
}

@test "PLANOPT-4: import works without optimizer present" {
    # Verify the import script has a graceful skip path
    grep -q "_optimizer_ran" ralph_import.sh || \
    grep -q "not installed\|not available\|graceful" ralph_import.sh
}
```

## Acceptance Criteria

- [ ] Import prompt includes task ordering rules (dependencies, module grouping, phase, size)
- [ ] Import prompt mentions `<!-- id: -->` and `<!-- depends: -->` metadata syntax
- [ ] Post-import runs plan_optimize_section on generated fix_plan.md
- [ ] Optimizer sourced from `~/.ralph/lib/` (not project directory)
- [ ] Graceful skip when lib/plan_optimizer.sh doesn't exist
- [ ] First loop after import gets an optimized plan (no manual intervention)
- [ ] Prompt cache invariant documented in code comment
- [ ] ralph-explorer resolves vague PRD tasks to file paths during import
- [ ] `ralph-optimize` skill defined for manual on-demand optimization
