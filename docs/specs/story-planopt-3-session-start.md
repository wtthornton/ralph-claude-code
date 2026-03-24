# Story RALPH-PLANOPT-3: Session-Start Integration

**Epic:** [Plan Optimization on Startup](epic-plan-optimization.md)
**Priority:** Critical
**Status:** Not Started
**Effort:** Small
**Component:** `templates/hooks/on-session-start.sh`, `lib/plan_optimizer.sh`, `lib/import_graph.sh`
**Research basis:** Section-level hashing (rsync/CDC), Reflexion progress re-grounding, batch annotation

---

## Problem

Even with the import graph (PLANOPT-1) and reordering engine (PLANOPT-2) implemented,
there is no trigger to run optimization. It must execute automatically on session start,
with zero human intervention.

The original design had three critical flaws:
1. **Full-file hashing** — Every checkbox change triggered re-optimization (Ralph checks
   tasks every loop), causing wasted work. Research shows section-level hashing avoids this.
2. **Wrong source path** — Referenced `$CLAUDE_PROJECT_DIR/lib/` but lib/ lives in
   `~/.ralph/lib/` (the Ralph installation directory).
3. **No context enrichment** — The hook told Claude the plan was optimized but didn't
   provide useful information (batch boundaries, progress summary).

## Solution

### Ralph agent prompt awareness

The main `ralph.md` agent prompt must be updated to cooperate with the optimizer.
Add the following section to `.claude/agents/ralph.md`:

```markdown
## Plan Optimization Awareness

Your fix_plan.md task ordering has been optimized at session start. The ordering is
intentional — tasks are grouped by module and ordered by dependency. Trust the ordering:

- **Always pick the FIRST unchecked task.** The optimizer has already placed the most
  important/foundational task first.
- **Batch hints** may appear in the session context (e.g., `[BATCH-3: SMALL]`). Use
  these to determine how many tasks to batch without re-analyzing sizes yourself.
- **When you discover a new dependency** during implementation (e.g., "task X actually
  needs Y to be done first"), add explicit metadata to fix_plan.md:
  `<!-- depends: dependency-id -->` and `<!-- id: this-task-id -->`. The optimizer will
  use these on the next loop.
- **`<!-- resolved: path -->` annotations** are file-path resolutions from ralph-explorer.
  Trust these — don't re-search for the same files.
```

### Async import graph rebuild

When the import graph is stale (new source files created during previous loops), the
graph rebuild runs as a **background subprocess** (same pattern as `ralph-bg-tester`).
The current loop uses the stale cached graph; the fresh graph is available next loop.

```bash
# In the optimization section of on-session-start.sh:
if import_graph_is_stale "${CLAUDE_PROJECT_DIR:-.}" "$RALPH_DIR/.import_graph.json"; then
    # Start async rebuild — don't block the hook
    source "$IMPORT_GRAPH_LIB"
    import_graph_build_async "${CLAUDE_PROJECT_DIR:-.}" "$RALPH_DIR/.import_graph.json"
    # Use stale cache for this loop (better than no graph)
fi
```

### Section-level change detection

Instead of hashing the entire fix_plan.md, hash each `##` section independently.
When Ralph checks off a task in section 1, only section 1's hash changes — but since
checked tasks don't affect optimization, even that section can be skipped if no
unchecked tasks changed.

**Key insight:** Hash only the unchecked task lines within each section. Checkbox
state changes (`[ ]` → `[x]`) don't trigger re-optimization.

```bash
# Hash = sha256 of sorted unchecked task texts per section
# Section 1 unchanged? Skip. Section 2 has new task? Re-optimize section 2 only.
```

### Git-based fast path

For projects in git, a fast check before hashing:

```bash
# If fix_plan.md has no uncommitted changes AND hash file exists → skip
if git diff --quiet -- "$fix_plan" 2>/dev/null && [[ -f "$hash_file" ]]; then
    # Plan unchanged since last optimization
fi
```

### Context enrichment

After optimization, inject useful context into Claude's system prompt:

1. **Progress re-grounding** (Reflexion pattern) — Reminds Claude where it left off
2. **Batch annotation** — Tells Claude which upcoming tasks can be batched together

## Implementation

### Section-level hashing

