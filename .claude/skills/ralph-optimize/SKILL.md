---
name: ralph-optimize
description: >
  Manually re-optimize fix_plan.md task ordering. Rebuilds the import graph,
  resolves vague tasks via ralph-explorer, and reorders for dependency order,
  module locality, and phase ordering. Shows what changed.
user-invocable: true
disable-model-invocation: false
allowed-tools:
  - Read
  - Glob
  - Grep
  - Bash
  - Agent
argument-hint: "[--force] [--no-explorer]"
---

## Plan optimization

Manually trigger the fix_plan.md optimization pipeline.

### Steps

1. Source the Ralph optimizer libraries:
   ```bash
   for _lib_dir in "$HOME/.ralph/lib" "${RALPH_INSTALL_DIR:-}/lib"; do
     [[ -f "$_lib_dir/import_graph.sh" ]] && source "$_lib_dir/import_graph.sh" && break
   done
   for _lib_dir in "$HOME/.ralph/lib" "${RALPH_INSTALL_DIR:-}/lib"; do
     [[ -f "$_lib_dir/plan_optimizer.sh" ]] && source "$_lib_dir/plan_optimizer.sh" && break
   done
   ```

2. Rebuild the import graph (force rebuild if `$ARGUMENTS` contains `--force`):
   ```bash
   import_graph_ensure "." ".ralph/.import_graph.json"
   ```

3. Resolve vague tasks (skip if `$ARGUMENTS` contains `--no-explorer`):
   ```bash
   tasks_json=$(plan_parse_tasks ".ralph/fix_plan.md")
   plan_resolve_vague_tasks "$tasks_json" ".ralph/fix_plan.md" "."
   ```

4. Run the optimizer:
   ```bash
   plan_optimize_section ".ralph/fix_plan.md" "." ".ralph/.import_graph.json"
   ```

5. Report what changed by reading the diff file:
   ```bash
   cat .ralph/.plan_optimize_diff
   ```

### Output

Show the user:
- Number of tasks analyzed
- Number of tasks moved
- The before/after diff from `.ralph/.plan_optimize_diff`
- Import graph status (fresh/stale/rebuilt)
- Explorer resolution count (if any)

### Constraints

- NEVER modify .ralph/ files except fix_plan.md (which the optimizer writes atomically)
- If the optimizer is not installed, inform the user to run `ralph-upgrade`
- If no fix_plan.md exists, inform the user to run `ralph-enable` first
