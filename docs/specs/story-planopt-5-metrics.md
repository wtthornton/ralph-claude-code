# Story RALPH-PLANOPT-5: Optimization Metrics and Logging

**Epic:** [Plan Optimization on Startup](epic-plan-optimization.md)
**Priority:** Normal
**Status:** Not Started
**Effort:** Small
**Component:** `lib/plan_optimizer.sh`, `lib/metrics.sh`

---

## Problem

Without visibility into what the optimizer changed and whether it helped, there's no way
to validate the feature is working or tune the heuristics. Operators need to see:

- What was reordered and why
- How many tasks were moved
- Whether optimization is running or being skipped
- Long-term: whether optimized plans result in fewer loops

## Solution

Add lightweight logging and optional metrics to the plan optimizer.

### 1. Optimization log

Write a summary to `ralph.log` when optimization runs:

```
[2026-03-22 14:30:01] PLAN_OPTIMIZE: 12 unchecked tasks across 3 sections
[2026-03-22 14:30:01] PLAN_OPTIMIZE: Reordered 8 tasks (4 unchanged)
[2026-03-22 14:30:01] PLAN_OPTIMIZE: Moves: 3 dependency, 4 module-group, 1 size-cluster
[2026-03-22 14:30:01] PLAN_OPTIMIZE: Completed in 0.3s
```

### 2. Optimization diff

Write before/after task order to `.ralph/.plan_optimize_diff` for debugging:

```
## High Priority (5 tasks, 3 moved)
  KEPT:  1. Create user schema (src/db)
  MOVED: 2. Rename db constant (src/db)         [was #5, reason: module-group]
  MOVED: 3. Add user endpoint (src/api)          [was #1, reason: dependency]
  KEPT:  4. Add error handling (src/api)
  MOVED: 5. Fix config typo (config)             [was #3, reason: size-cluster]
```

### 3. Metrics integration

If `lib/metrics.sh` is available (Phase 8), append an optimization event to the
monthly JSONL metrics file:

```json
{"ts":"2026-03-22T14:30:01Z","event":"plan_optimize","tasks_total":12,"tasks_moved":8,"sections":3,"duration_ms":300}
```

### 4. Skip logging

When optimization is skipped (hash match), log minimally:

```
[2026-03-22 14:30:01] PLAN_OPTIMIZE: Skipped (plan unchanged since last optimization)
```

## Implementation

```bash
plan_log_optimization() {
    local fix_plan="$1"
    local before_order="$2"  # JSON array of line_nums in original order
    local after_order="$3"   # JSON array of line_nums in optimized order
    local duration_ms="$4"
    local ralph_log="${RALPH_DIR:-$(dirname "$fix_plan")}/ralph.log"
    local diff_file="${RALPH_DIR:-$(dirname "$fix_plan")}/.plan_optimize_diff"

    local total=$(echo "$after_order" | jq 'length')
    local moved=$(diff <(echo "$before_order" | jq -r '.[]') <(echo "$after_order" | jq -r '.[]') | grep -c '^[<>]' || echo 0)
    moved=$((moved / 2))  # diff counts both < and > for each move

    # Log to ralph.log
    local ts=$(date '+%Y-%m-%d %H:%M:%S')
    echo "[$ts] PLAN_OPTIMIZE: $total unchecked tasks, $moved moved, ${duration_ms}ms" >> "$ralph_log"

    # Write diff file
    # ... (build before/after comparison with move reasons)

    # Metrics (if available)
    if [[ -f "${RALPH_DIR}/metrics.sh" ]] || type ralph_record_metric &>/dev/null; then
        ralph_record_metric "plan_optimize" \
            "tasks_total=$total" \
            "tasks_moved=$moved" \
            "duration_ms=$duration_ms"
    fi
}
```

## Test Plan

```bash
# tests/unit/test_plan_metrics.bats

@test "PLANOPT-5: optimization logs to ralph.log" {
    setup_ralph_project
    run_optimization
    grep -q "PLAN_OPTIMIZE" .ralph/ralph.log
}

@test "PLANOPT-5: diff file shows moved tasks" {
    setup_ralph_project
    run_optimization_with_moves
    [[ -f .ralph/.plan_optimize_diff ]]
    grep -q "MOVED" .ralph/.plan_optimize_diff
}

@test "PLANOPT-5: skip logs when plan unchanged" {
    setup_ralph_project
    run_optimization  # First run
    run_optimization  # Second run (no changes)
    grep -q "Skipped" .ralph/ralph.log
}

@test "PLANOPT-5: metrics event recorded" {
    setup_ralph_project
    source lib/metrics.sh 2>/dev/null || skip "metrics not available"
    run_optimization
    grep -q "plan_optimize" .ralph/metrics/*.jsonl
}
```

## Acceptance Criteria

- [ ] Optimization summary logged to ralph.log (task count, moves, duration)
- [ ] Diff file written showing before/after with move reasons
- [ ] Skip events logged when hash matches
- [ ] Metrics integration when lib/metrics.sh is available
- [ ] Logging does not add > 100ms overhead
- [ ] Diff file is overwritten each run (not appended — keeps it small)