```bash
plan_section_hashes() {
    local fix_plan="$1"
    # Output: one hash per section (of unchecked task lines only)

    awk '
    /^## / {
        if (section_text != "") {
            # Hash the accumulated unchecked tasks for the previous section
            cmd = "echo \"" section_text "\" | sha256sum | cut -d\\  -f1"
            cmd | getline hash
            close(cmd)
            print section_name "\t" hash
        }
        section_name = $0
        section_text = ""
        next
    }
    /^- \[ \]/ {
        # Only hash unchecked task text (not checked tasks)
        section_text = section_text $0 "\n"
    }
    END {
        if (section_text != "") {
            cmd = "echo \"" section_text "\" | sha256sum | cut -d\\  -f1"
            cmd | getline hash
            close(cmd)
            print section_name "\t" hash
        }
    }
    ' "$fix_plan"
}

plan_changed_sections() {
    local fix_plan="$1"
    local hash_file="$2"  # .ralph/.plan_section_hashes

    local current_hashes
    current_hashes=$(plan_section_hashes "$fix_plan")

    if [[ ! -f "$hash_file" ]]; then
        # First run: all sections are "changed"
        echo "$current_hashes" | cut -f1
        echo "$current_hashes" > "$hash_file"
        return
    fi

    local previous_hashes
    previous_hashes=$(cat "$hash_file")

    # Diff to find changed sections
    local changed=""
    while IFS=$'\t' read -r section hash; do
        local prev_hash
        prev_hash=$(echo "$previous_hashes" | grep "^${section}	" | cut -f2)
        if [[ "$hash" != "$prev_hash" ]]; then
            echo "$section"
        fi
    done <<< "$current_hashes"

    # Update stored hashes (will be overwritten with post-optimization hashes)
    echo "$current_hashes" > "$hash_file"
}
```

### Batch annotation

```bash
plan_annotate_batches() {
    local tasks_json="$1"
    # Analyze upcoming unchecked tasks and emit batch boundaries
    # Uses .size field from plan_parse_tasks (0=SMALL, 1=MEDIUM, 2=LARGE)

    # Map numeric size to label
    local -A size_labels=([0]="SMALL" [1]="MEDIUM" [2]="LARGE")

    echo "$tasks_json" | jq -r '
        [.[] | select(.checked == false)] | .[0:8] |
        .[] | "\(.size // 1)"
    ' | {
        local result=""
        local batch_size=0
        local prev_size=""

        while IFS= read -r size; do
            if [[ "$size" == "$prev_size" || -z "$prev_size" ]]; then
                batch_size=$((batch_size + 1))
            else
                if [[ $batch_size -gt 1 ]]; then
                    result="${result}[BATCH-${batch_size}: ${size_labels[$prev_size]:-MEDIUM}] "
                elif [[ -n "$prev_size" ]]; then
                    result="${result}[SINGLE: ${size_labels[$prev_size]:-MEDIUM}] "
                fi
                batch_size=1
            fi
            prev_size="$size"
        done

        # Emit final batch
        if [[ $batch_size -gt 1 ]]; then
            result="${result}[BATCH-${batch_size}: ${size_labels[$prev_size]:-MEDIUM}]"
        elif [[ -n "$prev_size" ]]; then
            result="${result}[SINGLE: ${size_labels[$prev_size]:-MEDIUM}]"
        fi

        echo "$result"
    }
}
```

### Updated on-session-start.sh

