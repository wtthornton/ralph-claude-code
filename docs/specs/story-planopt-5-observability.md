# Story RALPH-PLANOPT-5: Observability and Logging

**Epic:** [Plan Optimization on Startup](epic-plan-optimization.md)
**Priority:** Normal
**Status:** Not Started
**Effort:** Small
**Component:** `lib/plan_optimizer.sh`, `on-task-completed.sh`, `on-stop.sh`

---

## Problem

Without visibility into what the optimizer changed, there's no way to validate the
feature is working or debug issues when task ordering seems wrong. Operators need to see:

- Whether optimization ran or was skipped (and why)
- What was reordered and why
- How many tasks were moved
- Whether the import graph was used

Additionally, the import graph goes stale during a session as Ralph creates and modifies
files. The existing **TaskCompleted** and **Stop** hooks can incrementally invalidate
graph entries for modified files, keeping the graph fresh without full rebuilds.

This story is intentionally lightweight — no metrics integration, no dashboards. Ship the
optimizer, validate it works via log inspection, add metrics later if needed.

## Solution

### 1. Optimization summary in ralph.log

One line per optimization run:

```
[2026-03-24 14:30:01] PLAN_OPTIMIZE: 12 unchecked tasks, 8 moved, 3 dep-pairs, 0.3s
[2026-03-24 14:30:01] PLAN_OPTIMIZE: import_graph=yes, sections_changed=2/5
```

### 2. Skip logging

When optimization is skipped, log the reason:

```
[2026-03-24 14:30:01] PLAN_OPTIMIZE: Skipped (no sections changed)
[2026-03-24 14:30:01] PLAN_OPTIMIZE: Skipped (1 unchecked task, nothing to reorder)
[2026-03-24 14:30:01] PLAN_OPTIMIZE: Skipped (RALPH_NO_OPTIMIZE=true)
```

### 3. Optimization diff file

Write before/after task order to `.ralph/.plan_optimize_diff` for debugging.
Overwritten each run (not appended — keeps it small):

```
## Phase 1: Core Setup (5 unchecked, 3 moved)
  KEPT:  1. Create user schema (src/db)                [phase: create]
  MOVED: 2. Rename db constant (src/db)                [was #5, reason: module-group]
  MOVED: 3. Add user endpoint (src/api)                [was #1, reason: dependency(import-graph)]
  KEPT:  4. Add error handling (src/api)               [phase: modify]
  MOVED: 5. Fix config typo (config)                   [was #3, reason: module-isolate]
```

### 4. Equivalence check logging

When the equivalence check catches a problem, log details for debugging:

```
[2026-03-24 14:30:01] PLAN_OPTIMIZE: ABORT — task count changed (12 → 11). Backup preserved.
```

## Implementation

```bash
# Add to lib/plan_optimizer.sh

PLAN_OPT_LOG_TAG="PLAN_OPTIMIZE"

plan_opt_log() {
    local ralph_log="${RALPH_DIR:-.ralph}/ralph.log"
    local ts
    ts=$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo "unknown")
    echo "[$ts] $PLAN_OPT_LOG_TAG: $*" >> "$ralph_log"
}

plan_opt_log_skip() {
    local reason="$1"
    plan_opt_log "Skipped ($reason)"
}

plan_opt_log_result() {
    local total="$1"
    local moved="$2"
    local dep_pairs="$3"
    local duration_ms="$4"
    local import_graph_used="$5"
    local sections_changed="$6"
    local sections_total="$7"

    plan_opt_log "$total unchecked tasks, $moved moved, $dep_pairs dep-pairs, ${duration_ms}ms"
    plan_opt_log "import_graph=$import_graph_used, sections_changed=$sections_changed/$sections_total"
}

plan_write_diff() {
    local diff_file="${RALPH_DIR:-.ralph}/.plan_optimize_diff"
    local before_order="$1"  # JSON array: [{idx, text, module, ...}, ...]
    local after_order="$2"   # JSON array: [{idx, text, module, reason, ...}, ...]

    # Build human-readable diff
    {
        echo "# Plan Optimization Diff"
        echo "# Generated: $(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)"
        echo ""

        local current_section=""

        echo "$after_order" | jq -r '.[] | "\(.section)\t\(.original_pos)\t\(.new_pos)\t\(.text)\t\(.reason // "kept")"' | \
        while IFS=$'\t' read -r section orig_pos new_pos text reason; do
            if [[ "$section" != "$current_section" ]]; then
                echo ""
                echo "$section"
                current_section="$section"
            fi

            if [[ "$orig_pos" == "$new_pos" ]]; then
                printf "  KEPT:  %d. %s\n" "$new_pos" "$text"
            else
                printf "  MOVED: %d. %s  [was #%d, reason: %s]\n" "$new_pos" "$text" "$orig_pos" "$reason"
            fi
        done
    } > "$diff_file"
}
```

### 5. TaskCompleted hook — incremental import graph invalidation

The `TaskCompleted` hook (already defined in `.claude/settings.json` line 89-98) fires
after each task completion. Add import graph invalidation for modified files:

```bash
# Add to .ralph/hooks/on-task-completed.sh

RALPH_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"

# Source import graph lib for invalidation
RALPH_LIB=""
for _lib_dir in "$HOME/.ralph/lib" "${RALPH_INSTALL_DIR:-/nonexistent}/lib"; do
    [[ -d "$_lib_dir" ]] && RALPH_LIB="$_lib_dir" && break
done

if [[ -n "$RALPH_LIB" && -f "$RALPH_LIB/import_graph.sh" ]]; then
    source "$RALPH_LIB/import_graph.sh"

    # Read files modified this loop (written by on-file-change.sh or on-stop.sh)
    if [[ -f "$RALPH_DIR/.files_modified_this_loop" ]]; then
        while IFS= read -r modified_file; do
            [[ -z "$modified_file" ]] && continue
            # Only invalidate source files (not config, docs, etc.)
            if echo "$modified_file" | grep -qE '\.(py|ts|tsx|js|jsx|sh)$'; then
                import_graph_invalidate_file "$modified_file" "$RALPH_DIR/.import_graph.json" 2>/dev/null || true
            fi
        done < "$RALPH_DIR/.files_modified_this_loop"
    fi
fi

exit 0
```

### 6. Stop hook integration — track files for graph invalidation

The existing `on-stop.sh` hook already extracts `files_changed` from Claude's response
and can write to `.files_modified_this_loop`. Add a section that also marks the import
graph stale when new files are **created** (not just modified):

```bash
# Add to on-stop.sh, after files_changed extraction:

# Mark import graph stale if new source files were created
if [[ -n "$files_changed" ]]; then
    local new_files_created=false
    for f in $files_changed; do
        if echo "$f" | grep -qE '\.(py|ts|tsx|js|jsx|sh)$'; then
            # Check if this file existed before the loop started
            if ! git show HEAD:"$f" &>/dev/null 2>&1; then
                new_files_created=true
                break
            fi
        fi
    done

    if [[ "$new_files_created" == "true" ]]; then
        touch "$RALPH_DIR/.import_graph.json.stale" 2>/dev/null || true
    fi
fi
```

### Integration with plan_optimize_section

Add timing and logging to the orchestrator in PLANOPT-2:

```bash
plan_optimize_section() {
    local fix_plan="$1"
    local project_root="$2"
    local import_graph="$3"

    local start_time
    start_time=$(date +%s%N 2>/dev/null || echo 0)

    # ... (existing optimization logic) ...

    local end_time
    end_time=$(date +%s%N 2>/dev/null || echo 0)
    local duration_ms=$(( (end_time - start_time) / 1000000 ))

    # Count moves
    local moved_count=0
    # ... (compare before/after indices) ...

    local import_graph_used="no"
    [[ -f "$import_graph" && $(jq 'length' "$import_graph" 2>/dev/null) -gt 0 ]] && import_graph_used="yes"

    plan_opt_log_result "$unchecked_count" "$moved_count" "$dep_pair_count" \
        "$duration_ms" "$import_graph_used" "$changed_section_count" "$total_section_count"

    plan_write_diff "$before_json" "$after_json"
}
```

## Test Plan

```bash
# tests/unit/test_plan_observability.bats

@test "PLANOPT-5: optimization logs to ralph.log" {
    setup_ralph_project
    run_optimization
    grep -q "PLAN_OPTIMIZE" .ralph/ralph.log
}

@test "PLANOPT-5: log includes task count and move count" {
    setup_ralph_project
    run_optimization_with_moves
    grep -qE "PLAN_OPTIMIZE:.*unchecked.*moved" .ralph/ralph.log
}

@test "PLANOPT-5: log includes duration" {
    setup_ralph_project
    run_optimization
    grep -qE "PLAN_OPTIMIZE:.*[0-9]+ms" .ralph/ralph.log
}

@test "PLANOPT-5: skip logged with reason" {
    setup_ralph_project
    run_optimization  # First run
    run_optimization  # Second run (no changes)
    grep -q "Skipped" .ralph/ralph.log
}

@test "PLANOPT-5: diff file shows MOVED and KEPT" {
    setup_ralph_project
    run_optimization_with_moves
    [[ -f .ralph/.plan_optimize_diff ]]
    grep -q "MOVED" .ralph/.plan_optimize_diff
    grep -q "KEPT" .ralph/.plan_optimize_diff
}

@test "PLANOPT-5: diff file overwritten not appended" {
    setup_ralph_project
    run_optimization_with_moves
    local size1=$(wc -c < .ralph/.plan_optimize_diff)
    run_optimization_with_moves
    local size2=$(wc -c < .ralph/.plan_optimize_diff)
    # Sizes should be similar (overwritten, not doubled)
    [[ $size2 -lt $((size1 * 2)) ]]
}

@test "PLANOPT-5: equivalence abort logged" {
    setup_ralph_project
    # Force an equivalence failure (mock scenario)
    plan_opt_log "ABORT — task count changed (5 → 4). Backup preserved."
    grep -q "ABORT" .ralph/ralph.log
}

@test "PLANOPT-5: import graph usage logged" {
    setup_ralph_project
    run_optimization
    grep -qE "import_graph=(yes|no)" .ralph/ralph.log
}
```

## Acceptance Criteria

- [ ] Optimization summary logged to ralph.log (task count, moves, duration, import graph status)
- [ ] Skip events logged with reason (unchanged, single task, disabled)
- [ ] Diff file written showing MOVED/KEPT with move reasons
- [ ] Diff file overwritten each run (not appended)
- [ ] Equivalence check failures logged with details
- [ ] Logging adds < 50ms overhead
- [ ] No metrics integration (deferred — ship and validate first)
- [ ] `on-task-completed.sh` hook invalidates import graph entries for modified source files
- [ ] `on-stop.sh` hook marks import graph stale when new source files are created
- [ ] Incremental invalidation uses `import_graph_invalidate_file` from PLANOPT-1
- [ ] Hook integration is non-fatal (errors logged, never blocks the loop)