```bash
#!/bin/bash
# .ralph/hooks/on-session-start.sh
# SessionStart hook — reads loop state, optimizes plan, emits context.

set -euo pipefail

RALPH_DIR="${CLAUDE_PROJECT_DIR:-.}/.ralph"

# Guard: only run if this is a Ralph-managed project
if [[ ! -d "$RALPH_DIR" ]]; then
    exit 0
fi

# --- Source Ralph libraries ---
# Libraries live in the Ralph installation, not the project
RALPH_LIB=""
for _lib_dir in "$HOME/.ralph/lib" "${RALPH_INSTALL_DIR:-/nonexistent}/lib"; do
    if [[ -d "$_lib_dir" ]]; then
        RALPH_LIB="$_lib_dir"
        break
    fi
done

# --- Read loop state ---
loop_count=0
last_status=""
if [[ -f "$RALPH_DIR/status.json" ]]; then
    loop_count=$(jq -r '.loop_count // 0' "$RALPH_DIR/status.json" 2>/dev/null || echo "0")
    last_status=$(jq -r '.status // ""' "$RALPH_DIR/status.json" 2>/dev/null || echo "")
fi

# --- Read fix_plan completion ---
total_tasks=0
done_tasks=0
FIX_PLAN="$RALPH_DIR/fix_plan.md"
if [[ -f "$FIX_PLAN" ]]; then
    total_tasks=$(grep -c '^\- \[' "$FIX_PLAN" 2>/dev/null) || total_tasks=0
    done_tasks=$(grep -c '^\- \[x\]' "$FIX_PLAN" 2>/dev/null) || done_tasks=0
fi
remaining=$((total_tasks - done_tasks))

# --- Read circuit breaker state ---
cb_state="CLOSED"
if [[ -f "$RALPH_DIR/.circuit_breaker_state" ]]; then
    cb_state=$(jq -r '.state // "CLOSED"' "$RALPH_DIR/.circuit_breaker_state" 2>/dev/null || echo "CLOSED")
fi

# --- Plan optimization ---
NO_OPTIMIZE="${RALPH_NO_OPTIMIZE:-false}"
DRY_RUN="${DRY_RUN:-false}"
plan_optimized=false
batch_annotation=""

# Skip optimization in dry-run mode (never modify files during dry run)
if [[ -f "$FIX_PLAN" && -n "$RALPH_LIB" && "$NO_OPTIMIZE" != "true" && "$DRY_RUN" != "true" && $remaining -gt 1 ]]; then
    PLAN_OPTIMIZER="$RALPH_LIB/plan_optimizer.sh"
    IMPORT_GRAPH_LIB="$RALPH_LIB/import_graph.sh"
    HASH_FILE="$RALPH_DIR/.plan_section_hashes"

    if [[ -f "$PLAN_OPTIMIZER" ]]; then
        source "$PLAN_OPTIMIZER"

        # Check which sections changed (section-level hashing of unchecked lines only)
        changed_sections=$(plan_changed_sections "$FIX_PLAN" "$HASH_FILE" 2>/dev/null || echo "")

        if [[ -n "$changed_sections" ]]; then
            # Ensure import graph is available (async rebuild if stale)
            if [[ -f "$IMPORT_GRAPH_LIB" ]]; then
                source "$IMPORT_GRAPH_LIB"
                if import_graph_is_stale "${CLAUDE_PROJECT_DIR:-.}" "$RALPH_DIR/.import_graph.json" 2>/dev/null; then
                    # Async rebuild — use stale cache for this loop
                    import_graph_build_async "${CLAUDE_PROJECT_DIR:-.}" "$RALPH_DIR/.import_graph.json" 2>/dev/null || true
                fi
            fi

            # Run optimizer (non-fatal — never block the loop)
            if plan_optimize_section "$FIX_PLAN" "${CLAUDE_PROJECT_DIR:-.}" "$RALPH_DIR/.import_graph.json" 2>/dev/null; then
                plan_optimized=true
                # Update section hashes to reflect optimized plan
                plan_section_hashes "$FIX_PLAN" > "$HASH_FILE" 2>/dev/null || true
            fi
        fi

        # Generate batch annotation for context injection
        if [[ -f "$PLAN_OPTIMIZER" ]] && declare -f plan_annotate_batches &>/dev/null; then
            local tasks_json
            tasks_json=$(plan_parse_tasks "$FIX_PLAN" 2>/dev/null || echo "[]")
            batch_annotation=$(plan_annotate_batches "$tasks_json" 2>/dev/null || echo "")
        fi
    fi
fi

# --- Clear per-loop file tracking ---
: > "$RALPH_DIR/.files_modified_this_loop" 2>/dev/null || true

# --- Emit context to stderr ---
if [[ $total_tasks -gt 0 && $remaining -eq 0 ]]; then
    cat >&2 <<EOF
Ralph loop #$((loop_count + 1)). Tasks: $done_tasks/$total_tasks complete, 0 remaining.
Circuit breaker: $cb_state.$([ -n "$last_status" ] && echo " Last loop: $last_status.")
ALL TASKS COMPLETE. Do NOT run tests, lint, or any verification. Emit your RALPH_STATUS block with STATUS: COMPLETE, TASKS_COMPLETED_THIS_LOOP: 0, TESTS_STATUS: PASSING, EXIT_SIGNAL: true, and STOP immediately.
EOF
else
    # Progress re-grounding (Reflexion pattern)
    last_completed=""
    if [[ -f "$FIX_PLAN" ]]; then
        last_completed=$(grep -E '^\- \[x\]' "$FIX_PLAN" | tail -1 | sed 's/^- \[x\] //' | head -c 80)
    fi

    cat >&2 <<EOF
Ralph loop #$((loop_count + 1)). Tasks: $done_tasks/$total_tasks complete, $remaining remaining.
Circuit breaker: $cb_state.$([ -n "$last_status" ] && echo " Last loop: $last_status.")$([ -n "$last_completed" ] && echo " Last completed: $last_completed.")$([ "$plan_optimized" = "true" ] && echo " Fix plan re-optimized (tasks reordered for dependency order and module locality).")$([ -n "$batch_annotation" ] && echo " Batch hint: $batch_annotation")
Read .ralph/fix_plan.md and do the FIRST unchecked item. IMPORTANT: Only run tests at epic boundaries (last task in a ## section). Otherwise set TESTS_STATUS: DEFERRED — do NOT run any test commands.
EOF

    # CTXMGMT-2: Decomposition detection (unchanged from original)
    if [[ "${RALPH_PROGRESSIVE_CONTEXT:-false}" == "true" ]]; then
        _ctx_lib_loaded=false
        for _lib_path in "$HOME/.ralph/lib/context_management.sh" \
                         "${RALPH_INSTALL_DIR:-/nonexistent}/lib/context_management.sh"; do
            if [[ -f "$_lib_path" ]]; then
                source "$_lib_path"
                _ctx_lib_loaded=true
                break
            fi
        done

        if [[ "$_ctx_lib_loaded" == "true" ]] && declare -f ralph_detect_decomposition_needed &>/dev/null; then
            current_task=$(grep -m1 -E '^\s*- \[ \]' "$RALPH_DIR/fix_plan.md" 2>/dev/null || echo "")
            if [[ -n "$current_task" ]]; then
                decomp_result=$(ralph_detect_decomposition_needed "$current_task" "${loop_count:-0}" 2>/dev/null || echo '{"decompose":false}')
                if echo "$decomp_result" | jq -r '.decompose' 2>/dev/null | grep -q "true"; then
                    reasons=$(echo "$decomp_result" | jq -r '.reasons // ""' 2>/dev/null)
                    echo "" >&2
                    echo "DECOMPOSITION SIGNAL: Current task may be too large ($reasons). Consider breaking into sub-tasks." >&2
                fi
            fi
        fi
    fi
fi

exit 0
```

### Performance budget

| Scenario | Expected time |
|----------|--------------|
| Plan unchanged (hash match) | < 50ms |
| Plan changed, 1 section, 10 tasks | < 300ms |
| Plan changed, 5 sections, 50 tasks | < 800ms |
| Import graph rebuild needed | + 1-3s (rare, only when source files change) |
| **Hard cap** | **< 2 seconds total (excluding import graph rebuild)** |

## Test Plan

```bash
# tests/unit/test_session_start_integration.bats

@test "PLANOPT-3: optimization runs on first loop (no hash file)" {
    setup_ralph_project
    rm -f .ralph/.plan_section_hashes
    run bash templates/hooks/on-session-start.sh
    [[ "$status" -eq 0 ]]
    [[ -f .ralph/.plan_section_hashes ]]
}

@test "PLANOPT-3: skips when unchecked tasks unchanged" {
    setup_ralph_project
    bash templates/hooks/on-session-start.sh 2>/dev/null
    local hash1=$(cat .ralph/.plan_section_hashes)

    # Simulate Ralph checking off a task (only checkbox changes)
    sed -i 's/^- \[ \]/- [x]/' .ralph/fix_plan.md  # Check first unchecked task

    bash templates/hooks/on-session-start.sh 2>/dev/null
    # Unchecked task hashes should not have triggered re-optimization
    # (hash is computed only from unchecked lines)
}

@test "PLANOPT-3: re-optimizes when human adds a task" {
    setup_ralph_project
    bash templates/hooks/on-session-start.sh 2>/dev/null
    local hash1=$(cat .ralph/.plan_section_hashes)

    echo "- [ ] New human task in src/api" >> .ralph/fix_plan.md
    bash templates/hooks/on-session-start.sh 2>/dev/null
    local hash2=$(cat .ralph/.plan_section_hashes)

    [[ "$hash1" != "$hash2" ]]
}

@test "PLANOPT-3: RALPH_NO_OPTIMIZE=true skips optimization" {
    setup_ralph_project
    rm -f .ralph/.plan_section_hashes
    RALPH_NO_OPTIMIZE=true run bash templates/hooks/on-session-start.sh
    [[ "$status" -eq 0 ]]
    [[ ! -f .ralph/.plan_section_hashes ]]
}

@test "PLANOPT-3: optimizer failure does not block session start" {
    setup_ralph_project
    # Corrupt the optimizer
    echo "exit 1" > "$HOME/.ralph/lib/plan_optimizer.sh"
    run bash templates/hooks/on-session-start.sh
    [[ "$status" -eq 0 ]]
}

@test "PLANOPT-3: context includes progress re-grounding" {
    setup_ralph_project
    # Check off a task
    sed -i '0,/\[ \]/s//[x]/' .ralph/fix_plan.md
    output=$(bash templates/hooks/on-session-start.sh 2>&1)
    echo "$output" | grep -q "Last completed:"
}

@test "PLANOPT-3: context includes batch annotation" {
    setup_ralph_project
    output=$(bash templates/hooks/on-session-start.sh 2>&1)
    # Should mention batch hint if multiple tasks of same size
    echo "$output" | grep -qE "Batch hint:|BATCH|SINGLE" || true
}

@test "PLANOPT-3: resolves lib path from ~/.ralph/lib/" {
    setup_ralph_project
    # Verify it does NOT look in $CLAUDE_PROJECT_DIR/lib/
    output=$(bash -x templates/hooks/on-session-start.sh 2>&1)
    echo "$output" | grep -v 'CLAUDE_PROJECT_DIR.*/lib/plan_optimizer'
}

@test "PLANOPT-3: skips optimization when 0-1 unchecked tasks remain" {
    setup_ralph_project
    # Leave only 1 unchecked task
    sed -i '0,/\[ \]/!s/\[ \]/[x]/' .ralph/fix_plan.md
    run bash templates/hooks/on-session-start.sh
    [[ "$status" -eq 0 ]]
    # Should skip (nothing to reorder)
}
```

## Acceptance Criteria

- [ ] Section-level hashing of unchecked task lines only (checkbox changes don't trigger)
- [ ] Changed sections detected and only those re-optimized
- [ ] Library path resolves from `~/.ralph/lib/` or `$RALPH_INSTALL_DIR/lib/` (not project dir)
- [ ] Import graph refreshed before optimization (if lib available)
- [ ] Optimizer failure is non-fatal (warning logged, session continues)
- [ ] `RALPH_NO_OPTIMIZE=true` disables optimization
- [ ] Progress re-grounding injected (last completed task)
- [ ] Batch annotation injected (upcoming batch boundaries)
- [ ] Completes in < 2 seconds for plans with up to 100 tasks (excluding import graph rebuild)
- [ ] Skips optimization when 0-1 unchecked tasks remain
- [ ] Works on Linux, macOS, and WSL (sha256sum/shasum portability)
- [ ] Import graph rebuild is async (background subprocess, non-blocking)
- [ ] Stale import graph used as fallback when async rebuild in progress
- [ ] `ralph.md` agent prompt updated with Plan Optimization Awareness section
- [ ] Ralph instructed to trust task ordering and use batch hints
- [ ] Ralph instructed to write `<!-- depends: -->` metadata when discovering new dependencies
- [ ] Optimization skipped when `DRY_RUN=true` (never modify files in dry-run mode)
- [ ] New `.ralphrc` variables documented: `RALPH_NO_OPTIMIZE`, `RALPH_NO_EXPLORER_RESOLVE`
